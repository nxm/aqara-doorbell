import XCTest
import Foundation
import AppKit
import AVFoundation
@testable import AqaraMenuBar

final class EventMediaTests: XCTestCase {
    let key = "000102030405060708090a0b0c0d0e0f"
    let cipher = Data([0x1a,0x01,0x3f,0x65,0xd5,0x75,0x82,0x66,0x35,0xec,0xc5,0xbb,0x98,0x51,0x01,0xc2,
                       0x06,0x6d,0x51,0xe4,0xe2,0x27,0x12,0xf5,0x33,0x5b,0x3e,0x02,0x41,0xe7,0x76,0x72])
    let plain = Data([0xff,0xd8,0xff,0xe0,0x00,0x10,0x4a,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01])
    var credentialsJSON: [String: Any] {
        ["awsAccessKey": "test-access", "awsSecretKey": "test-secret", "sessionToken": "test-token",
         "region": "eu-frankfurt", "endpoint": "cos.eu-frankfurt.myqcloud.com", "bucketName": "test-bucket"]
    }
    func response() -> [String: Any] {
        ["result": ["defaultAwsStsFile": credentialsJSON, "cameraFileList": [
            ["deviceId": "device", "triggerTime": 1234567890123 as Int64, "path": "folder/",
             "snapshotName": "a b+c.jpg", "videoName": "clip.mp4", "key": key, "isSliced": false]
        ]]]
    }

    func testDecryptionAgainstOpenSSLVectorAndPaddingFailures() throws {
        XCTAssertEqual(try AqaraCOSCrypto.decrypt(cipher, eventKey: key), plain)
        XCTAssertEqual(try AqaraCOSCrypto.decrypt(cipher, eventKey: key.uppercased()), plain)
        XCTAssertThrowsError(try AqaraCOSCrypto.decrypt(cipher, eventKey: "invalid"))
        XCTAssertThrowsError(try AqaraCOSCrypto.decrypt(Data(cipher.dropLast()), eventKey: key))
        var damaged = cipher; damaged[15] ^= 1
        XCTAssertThrowsError(try AqaraCOSCrypto.decrypt(damaged, eventKey: key))
    }

    func testSigningMatchesIndependentPythonVector() throws {
        let formatter = ISO8601DateFormatter()
        let request = try COSRequestSigner.request(object: "folder/a b+c.jpg", bucket: "test-bucket",
            credentials: COSCredentials(json: credentialsJSON)!, date: formatter.date(from: "2026-10-13T08:00:00Z")!)
        XCTAssertEqual(request.url?.absoluteString, "https://test-bucket.cos.eu-frankfurt.myqcloud.com/folder/a%20b%2Bc.jpg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "test-token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.hasSuffix(
            "Signature=675b79b3ad63be3c3869de7ea0d245144a8aea4f256bf99c30fb83e640752f05"))
    }

    func testEventMetadataAndCredentialFallback() {
        let event = AqaraCloud.parseEvents(response())[0]
        XCTAssertEqual(event.triggerTime, 1234567890123)
        XCTAssertEqual(event.key, key)
        XCTAssertEqual(event.bucket, "test-bucket")
        XCTAssertEqual(event.credentials?.accessKey, "test-access")
        XCTAssertFalse(event.isSliced)
        var root = response()["result"] as! [String: Any]
        var items = root["cameraFileList"] as! [[String: Any]]
        var own = credentialsJSON; own["awsAccessKey"] = "event-access"
        items[0]["awsStsFile"] = own; items[0]["bucket"] = "event-bucket"
        root["cameraFileList"] = items
        let overridden = AqaraCloud.parseEvents(["result": root])[0]
        XCTAssertEqual(overridden.credentials?.accessKey, "event-access")
        XCTAssertEqual(overridden.bucket, "event-bucket")
    }

    func testRealCOSCaptureWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["AQARA_COS_CAPTURE"] else {
            throw XCTSkip("Set AQARA_COS_CAPTURE to a local event response for the live COS check")
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let event = try XCTUnwrap(AqaraCloud.parseEvents(json).first { $0.triggerTime == 1791819925717 })
        let cloud = AqaraCloud(config: .init(baseURL: "https://unused.invalid", appId: "", appKey: "", phoneId: ""))
        let media = COSEventMedia(cloud: cloud, homeId: "unused")
        let jpeg = try await media.snapshot(event)
        XCTAssertEqual(COSRequestSigner.hash(jpeg), "87a027bbea635e37cad43ef6faffbad9c91c0628eb208b0c443343e3fbfc8d66")
        XCTAssertNotNil(NSImage(data: jpeg))
        let clip = try await media.video(event)
        XCTAssertEqual(COSRequestSigner.hash(try Data(contentsOf: clip)), "c3a2f2f40f7b41faa5729fa369528a1c1efa9f43d4f15ae90b5f1d4cce54b487")
        let playable = try await AVURLAsset(url: clip).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testDownloadDecryptAndCache() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaURLProtocol.self]
        let session = URLSession(configuration: config)
        let cloud = AqaraCloud(config: .init(baseURL: "https://unused.invalid", appId: "", appKey: "", phoneId: ""))
        let media = COSEventMedia(cloud: cloud, homeId: "home", session: session)
        let event = AqaraCloud.parseEvents(response())[0]
        MediaURLProtocol.requests = 0
        MediaURLProtocol.data = cipher
        let first = try await media.snapshot(event)
        let second = try await media.snapshot(event)
        XCTAssertEqual(first, plain); XCTAssertEqual(second, plain)
        XCTAssertEqual(MediaURLProtocol.requests, 1)
    }
}

private final class MediaURLProtocol: URLProtocol {
    static var requests = 0
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
