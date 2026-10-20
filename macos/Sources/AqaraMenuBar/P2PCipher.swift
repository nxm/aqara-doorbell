import Foundation

// Port of p2p/cipher.cpp: PPCS transport cipher, PPPP/lumi framing, init-string decode.

enum PPCS {
    static let table: [UInt8] = [
        0x7c,0x9c,0xe8,0x4a,0x13,0xde,0xdc,0xb2,0x2f,0x21,0x23,0xe4,0x30,0x7b,0x3d,0x8c,0xbc,0x0b,0x27,
        0x0c,0x3c,0xf7,0x9a,0xe7,0x08,0x71,0x96,0x00,0x97,0x85,0xef,0xc1,0x1f,0xc4,0xdb,0xa1,0xc2,0xeb,
        0xd9,0x01,0xfa,0xba,0x3b,0x05,0xb8,0x15,0x87,0x83,0x28,0x72,0xd1,0x8b,0x5a,0xd6,0xda,0x93,0x58,
        0xfe,0xaa,0xcc,0x6e,0x1b,0xf0,0xa3,0x88,0xab,0x43,0xc0,0x0d,0xb5,0x45,0x38,0x4f,0x50,0x22,0x66,
        0x20,0x7f,0x07,0x5b,0x14,0x98,0x1d,0x9b,0xa7,0x2a,0xb9,0xa8,0xcb,0xf1,0xfc,0x49,0x47,0x06,0x3e,
        0xb1,0x0e,0x04,0x3a,0x94,0x5e,0xee,0x54,0x11,0x34,0xdd,0x4d,0xf9,0xec,0xc7,0xc9,0xe3,0x78,0x1a,
        0x6f,0x70,0x6b,0xa4,0xbd,0xa9,0x5d,0xd5,0xf8,0xe5,0xbb,0x26,0xaf,0x42,0x37,0xd8,0xe1,0x02,0x0a,
        0xae,0x5f,0x1c,0xc5,0x73,0x09,0x4e,0x69,0x24,0x90,0x6d,0x12,0xb3,0x19,0xad,0x74,0x8a,0x29,0x40,
        0xf5,0x2d,0xbe,0xa5,0x59,0xe0,0xf4,0x79,0xd2,0x4b,0xce,0x89,0x82,0x48,0x84,0x25,0xc6,0x91,0x2b,
        0xa2,0xfb,0x8f,0xe9,0xa6,0xb0,0x9e,0x3f,0x65,0xf6,0x03,0x31,0x2e,0xac,0x0f,0x95,0x2c,0x5c,0xed,
        0x39,0xb7,0x33,0x6c,0x56,0x7e,0xb4,0xa0,0xfd,0x7a,0x81,0x53,0x51,0x86,0x8d,0x9f,0x77,0xff,0x6a,
        0x80,0xdf,0xe2,0xbf,0x10,0xd7,0x75,0x64,0x57,0x76,0xf3,0x55,0xcd,0xd0,0xc8,0x18,0xe6,0x36,0x41,
        0x62,0xcf,0x99,0xf2,0x32,0x4c,0x67,0x60,0x61,0x92,0xca,0xd3,0xea,0x63,0x7d,0x16,0xb6,0x8e,0xd4,
        0x68,0x35,0xc3,0x52,0x9d,0x46,0x44,0x1e,0x17]

    static let initLUT: [UInt8] = [
        0x49,0x59,0x43,0x3d,0xb5,0xbf,0x6d,0xa3,0x47,0x53,0x4f,0x61,0x65,0xe3,0x71,0xe9,0x67,0x7f,
        0x02,0x03,0x0b,0xad,0xb3,0x89,0x2b,0x2f,0x35,0xc1,0x6b,0x8b,0x95,0x97,0x11,0xe5,0xa7,0x0d,
        0xef,0xf1,0x05,0x07,0x83,0xfb,0x9d,0x3b,0xc5,0xc7,0x13,0x17,0x1d,0x1f,0x25,0x29,0xd3,0xdf]

    private static func seeds(_ key: [UInt8]) -> [UInt8] {
        let klen = min(key.count, 20)
        var total: UInt32 = 0, sx: UInt32 = 0, s3: UInt32 = 0
        for i in 0..<klen { let b = UInt32(key[i]); total &+= b; sx ^= b; s3 &+= (b &* 0xab) / 512 }
        let negTotal = UInt8(truncatingIfNeeded: -Int(total & 0xffffffff))
        return [UInt8(total & 0xff), negTotal, UInt8(s3 & 0xff), UInt8(sx & 0xff)]
    }

