import Foundation
import CryptoKit

struct COSCredentials: Sendable {
    let accessKey: String
    let secretKey: String
    let sessionToken: String
    let region: String
    let endpoint: String
    let bucket: String

    init?(json: [String: Any]) {
        guard let accessKey = json["awsAccessKey"] as? String, !accessKey.isEmpty,
              let secretKey = json["awsSecretKey"] as? String, !secretKey.isEmpty,
              let token = json["sessionToken"] as? String, !token.isEmpty,
              let region = json["region"] as? String,
              let endpoint = json["endpoint"] as? String else { return nil }
        self.accessKey = accessKey; self.secretKey = secretKey; sessionToken = token
        self.region = region; self.endpoint = endpoint
        bucket = json["bucketName"] as? String ?? ""
    }
}

enum EventMediaError: Error, LocalizedError {
    case unavailable, unsupported, http(Int), invalidMedia
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This event’s media is no longer available."
        case .unsupported: return "This recording format is not supported yet."
        case .http(let code): return "Could not download this recording (HTTP \(code)). Try again."
        case .invalidMedia: return "The downloaded media could not be opened."
        }
    }
}

enum COSRequestSigner {
    static func request(object: String, bucket: String, credentials c: COSCredentials,
                        date: Date = Date()) throws -> URLRequest {
        let endpoint = c.endpoint.replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !bucket.isEmpty, !object.isEmpty,
              !endpoint.contains("/"), !endpoint.contains(":"),
              endpoint.hasSuffix(".myqcloud.com") else { throw EventMediaError.unavailable }
        let host = "\(bucket).\(endpoint)"
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/")
        guard let path = ("/" + object).addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "https://\(host)\(path)") else { throw EventMediaError.unavailable }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let emptyHash = hash(Data())
        let headers = "host:\(host)\nx-amz-content-sha256:\(emptyHash)\nx-amz-date:\(timestamp)\nx-amz-security-token:\(c.sessionToken)\n"
        let signed = "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
        let canonical = "GET\n\(path)\n\n\(headers)\n\(signed)\n\(emptyHash)"
        let scope = "\(day)/\(c.region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash(Data(canonical.utf8)))"
        var key = hmac(Data(("AWS4" + c.secretKey).utf8), day)
        key = hmac(key, c.region); key = hmac(key, "s3"); key = hmac(key, "aws4_request")
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(emptyHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(c.sessionToken, forHTTPHeaderField: "x-amz-security-token")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(c.accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func hmac(_ key: Data, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }
}

/// Media requests never open P2P or wake the camera. STS credentials are refreshed once on 403.
actor COSEventMedia {
    let cloud: AqaraCloud
    let homeId: String
    private let session: URLSession
    private var thumbnails: [String: Data] = [:]
    private var thumbnailOrder: [String] = []
    private var videos: [String: URL] = [:]
    private var videoOrder: [String] = []
    private let directory: URL

    init(cloud: AqaraCloud, homeId: String, session: URLSession? = nil) {
        self.cloud = cloud; self.homeId = homeId
        self.session = session ?? URLSession(configuration: .ephemeral)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aqara-events-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func snapshot(_ event: AqaraCloud.CameraEvent) async throws -> Data {
        let id = event.mediaCacheKey + ":jpg"
        if let data = thumbnails[id] { return data }
        let data = try await download(event, video: false)
        guard data.starts(with: [0xff, 0xd8, 0xff]) else { throw EventMediaError.invalidMedia }
        if thumbnails[id] == nil { thumbnailOrder.append(id) }
        thumbnails[id] = data
        while thumbnailOrder.count > 40 { thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) }
        return data
    }

    func video(_ event: AqaraCloud.CameraEvent) async throws -> URL {
        let id = event.mediaCacheKey + ":mp4"
        if let url = videos[id], FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await download(event, video: true)
        guard data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) else { throw EventMediaError.invalidMedia }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(COSRequestSigner.hash(Data(id.utf8)) + ".mp4")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if videos[id] == nil { videoOrder.append(id) }
        videos[id] = url
        while videoOrder.count > 3 {
            if let old = videos.removeValue(forKey: videoOrder.removeFirst()) { try? FileManager.default.removeItem(at: old) }
        }
        return url
    }

    private func download(_ event: AqaraCloud.CameraEvent, video: Bool, refresh: Bool = true) async throws -> Data {
        if event.isSliced { throw EventMediaError.unsupported }
        let name = video ? event.videoName : event.snapshotName
        guard !name.isEmpty, let credentials = event.credentials else { throw EventMediaError.unavailable }
        let request = try COSRequestSigner.request(object: event.path + name, bucket: event.bucket, credentials: credentials)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw EventMediaError.invalidMedia }
        if http.statusCode == 403, refresh {
            let events = try await cloud.events(positionId: homeId, did: event.did,
                                               sinceMs: event.triggerTime - 1, size: 10, untilMs: event.triggerTime + 1)
            guard let updated = events.first(where: { $0.id == event.id }) else { throw EventMediaError.unavailable }
            return try await download(updated, video: video, refresh: false)
        }
        guard http.statusCode == 200 else { throw EventMediaError.http(http.statusCode) }
        return try AqaraCOSCrypto.decrypt(data, eventKey: event.key)
    }
}
