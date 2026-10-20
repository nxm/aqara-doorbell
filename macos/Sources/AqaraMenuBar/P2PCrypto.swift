import Foundation
import CryptoKit

// Ported from resonaura/aqara-g5pro-mqtt native engine (crypto/chacha20.cpp,
// p2p/cipher.cpp) + decryptor.ts (hsalsa20). Pure Swift, no ffmpeg/native deps.

// MARK: - ChaCha20 (djb) + Aqara frame decryption

enum ChaCha20 {
    @inline(__always) static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    @inline(__always) static func qr(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    @inline(__always) static func u32le(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | (UInt32(p[1]) << 8) | (UInt32(p[2]) << 16) | (UInt32(p[3]) << 24)
    }

    static func block(key: [UInt8], nonce: [UInt8], counter: UInt64, out: inout [UInt8]) {
        var st = [UInt32](repeating: 0, count: 16)
        st[0] = 0x61707865; st[1] = 0x3320646e; st[2] = 0x79622d32; st[3] = 0x6b206574
        key.withUnsafeBufferPointer { kb in
            for i in 0..<8 { st[4 + i] = u32le(kb.baseAddress! + i * 4) }
        }
        st[12] = UInt32(counter & 0xffffffff)
        st[13] = UInt32((counter >> 32) & 0xffffffff)
        nonce.withUnsafeBufferPointer { nb in
            st[14] = u32le(nb.baseAddress!); st[15] = u32le(nb.baseAddress! + 4)
        }
        var w = st
        for _ in 0..<10 {
            qr(&w, 0, 4, 8, 12); qr(&w, 1, 5, 9, 13); qr(&w, 2, 6, 10, 14); qr(&w, 3, 7, 11, 15)
            qr(&w, 0, 5, 10, 15); qr(&w, 1, 6, 11, 12); qr(&w, 2, 7, 8, 13); qr(&w, 3, 4, 9, 14)
        }
        for i in 0..<16 {
            let v = w[i] &+ st[i]
            out[i * 4] = UInt8(v & 0xff); out[i * 4 + 1] = UInt8((v >> 8) & 0xff)
            out[i * 4 + 2] = UInt8((v >> 16) & 0xff); out[i * 4 + 3] = UInt8((v >> 24) & 0xff)
        }
    }

    static func xorStream(key: [UInt8], nonce: [UInt8], counter: UInt64, data: inout [UInt8], offset: Int, len: Int) {
        var blk = [UInt8](repeating: 0, count: 64)
        var off = 0
        while off < len {
            block(key: key, nonce: nonce, counter: counter + UInt64(off / 64), out: &blk)
            let chunk = min(64, len - off)
            for i in 0..<chunk { data[offset + off + i] ^= blk[i] }
            off += chunk
        }
    }

    /// Video frame: [nonce(8)][nalCount(1)][table nalCount*(off u32,len u32)][tail NALs].
    /// XOR 16 bytes at pos 32,192,352,... (stride 160) of each NAL with keystream[0:16].
    static func decryptVideo(_ payload: inout [UInt8], key: [UInt8]) {
        let len = payload.count
        guard len >= 10 else { return }
        let nalCount = Int(payload[8])
        let tableEnd = 9 + nalCount * 8
        guard nalCount > 0, tableEnd < len else { return }
        let nonce = Array(payload[0..<8])
        var blk = [UInt8](repeating: 0, count: 64)
        block(key: key, nonce: nonce, counter: 0, out: &blk)
        let tailOff = tableEnd
        let tailLen = len - tableEnd
        for i in 0..<nalCount {
            let base = 9 + i * 8
            let off = Int(u32(payload, base))
            let nalLen = Int(u32(payload, base + 4))
            var pos = 32
            while pos + 16 <= nalLen {
                let absOff = off + pos
                if absOff + 16 > tailLen { break }
                for k in 0..<16 { payload[tailOff + absOff + k] ^= blk[k] }
                pos += 160
            }
        }
    }

    /// Audio frame: [AVIO hdr 32][nonce(8)][audio]; payloadLen u32 at offset 28.
    static func decryptAudio(_ payload: inout [UInt8], key: [UInt8]) {
        let len = payload.count
        guard len >= 40 else { return }
        let payloadLen = Int(u32(payload, 28))
        guard payloadLen > 8, 32 + payloadLen <= len else { return }
        let nonce = Array(payload[32..<40])
        let audioLen = payloadLen - 8
        xorStream(key: key, nonce: nonce, counter: 0, data: &payload, offset: 40, len: audioLen)
    }

    @inline(__always) static func u32(_ a: [UInt8], _ i: Int) -> UInt32 {
        UInt32(a[i]) | (UInt32(a[i + 1]) << 8) | (UInt32(a[i + 2]) << 16) | (UInt32(a[i + 3]) << 24)
    }
}

// MARK: - HSalsa20 key derivation (shared secret -> 32-byte frame key)

enum HSalsa20 {
    @inline(__always) static func R(_ v: UInt32, _ c: UInt32) -> UInt32 { (v << c) | (v >> (32 - c)) }

