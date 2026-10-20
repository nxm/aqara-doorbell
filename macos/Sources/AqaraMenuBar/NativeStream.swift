import Foundation
import AVFoundation

// Native live-view orchestrator (replaces the Node/ffmpeg sidecar for video):
// cloud p2p/info + p2p/sign → X25519/HSalsa20 frame key → P2PClient → AVIOReassembler
// → VideoRenderer → AVSampleBufferDisplayLayer. Mirrors session.cpp's StreamSession,
// minus the RTSP server.

enum NativeLog {
    static let path = "/tmp/aqara-native.log"
    private static let queue = DispatchQueue(label: "aqara.native.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        print(line, terminator: "")
        queue.async {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

@MainActor
final class NativeStream {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let renderer: VideoRenderer
    private let cloud: AqaraCloud
    private let did: String

    /// 0x100E target after the first keyframe (session.cpp heuristic). nil disables the switch.
    var qualityChannel: Int? = 0
    var onStatus: ((String) -> Void)?
    var onVideoStarted: (() -> Void)?
    var onBitrate: ((Int) -> Void)?          // KB/s, emitted ~1×/s

    private let byteCounter = Locked(0)       // bytes received since last tick (video+audio)
    private var bitrateTimer: Timer?

    private var client: P2PClient?
    private var reassembler: AVIOReassembler?
    private let audio = AudioPlayer()
    func setMuted(_ muted: Bool) { audio?.setMuted(muted) }
    private var startTask: Task<Void, Never>?
    private(set) var active = false

    // Shared with the receiver thread (video callback) — same role as session.cpp's flags.
    private let qualityState = Locked((seenFirstKeyframe: false, switched: false))

    init(cloud: AqaraCloud, did: String) {
        self.cloud = cloud
        self.did = did
        self.renderer = VideoRenderer(layer: displayLayer)
    }

    func start() {
        guard !active else { return }
        active = true
        qualityState.value = (false, false)
        byteCounter.value = 0
        bitrateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let bytes = self.byteCounter.withLock { v -> Int in let x = v; v = 0; return x }
            self.onBitrate?(bytes / 1024)
        }
        startTask = Task { await run() }
    }

    func stop() {
        guard active else { return }
        active = false
        startTask?.cancel()
        startTask = nil
        bitrateTimer?.invalidate(); bitrateTimer = nil
        onBitrate?(0)
        audio?.stop()
        let c = client
        client = nil
        reassembler = nil
        renderer.flush()
        status("Stopped")
        // stop() joins the socket threads (≤ ~1s); keep that off the main thread.
        DispatchQueue.global(qos: .utility).async { c?.stop() }
    }

    func requestKeyframe() { client?.requestKeyframe() }

    private var talk: TalkbackSender?
    func startTalk() {
        guard let client, talk == nil else { return }
        client.startTalkback()
        let t = TalkbackSender()
        t?.onFrame = { [weak client] adts in client?.sendTalkbackFrame(adts) }
        t?.start()
        talk = t
        status("Talking…")
    }
    func stopTalk() {
        talk?.stop(); talk = nil
        client?.stopTalkback()
    }

    private func status(_ s: String) {
        NativeLog.write("[Native] " + s)
        onStatus?(s)
    }

    private func run() async {
        do {
            status("Fetching P2P info…")
            let info = try await cloud.p2pInfo(did: did)
            let (priv, pubHex) = P2PKeys.generate()
            status("Signing session key…")
            let sig = try await cloud.p2pSign(did: did, appPublicKeyHex: pubHex)
            let devPub = sig.p2pDevPublicKey.isEmpty ? info.devP2pPublicKey : sig.p2pDevPublicKey
            guard let vk = P2PKeys.frameKey(appPriv: priv, devPubHex: devPub) else {
                throw AqaraError.crypto("bad device public key: \(devPub)")
            }
            guard active, !Task.isCancelled else { return }
            NativeLog.write("[Native] p2pId=\(info.p2pId) signTime=\(sig.time) appPub=\(pubHex.prefix(8))… devPub=\(devPub.prefix(8))…")

            // vk == ak: the engine passes the same HSalsa20 key for both (bridge.ts).
            let reasm = AVIOReassembler(videoKey: vk, audioKey: vk)
            let cfg = P2PConfig(did: did, p2pId: info.p2pId, initString: info.initStringApp,
                                appPubHex: pubHex, appSign: sig.sign, signTime: sig.time, devPubHex: devPub)
            let client = P2PClient(config: cfg, reassembler: reasm) { [weak self] ev in
                Task { @MainActor in self?.handle(ev) }
            }

            let renderer = self.renderer
            let qualityState = self.qualityState
            let wantChannel = self.qualityChannel
            let did = self.did
            let byteCounter = self.byteCounter
            reasm.onVideo = { [weak client, weak self] vf in
                byteCounter.withLock { $0 += vf.annexB.count }
                renderer.push(vf)
                Self.maybeSwitchQuality(vf, did: did, want: wantChannel, state: qualityState, client: client)
                if vf.isKeyframe, let self {
                    Task { @MainActor in self.noteKeyframe(vf) }
                }
            }
            let audio = self.audio
            reasm.onAudio = { af in
                byteCounter.withLock { $0 += af.aacADTS.count }
                audio?.play(af.aacADTS)                    // hear the camera (incoming audio)
            }
            audio?.start()
            reasm.onKeyframeRequest = { [weak client] in
                renderer.resync()
                client?.requestKeyframe()
            }
            renderer.onFirstFrame = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.status("Live")
                    self.onVideoStarted?()
                }
            }
            renderer.onDimensions = { w, h in NativeLog.write("[Native] video \(w)x\(h)") }
            renderer.onLog = { s in NativeLog.write("[Render] " + s) }

            status("Connecting P2P…")
            guard client.start() else { throw AqaraError.badResponse("P2P socket start failed") }
            guard active else { client.stop(); return }
            self.client = client
            self.reassembler = reasm
        } catch {
            status("P2P failed: \(error)")
            active = false
        }
    }

