import Foundation

// Default: run the menu-bar app. `cli` arg: run the cloud-validation CLI.
if CommandLine.arguments.contains("crypto-test") {
    runCryptoTest()
} else if let i = CommandLine.arguments.firstIndex(of: "selftest"), i + 1 < CommandLine.arguments.count {
    runSelfTest(dir: CommandLine.arguments[i + 1])
} else if CommandLine.arguments.contains("cli") {
    runCLI()
} else {
    MainActor.assumeIsolated { runMenuBarApp() }
}

func runCryptoTest() {
    // Decode a PPCS init string (from `camera/p2p/info`) into relay masters +
    // key. Provide your own device's value via AQARA_INITSTRING.
    if let initStr = ProcessInfo.processInfo.environment["AQARA_INITSTRING"] {
        if let r = PPCS.decodeInitString(initStr) {
            print("masters: \(r.masters)")
            print("key:     \(r.key)")
        } else {
            print("❌ decode failed")
        }
    } else {
        print("set AQARA_INITSTRING=<your device's PPCS init string> to decode it")
    }
    // HSalsa20 sanity: deterministic 32-byte output for a fixed input.
    let shared = [UInt8](repeating: 0x11, count: 32)
    let vk = HSalsa20.derive(shared)
    print("hsalsa20(0x11*32): \(vk.prefix(8).map { String(format: "%02x", $0) }.joined())…  len=\(vk.count)")
}

/// Offline conformance check against the vendor C++ (scratch harness): reads
/// `<dir>/vectors.txt`, writes `<dir>/framing_swift.txt` + `<dir>/reasm_swift.txt`
/// in the same format the C++ harness emits, for a byte-exact diff.
func runSelfTest(dir: String) {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // Framing (mirrors harness.cpp)
    var fr = ""
    let p2pId = ProcessInfo.processInfo.environment["AQARA_P2PID"] ?? "AQARADE-000000-XXXXX"
    fr += "punch \(hex(PPCS.punchPayload(p2pId)))\n"
    let json = "{\"timestamp\":\"1791834394747\",\"app_sign\":\"abcd\",\"app_public_key\":\"ef01\"}"
    let lumi = PPCS.buildLumiFrame(type: 0x1000, payload: Array(json.utf8), seq: 7)
    fr += "lumi \(hex(lumi))\n"
    var drw = [UInt8](repeating: 0, count: 4 + lumi.count)
    drw[0] = 0xD1; drw[1] = 0; drw[2] = 0x01; drw[3] = 0x02
    drw.replaceSubrange(4..., with: lumi)
    var pkt = PPCS.buildPPPP(0xD0, drw)
    fr += "drw_plain \(hex(pkt))\n"
    let k = Array("aqarager19kn".utf8)
    PPCS.encrypt(key: k, data: &pkt)
    fr += "drw_enc \(hex(pkt))\n"
    fr += "talkback \(hex(PPCS.buildTalkbackBody(P2PClient.talkbackLead)))\n"
    var hello = PPCS.buildPPPP(0x00, [])
    PPCS.encrypt(key: k, data: &hello)
    fr += "hello_enc \(hex(hello))\n"
    try? fr.write(toFile: dir + "/framing_swift.txt", atomically: true, encoding: .utf8)

    // Reassembler
    guard let vec = try? String(contentsOfFile: dir + "/vectors.txt", encoding: .utf8) else {
        print("no vectors.txt in \(dir)"); exit(1)
    }
    var key: [UInt8] = []
    var pkts: [(UInt8, UInt16, [UInt8])] = []
    for line in vec.split(separator: "\n") {
        let f = line.split(separator: " ")
        if f.first == "key" { key = hexToBytes(String(f[1])) }
        else if f.first == "pkt" { pkts.append((UInt8(f[1])!, UInt16(f[2])!, hexToBytes(String(f[3])))) }
    }
    var ex = ""
    let r = AVIOReassembler(videoKey: key, audioKey: key)
    var kfReq = 0
    r.onVideo = { vf in
        ex += "V kf=\(vf.isKeyframe ? 1 : 0) w=\(vf.width) h=\(vf.height) codec=\(vf.codecId) ts=\(vf.timestampMs) \(hex(vf.annexB))\n"
    }
    r.onAudio = { af in ex += "A ts=\(af.timestampMs) \(hex(af.aacADTS))\n" }
    r.onKeyframeRequest = { kfReq += 1; ex += "KF\n" }
    for p in pkts { r.push(channel: p.0, seq: p.1, data: p.2) }
    try? ex.write(toFile: dir + "/reasm_swift.txt", atomically: true, encoding: .utf8)

    // Annex-B splitter sanity (VideoRenderer): NAL ranges over a 3- and 4-byte start-code mix.
    let ab: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9, 9]
    let ranges = VideoRenderer.splitAnnexB(ab).map { Array(ab[$0]) }
    print("splitAnnexB: \(ranges.map(hex))  (expect 6701 02, 6803, 65090909)")
    print("datagrams=\(pkts.count) kf_req=\(kfReq)")
}

func env(_ k: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[k], !v.isEmpty else { return nil }
    return v
}

func runCLI() {
    let baseURL = env("AQARA_URL") ?? "https://rpc-ger.aqara.com"
    guard let user = env("AQARA_USER"), let pass = env("AQARA_PASS") else {
        FileHandle.standardError.write(Data("Set AQARA_USER and AQARA_PASS (and optional AQARA_URL)\n".utf8))
        exit(2)
    }
    let cloud = AqaraCloud(config: .init(
        baseURL: baseURL, appId: AqaraCloud.defaultAppId,
        appKey: AqaraCloud.defaultAppKey,
        phoneId: "aqara-menubar-\(ProcessInfo.processInfo.hostName)"))

    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            try await cloud.login(email: user, password: pass)
            print("✅ Login OK")
            let devs = try await cloud.devices()
            print("📱 Devices: \(devs.count)")
            for d in devs { print("  - \(d.name) (\(d.model)) did=\(d.did) pos=\(d.positionId)") }

            let homes = try await cloud.homeIds()
            print("🏠 Home positions: \(homes)")
            if let cam = devs.first(where: { $0.model.hasPrefix("lumi.camera") }), let home = homes.first {
                let weekAgo = Int64(Date().timeIntervalSince1970 * 1000) - 7 * 86_400_000
                let evs = try await cloud.events(positionId: home, did: cam.did, sinceMs: weekAgo, size: 10)
                print("🎞  Events (last 7d): \(evs.count)")
                for e in evs.prefix(5) {
                    let date = Date(timeIntervalSince1970: Double(e.triggerTime) / 1000)
                    print("  - \(e.name) @ \(date)  snap=\(e.snapshotName) clip=\(e.videoName) (\(e.videoLen)s)")
                }
            }
        } catch { print("❌ \(error)") }
        sem.signal()
    }
    sem.wait()
}
