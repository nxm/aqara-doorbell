import Foundation
import AVFoundation

/// Captures the Mac mic, encodes to AAC-LC 16 kHz mono, wraps each frame in an
/// MPEG-2 ADTS header, and hands it to `onFrame` for P2P talkback transmission.
/// Target format matches TALKBACK_LEAD (0xFFF9 0x60… = MPEG-2 AAC-LC, 16 kHz, mono).
final class TalkbackSender {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let aacFormat: AVAudioFormat
    private var running = false
    var onFrame: (([UInt8]) -> Void)?

    init?() {
        guard let fmt = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]) else { return nil }
        aacFormat = fmt
    }

    /// Request mic permission then start capturing + encoding.
    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.begin() }
        }
    }

    private func begin() {
        guard !running else { return }
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)        // engine's native (e.g. 48 kHz float)
        guard inFmt.sampleRate > 0, let conv = AVAudioConverter(from: inFmt, to: aacFormat) else { return }
        converter = conv
        running = true

        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
            self?.encode(buf)
        }
        do { try engine.start() } catch { running = false }
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func encode(_ pcm: AVAudioPCMBuffer) {
        guard running, let conv = converter else { return }
        // AAC output: 1024 samples/frame @16k. Allocate a packet buffer.
        guard let out = AVAudioCompressedBuffer(format: aacFormat,
                                                packetCapacity: 8, maximumPacketSize: 768) as AVAudioCompressedBuffer? else { return }
        var supplied = false
        let status = conv.convert(to: out, error: nil) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return pcm
        }
        guard status != .error, out.packetCount > 0 else { return }

        // Split the compressed buffer into individual AAC packets → ADTS-wrap each.
        let data = Data(bytes: out.data, count: Int(out.byteLength))
        if let descs = out.packetDescriptions {
            for i in 0..<Int(out.packetCount) {
                let d = descs[i]
                let len = Int(d.mDataByteSize)
                let start = Int(d.mStartOffset)
                guard start + len <= data.count else { continue }
                emit(Array(data[start..<start + len]))
            }
        } else {
            emit(Array(data))        // no descriptions → whole buffer is one frame
        }
    }

    private func emit(_ rawAAC: [UInt8]) {
        guard !rawAAC.isEmpty else { return }
        let n = rawAAC.count + 7
        // MPEG-2 ADTS, AAC-LC (profile 01), freq_idx=8 (16 kHz), channel_cfg=1 (mono), no CRC.
        var adts: [UInt8] = [
            0xFF, 0xF9,
            0x60,                                   // profile=01 | freq=1000 | priv=0 | chan_hi=0
            UInt8(0x40 | ((n >> 11) & 0x03)),       // chan_lo=01 | frame_len[12:11]
            UInt8((n >> 3) & 0xFF),                 // frame_len[10:3]
            UInt8(((n & 0x07) << 5) | 0x1F),        // frame_len[2:0] | buffer_fullness hi
            0xFC,                                   // buffer_fullness lo | num_frames-1=0
        ]
        adts.append(contentsOf: rawAAC)
        onFrame?(adts)
    }
}
