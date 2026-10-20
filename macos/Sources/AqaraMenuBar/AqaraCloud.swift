import Foundation
import CryptoKit
import Security

/// Client for Aqara's private app-cloud RPC (rpc-ger.aqara.com etc).
/// Reverse-engineered: login = RSA(MD5(pwd)) + MD5 request signing.
/// Pure HTTPS — works from any network (no LAN needed), unlike the P2P media path.
actor AqaraCloud {
    struct Config {
        var baseURL: String          // e.g. https://rpc-ger.aqara.com
        var appId: String
        var appKey: String
        var phoneId: String
    }

    // Default app credential pair (works across regions; from open-source prior art).
    static let defaultAppId = "444c476ef7135e53330f46e7"
    static let defaultAppKey = "uOJy0qmKwXj6aHUB2KQEIJuXHMDVTAJi"

    // RSA-1024 public key baked into the Aqara app (login password encryption).
    private static let loginPubKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCG46slB57013JJs4Vvj5cVyMpR
    9b+B2F+YJU6qhBEYbiEmIdWpFPpOuBikDs2FcPS19MiWq1IrmxJtkICGurqImRUt
    4lP688IWlEmqHfSxSRf2+aH0cH8VWZ2OaZn5DWSIHIPBF2kxM71q8stmoYiV0oZs
    rZzBHsMuBwA4LQdxBwIDAQAB
    -----END PUBLIC KEY-----
    """

    let config: Config
    private var token: String?
    private var userId: String?
    private let session: URLSession

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Crypto helpers

    private func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Sign = MD5("Appid=..&Nonce=..&Time=..[&Token=..][&<signBody>]&<appKey>")
    private func sign(nonce: String, time: String, token: String?, signBody: String) -> String {
        var pre = "Appid=\(config.appId)&Nonce=\(nonce)&Time=\(time)"
        if let t = token, !t.isEmpty { pre += "&Token=\(t)" }
        if !signBody.isEmpty { pre += "&\(signBody)" }
        pre += "&\(config.appKey)"
        return md5Hex(pre)
    }

    /// RSA/ECB/PKCS1 encrypt of the md5-hex of the password, base64-encoded.
    private func encryptPassword(_ password: String) throws -> String {
        let md5pw = md5Hex(password)                       // 32 ascii hex chars
        let der = try Self.spkiToPKCS1(Self.pemToDER(Self.loginPubKeyPEM))
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            throw AqaraError.crypto("SecKeyCreateWithData: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(md5pw.utf8) as CFData, &err) else {
            throw AqaraError.crypto("encrypt: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return (enc as Data).base64EncodedString()
    }

    private static func pemToDER(_ pem: String) -> Data {
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: b64) ?? Data()
    }

    /// Strip the SubjectPublicKeyInfo wrapper → raw PKCS#1 RSAPublicKey (what Security wants).
    private static func spkiToPKCS1(_ spki: Data) throws -> Data {
        let b = [UInt8](spki)
        var i = 0
        func readLen() -> Int {
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f; len = 0
                for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }
            }
            return len
        }
        guard b.count > 2, b[i] == 0x30 else { throw AqaraError.crypto("bad SPKI") }
        i += 1; _ = readLen()                   // outer SEQUENCE
        guard b[i] == 0x30 else { throw AqaraError.crypto("no AlgId") }
        i += 1; let algLen = readLen(); i += algLen   // skip AlgorithmIdentifier
        guard b[i] == 0x03 else { throw AqaraError.crypto("no BIT STRING") }
        i += 1; _ = readLen()                   // BIT STRING
        guard b[i] == 0x00 else { throw AqaraError.crypto("bad unused bits") }
        i += 1                                   // skip unused-bits byte
        return Data(b[i...])                     // PKCS#1 RSAPublicKey
    }

    // MARK: - Request core

    private func request(_ method: String, _ path: String,
                         query: [(String, String)] = [],
                         jsonBody: Any? = nil) async throws -> [String: Any] {
        let t = String(Int(Date().timeIntervalSince1970 * 1000))
        let n = nonce()

        var signBody = ""
        var bodyData: Data?
        var urlString = config.baseURL + path

        if method == "GET", !query.isEmpty {
            // sign body = params sorted by key, raw values; URL = percent-encoded.
            let sorted = query.sorted { $0.0 < $1.0 }
            signBody = sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            var comps = URLComponents(string: urlString)!
            comps.queryItems = sorted.map { URLQueryItem(name: $0.0, value: $0.1) }
            urlString = comps.url!.absoluteString
        } else if let jb = jsonBody {
            let data = try JSONSerialization.data(withJSONObject: jb, options: [])
            bodyData = data
            signBody = String(data: data, encoding: .utf8) ?? ""
        }

        let isLogin = path.contains("/user/login")
        let tok = isLogin ? nil : token
        let s = sign(nonce: n, time: t, token: tok, signBody: signBody)

        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = method
        req.setValue(config.appId, forHTTPHeaderField: "Appid")
        req.setValue(config.phoneId, forHTTPHeaderField: "phoneid")
        req.setValue(t, forHTTPHeaderField: "Time")
        req.setValue(n, forHTTPHeaderField: "Nonce")
        req.setValue(s, forHTTPHeaderField: "Sign")
        req.setValue("en", forHTTPHeaderField: "Lang")
        req.setValue("NG", forHTTPHeaderField: "Area")
        if let tok { req.setValue(tok, forHTTPHeaderField: "Token") }
        if let uid = userId, !isLogin { req.setValue(uid, forHTTPHeaderField: "Userid") }
        if let bodyData {
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, _) = try await session.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AqaraError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        if let code = obj["code"] as? Int, code != 0 {
            throw AqaraError.api(code, obj["message"] as? String ?? "")
        }
        return obj
    }

    // MARK: - Public API

    func login(email: String, password: String) async throws {
        let enc = try encryptPassword(password)
        let body: [String: Any] = ["account": email, "encryptType": 2, "password": enc]
        let res = try await request("POST", "/app/v1.0/lumi/user/login", jsonBody: body)
        guard let result = res["result"] as? [String: Any],
              let tok = result["token"] as? String else {
            throw AqaraError.badResponse("no token")
        }
        self.token = tok
        self.userId = result["userId"] as? String
    }

    struct Device { let did: String; let name: String; let model: String; let positionId: String }

    func devices() async throws -> [Device] {
        let res = try await request("GET", "/app/v1.0/lumi/app/position/device/query")
        let list = (res["result"] as? [String: Any])?["devices"] as? [[String: Any]]
            ?? res["result"] as? [[String: Any]] ?? []
        return list.map {
            Device(did: $0["did"] as? String ?? "",
                   name: $0["deviceName"] as? String ?? "",
                   model: $0["model"] as? String ?? "",
                   positionId: $0["positionId"] as? String ?? "")
        }
    }

    /// Debug: raw GET for exploring endpoint shapes.
    func debugGet(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        try await request("GET", path, query: query)
    }

    /// Home-level positionIds (real1.*) — intelligent/query needs these, not the
    /// device's room positionId (real2.*).
    func homeIds() async throws -> [String] {
        let res = try await request("GET", "/app/v1.0/lumi/app/position/query/home/list")
        let homes = (res["result"] as? [String: Any])?["homes"] as? [[String: Any]] ?? []
        return homes.compactMap { $0["homeId"] as? String }
    }

    struct CameraEvent: Identifiable, Sendable {
        let name: String        // "Lingerer Detection"
        let triggerTime: Int64  // ms
        let snapshotName: String
        let videoName: String
        let videoLen: Int
        let did: String
        let path: String
        let bucket: String
        let key: String
        let credentials: COSCredentials?
        let isSliced: Bool
        var id: String { "\(did):\(triggerTime):\(path)" }
        var mediaCacheKey: String { "\(id):\(snapshotName):\(videoName):\(key)" }
    }

    /// Video Event History (free): person/motion AI events with snapshot/clip metadata.
    func events(positionId: String, did: String? = nil, sinceMs: Int64, size: Int = 20, untilMs: Int64? = nil) async throws -> [CameraEvent] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let deviceIds = did.map { "[\"\($0)\"]" } ?? "[]"
        let q: [(String, String)] = [
            ("aiDataType", "0"), ("aiSortType", "0"), ("aiTagList", "[]"),
            ("deviceIds", deviceIds), ("endTime", String(untilMs ?? now)), ("positionId", positionId),
            ("reversed", "1"), ("size", String(size)), ("startIndex", "0"),
            ("startTime", String(sinceMs)), ("videoTypeList", "[]"),
        ]
        let res = try await request("GET", "/app/v1.0/lumi/devex/camera/video/intelligent/query", query: q)
        return Self.parseEvents(res)
    }

    nonisolated static func parseEvents(_ response: [String: Any]) -> [CameraEvent] {
        let result = response["result"] as? [String: Any] ?? [:]
        let files = result["cameraFileList"] as? [[String: Any]] ?? []
        let defaults = COSCredentials(json: result["defaultAwsStsFile"] as? [String: Any] ?? [:])
            ?? COSCredentials(json: result)
        return files.map { item in
            let credentials = COSCredentials(json: item["awsStsFile"] as? [String: Any] ?? [:]) ?? defaults
            let bucket = item["bucket"] as? String ?? ""
            return CameraEvent(name: item["videoEventName"] as? String ?? "Event",
                        triggerTime: (item["triggerTime"] as? NSNumber)?.int64Value ?? 0,
                        snapshotName: item["snapshotName"] as? String ?? "",
                        videoName: item["videoName"] as? String ?? "",
                        videoLen: item["videoLen"] as? Int ?? 0,
                        did: item["deviceId"] as? String ?? "",
                        path: item["path"] as? String ?? "",
                        bucket: bucket.isEmpty ? (credentials?.bucket ?? "") : bucket,
                        key: item["key"] as? String ?? "",
                        credentials: credentials,
                        isSliced: item["isSliced"] as? Bool ?? false)
        }
    }

    // MARK: - P2P live-stream bootstrap (aqara.ts getP2PInfo / signP2PKey)

    struct P2PInfo {
        let p2pId: String            // e.g. "AQARADE-NNNNNN-XXXXX" (PPCS/TUTK device id)
        let initStringApp: String    // "<encoded masters>:<ppcs key>"
        let devP2pPublicKey: String  // hex X25519 public key of the camera
    }

    struct P2PSign {
        let sign: String             // hex, presented to the camera in the 0x1000 login
        let p2pDevPublicKey: String  // hex X25519 public key (may duplicate P2PInfo's)
        let time: String             // ms timestamp the cloud signed; echoed as login "timestamp"
    }

    func p2pInfo(did: String) async throws -> P2PInfo {
        let res = try await request("GET", "/app/v1.0/lumi/devex/camera/p2p/info", query: [("did", did)])
        guard let r = res["result"] as? [String: Any],
              let p2pId = r["p2pId"] as? String,
              let initStr = r["initStringApp"] as? String else {
            throw AqaraError.badResponse("p2p/info: \(res)")
        }
        return P2PInfo(p2pId: p2pId, initStringApp: initStr,
                       devP2pPublicKey: r["devP2pPublicKey"] as? String ?? "")
    }

    func p2pSign(did: String, appPublicKeyHex: String) async throws -> P2PSign {
        let body: [String: Any] = ["did": did, "p2pAppPublicKey": appPublicKeyHex, "devPwd": ""]
        let res = try await request("POST", "/app/v1.0/lumi/devex/camera/p2p/sign", jsonBody: body)
        guard let r = res["result"] as? [String: Any], let sign = r["sign"] as? String else {
            throw AqaraError.badResponse("p2p/sign: \(res)")
        }
        // The cloud has been seen returning `time` both as a JSON string and as a number.
        let time: String
        if let s = r["time"] as? String { time = s }
        else if let n = r["time"] as? NSNumber { time = n.stringValue }
        else { time = "" }
        return P2PSign(sign: sign, p2pDevPublicKey: r["p2pDevPublicKey"] as? String ?? "", time: time)
    }

    /// Read device attributes (battery, wifi, power mode, ...).
    func status(did: String, attrs: [String]) async throws -> [String: String] {
        let body: [String: Any] = ["data": [["options": attrs, "subjectId": did]]]
        let res = try await request("POST", "/app/v1.0/lumi/res/query", jsonBody: body)
        var out: [String: String] = [:]
        for item in (res["result"] as? [[String: Any]] ?? []) {
            if let a = item["attr"] as? String { out[a] = "\(item["value"] ?? "")" }
        }
        return out
    }
}

enum AqaraError: Error, CustomStringConvertible {
    case crypto(String), api(Int, String), badResponse(String)
    var description: String {
        switch self {
        case .crypto(let m): return "crypto: \(m)"
        case .api(let c, let m): return "api code=\(c): \(m)"
        case .badResponse(let m): return "bad response: \(m)"
        }
    }
}