    private var keyframeLogged = false
    private func noteKeyframe(_ vf: VideoFrame) {
        guard !keyframeLogged else { return }
        keyframeLogged = true
        NativeLog.write("[Native] first keyframe \(vf.width)x\(vf.height) codec=0x\(String(vf.codecId, radix: 16)) bytes=\(vf.annexB.count)")
    }

    /// session.cpp: once per session, after the first keyframe, upgrade the resolution via
    /// 0x100E if the camera is not already running at the ladder rung we asked for.
    nonisolated private static func maybeSwitchQuality(_ vf: VideoFrame, did: String, want: Int?,
                                                       state: Locked<(seenFirstKeyframe: Bool, switched: Bool)>,
                                                       client: P2PClient?) {
        guard let want else { return }
        let decision: Bool = state.withLock { s in
            if vf.isKeyframe && !s.seenFirstKeyframe { s.seenFirstKeyframe = true }
            guard vf.height > 0, !s.switched, s.seenFirstKeyframe else { return false }
            let h = Int(vf.height)
            var needsSwitch = false
            // The C++ keys this on the did string; "lumi3.*" dids (incl. the G410) take the G5 branch.
            let isG5 = did.contains("agl004") || did.contains("lumi3")
            if isG5 {
                // channel 3=1520p (max), 0=1080p (mid), 2=360p (low)
                if want == 3 && h < 1400 { needsSwitch = true }
                else if want == 0 && (h < 1000 || h > 1200) { needsSwitch = true }
                else if want == 2 && h > 500 { needsSwitch = true }
            } else {
                // channel 0=1296p (max), 1=1080p (mid), 2=360p (low)
                if want == 0 && h < 1200 { needsSwitch = true }
                else if want == 1 && (h < 900 || h > 1150) { needsSwitch = true }
                else if want == 2 && h > 500 { needsSwitch = true }
            }
            if needsSwitch { s.switched = true }
            return needsSwitch
        }
        if decision {
            NativeLog.write("[Native] camera at \(vf.width)x\(vf.height), desired channel \(want): sending 0x100E")
            client?.setQuality(want)
        }
    }

    private func handle(_ ev: P2PEvent) {
        switch ev {
        case .log(let s):
            NativeLog.write(s)
        case .connected(let ip, let port):
            status("Connected \(ip):\(port), logging in…")
        case .sessionReady:
            status("Session ready, waiting for video…")
        case .talkbackReady:
            status("Talkback ready")
        case .unhealthy:
            status("No video from camera (unhealthy)")
        }
    }
}
