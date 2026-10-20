import AVFoundation
import CoreMedia
import SwiftUI
import AppKit

// Annex-B H.264 / HEVC → CMSampleBuffer → AVSampleBufferDisplayLayer.
// The display layer decodes through VideoToolbox internally; we only have to hand it
// length-prefixed (AVCC/HVCC) access units together with a format description built
// from the stream's in-band parameter sets.

final class VideoRenderer: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    var onFirstFrame: (() -> Void)?
    var onDimensions: ((Int, Int) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "aqara.video.render", qos: .userInteractive)
    private var formatDesc: CMFormatDescription?
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var isHEVC = false
    private var waitingForKeyframe = true
    private var framesEnqueued = 0
    private var lastDims = (0, 0)

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    func push(_ frame: VideoFrame) {
        queue.async { self.process(frame) }
    }

    /// After a reassembly gap or a decode failure: drop everything until the next IDR.
    func resync() {
        queue.async { self.waitingForKeyframe = true }
    }

    func flush() {
        queue.async {
            self.layer.flush()
            self.waitingForKeyframe = true
            self.formatDesc = nil
            self.sps = nil; self.pps = nil; self.vps = nil
            self.framesEnqueued = 0
        }
    }

    // MARK: - Annex-B parsing

    /// Byte ranges of each NAL unit (start codes excluded). Trailing zero bytes that
    /// belong to a following 4-byte start code are trimmed (a NAL never ends in 0x00).
    static func splitAnnexB(_ d: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let n = d.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start && d[end - 1] == 0 { end -= 1 }
                    if end > start { ranges.append(start..<end) }
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0 && start < n {
            var end = n
            while end > start && d[end - 1] == 0 { end -= 1 }
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    private func process(_ frame: VideoFrame) {
        let hevc = frame.codecId == 0x004F
        if hevc != isHEVC {
            isHEVC = hevc
            formatDesc = nil
            sps = nil; pps = nil; vps = nil
        }

        let d = frame.annexB
        var access: [UInt8] = []
        access.reserveCapacity(d.count + 32)
        var hasIDR = false
        var paramsChanged = false

        for r in Self.splitAnnexB(d) {
            let nal = Array(d[r])
            guard let first = nal.first else { continue }
            if hevc {
                let t = (first >> 1) & 0x3f
                switch t {
                case 32: if vps != nal { vps = nal; paramsChanged = true }
                case 33: if sps != nal { sps = nal; paramsChanged = true }
                case 34: if pps != nal { pps = nal; paramsChanged = true }
                case 35: continue   // AUD
                default:
                    if t >= 16 && t <= 21 { hasIDR = true }
                    appendLengthPrefixed(&access, nal)
                }
            } else {
                let t = first & 0x1f
                switch t {
                case 7: if sps != nal { sps = nal; paramsChanged = true }
                case 8: if pps != nal { pps = nal; paramsChanged = true }
                case 9, 12: continue   // AUD, filler
                default:
                    if t == 5 { hasIDR = true }
                    appendLengthPrefixed(&access, nal)
                }
            }
        }

        if paramsChanged { formatDesc = nil }
        if formatDesc == nil { formatDesc = makeFormatDescription() }
        guard let fd = formatDesc else { return }   // no parameter sets yet: wait for the IDR that carries them

        let keyframe = hasIDR || frame.isKeyframe
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }
        guard !access.isEmpty else { return }

        if layer.status == .failed {
            onLog?("display layer failed: \(layer.error?.localizedDescription ?? "?"), flushing")
            layer.flush()
            waitingForKeyframe = true
            if !keyframe { return }
        }

        guard let sample = makeSampleBuffer(access, format: fd, ptsMs: frame.timestampMs, keyframe: keyframe) else { return }
        layer.enqueue(sample)
        framesEnqueued += 1

        if framesEnqueued == 1 { onFirstFrame?() }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let wh = (Int(dims.width), Int(dims.height))
        if wh != lastDims { lastDims = wh; onDimensions?(wh.0, wh.1) }
    }

    @inline(__always) private func appendLengthPrefixed(_ out: inout [UInt8], _ nal: [UInt8]) {
        let n = UInt32(nal.count)
        out.append(UInt8((n >> 24) & 0xff)); out.append(UInt8((n >> 16) & 0xff))
        out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff))
        out.append(contentsOf: nal)
    }

    // MARK: - CoreMedia plumbing

    private func makeFormatDescription() -> CMFormatDescription? {
        guard let sps, let pps else { return nil }
        var fd: CMFormatDescription?
        var status: OSStatus = -1
        if isHEVC {
            guard let vps else { return nil }
            vps.withUnsafeBufferPointer { v in
                sps.withUnsafeBufferPointer { s in
                    pps.withUnsafeBufferPointer { p in
                        var ptrs: [UnsafePointer<UInt8>] = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
                        var sizes: [Int] = [v.count, s.count, p.count]
                        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 3,
                            parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                    }
                }
            }
        } else {
            sps.withUnsafeBufferPointer { s in
                pps.withUnsafeBufferPointer { p in
                    var ptrs: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                    var sizes: [Int] = [s.count, p.count]
                    status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                }
            }
        }
        if status != noErr {
            onLog?("format description failed (\(isHEVC ? "HEVC" : "H.264")): OSStatus \(status)")
            return nil
        }
        return fd
    }

    private func makeSampleBuffer(_ bytes: [UInt8], format: CMFormatDescription, ptsMs: UInt64, keyframe: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard st == kCMBlockBufferNoErr, let bb = block else { return nil }
        st = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard st == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMs), timescale: 1000),
            decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sb = sample else { return nil }

        // Live view: render as soon as decoded rather than scheduling against a timebase.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !keyframe {
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }
}

// MARK: - SwiftUI host

/// NSView hosting an AVSampleBufferDisplayLayer so the popover can show live video.
final class VideoHostView: NSView {
    private weak var display: AVSampleBufferDisplayLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(_ l: AVSampleBufferDisplayLayer) {
        guard display !== l else { return }
        display?.removeFromSuperlayer()
        l.videoGravity = .resizeAspectFill
        l.backgroundColor = NSColor.black.cgColor
        l.frame = bounds
        layer?.addSublayer(l)
        display = l
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display?.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoHostView {
        let v = VideoHostView(frame: .zero)
        v.attach(layer)
        return v
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.attach(layer)
    }
}
