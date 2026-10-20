import Foundation
import CommonCrypto

/// G410 unsliced COS snapshots/clips. eventKey is the API event's 32-hex key.
public enum AqaraCOSCrypto {
    public enum DecryptionError: Error {
        case invalidEventKey
        case invalidCiphertextLength
        case invalidPadding
        case cryptorFailed(CCCryptorStatus)
    }

    public static let iv: [UInt8] = [
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c
    ]

    public static func deriveKey(eventKey: String) throws -> Data {
        let hex = Array(eventKey.utf8)
        guard hex.count == 32 else { throw DecryptionError.invalidEventKey }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var key = Data()
        for i in stride(from: 0, to: 32, by: 2) {
            guard let high = nibble(hex[i]), let low = nibble(hex[i + 1]) else {
                throw DecryptionError.invalidEventKey
            }
            key.append((high << 4) | low)
        }
        return key
    }

    public static func decrypt(_ ciphertext: Data, eventKey: String) throws -> Data {
        let key = try deriveKey(eventKey: eventKey)
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw DecryptionError.invalidCiphertextLength
        }
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0), // CBC; validate and remove PKCS#7 below
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, ciphertext.count,
                                out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DecryptionError.cryptorFailed(status) }
        output.count = moved
        guard let padding = output.last, padding >= 1, padding <= kCCBlockSizeAES128,
              output.suffix(Int(padding)).allSatisfy({ $0 == padding }) else {
            throw DecryptionError.invalidPadding
        }
        output.removeLast(Int(padding))
        return output
    }
}
