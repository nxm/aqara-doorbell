import Foundation
import AVFoundation

/// Decodes incoming AAC-LC (16 kHz mono, ADTS-framed) audio frames from the camera
/// and plays them through the Mac speakers — the "hear the visitor" half of two-way.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let aacFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var started = false
    private let q = DispatchQueue(label: "aqara.audioplay")

    init?() {
        guard let aac = AVAudioFormat(settings: [
                  AVFormatIDKey: kAudioFormatMPEG4AAC,
                  AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000, channels: 1, interleaved: false)
        else { return nil }
        aacFormat = aac; pcmFormat = pcm
    }

    func setMuted(_ muted: Bool) {
        q.async { [weak self] in self?.player.volume = muted ? 0 : 1 }
    }

    func start() { q.sync { startOnQueue() } }

    private func startOnQueue() {
        guard !started else { return }
        converter = AVAudioConverter(from: aacFormat, to: pcmFormat)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        do { try engine.start(); player.play(); started = true } catch { started = false }
    }

    func stop() { q.sync { stopOnQueue() } }

    private func stopOnQueue() {
        guard started else { return }
        started = false
        player.stop(); engine.stop()
        engine.disconnectNodeOutput(player); engine.detach(player)
        converter = nil
    }

    /// Feed one AAC frame (ADTS-framed or raw).
    func play(_ frame: [UInt8]) {
        q.async { [weak self] in self?.decodeAndSchedule(frame) }
    }

    private func decodeAndSchedule(_ frame: [UInt8]) {
        guard started, let conv = converter, frame.count > 2 else { return }
        // Strip ADTS header if present (0xFFFx sync); protection_absent bit → 7-byte header.
        var raw = frame
        if frame[0] == 0xFF && (frame[1] & 0xF0) == 0xF0 {
            let hdr = (frame[1] & 0x01) == 1 ? 7 : 9
            guard frame.count > hdr else { return }
            raw = Array(frame[hdr...])
        }
        guard !raw.isEmpty,
              let comp = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: raw.count) as AVAudioCompressedBuffer?
        else { return }
        raw.withUnsafeBytes { comp.data.copyMemory(from: $0.baseAddress!, byteCount: raw.count) }
        comp.byteLength = UInt32(raw.count)
        comp.packetCount = 1
        comp.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(raw.count))

        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2048) else { return }
        var fed = false
        let st = conv.convert(to: out, error: nil) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true; s.pointee = .haveData; return comp
        }
        guard st != .error, out.frameLength > 0 else { return }
        player.scheduleBuffer(out, completionHandler: nil)
    }
}
