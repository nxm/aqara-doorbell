import Foundation

// Port of native/src/media/reassembler.{hpp,cpp} (AVIOReassembler).
//
// DRW channel payloads (channels 1/4/5 = video, 2 = audio) are a byte stream of
// 32-byte AVIO frame headers followed by their payloads, split arbitrarily across
// UDP datagrams. Frames are re-sequenced per channel, concatenated, and cut at
// header boundaries; video payloads are ChaCha20-decrypted (sparse NAL scheme)
// and converted to Annex-B, audio payloads to raw AAC ADTS.

struct VideoFrame {
    var annexB: [UInt8]
    var isKeyframe: Bool
    var width: UInt16
    var height: UInt16
    var codecId: UInt16        // 0x004E = H.264, 0x004F = HEVC, 0x0050 = also treated as video
    var timestampMs: UInt64
}

struct AudioFrame {
    var aacADTS: [UInt8]
    var timestampMs: UInt64
}

/// Not thread-safe by design (same as the C++): push packets from the single P2P receiver thread.
final class AVIOReassembler {
    var onVideo: ((VideoFrame) -> Void)?
    var onAudio: ((AudioFrame) -> Void)?
    var onKeyframeRequest: (() -> Void)?

    private var videoKey: [UInt8]
    private var audioKey: [UInt8]

    private final class ChannelState {
        var expectedSeq: Int = -1
        var reorderBuf: [UInt16: [UInt8]] = [:]
        var streamBuf: [UInt8] = []
        var pendingAudio: [UInt8] = []
        var pendingAudioExpected = 0
        var gapNotified = false
    }

    private var channels: [UInt8: ChannelState] = [:]
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private var vps: [UInt8] = []

    private(set) var packetsReceived: UInt64 = 0
    private(set) var packetsDuplicate: UInt64 = 0
    private(set) var sequenceGaps: UInt64 = 0
    private(set) var videoFrames: UInt64 = 0
    private(set) var audioFrames: UInt64 = 0
    private(set) var discardedBytes: UInt64 = 0
    private var lastAudioTsMs: UInt64 = 0

    private static let maxStreamBuffer = 4 * 1024 * 1024

    init(videoKey: [UInt8], audioKey: [UInt8]) {
        self.videoKey = Self.pad32(videoKey)
        self.audioKey = Self.pad32(audioKey)
    }

    private static func pad32(_ k: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<min(32, k.count) { out[i] = k[i] }
        return out
    }

    func setKeys(videoKey: [UInt8]?, audioKey: [UInt8]?) {
        if let v = videoKey { self.videoKey = Self.pad32(v) }
        if let a = audioKey { self.audioKey = Self.pad32(a) }
        reset()
    }

    func reset() {
        channels.removeAll()
        lastAudioTsMs = 0
    }

    // MARK: - Little-endian helpers