    static func derive(_ shared: [UInt8]) -> [UInt8] {
        func rd(_ i: Int) -> UInt32 {
            UInt32(shared[i]) | (UInt32(shared[i+1]) << 8) | (UInt32(shared[i+2]) << 16) | (UInt32(shared[i+3]) << 24)
        }
        let c0: UInt32 = 0x61707865, c1: UInt32 = 0x3320646e, c2: UInt32 = 0x79622d32, c3: UInt32 = 0x6b206574
        let k0 = rd(0), k1 = rd(4), k2 = rd(8), k3 = rd(12), k4 = rd(16), k5 = rd(20), k6 = rd(24), k7 = rd(28)
        var x0 = c0, x1 = k0, x2 = k1, x3 = k2
        var x4 = k3, x5 = c1, x6: UInt32 = 0, x7: UInt32 = 0
        var x8: UInt32 = 0, x9: UInt32 = 0, x10 = c2, x11 = k4
        var x12 = k5, x13 = k6, x14 = k7, x15 = c3
        for _ in 0..<10 {
            x4 ^= R(x0 &+ x12, 7);  x8 ^= R(x4 &+ x0, 9);  x12 ^= R(x8 &+ x4, 13);  x0 ^= R(x12 &+ x8, 18)
            x9 ^= R(x5 &+ x1, 7);   x13 ^= R(x9 &+ x5, 9);  x1 ^= R(x13 &+ x9, 13);  x5 ^= R(x1 &+ x13, 18)
            x14 ^= R(x10 &+ x6, 7); x2 ^= R(x14 &+ x10, 9); x6 ^= R(x2 &+ x14, 13);  x10 ^= R(x6 &+ x2, 18)
            x3 ^= R(x15 &+ x11, 7); x7 ^= R(x3 &+ x15, 9);  x11 ^= R(x7 &+ x3, 13);  x15 ^= R(x11 &+ x7, 18)
            x1 ^= R(x0 &+ x3, 7);   x2 ^= R(x1 &+ x0, 9);   x3 ^= R(x2 &+ x1, 13);   x0 ^= R(x3 &+ x2, 18)
            x6 ^= R(x5 &+ x4, 7);   x7 ^= R(x6 &+ x5, 9);   x4 ^= R(x7 &+ x6, 13);   x5 ^= R(x4 &+ x7, 18)
            x11 ^= R(x10 &+ x9, 7); x8 ^= R(x11 &+ x10, 9); x9 ^= R(x8 &+ x11, 13);  x10 ^= R(x9 &+ x8, 18)
            x12 ^= R(x15 &+ x14, 7);x13 ^= R(x12 &+ x15, 9);x14 ^= R(x13 &+ x12, 13); x15 ^= R(x14 &+ x13, 18)
        }
        var out = [UInt8](repeating: 0, count: 32)
        for (idx, v) in [x0, x5, x10, x15, x6, x7, x8, x9].enumerated() {
            out[idx*4] = UInt8(v & 0xff); out[idx*4+1] = UInt8((v >> 8) & 0xff)
            out[idx*4+2] = UInt8((v >> 16) & 0xff); out[idx*4+3] = UInt8((v >> 24) & 0xff)
        }
        return out
    }
}

// MARK: - X25519 ECDH (CryptoKit) + full key derivation

enum P2PKeys {
    /// Generate ephemeral X25519 keypair; returns (privateKey, pubHex).
    static func generate() -> (Curve25519.KeyAgreement.PrivateKey, String) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())
    }

    /// vk = ak = HSalsa20( X25519(appPriv, devPub) ). Raw ECDH (no HKDF), like node diffieHellman.
    static func frameKey(appPriv: Curve25519.KeyAgreement.PrivateKey, devPubHex: String) -> [UInt8]? {
        guard let devPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hexToBytes(devPubHex)) else { return nil }
        guard let shared = try? appPriv.sharedSecretFromKeyAgreement(with: devPub) else { return nil }
        let raw = shared.withUnsafeBytes { Array($0) }   // 32 raw bytes
        return HSalsa20.derive(raw)
    }
}

func hexToBytes(_ hex: String) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(hex.count / 2)
    var idx = hex.startIndex
    while let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex), next <= hex.endIndex {
        if let b = UInt8(hex[idx..<next], radix: 16) { out.append(b) }
        idx = next
        if idx == hex.endIndex { break }
    }
    return out
}
