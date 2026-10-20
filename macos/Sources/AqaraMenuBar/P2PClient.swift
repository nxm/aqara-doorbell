import Foundation
import Darwin

// Port of native/src/p2p/client.{hpp,cpp} + protocol.hpp: the PPCS/TUTK UDP transport
// that discovers the camera (master servers, LAN broadcast, direct punch), completes
// the PUNCH/RDY handshake, authenticates with the cloud-signed key (lumi 0x1000) and
// shuttles encrypted DRW datagrams in both directions. Wire layout is byte-exact with
// the C++; threading uses three Foundation threads like the original.

struct P2PConfig {
    var did: String
    var p2pId: String
    var initString: String
    var appPubHex: String
    var appSign: String
    var signTime: String
    var devPubHex: String
    var cameraIP: String = ""
    var cameraPort: Int = 0
}

enum P2PEvent {
    case connected(ip: String, port: UInt16)
    case sessionReady
    case talkbackReady
    case unhealthy
    case log(String)
}

/// PPCS transport message types (magic prefix 0xF1).
enum PpcsMsg {
    static let hello: UInt8 = 0x00          // Initial discovery handshake probe
    static let close: UInt8 = 0x06          // Clean session termination
    static let query: UInt8 = 0x20          // Master-server endpoint query
    static let lanBroadcast: UInt8 = 0x30   // LAN subnet broadcast probe
    static let punch: UInt8 = 0x41          // UDP hole-punching packet
    static let ready: UInt8 = 0x42          // Tunnel readiness signal from camera
    static let readyAck: UInt8 = 0x43       // Acknowledgment for tunnel readiness
    static let altDrw: UInt8 = 0x82         // Alternate DRW transport marker
    static let drw: UInt8 = 0xD0            // Encrypted Data Read/Write payload
    static let drwAck: UInt8 = 0xD1         // Acknowledgment for DRW sequence (also the DRW body marker)
    static let drwExtra: UInt8 = 0xD8       // Extended DRW data transport
    static let alive: UInt8 = 0xE0          // Keepalive ping
    static let aliveAck: UInt8 = 0xE1       // Keepalive pong
}

/// Lumi application-layer command types carried in channel-0 DRW frames.
enum LumiCmd {
    static let loginReq: UInt32 = 0x1000
    static let loginResp: UInt32 = 0x1001
    static let sessionStartReq: UInt32 = 0x1002
    static let sessionStartResp: UInt32 = 0x1003
    static let sessionStop: UInt32 = 0x1004
    static let ptzOrTalkStart: UInt32 = 0x100A
    static let talkbackResp: UInt32 = 0x100B
    static let talkStop: UInt32 = 0x100C
    static let setQuality: UInt32 = 0x100E
    static let keyframeReq: UInt32 = 0x1018
    static let keyframeResp: UInt32 = 0x1019
    static let streamStartReq: UInt32 = 0x101C
}

extension PPCS {
    /// Talkback DRW body: 32-byte zero header with the ADTS length LE at offset 28, then ADTS.
    static func buildTalkbackBody(_ adts: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 32 + adts.count)
        let len = UInt32(adts.count)
        body[28] = UInt8(len & 0xff); body[29] = UInt8((len >> 8) & 0xff)
        body[30] = UInt8((len >> 16) & 0xff); body[31] = UInt8((len >> 24) & 0xff)
        if !adts.isEmpty { body.replaceSubrange(32..., with: adts) }
        return body
    }
}

/// Lock-protected box standing in for the C++ std::atomic / mutex-guarded members.
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
    func withLock<R>(_ body: (inout T) throws -> R) rethrows -> R {
        try lock.withLock { try body(&v) }
    }
    @discardableResult func exchange(_ new: T) -> T {
        lock.withLock { let old = v; v = new; return old }
    }
}

extension Locked where T: Equatable {
    func compareExchange(expected: T, new: T) -> Bool {
        lock.withLock {
            guard v == expected else { return false }
            v = new
            return true
        }
    }
}

private func currentTimeMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - sockaddr helpers

private func makeAddr(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    _ = ip.withCString { inet_pton(AF_INET, $0, &a.sin_addr) }
    return a
}