    @inline(__always) private static func u16le(_ d: [UInt8], _ i: Int) -> UInt16 {
        UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    @inline(__always) private static func u32le(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }

    @inline(__always) private static func hasAnnexBPrefix(_ d: [UInt8], _ off: Int, _ len: Int) -> Bool {
        if len < 3 || off + 3 > d.count { return false }
        if d[off] == 0 && d[off + 1] == 0 && d[off + 2] == 1 { return true }
        if len >= 4 && off + 4 <= d.count && d[off] == 0 && d[off + 1] == 0 && d[off + 2] == 0 && d[off + 3] == 1 { return true }
        return false
    }

    /// Video AVIO header: codec id in {0x4E,0x4F,0x50}, sane payload length (16 B .. 2 MiB).
    private static func isVideoHeaderSafe(_ d: [UInt8], _ off: Int, _ len: Int) -> Bool {
        if len < 32 { return false }
        let codec = u16le(d, off)
        if codec != 0x004E && codec != 0x004F && codec != 0x0050 { return false }
        let payloadLen = u32le(d, off + 28)
        return payloadLen >= 16 && payloadLen <= 2 * 1024 * 1024
    }

    /// Audio AVIO header: codec 0x0088, flags 0x000e (observed Aqara AAC), payload 9..4096 B.
    private static func isAudioHeaderSafe(_ d: [UInt8], _ off: Int, _ len: Int) -> Bool {
        if len < 32 || u16le(d, off) != 0x0088 { return false }
        if u16le(d, off + 2) != 0x000e { return false }
        let payloadLen = u32le(d, off + 28)
        if payloadLen <= 8 || payloadLen > 4096 { return false }
        return true
    }

    // MARK: - Sequencing

    private func recoverFromSequenceGap(_ channel: UInt8, _ state: ChannelState, nextSeq: UInt16) {
        sequenceGaps += 1
        discardedBytes += UInt64(state.streamBuf.count)
        state.streamBuf.removeAll(keepingCapacity: true)
        state.pendingAudio.removeAll()
        state.pendingAudioExpected = 0
        state.gapNotified = false
        state.expectedSeq = Int(nextSeq)
        onKeyframeRequest?()
    }

    private func drainReorderBuffer(_ channel: UInt8, _ state: ChannelState) {
        while true {
            let key = UInt16(truncatingIfNeeded: state.expectedSeq)
            guard let pkt = state.reorderBuf[key] else { break }
            handlePacketImmediate(channel, state, pkt)
            state.reorderBuf.removeValue(forKey: key)
            state.expectedSeq = Int(key &+ 1)
        }
    }

    func push(channel: UInt8, seq: UInt16, data: [UInt8]) {
        if data.isEmpty { return }
        packetsReceived += 1
        let state: ChannelState
        if let s = channels[channel] { state = s } else { state = ChannelState(); channels[channel] = state }

        if state.expectedSeq == -1 { state.expectedSeq = Int(seq) }

        let expected = UInt16(truncatingIfNeeded: state.expectedSeq)
        let diff = Int16(bitPattern: seq &- expected)
        if diff == 0 {
            handlePacketImmediate(channel, state, data)
            state.expectedSeq = Int(seq &+ 1)
            drainReorderBuffer(channel, state)
            if state.reorderBuf.isEmpty { state.gapNotified = false }
            return
        }

        if diff < 0 {
            packetsDuplicate += 1
            return
        }

        if diff < 64 {
            if !state.gapNotified {
                state.gapNotified = true
                onKeyframeRequest?()
            }
            if state.reorderBuf[seq] == nil { state.reorderBuf[seq] = data }
            if state.reorderBuf.count < 16 { return }

            // The missing datagram did not arrive within the jitter window. Never
            // concatenate later fragments onto a damaged frame: discard residue,
            // request an IDR, then resume at the nearest buffered sequence.
            var restartSeq = expected
            var bestDistance: UInt16 = 0xffff
            for k in state.reorderBuf.keys {
                let distance = k &- expected
                if distance < bestDistance { bestDistance = distance; restartSeq = k }
            }
            recoverFromSequenceGap(channel, state, nextSeq: restartSeq)
            drainReorderBuffer(channel, state)
            return
        }

        // Session reset or a jump larger than the reorder window.
        state.reorderBuf.removeAll()
        recoverFromSequenceGap(channel, state, nextSeq: seq)
        handlePacketImmediate(channel, state, data)
        state.expectedSeq = Int(seq &+ 1)
    }

    // MARK: - Byte stream assembly

    private func appendVideoBytes(_ channel: UInt8, _ state: ChannelState, _ d: [UInt8], _ off: Int, _ count: Int) {
        if count == 0 { return }
        if state.streamBuf.count + count > Self.maxStreamBuffer {
            discardedBytes += UInt64(state.streamBuf.count)
            state.streamBuf.removeAll(keepingCapacity: true)
            onKeyframeRequest?()
        }
        state.streamBuf.append(contentsOf: d[off..<(off + count)])
        parseStreamBuffer(channel, state)
    }

    private func handlePacketImmediate(_ channel: UInt8, _ state: ChannelState, _ d: [UInt8]) {
        var off = 0
        var len = d.count

        if !state.pendingAudio.isEmpty {
            let needed = state.pendingAudioExpected - state.pendingAudio.count
            let take = min(needed, len)
            state.pendingAudio.append(contentsOf: d[off..<(off + take)])
            off += take
            len -= take
            if state.pendingAudio.count < state.pendingAudioExpected { return }
            processCompletedAudio(state.pendingAudio)
            state.pendingAudio.removeAll()
            state.pendingAudioExpected = 0
        }

        // Audio does not necessarily begin at UDP offset zero. Aqara can finish a
        // video fragment and append a complete 0x0088 frame in the same DRW body,
        // or place audio between two fragments of one video frame. Peel every
        // strongly validated audio header before feeding the remaining bytes to
        // the video stream assembler.
        while len > 0 {
            var audioOffset = len
            var i = 0
            while i + 32 <= len {
                if Self.isAudioHeaderSafe(d, off + i, len - i) { audioOffset = i; break }
                i += 1
            }

            if audioOffset == len {
                appendVideoBytes(channel, state, d, off, len)
                return
            }

            appendVideoBytes(channel, state, d, off, audioOffset)
            off += audioOffset
            len -= audioOffset

            let audioLen = 32 + Int(Self.u32le(d, off + 28))
            if audioLen > len {
                state.pendingAudio = Array(d[off..<(off + len)])
                state.pendingAudioExpected = audioLen
                return
            }
            processCompletedAudio(Array(d[off..<(off + audioLen)]))
            off += audioLen
            len -= audioLen
        }
    }

    private func parseStreamBuffer(_ channel: UInt8, _ state: ChannelState) {
        while state.streamBuf.count >= 32 {
            let buf = state.streamBuf
            let size = buf.count

            if Self.isAudioHeaderSafe(buf, 0, size) {
                let frameLen = 32 + Int(Self.u32le(buf, 28))   // dataLen includes the 8 B nonce plus encrypted AAC
                if frameLen > size { return }
                processCompletedAudio(Array(buf[0..<frameLen]))
                state.streamBuf.removeFirst(frameLen)
                continue
            }

            if Self.isVideoHeaderSafe(buf, 0, size) {
                let frameLen = 32 + Int(Self.u32le(buf, 28))
                if frameLen > size { return }
                processCompletedAVIO(Array(buf[0..<frameLen]))
                state.streamBuf.removeFirst(frameLen)
                continue
            }

            // We may be resuming after a lost UDP datagram. Search for the next
            // complete header, but retain 31 trailing bytes so split headers survive.
            var next = 1
            while next + 32 <= size {
                if Self.isAudioHeaderSafe(buf, next, size - next) || Self.isVideoHeaderSafe(buf, next, size - next) { break }
                next += 1
            }
            if next + 32 > size {
                let drop = size - 31
                discardedBytes += UInt64(drop)
                state.streamBuf.removeFirst(drop)
                return
            }
            discardedBytes += UInt64(next)
            state.streamBuf.removeFirst(next)
        }
    }

    // MARK: - Frame completion

    private func processCompletedAudio(_ data: [UInt8]) {
        if data.count < 32 { return }
        let msPart = Self.u32le(data, 8)
        let sPart = Self.u32le(data, 12)
        let tsMs = UInt64(sPart) * 1000 + UInt64(msPart)

        // Deduplicate retransmitted / redundant audio frames
        if tsMs != 0 && tsMs == lastAudioTsMs { return }
        lastAudioTsMs = tsMs

        // Same preconditions under which ChaCha20::decrypt_audio_payload returns false.
        let payloadLen = Int(Self.u32le(data, 28))
        if data.count < 40 || payloadLen <= 8 || 32 + payloadLen > data.count { return }

        var frame = data
        ChaCha20.decryptAudio(&frame, key: audioKey)
        let audioLen = payloadLen - 8

        let af = AudioFrame(aacADTS: Array(frame[40..<(40 + audioLen)]), timestampMs: tsMs)
        audioFrames += 1
        onAudio?(af)
    }

    private func processCompletedAVIO(_ data: [UInt8]) {
        if data.count < 32 { return }

        let codecId = Self.u16le(data, 0)
        let avioKeyframe = (Self.u16le(data, 2) & 0x0001) != 0
        let msPart = Self.u32le(data, 8)
        let sPart = Self.u32le(data, 12)
        let tsMs = UInt64(sPart) * 1000 + UInt64(msPart)
        let width = Self.u16le(data, 16)
        let height = Self.u16le(data, 20)
        let payloadLen = Int(Self.u32le(data, 28))

        if 32 + payloadLen > data.count { return }

        var payload = Array(data[32..<(32 + payloadLen)])
        ChaCha20.decryptVideo(&payload, key: videoKey)
        if payload.isEmpty { return }

        let nalCount = payload.count >= 9 ? Int(payload[8]) : 0
        let tableEnd = 9 + nalCount * 8

        var annexB: [UInt8] = []
        annexB.reserveCapacity(payload.count + 64)
        let startCode: [UInt8] = [0, 0, 0, 1]

        if tableEnd <= payload.count && Self.hasAnnexBPrefix(payload, tableEnd, payload.count - tableEnd) {
            // Tail already has Annex-B start codes (typically IDR with SPS/PPS)
            annexB.append(contentsOf: payload[tableEnd...])
        } else if nalCount > 0 && tableEnd < payload.count {
            let tailOff = tableEnd
            let tailLen = payload.count - tableEnd

            let firstOff = Int(Self.u32le(payload, 9))
            if firstOff > 0 && firstOff < tailLen {
                // In-band parameter sets before first table entry
                if !Self.hasAnnexBPrefix(payload, tailOff, firstOff) { annexB.append(contentsOf: startCode) }
                annexB.append(contentsOf: payload[tailOff..<(tailOff + firstOff)])
            }

            for i in 0..<nalCount {
                let off = Int(Self.u32le(payload, 9 + i * 8))
                let nalLen = Int(Self.u32le(payload, 9 + i * 8 + 4))
                if nalLen == 0 || off + nalLen > tailLen { continue }
                let nalStart = tailOff + off
                if !Self.hasAnnexBPrefix(payload, nalStart, nalLen) { annexB.append(contentsOf: startCode) }
                annexB.append(contentsOf: payload[nalStart..<(nalStart + nalLen)])
            }
        } else {
            // Fallback
            if !Self.hasAnnexBPrefix(payload, 0, payload.count) { annexB.append(contentsOf: startCode) }
            annexB.append(contentsOf: payload)
        }

        if annexB.isEmpty { return }

        // Scan for SPS (type 7 / 33), PPS (type 8 / 34), VPS (type 32)
        var i = 0
        let isHEVC = (codecId == 0x004F)
        var foundIDR = avioKeyframe
        let n = annexB.count

        while i + 4 < n {
            var prefixLen = 0
            if annexB[i] == 0 && annexB[i + 1] == 0 && annexB[i + 2] == 1 { prefixLen = 3 }
            else if annexB[i] == 0 && annexB[i + 1] == 0 && annexB[i + 2] == 0 && annexB[i + 3] == 1 { prefixLen = 4 }

            if prefixLen > 0 {
                let nalStart = i + prefixLen
                var nextStart = n
                var j = nalStart
                while j + 3 < n {
                    if annexB[j] == 0 && annexB[j + 1] == 0 && (annexB[j + 2] == 1 || (annexB[j + 2] == 0 && annexB[j + 3] == 1)) {
                        nextStart = j
                        break
                    }
                    j += 1
                }
                let nalLen = nextStart - nalStart
                if nalLen > 0 {
                    let nalType = isHEVC ? ((annexB[nalStart] >> 1) & 0x3f) : (annexB[nalStart] & 0x1f)
                    if !isHEVC {
                        if nalType == 7 { sps = Array(annexB[nalStart..<nextStart]) }
                        else if nalType == 8 { pps = Array(annexB[nalStart..<nextStart]) }
                        else if nalType == 5 { foundIDR = true }
                    } else {
                        if nalType == 32 { vps = Array(annexB[nalStart..<nextStart]) }
                        else if nalType == 33 { sps = Array(annexB[nalStart..<nextStart]) }
                        else if nalType == 34 { pps = Array(annexB[nalStart..<nextStart]) }
                        else if nalType >= 19 && nalType <= 21 { foundIDR = true }
                    }
                }
                i = nextStart
            } else {
                i += 1
            }
        }

        if let cb = onVideo {
            videoFrames += 1
            cb(VideoFrame(annexB: annexB, isKeyframe: foundIDR, width: width, height: height,
                          codecId: codecId, timestampMs: tsMs))
        }
    }
}