    static func encrypt(key: [UInt8], data: inout [UInt8]) {
        guard !key.isEmpty, !data.isEmpty else { return }
        let sd = seeds(key)
        data[0] = table[Int(sd[0])] ^ data[0]
        var fb = data[0]
        for i in 1..<data.count {
            data[i] = table[Int((UInt16(sd[Int(fb & 3)]) + UInt16(fb)) & 0xff)] ^ data[i]
            fb = data[i]
        }
    }

    static func decrypt(key: [UInt8], data: inout [UInt8]) {
        guard !key.isEmpty, !data.isEmpty else { return }
        let sd = seeds(key)
        var fb = data[0]
        data[0] = table[Int(sd[0])] ^ data[0]
        for i in 1..<data.count {
            let orig = data[i]
            data[i] = table[Int((UInt16(sd[Int(fb & 3)]) + UInt16(fb)) & 0xff)] ^ data[i]
            fb = orig
        }
    }

    static func buildPPPP(_ msgType: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4 + payload.count)
        out[0] = 0xF1; out[1] = msgType
        out[2] = UInt8((payload.count >> 8) & 0xff); out[3] = UInt8(payload.count & 0xff)
        if !payload.isEmpty { out.replaceSubrange(4..<(4 + payload.count), with: payload) }
        return out
    }

    /// 20-byte punch packet from "PRE-123456-SUF".
    static func punchPayload(_ p2pId: String) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        let parts = p2pId.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let pre = parts.count > 0 ? parts[0] : ""
        let numStr = parts.count > 1 ? parts[1] : ""
        let suf = parts.count > 2 ? parts[2] : ""
        let preBytes = Array(pre.utf8.prefix(7))
        for (i, c) in preBytes.enumerated() { b[i] = c }
        let n = UInt32(numStr) ?? 0
        b[9] = UInt8((n >> 16) & 0xff); b[10] = UInt8((n >> 8) & 0xff); b[11] = UInt8(n & 0xff)
        let sufBytes = Array(suf.utf8.prefix(8))
        for (i, c) in sufBytes.enumerated() { b[12 + i] = c }
        return b
    }

    /// lumi control frame: "lumi" + type(LE32) + seq(LE32) + len(LE32) + payload.
    static func buildLumiFrame(type: UInt32, payload: [UInt8], seq: UInt32) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 16 + payload.count)
        f[0] = 0x6c; f[1] = 0x75; f[2] = 0x6d; f[3] = 0x69   // "lumi"
        f[4] = UInt8(type & 0xff); f[5] = UInt8((type >> 8) & 0xff); f[6] = UInt8((type >> 16) & 0xff); f[7] = UInt8((type >> 24) & 0xff)
        f[8] = UInt8(seq & 0xff); f[9] = UInt8((seq >> 8) & 0xff); f[10] = UInt8((seq >> 16) & 0xff); f[11] = UInt8((seq >> 24) & 0xff)
        let len = UInt32(payload.count)
        f[12] = UInt8(len & 0xff); f[13] = UInt8((len >> 8) & 0xff); f[14] = UInt8((len >> 16) & 0xff); f[15] = UInt8((len >> 24) & 0xff)
        if !payload.isEmpty { f.replaceSubrange(16..<(16 + payload.count), with: payload) }
        return f
    }

    /// Decode init-string ("<hex>:<key>") -> master server IPs + key.
    static func decodeInitString(_ initStr: String) -> (masters: [String], key: String)? {
        var s = initStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{") {
            // {"InitString":"..."} / {"initString":"..."}
            if let r = s.range(of: "\"InitString\"") ?? s.range(of: "\"initString\"") {
                if let colon = s[r.upperBound...].firstIndex(of: ":") {
                    let after = s[s.index(after: colon)...]
                    if let q1 = after.firstIndex(of: "\"") {
                        let rest = after[after.index(after: q1)...]
                        if let q2 = rest.firstIndex(of: "\"") { s = String(rest[..<q2]) }
                    }
                }
            }
        }
        var key = ""
        var enc = s
        if let colon = s.firstIndex(of: ":") { enc = String(s[..<colon]); key = String(s[s.index(after: colon)...]) }
        guard enc.count >= 2, enc.count % 2 == 0 else { return nil }
        let encUpper = Array(enc.uppercased().utf8)
        var out = [UInt8](); out.reserveCapacity(encUpper.count / 2)
        let pairs = encUpper.count / 2
        for i in 0..<pairs {
            var running: UInt8 = 0x39
            for j in 0..<i { running ^= out[j] }
            let hi = encUpper[2 * i], lo = encUpper[2 * i + 1]
            let rawN = UInt8(truncatingIfNeeded: Int(lo) + (Int(hi) << 4) + 0xaf)
            out.append(initLUT[i % 54] ^ running ^ rawN)
        }
        let text = String(decoding: out, as: UTF8.self)
        let masters = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return masters.isEmpty ? nil : (masters, key)
    }
}