private func ipString(_ a: sockaddr_in) -> String {
    var addr = a.sin_addr
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let ok = buf.withUnsafeMutableBufferPointer { p in
        inet_ntop(AF_INET, &addr, p.baseAddress, socklen_t(INET_ADDRSTRLEN)) != nil
    }
    guard ok else { return "?" }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

private func hostPort(_ a: sockaddr_in) -> UInt16 { UInt16(bigEndian: a.sin_port) }

private func sameEndpoint(_ a: sockaddr_in, _ b: sockaddr_in) -> Bool {
    a.sin_family == b.sin_family && a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port
}

private func isLanIP(_ a: sockaddr_in) -> Bool {
    let ip = UInt32(bigEndian: a.sin_addr.s_addr)
    return (ip >= 0x0A000000 && ip <= 0x0AFFFFFF) ||   // 10.0.0.0/8
           (ip >= 0xAC100000 && ip <= 0xAC1FFFFF) ||   // 172.16.0.0/12
           (ip >= 0xC0A80000 && ip <= 0xC0A8FFFF)      // 192.168.0.0/16
}

// MARK: - Client

final class P2PClient: @unchecked Sendable {
    static let tutkMasters = ["54.71.80.151", "54.214.103.243", "3.23.78.166", "106.75.105.109",
                              "117.50.21.84", "106.75.105.110", "117.50.21.85", "117.50.19.124",
                              "106.75.76.108", "117.50.19.125", "106.75.76.109", "117.50.62.24",
                              "117.50.62.25"]

    static let talkbackLead: [UInt8] = [0xff, 0xf9, 0x60, 0x40, 0x01, 0x7f, 0xfc, 0x00, 0xd0, 0x00, 0x07]

    private let config: P2PConfig
    private let reassembler: AVIOReassembler
    private let onEvent: (P2PEvent) -> Void

    private let ppcsKey: [UInt8]
    private let punchBuf: [UInt8]
    private let masterServers: [String]

    private let udpFd = Locked<Int32>(-1)
    private let running = Locked(false)
    private let isConnectedFlag = Locked(false)
    private let sessionStarted = Locked(false)
    private let sessionReady = Locked(false)
    private let connectedNotified = Locked(false)
    private let lastLoginSentMs = Locked<Int64>(0)
    private let sessionReadySinceMs = Locked<Int64>(0)
    private let lastMediaTrafficMs = Locked<Int64>(0)
    private let lastVideoTrafficMs = Locked<Int64>(0)
    private let lastAudioTrafficMs = Locked<Int64>(0)
    private let lastStreamRetryMs = Locked<Int64>(0)
    private let lastUnhealthyEmittedMs = Locked<Int64>(0)
    private let lastKfReqSentMs = Locked<Int64>(0)
    private let startTimeMs = Locked<Int64>(0)
    private let lastP2PTrafficMs = Locked<Int64>(0)

    private let cameraAddr = Locked(sockaddr_in())
    private let endpoints = Locked<[sockaddr_in]>([])

    private struct Seqs {
        var cmd: UInt32 = 1
        var ch0: UInt16 = 0
        var ch3: UInt16 = 0
        var talk: UInt16 = 0
        var talkFramesSent = 0
    }
    private let seqs = Locked(Seqs())

    private let pendingAcks = Locked<[Set<UInt16>]>(Array(repeating: [], count: 8))

    private let stopSignal = DispatchSemaphore(value: 0)
    private let threadsDone = DispatchGroup()

    var isConnected: Bool { isConnectedFlag.value }
    var isSessionReady: Bool { sessionReady.value }

    init(config: P2PConfig, reassembler: AVIOReassembler, onEvent: @escaping (P2PEvent) -> Void) {
        self.config = config
        self.reassembler = reassembler
        self.onEvent = onEvent

        var keyStr = ""
        var masters: [String] = []
        if let decoded = PPCS.decodeInitString(config.initString) {
            masters = decoded.masters
            keyStr = decoded.key
        }
        // Append default master servers as fallback
        for def in Self.tutkMasters where !masters.contains(def) { masters.append(def) }
        self.masterServers = masters

        if keyStr.isEmpty {
            keyStr = config.initString
            if let colon = keyStr.lastIndex(of: ":") { keyStr = String(keyStr[keyStr.index(after: colon)...]) }
        }
        if keyStr.isEmpty { keyStr = "aqaraus19kn" }
        self.ppcsKey = Array(keyStr.utf8)
        self.punchBuf = PPCS.punchPayload(config.p2pId)

        if !config.cameraIP.isEmpty && config.cameraPort > 0 {
            cameraAddr.value = makeAddr(config.cameraIP, UInt16(truncatingIfNeeded: config.cameraPort))
        }
        log("Decoded \(decodedCount(config)) regional master server(s); using \(masters.count) total: \(masters.joined(separator: ", "))")
    }

    private func decodedCount(_ c: P2PConfig) -> Int { PPCS.decodeInitString(c.initString)?.masters.count ?? 0 }

    deinit { stop() }

    private func log(_ s: String) { onEvent(.log("[P2P] " + s)) }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !running.value else { return true }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { log("socket() failed: \(String(cString: strerror(errno)))"); return false }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &opt, socklen_t(MemoryLayout<Int32>.size))

        // macOS caps SO_RCVBUF below the 8 MiB the C++ asks for; take the largest it grants.
        for mb in [8, 4, 2, 1] {
            var rcvbuf: Int32 = Int32(mb * 1024 * 1024)
            if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
        }

        // Receive timeout so the receiver thread can observe `running` and exit (the
        // C++ relies on close() interrupting recvfrom, which is not reliable on Darwin).
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = 0      // INADDR_ANY
        local.sin_port = 0             // ephemeral port
        let bound = withUnsafePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 {
            log("bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }

        udpFd.value = fd
        running.value = true
        startTimeMs.value = currentTimeMs()
        lastP2PTrafficMs.value = currentTimeMs()

        spawn("p2p-receiver") { [self] in receiverLoop() }
        spawn("p2p-discovery") { [self] in discoveryLoop() }
        spawn("p2p-watchdog") { [self] in watchdogLoop() }

        log("Started P2P client for \(config.did) p2p_id=\(config.p2pId)")
        return true
    }

    func stop() {
        guard running.value else { return }

        // The C++ flips running_ before these sends, which makes send_raw_packet drop
        // them silently; the stated intent (release the camera slot right away so the
        // battery doorbell can sleep / no ghost session lock) is honoured here.
        if isConnectedFlag.value {
            sendLumiCmd(LumiCmd.sessionStop)
        }
        var closePkt = PPCS.buildPPPP(PpcsMsg.close, [])
        PPCS.encrypt(key: ppcsKey, data: &closePkt)
        let cam = cameraAddr.value
        if cam.sin_port != 0 { sendRaw(closePkt, to: cam) }
        if !config.cameraIP.isEmpty { sendRaw(closePkt, to: makeAddr(config.cameraIP, 32108)) }

        running.value = false
        for _ in 0..<3 { stopSignal.signal() }
        _ = threadsDone.wait(timeout: .now() + 3)

        let fd = udpFd.exchange(-1)
        if fd >= 0 { close(fd) }
    }

    private func spawn(_ name: String, _ body: @escaping () -> Void) {
        threadsDone.enter()
        let t = Thread { [threadsDone] in
            body()
            threadsDone.leave()
        }
        t.name = name
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Sleep that wakes early on stop(). Returns false when the client is stopping.
    private func sleepUnlessStopped(ms: Int) -> Bool {
        if stopSignal.wait(timeout: .now() + .milliseconds(ms)) == .success { return false }
        return running.value
    }

    // MARK: - Raw send

    private func sendRaw(_ data: [UInt8], to dest: sockaddr_in) {
        guard running.value, !data.isEmpty else { return }
        let fd = udpFd.value
        guard fd >= 0 else { return }
        var d = dest
        let ret = data.withUnsafeBytes { buf -> Int in
            withUnsafePointer(to: &d) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if ret < 0 && running.value {
            let e = errno
            // Link-local broadcast targets (169.254.x) routinely fail; not worth logging.
            if e != EBADF && e != EHOSTUNREACH && e != EHOSTDOWN && e != ENETUNREACH {
                log("sendto failed to \(ipString(dest)):\(hostPort(dest)) err=\(String(cString: strerror(e)))")
            }
        }
    }

    private func sendRaw(_ data: [UInt8], ip: String, port: UInt16) {
        sendRaw(data, to: makeAddr(ip, port))
    }

    private func encrypted(_ msgType: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        var pkt = PPCS.buildPPPP(msgType, payload)
        PPCS.encrypt(key: ppcsKey, data: &pkt)
        return pkt
    }

    /// DRW = [0xD1, channel, seqHi, seqLo, payload] wrapped in PPPP 0xD0, PPCS-encrypted, to the camera.
    private func sendEncDrw(channel: UInt8, seq: UInt16, payload: [UInt8]) {
        guard isConnectedFlag.value, udpFd.value >= 0 else { return }
        var drw = [UInt8](repeating: 0, count: 4 + payload.count)
        drw[0] = 0xD1   // DRW_MARKER
        drw[1] = channel
        drw[2] = UInt8((seq >> 8) & 0xff)
        drw[3] = UInt8(seq & 0xff)
        if !payload.isEmpty { drw.replaceSubrange(4..., with: payload) }
        sendRaw(encrypted(PpcsMsg.drw, drw), to: cameraAddr.value)
    }

    private func nextCmdSeq() -> UInt32 { seqs.withLock { let s = $0.cmd; $0.cmd &+= 1; return s } }
    private func nextCh0Seq() -> UInt16 { seqs.withLock { let s = $0.ch0; $0.ch0 &+= 1; return s } }
    private func nextCh3Seq() -> UInt16 { seqs.withLock { let s = $0.ch3; $0.ch3 &+= 1; return s } }

    /// build_lumi_frame(type, payload, cmd_seq_++) + send_enc_drw(channel, chN_seq_++, frame).
    private func sendLumiCmd(_ type: UInt32, _ payload: [UInt8] = [], channel: UInt8 = 0) {
        let frame = PPCS.buildLumiFrame(type: type, payload: payload, seq: nextCmdSeq())
        let seq = channel == 3 ? nextCh3Seq() : nextCh0Seq()
        sendEncDrw(channel: channel, seq: seq, payload: frame)
    }

    // MARK: - ACKs

    private func queueAck(channel: UInt8, seq: UInt16) {
        guard channel < 8 else { return }
        pendingAcks.withLock { _ = $0[Int(channel)].insert(seq) }
    }

    private func flushAcks(channel: UInt8) {
        guard channel < 8, isConnectedFlag.value else { return }
        let seqList: [UInt16] = pendingAcks.withLock { acks in
            if acks[Int(channel)].isEmpty { return [] }
            let s = acks[Int(channel)].sorted()   // std::set iteration order
            acks[Int(channel)].removeAll()
            return s
        }
        if seqList.isEmpty { return }

        var i = 0
        while i < seqList.count {
            let chunk = min(seqList.count - i, 32)
            var ack = [UInt8](repeating: 0, count: 4 + chunk * 2)
            ack[0] = 0xD1   // DRW_MARKER
            ack[1] = channel
            ack[2] = UInt8((chunk >> 8) & 0xff)
            ack[3] = UInt8(chunk & 0xff)
            for c in 0..<chunk {
                let s = seqList[i + c]
                ack[4 + c * 2] = UInt8((s >> 8) & 0xff)
                ack[4 + c * 2 + 1] = UInt8(s & 0xff)
            }
            sendRaw(encrypted(PpcsMsg.drwAck, ack), to: cameraAddr.value)
            i += chunk
        }
    }

    // MARK: - Session commands

    private func notifyConnected(_ endpoint: sockaddr_in) {
        if connectedNotified.exchange(true) { return }
        onEvent(.connected(ip: ipString(endpoint), port: hostPort(endpoint)))
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    private func sendLoginIfDue(minIntervalMs: Int64 = 1000) {
        guard isConnectedFlag.value, !sessionStarted.value else { return }
        let now = currentTimeMs()
        let previous = lastLoginSentMs.value
        if previous != 0 && now - previous < minIntervalMs { return }
        if !lastLoginSentMs.compareExchange(expected: previous, new: now) { return }

        // Field order matches the glaze serialisation of P2PLoginPayload (all strings).
        let ts = config.signTime.isEmpty ? String(now) : config.signTime
        let loginJSON = "{\"timestamp\":\(jsonString(ts)),\"app_sign\":\(jsonString(config.appSign)),\"app_public_key\":\(jsonString(config.appPubHex))}"
        log("Sending 0x1000 Login for \(config.did)")
        sendLumiCmd(LumiCmd.loginReq, Array(loginJSON.utf8))
    }

    func requestKeyframe() {
        let now = currentTimeMs()
        let prev = lastKfReqSentMs.value
        if prev != 0 && now - prev < 1500 {
            return   // Rate limit: at most 1 IDR request every 1.5s to prevent encoder stress
        }
        lastKfReqSentMs.value = now
        sendLumiCmd(LumiCmd.keyframeReq)
    }

    func setQuality(_ channel: Int) {
        sendLumiCmd(LumiCmd.setQuality, Array("{\"channel\":\(channel)}".utf8))
    }

    func ptz(action: Int, speed: Int = 50) {
        sendLumiCmd(LumiCmd.ptzOrTalkStart, Array("{\"action\":\(action),\"speed\":\(speed)}".utf8))
    }

    func startTalkback() {
        guard isConnectedFlag.value else { return }
        log("Sending 0x100A startTalk to \(config.did)")
        seqs.withLock { $0.talk = 0; $0.talkFramesSent = 0 }
        sendLumiCmd(LumiCmd.ptzOrTalkStart)
    }

    func stopTalkback() {
        guard isConnectedFlag.value else { return }
        log("Sending 0x100C stopTalk to \(config.did)")
        sendLumiCmd(LumiCmd.talkStop)
    }

    func sendTalkbackFrame(_ adts: [UInt8]) {
        guard isConnectedFlag.value, !adts.isEmpty else { return }

        var body: [UInt8]
        // Check if payload is already wrapped with 32-byte PPCS header
        if adts.count >= 32 && adts[0] == 0 && adts[1] == 0 && adts[2] == 0 && adts[3] == 0 {
            body = adts
        } else {
            let framesSent = seqs.withLock { $0.talkFramesSent }
            if framesSent == 0 && Array(adts.prefix(11)) != Self.talkbackLead {
                let leadBody = PPCS.buildTalkbackBody(Self.talkbackLead)
                let leadSeq = seqs.withLock { $0.talk }
                for _ in 0..<3 { sendEncDrw(channel: 2, seq: leadSeq, payload: leadBody) }
                seqs.withLock { $0.talk &+= 1 }
            }
            body = PPCS.buildTalkbackBody(adts)
        }

        let currentSeq: UInt16 = seqs.withLock { s in
            let v = s.talk
            s.talk &+= 1
            s.talkFramesSent += 1
            return v
        }
        // Native PPCS reliability: send 3 identical datagrams with identical sequence number
        for _ in 0..<3 { sendEncDrw(channel: 2, seq: currentSeq, payload: body) }
    }

    // MARK: - Discovery

    static func primaryLocalIP() -> String {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddrPtr) }
        var best = "127.0.0.1"
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            if ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let s = ipString(sin)
            if s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.hasPrefix("172.") {
                best = s
                break
            }
        }
        return best
    }

    static func broadcastIPs() -> [String] {
        var ips: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return ips }
        defer { freeifaddrs(ifaddrPtr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            if ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 { continue }
            if ifa.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0, let bcast = ifa.pointee.ifa_dstaddr {
                let sin = bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                ips.append(ipString(sin))
            }
        }
        return ips
    }

    private func discoveryLoop() {
        let fd = udpFd.value
        var local = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addrLen) }
        }
        let myPort = UInt16(bigEndian: local.sin_port)

        // QUERY body: punch(20) + {2,0 (AF_INET)} + port LE + local IPv4 octets reversed + zero pad.
        var req20 = [UInt8](repeating: 0, count: 36)
        if punchBuf.count >= 20 { req20.replaceSubrange(0..<20, with: punchBuf[0..<20]) }
        req20[20] = 2
        req20[21] = 0   // AF_INET
        req20[22] = UInt8(myPort & 0xff)
        req20[23] = UInt8((myPort >> 8) & 0xff)

        let localIP = Self.primaryLocalIP()
        var ipNum: UInt32 = 0
        _ = localIP.withCString { inet_pton(AF_INET, $0, &ipNum) }
        let ipBytes = withUnsafeBytes(of: ipNum) { Array($0) }   // network (memory) order
        req20[24] = ipBytes[3]
        req20[25] = ipBytes[2]
        req20[26] = ipBytes[1]
        req20[27] = ipBytes[0]

        let queryPkt = encrypted(PpcsMsg.query, req20)
        let helloPkt = encrypted(PpcsMsg.hello)
        let punchPkt = encrypted(PpcsMsg.punch, punchBuf)
        let lanBcast: [UInt8] = [0xF1, PpcsMsg.lanBroadcast, 0x00, 0x00]   // sent unencrypted, as in the C++
        let bcasts = Self.broadcastIPs()
        log("Discovery started on local port \(myPort) local_ip=\(localIP) broadcasts=\(bcasts)")

        var attempts = 0
        while running.value && !isConnectedFlag.value {
            attempts += 1

            // 1. Query TUTK Master Servers (regional decoded masters first, then fallbacks)
            for master in masterServers {
                sendRaw(helloPkt, ip: master, port: 32100)
                sendRaw(queryPkt, ip: master, port: 32100)
            }

            // 2. Query known endpoints
            for ep in endpoints.value { sendRaw(punchPkt, to: ep) }

            // 3. Direct camera IP / LAN
            if !config.cameraIP.isEmpty {
                let port = UInt16(truncatingIfNeeded: config.cameraPort > 0 ? config.cameraPort : 32108)
                sendRaw(punchPkt, ip: config.cameraIP, port: port)
                sendRaw(lanBcast, ip: config.cameraIP, port: 32108)
                if port != 32108 { sendRaw(punchPkt, ip: config.cameraIP, port: 32108) }
            }
            for b in bcasts { sendRaw(lanBcast, ip: b, port: 32108) }

            // 200ms during the first 150 attempts (~30s burst), then 1000ms to probe steadily
            if !sleepUnlessStopped(ms: attempts < 150 ? 200 : 1000) { break }
        }
    }

    // MARK: - Receive

    private func receiverLoop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let fd = udpFd.value

        while running.value {
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf -> Int in
                withUnsafeMutablePointer(to: &src) { sp in
                    sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, buf.baseAddress, buf.count, 0, sa, &srcLen)
                    }
                }
            }
            if n <= 0 {
                if !running.value { break }
                continue   // EAGAIN from SO_RCVTIMEO, or a transient error
            }
            handlePacket(Array(buffer[0..<n]), from: src)
        }
    }

    private func handlePacket(_ data: [UInt8], from src: sockaddr_in) {
        guard data.count >= 4 else { return }
        lastP2PTrafficMs.value = currentTimeMs()

        var dec = data
        if dec[0] != 0xF1 { PPCS.decrypt(key: ppcsKey, data: &dec) }
        if dec[0] != 0xF1 {
            log(String(format: "Drop non-PPCS packet %dB from %@:%d byte0=0x%02x dec0=0x%02x",
                       data.count, ipString(src), Int(hostPort(src)), Int(data[0]), Int(dec[0])))
            return
        }

        let msgType = dec[1]
        let payloadLen = Int(dec[2]) << 8 | Int(dec[3])
        guard 4 + payloadLen <= dec.count else { return }
        let payload = Array(dec[4..<(4 + payloadLen)])
        let srcIP = ipString(src)

        if (msgType == 0x40 || msgType == 0x21) && payloadLen >= 8 {
            // Master server response with camera endpoint
            let epPort = UInt16(payload[2]) | (UInt16(payload[3]) << 8)
            let ip1 = "\(payload[7]).\(payload[6]).\(payload[5]).\(payload[4])"
            let ip2 = "\(payload[4]).\(payload[5]).\(payload[6]).\(payload[7])"
            let ep = makeAddr(ip1, epPort)
            let ep2 = makeAddr(ip2, epPort)

            let validEp = ep.sin_addr.s_addr != 0 && epPort > 0
            let validEp2 = ep2.sin_addr.s_addr != 0 && epPort > 0

            if validEp || validEp2 {
                endpoints.withLock { eps in
                    if validEp { eps.append(ep) }
                    if validEp2 && ep2.sin_addr.s_addr != ep.sin_addr.s_addr { eps.append(ep2) }
                }
            }
            log("Master server \(srcIP) returned camera endpoint candidate(s): \(ip1):\(epPort) / \(ip2):\(epPort) for \(config.did)")

            let punchPkt = encrypted(PpcsMsg.punch, punchBuf)
            if validEp { sendRaw(punchPkt, to: ep) }
            if validEp2 && ep2.sin_addr.s_addr != ep.sin_addr.s_addr { sendRaw(punchPkt, to: ep2) }

        } else if msgType == PpcsMsg.punch {
            // PUNCH from a candidate endpoint. Once connected, keep the winning
            // endpoint pinned instead of letting late LAN discovery steal it.
            if !isConnectedFlag.value && (isLanIP(src) || !isLanIP(cameraAddr.value)) {
                cameraAddr.value = src
            }
            sendRaw(encrypted(PpcsMsg.punch, punchBuf), to: src)
            sendRaw(encrypted(PpcsMsg.ready, punchBuf), to: src)

        } else if msgType == PpcsMsg.ready {
            // RDY establishes the endpoint. Ignore late RDY packets from other
            // discovery candidates after a session is already active.
            let alreadyConnected = isConnectedFlag.value
            if alreadyConnected && !sameEndpoint(src, cameraAddr.value) {
                if !sessionStarted.value && isLanIP(src) {
                    cameraAddr.value = src
                    lastLoginSentMs.value = 0
                } else {
                    return
                }
            } else if !alreadyConnected {
                cameraAddr.value = src
            }

            sendRaw(encrypted(PpcsMsg.readyAck), to: src)
            sendRaw(encrypted(PpcsMsg.alive), to: src)

            let firstHandshake = !isConnectedFlag.exchange(true)
            if firstHandshake {
                log("RDY Handshake OK with \(srcIP):\(hostPort(src))")
                notifyConnected(src)
            }
            // Cameras may repeat RDY while our ACK is in flight. Retry auth at most
            // once per second instead of creating a login storm for every RDY.
            sendLoginIfDue()

        } else if msgType == PpcsMsg.readyAck {
            // Ignore late RDY_ACK packets from non-winning endpoints.
            let alreadyConnected = isConnectedFlag.value
            if alreadyConnected && !sameEndpoint(src, cameraAddr.value) {
                if !sessionStarted.value && isLanIP(src) {
                    cameraAddr.value = src
                    lastLoginSentMs.value = 0
                } else {
                    return
                }
            } else if !alreadyConnected {
                cameraAddr.value = src
            }
            let firstHandshake = !isConnectedFlag.exchange(true)
            if firstHandshake {
                notifyConnected(src)
                sendRaw(encrypted(PpcsMsg.alive), to: cameraAddr.value)
            }
            sendLoginIfDue()

        } else if msgType == PpcsMsg.alive {
            sendRaw(encrypted(PpcsMsg.aliveAck), to: src)

        } else if (msgType == PpcsMsg.drw || msgType == PpcsMsg.drwExtra || msgType == PpcsMsg.altDrw)
                    && payloadLen >= 4 && payload[0] == PpcsMsg.drwAck {
            // flush_acks() targets camera_addr_. Reject data from a late candidate,
            // otherwise ACKs go to a different peer and the camera retries forever.
            if isConnectedFlag.value && !sameEndpoint(src, cameraAddr.value) {
                if !sessionReady.value && isLanIP(src) {
                    cameraAddr.value = src
                } else {
                    return
                }
            }
            let channel = payload[1]
            let seq = UInt16(payload[2]) << 8 | UInt16(payload[3])
            let now = currentTimeMs()
            if channel != 0 { lastMediaTrafficMs.value = now }
            if channel == 1 || channel == 4 || channel == 5 {
                lastVideoTrafficMs.value = now
            } else if channel == 2 {
                lastAudioTrafficMs.value = now
            }
            let chanData = Array(payload[4...])

            queueAck(channel: channel, seq: seq)
            flushAcks(channel: channel)

            if channel == 0 {
                handleChannel0Data(chanData)
            } else if channel == 1 || channel == 4 || channel == 5 {
                if !sessionReady.exchange(true) {
                    sessionReadySinceMs.value = currentTimeMs()
                    onEvent(.sessionReady)
                }
                reassembler.push(channel: channel, seq: seq, data: chanData)
            } else if channel == 2 {
                reassembler.push(channel: channel, seq: seq, data: chanData)
            }
        }
    }

    /// Channel 0 carries back-to-back "lumi" frames: magic(4) type(LE32) seq(LE32) len(LE32) body.
    private func handleChannel0Data(_ data: [UInt8]) {
        var off = 0
        let len = data.count
        while off + 16 <= len && data[off] == 0x6c && data[off + 1] == 0x75 && data[off + 2] == 0x6d && data[off + 3] == 0x69 {
            let type = UInt32(data[off + 4]) | (UInt32(data[off + 5]) << 8) | (UInt32(data[off + 6]) << 16) | (UInt32(data[off + 7]) << 24)
            let bodyLen = Int(UInt32(data[off + 12]) | (UInt32(data[off + 13]) << 8) | (UInt32(data[off + 14]) << 16) | (UInt32(data[off + 15]) << 24))
            if off + 16 + bodyLen > len { break }
            dispatchChannel0(type: type, body: Array(data[(off + 16)..<(off + 16 + bodyLen)]))
            off += 16 + bodyLen
        }
    }

    private func dispatchChannel0(type: UInt32, body: [UInt8]) {
        let bodyStr = String(decoding: body, as: UTF8.self)
        log(String(format: "Channel 0 frame for %@ type=0x%x body_len=%d body=%@", config.did, type, body.count, bodyStr))

        if type == LumiCmd.loginResp {
            // A DRW response may be retransmitted or even batched several times.
            // Advance the auth state exactly once, independently of session_ready_.
            if !sessionStarted.exchange(true) {
                log("0x1001 Login OK for \(config.did), sending 0x101C stream start & 0x1002 session start")
                // Match official client ordering from Frida: channel 3
                // stream/record-list request first (0x101C), then channel 0 live-session start (0x1002).
                sendLumiCmd(LumiCmd.streamStartReq, channel: 3)
                sendLumiCmd(LumiCmd.sessionStartReq)
            }
        } else if type == LumiCmd.sessionStartResp {
            if !sessionReady.exchange(true) {
                log("0x1003 Session Ready for \(config.did), requesting keyframe (0x1018)")
                sessionReadySinceMs.value = currentTimeMs()
                requestKeyframe()
                onEvent(.sessionReady)
            }
        } else if type == LumiCmd.talkbackResp {
            log("Talkback channel prepared (0x100B)")
            onEvent(.talkbackReady)
        }
    }

    // MARK: - Watchdog

    private func watchdogLoop() {
        var tick = 0
        while running.value {
            if !sleepUnlessStopped(ms: 1000) { break }
            tick += 1

            if !isConnectedFlag.value {
                let now = currentTimeMs()
                if now - startTimeMs.value > 20000 && now - lastUnhealthyEmittedMs.value > 20000 {
                    lastUnhealthyEmittedMs.value = now
                    log("Connection establishment timed out (20s) for \(config.did), emitting unhealthy event")
                    onEvent(.unhealthy)
                }
                continue
            }

            // Keepalive ALIVE every 2 seconds
            if tick % 2 == 0 {
                sendRaw(encrypted(PpcsMsg.alive), to: cameraAddr.value)
            }

            if !sessionStarted.value {
                if tick % 3 == 0 { sendLoginIfDue(minIntervalMs: 2500) }
            } else if !sessionReady.value {
                if tick % 2 == 0 { sendLumiCmd(LumiCmd.sessionStartReq) }
            } else {
                let now = currentTimeMs()
                let videoAt = lastVideoTrafficMs.value
                let readyAt = sessionReadySinceMs.value

                // Only retry if no video traffic has arrived within 4s of session ready, or if video stopped for > 6s
                if videoAt == 0 && readyAt > 0 && now - readyAt > 4000 && now - lastStreamRetryMs.value > 5000 {
                    lastStreamRetryMs.value = now
                    log("No video after session ready for \(config.did), retrying stream start")
                    sendLumiCmd(LumiCmd.streamStartReq, channel: 3)
                    sendLumiCmd(LumiCmd.sessionStartReq)
                    requestKeyframe()

                    if now - readyAt > 15000 && now - lastUnhealthyEmittedMs.value > 15000 {
                        lastUnhealthyEmittedMs.value = now
                        log("No video received for \(config.did) after 15s, emitting unhealthy event")
                        onEvent(.unhealthy)
                    }
                } else if videoAt > 0 && now - videoAt > 6000 && now - lastStreamRetryMs.value > 5000 {
                    lastStreamRetryMs.value = now
                    log("Video stream stalled (\((now - videoAt) / 1000)s) for \(config.did), requesting keyframe")
                    requestKeyframe()

                    if now - videoAt > 12000 {
                        sendLumiCmd(LumiCmd.streamStartReq, channel: 3)
                        sendLumiCmd(LumiCmd.sessionStartReq)
                    }

                    if now - videoAt > 15000 && now - lastUnhealthyEmittedMs.value > 15000 {
                        lastUnhealthyEmittedMs.value = now
                        log("Video stream unresponsive for \(config.did), emitting unhealthy event")
                        onEvent(.unhealthy)
                    }
                }
            }
        }
    }
}
