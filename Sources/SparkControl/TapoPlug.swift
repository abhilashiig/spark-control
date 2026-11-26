import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

// MARK: - Models & Config

struct TapoPlugConfig: Codable, Equatable {
    var enabled = false
    var host = ""
    var mac = ""
    var model = ""
    var email = ""
    /// Seconds to keep the plug powered OFF before turning it back ON when power-cycling the DGX Spark.
    var powerCycleDelaySeconds = 10

    init(enabled: Bool = false, host: String = "", mac: String = "", model: String = "", email: String = "", powerCycleDelaySeconds: Int = 10) {
        self.enabled = enabled
        self.host = host
        self.mac = mac
        self.model = model
        self.email = email
        self.powerCycleDelaySeconds = powerCycleDelaySeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        mac = try c.decodeIfPresent(String.self, forKey: .mac) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        powerCycleDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .powerCycleDelaySeconds) ?? 10
    }
}

struct TapoDiscoveredDevice: Identifiable, Equatable, Sendable {
    var id: String { mac.isEmpty ? ip : mac }
    let ip: String
    let mac: String
    let model: String
    let deviceType: String
    let encryptType: String
    let port: Int
    let tls: Bool
}

struct TapoPlugStatus: Equatable, Sendable {
    let isOn: Bool
    let model: String
    let nickname: String
    let fwVer: String
    let hwVer: String
    let onTime: Int
    let rssi: Int?
    let currentPowerWatts: Double?
}

enum TapoPowerPhase: Equatable {
    case idle
    case checking
    case turningOff
    case waiting(remaining: Int)
    case turningOn
    case waitingForSpark
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .turningOff, .waiting, .turningOn, .waitingForSpark: return true
        case .idle, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking plug…"
        case .turningOff: return "Turning plug off…"
        case .waiting(let s): return "Off · waiting \(s)s…"
        case .turningOn: return "Turning plug on…"
        case .waitingForSpark: return "Plug on · booting Spark…"
        case .failed(let msg): return msg
        }
    }
}

enum TapoError: LocalizedError {
    case notConfigured
    case missingPassword
    case network(String)
    case protocolError(String)
    case authFailed(String)
    case cryptoError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Smart plug isn't configured yet."
        case .missingPassword: return "TP-Link password is missing. Enter it in Settings → Smart Plug."
        case .network(let m): return "Network error: \(m)"
        case .protocolError(let m): return "Tapo protocol error: \(m)"
        case .authFailed(let m): return m
        case .cryptoError(let m): return "Crypto error: \(m)"
        }
    }
}

// MARK: - macOS Keychain Storage

enum TapoKeychain {
    static let service = "com.grabians.sparkcontrol.tapo"

    @discardableResult
    static func savePassword(_ password: String, account: String) -> Bool {
        let acct = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !acct.isEmpty, let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func loadPassword(account: String) -> String? {
        let acct = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !acct.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(account: String) -> Bool {
        loadPassword(account: account)?.isEmpty == false
    }

    static func deletePassword(account: String) {
        let acct = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !acct.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Pure-Swift 256-bit Modular Math & NIST P-256 (secp256r1)

/// Fixed-width 256-bit unsigned integer (little-endian 64-bit limbs) for NIST P-256 SPAKE2+ point arithmetic.
struct U256: Equatable, Comparable, Sendable {
    var l0: UInt64
    var l1: UInt64
    var l2: UInt64
    var l3: UInt64

    static let zero = U256(0, 0, 0, 0)
    static let one  = U256(1, 0, 0, 0)

    init(_ l0: UInt64, _ l1: UInt64, _ l2: UInt64, _ l3: UInt64) {
        self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3
    }

    init(bigEndianBytes data: Data) {
        var padded = Data(repeating: 0, count: max(0, 32 - data.count))
        padded.append(data.suffix(32))
        let b = [UInt8](padded)
        func u64(_ offset: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(b[offset + i]) }
            return v
        }
        self.l3 = u64(0)
        self.l2 = u64(8)
        self.l1 = u64(16)
        self.l0 = u64(24)
    }

    var bigEndianBytes: Data {
        var out = Data(capacity: 32)
        for limb in [l3, l2, l1, l0] {
            var be = limb.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        return out
    }

    var isZero: Bool { (l0 | l1 | l2 | l3) == 0 }
    var isOdd: Bool { (l0 & 1) == 1 }

    func bit(at index: Int) -> Bool {
        switch index {
        case 0..<64: return ((l0 >> index) & 1) == 1
        case 64..<128: return ((l1 >> (index - 64)) & 1) == 1
        case 128..<192: return ((l2 >> (index - 128)) & 1) == 1
        case 192..<256: return ((l3 >> (index - 192)) & 1) == 1
        default: return false
        }
    }

    static func < (a: U256, b: U256) -> Bool {
        if a.l3 != b.l3 { return a.l3 < b.l3 }
        if a.l2 != b.l2 { return a.l2 < b.l2 }
        if a.l1 != b.l1 { return a.l1 < b.l1 }
        return a.l0 < b.l0
    }

    static func addWithCarry(_ a: U256, _ b: U256) -> (U256, Bool) {
        let (r0, c0) = a.l0.addingReportingOverflow(b.l0)
        let (t1, c1a) = a.l1.addingReportingOverflow(b.l1)
        let (r1, c1b) = t1.addingReportingOverflow(c0 ? 1 : 0)
        let c1 = c1a || c1b
        let (t2, c2a) = a.l2.addingReportingOverflow(b.l2)
        let (r2, c2b) = t2.addingReportingOverflow(c1 ? 1 : 0)
        let c2 = c2a || c2b
        let (t3, c3a) = a.l3.addingReportingOverflow(b.l3)
        let (r3, c3b) = t3.addingReportingOverflow(c2 ? 1 : 0)
        return (U256(r0, r1, r2, r3), c3a || c3b)
    }

    static func subWithBorrow(_ a: U256, _ b: U256) -> (U256, Bool) {
        let (r0, b0) = a.l0.subtractingReportingOverflow(b.l0)
        let (t1, b1a) = a.l1.subtractingReportingOverflow(b.l1)
        let (r1, b1b) = t1.subtractingReportingOverflow(b0 ? 1 : 0)
        let b1 = b1a || b1b
        let (t2, b2a) = a.l2.subtractingReportingOverflow(b.l2)
        let (r2, b2b) = t2.subtractingReportingOverflow(b1 ? 1 : 0)
        let b2 = b2a || b2b
        let (t3, b3a) = a.l3.subtractingReportingOverflow(b.l3)
        let (r3, b3b) = t3.subtractingReportingOverflow(b2 ? 1 : 0)
        return (U256(r0, r1, r2, r3), b3a || b3b)
    }

    static func modAdd(_ a: U256, _ b: U256, mod m: U256) -> U256 {
        let (s, carry) = addWithCarry(a, b)
        if carry || s >= m { return subWithBorrow(s, m).0 }
        return s
    }

    static func modSub(_ a: U256, _ b: U256, mod m: U256) -> U256 {
        let (d, borrow) = subWithBorrow(a, b)
        if borrow { return addWithCarry(d, m).0 }
        return d
    }

    static func modMul(_ a: U256, _ b: U256, mod m: U256) -> U256 {
        var res = U256.zero
        var addend = a >= m ? subWithBorrow(a, m).0 : a
        for i in 0..<256 {
            if b.bit(at: i) {
                res = modAdd(res, addend, mod: m)
            }
            addend = modAdd(addend, addend, mod: m)
        }
        return res
    }

    static func modPow(_ base: U256, _ exp: U256, mod m: U256) -> U256 {
        var res = U256.one
        var b = base >= m ? subWithBorrow(base, m).0 : base
        for i in 0..<256 {
            if exp.bit(at: i) {
                res = modMul(res, b, mod: m)
            }
            b = modMul(b, b, mod: m)
        }
        return res
    }

    /// Reduces an arbitrary-length big-endian byte sequence modulo `m`.
    static func fromBytesMod(_ data: Data, mod m: U256) -> U256 {
        var res = U256.zero
        for byte in data {
            for bitIdx in (0..<8).reversed() {
                res = modAdd(res, res, mod: m)
                if ((byte >> bitIdx) & 1) == 1 {
                    res = modAdd(res, .one, mod: m)
                }
            }
        }
        return res
    }
}

enum TapoP256 {
    static let p  = U256(0xFFFFFFFFFFFFFFFF, 0x00000000FFFFFFFF, 0x0000000000000000, 0xFFFFFFFF00000001)
    static let a  = U256(0xFFFFFFFFFFFFFFFC, 0x00000000FFFFFFFF, 0x0000000000000000, 0xFFFFFFFF00000001) // p - 3
    static let b  = U256(0x3BCE3C3E27D2604B, 0x651D06B0CC53B0F6, 0xB3EBBD55769886BC, 0x5AC635D8AA3A93E7)
    static let n  = U256(0xF3B9CAC2FC632551, 0xBCE6FAADA7179E84, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF00000000)
    static let pMinus2 = U256(0xFFFFFFFFFFFFFFFD, 0x00000000FFFFFFFF, 0x0000000000000000, 0xFFFFFFFF00000001)
    static let sqrtExp = U256(0x0000000000000000, 0x0000000040000000, 0x4000000000000000, 0x3FFFFFFFC0000000) // (p + 1) / 4

    struct Point: Equatable, Sendable {
        let x: U256
        let y: U256
    }

    static let G = Point(
        x: U256(0xF4A13945D898C296, 0x77037D812DEB33A0, 0xF8BCE6E563A440F2, 0x6B17D1F2E12C4247),
        y: U256(0xCBB6406837BF51F5, 0x2BCE33576B315ECE, 0x8EE7EB4A7C0F9E16, 0x4FE342E2FE1A7F9B)
    )

    /// RFC 9382 SPAKE2+ P-256 generator points M and N (compressed SEC1)
    static let M = try! decodeSEC1(Data(hex: "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f")!)
    static let N = try! decodeSEC1(Data(hex: "03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49")!)

    static func isOnCurve(_ pt: Point) -> Bool {
        let lhs = U256.modMul(pt.y, pt.y, mod: p)
        let x2 = U256.modMul(pt.x, pt.x, mod: p)
        let x3 = U256.modMul(x2, pt.x, mod: p)
        let ax = U256.modMul(a, pt.x, mod: p)
        let rhs = U256.modAdd(U256.modAdd(x3, ax, mod: p), b, mod: p)
        return lhs == rhs
    }

    static func neg(_ pt: Point?) -> Point? {
        guard let pt else { return nil }
        return Point(x: pt.x, y: pt.y.isZero ? .zero : U256.modSub(p, pt.y, mod: p))
    }

    static func add(_ p1: Point?, _ p2: Point?) -> Point? {
        guard let p1 else { return p2 }
        guard let p2 else { return p1 }
        let lam: U256
        if p1.x == p2.x {
            if U256.modAdd(p1.y, p2.y, mod: p).isZero { return nil }
            let x2 = U256.modMul(p1.x, p1.x, mod: p)
            let num = U256.modAdd(U256.modAdd(U256.modAdd(x2, x2, mod: p), x2, mod: p), a, mod: p)
            let den = U256.modAdd(p1.y, p1.y, mod: p)
            lam = U256.modMul(num, U256.modPow(den, pMinus2, mod: p), mod: p)
        } else {
            let num = U256.modSub(p2.y, p1.y, mod: p)
            let den = U256.modSub(p2.x, p1.x, mod: p)
            lam = U256.modMul(num, U256.modPow(den, pMinus2, mod: p), mod: p)
        }
        let x3 = U256.modSub(U256.modSub(U256.modMul(lam, lam, mod: p), p1.x, mod: p), p2.x, mod: p)
        let y3 = U256.modSub(U256.modMul(lam, U256.modSub(p1.x, x3, mod: p), mod: p), p1.y, mod: p)
        return Point(x: x3, y: y3)
    }

    static func mul(_ k: U256, _ pt: Point?) -> Point? {
        guard let pt, !k.isZero else { return nil }
        var res: Point? = nil
        var addend: Point? = pt
        for i in 0..<256 {
            if k.bit(at: i) {
                res = add(res, addend)
            }
            addend = add(addend, addend)
        }
        return res
    }

    static func decodeSEC1(_ raw: Data) throws -> Point {
        let data = Data(raw)
        guard let prefix = data.first else { throw TapoError.cryptoError("Empty SEC1 point") }
        if prefix == 0x04 && data.count == 65 {
            let x = U256(bigEndianBytes: data.subdata(in: 1..<33))
            let y = U256(bigEndianBytes: data.subdata(in: 33..<65))
            let pt = Point(x: x, y: y)
            guard isOnCurve(pt) else { throw TapoError.cryptoError("SEC1 point not on P-256 curve") }
            return pt
        }
        if (prefix == 0x02 || prefix == 0x03) && data.count == 33 {
            let x = U256(bigEndianBytes: data.subdata(in: 1..<33))
            let x2 = U256.modMul(x, x, mod: p)
            let x3 = U256.modMul(x2, x, mod: p)
            let ax = U256.modMul(a, x, mod: p)
            let rhs = U256.modAdd(U256.modAdd(x3, ax, mod: p), b, mod: p)
            var y = U256.modPow(rhs, sqrtExp, mod: p)
            if y.isOdd != ((prefix & 1) == 1) {
                y = U256.modSub(p, y, mod: p)
            }
            let pt = Point(x: x, y: y)
            guard isOnCurve(pt) else { throw TapoError.cryptoError("Decompressed SEC1 point not on P-256 curve") }
            return pt
        }
        throw TapoError.cryptoError("Unsupported SEC1 point format")
    }

    static func encodeUncompressed(_ pt: Point) -> Data {
        var out = Data([0x04])
        out.append(pt.x.bigEndianBytes)
        out.append(pt.y.bigEndianBytes)
        return out
    }
}

// MARK: - Hardware-Accelerated AES-CCM, AES-CMAC, PBKDF2, HKDF

enum TapoCrypto {
    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }

    static func aesEncryptBlock(_ block: Data, key: Data) throws -> Data {
        var out = Data(count: 16)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            block.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuf.baseAddress, key.count,
                        nil,
                        inBuf.baseAddress, 16,
                        outBuf.baseAddress, 16,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess, outLen == 16 else {
            throw TapoError.cryptoError("AES block encrypt failed (\(status))")
        }
        return out
    }

    private static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    /// RFC 3610 AES-CCM (no AAD, 12-byte nonce, 16-byte tag)
    static func aesCCMEncrypt(key: Data, nonce: Data, plaintext rawPlaintext: Data, tagLength: Int = 16) throws -> Data {
        let plaintext = Data(rawPlaintext)
        let key = Data(key)
        let nonce = Data(nonce)
        let q = 15 - nonce.count
        let flagsB0 = UInt8((((tagLength - 2) / 2) << 3) | (q - 1))
        var b0 = Data([flagsB0])
        b0.append(nonce)
        b0.append(contentsOf: bigEndianLength(plaintext.count, bytes: q))

        var x = try aesEncryptBlock(b0, key: key)
        var offset = 0
        while offset < plaintext.count {
            let end = min(offset + 16, plaintext.count)
            var chunk = plaintext.subdata(in: offset..<end)
            if chunk.count < 16 { chunk.append(Data(repeating: 0, count: 16 - chunk.count)) }
            x = try aesEncryptBlock(xor(x, chunk), key: key)
            offset += 16
        }
        let tag = x.prefix(tagLength)

        var ctr0 = Data([UInt8(q - 1)])
        ctr0.append(nonce)
        ctr0.append(Data(repeating: 0, count: q))
        let s0 = try aesEncryptBlock(ctr0, key: key)
        let encTag = xor(tag, s0.prefix(tagLength))

        var out = Data(capacity: plaintext.count + tagLength)
        var ctr = 1
        offset = 0
        while offset < plaintext.count {
            let end = min(offset + 16, plaintext.count)
            let chunk = plaintext.subdata(in: offset..<end)
            var ctri = Data([UInt8(q - 1)])
            ctri.append(nonce)
            ctri.append(contentsOf: bigEndianLength(ctr, bytes: q))
            let ks = try aesEncryptBlock(ctri, key: key)
            out.append(xor(chunk, ks.prefix(chunk.count)))
            ctr += 1
            offset += 16
        }
        out.append(encTag)
        return out
    }

    static func aesCCMDecrypt(key: Data, nonce: Data, ciphertextAndTag rawData: Data, tagLength: Int = 16) throws -> Data {
        let ciphertextAndTag = Data(rawData)
        let key = Data(key)
        let nonce = Data(nonce)
        guard ciphertextAndTag.count >= tagLength else {
            throw TapoError.cryptoError("AES-CCM ciphertext shorter than tag")
        }
        let ct = Data(ciphertextAndTag.prefix(ciphertextAndTag.count - tagLength))
        let encTag = Data(ciphertextAndTag.suffix(tagLength))
        let q = 15 - nonce.count

        var ctr0 = Data([UInt8(q - 1)])
        ctr0.append(nonce)
        ctr0.append(Data(repeating: 0, count: q))
        let s0 = try aesEncryptBlock(ctr0, key: key)
        let tag = xor(Data(encTag), s0.prefix(tagLength))

        var plaintext = Data(capacity: ct.count)
        var ctr = 1
        var offset = 0
        while offset < ct.count {
            let end = min(offset + 16, ct.count)
            let chunk = ct.subdata(in: offset..<end)
            var ctri = Data([UInt8(q - 1)])
            ctri.append(nonce)
            ctri.append(contentsOf: bigEndianLength(ctr, bytes: q))
            let ks = try aesEncryptBlock(ctri, key: key)
            plaintext.append(xor(chunk, ks.prefix(chunk.count)))
            ctr += 1
            offset += 16
        }

        let flagsB0 = UInt8((((tagLength - 2) / 2) << 3) | (q - 1))
        var b0 = Data([flagsB0])
        b0.append(nonce)
        b0.append(contentsOf: bigEndianLength(plaintext.count, bytes: q))

        var x = try aesEncryptBlock(b0, key: key)
        offset = 0
        while offset < plaintext.count {
            let end = min(offset + 16, plaintext.count)
            var chunk = plaintext.subdata(in: offset..<end)
            if chunk.count < 16 { chunk.append(Data(repeating: 0, count: 16 - chunk.count)) }
            x = try aesEncryptBlock(xor(x, chunk), key: key)
            offset += 16
        }
        guard constantTimeEqual(x.prefix(tagLength), tag) else {
            throw TapoError.cryptoError("AES-CCM authentication tag mismatch")
        }
        return plaintext
    }

    /// RFC 4493 AES-CMAC
    static func aesCMAC(key: Data, message rawMessage: Data) throws -> Data {
        let key = Data(key)
        let message = Data(rawMessage)
        let L = try aesEncryptBlock(Data(repeating: 0, count: 16), key: key)
        func dbl(_ b: Data) -> Data {
            var out = [UInt8](repeating: 0, count: 16)
            var carry: UInt8 = 0
            for i in (0..<16).reversed() {
                let byte = b[i]
                out[i] = (byte << 1) | carry
                carry = (byte & 0x80) != 0 ? 1 : 0
            }
            if (b[0] & 0x80) != 0 { out[15] ^= 0x87 }
            return Data(out)
        }
        let k1 = dbl(L)
        let k2 = dbl(k1)
        let n = max(1, (message.count + 15) / 16)
        let complete = !message.isEmpty && (message.count % 16 == 0)
        let lastStart = (n - 1) * 16
        let mLast: Data
        if complete {
            mLast = xor(message.subdata(in: lastStart..<message.count), k1)
        } else {
            var padded = message.subdata(in: lastStart..<message.count)
            padded.append(0x80)
            if padded.count < 16 { padded.append(Data(repeating: 0, count: 16 - padded.count)) }
            mLast = xor(padded, k2)
        }
        var x = Data(repeating: 0, count: 16)
        for i in 0..<(n - 1) {
            x = try aesEncryptBlock(xor(x, message.subdata(in: (i * 16)..<((i + 1) * 16))), key: key)
        }
        return try aesEncryptBlock(xor(x, mLast), key: key)
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBuf in
            password.withUnsafeBytes { pwBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outBuf.bindMemory(to: UInt8.self).baseAddress, length
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw TapoError.cryptoError("PBKDF2 failed (\(status))") }
        return out
    }

    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int, sha512: Bool) -> Data {
        if sha512 {
            let key = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
            return key.withUnsafeBytes { Data($0) }
        } else {
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
            return key.withUnsafeBytes { Data($0) }
        }
    }

    static func hmacDigest(key: Data, data: Data, sha512: Bool) -> Data {
        if sha512 {
            return Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        } else {
            return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
    }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bigEndianLength(_ value: Int, bytes: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes)
        var v = value
        for i in (0..<bytes).reversed() {
            out[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        return out
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

// MARK: - TDP UDP 20002 Discovery

enum TapoDiscovery {
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return ~crc
    }

    private static func buildProbePacket() -> Data {
        let payloadStr = #"{"params":{"rsa_key":"-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0Z3VS5JJcds3xfn/ygWyF\n-----END PUBLIC KEY-----\n"}}"#
        let payload = Data(payloadStr.utf8)
        let rnd = TapoCrypto.randomBytes(4)
        var pkt = Data()
        pkt.append(contentsOf: [2, 0, 0, 1])
        var lenBE = UInt16(payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { pkt.append(contentsOf: $0) }
        pkt.append(contentsOf: [17, 0])
        pkt.append(rnd)
        pkt.append(contentsOf: [0x5A, 0x6B, 0x7C, 0x8D])
        pkt.append(payload)
        var sum = crc32(pkt).bigEndian
        withUnsafeBytes(of: &sum) { pkt.replaceSubrange(12..<16, with: $0) }
        return pkt
    }

    /// Returns active non-loopback IPv4 LAN interfaces as (ip, netmask, broadcast) tuples.
    private static func localIPv4Interfaces() -> [(ip: UInt32, mask: UInt32, bcast: UInt32)] {
        var result: [(UInt32, UInt32, UInt32)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback,
               let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               let maskAddr = cur.pointee.ifa_netmask {
                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = maskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                // Skip link-local 169.254.x.x and Tailscale 100.64.0.0/10
                let isLinkLocal = (ip & 0xFFFF0000) == 0xA9FE0000
                let isTailscale = (ip & 0xFFC00000) == 0x64400000
                if !isLinkLocal && !isTailscale {
                    let bcast = (ip & mask) | ~mask
                    result.append((ip, mask, bcast))
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }

    private static func ipv4String(_ hostOrder: UInt32) -> String {
        "\((hostOrder >> 24) & 0xFF).\((hostOrder >> 16) & 0xFF).\((hostOrder >> 8) & 0xFF).\(hostOrder & 0xFF)"
    }

    private static func sendProbe(_ probe: Data, fd: Int32, ip: String) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(20002).bigEndian
        if inet_pton(AF_INET, ip, &addr.sin_addr) == 1 {
            probe.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = Darwin.sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// Scans the local Wi-Fi/LAN subnet(s) on UDP port 20002 (broadcast + unicast /24 sweep) for Tapo devices.
    static func scan(extraHost: String? = nil) async -> [TapoDiscoveredDevice] {
        await Task.detached {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return [] }
            defer { Darwin.close(fd) }

            var broadcastOn: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastOn, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var targets = Set<String>()
            if let extraHost, !extraHost.trimmingCharacters(in: .whitespaces).isEmpty {
                targets.insert(extraHost.trimmingCharacters(in: .whitespaces))
            }

            let ifaces = localIPv4Interfaces()
            for iface in ifaces {
                targets.insert(ipv4String(iface.bcast))
                // Unicast sweep the local /24 around this Mac's IP so plugs respond even when not in ARP cache or if broadcast is filtered.
                let base24 = iface.ip & 0xFFFFFF00
                for hostByte: UInt32 in 1...254 {
                    let candidate = base24 | hostByte
                    if candidate != iface.ip {
                        targets.insert(ipv4String(candidate))
                    }
                }
            }
            targets.insert("255.255.255.255")

            let probe = buildProbePacket()
            for ip in targets {
                sendProbe(probe, fd: fd, ip: ip)
            }

            var found: [TapoDiscoveredDevice] = []
            var seen = Set<String>()
            var recvBuf = [UInt8](repeating: 0, count: 4096)
            let deadline = Date().addingTimeInterval(2.2)

            while Date() < deadline {
                var srcAddr = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.recvfrom(fd, &recvBuf, recvBuf.count, 0, sa, &srcLen)
                    }
                }
                if n <= 16 {
                    if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        continue
                    }
                    break
                }
                var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &srcAddr.sin_addr, &ipChars, socklen_t(INET_ADDRSTRLEN))
                let senderIP = String(cString: ipChars)
                guard !seen.contains(senderIP) else { continue }
                seen.insert(senderIP)

                let body = Data(recvBuf[16..<n])
                if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                   let res = obj["result"] as? [String: Any] {
                    let dtype = (res["device_type"] as? String) ?? ""
                    // Filter out routers (e.g. Deco M4R), cameras, and bulbs — keep only smart plugs/switches.
                    guard dtype.uppercased().contains("PLUG") || dtype.uppercased().contains("SWITCH") else { continue }
                    let ip = (res["ip"] as? String) ?? senderIP
                    let mac = (res["mac"] as? String) ?? ""
                    let model = (res["device_model"] as? String) ?? "Tapo Plug"
                    let mgt = res["mgt_encrypt_schm"] as? [String: Any]
                    let tpap = res["tpap"] as? [String: Any]
                    let enc = (mgt?["encrypt_type"] as? String) ?? (tpap != nil ? "TPAP" : "KLAP")
                    let port = (tpap?["port"] as? Int) ?? (mgt?["http_port"] as? Int) ?? 80
                    let tls = ((tpap?["tls"] as? Int) ?? 0) == 1
                    found.append(TapoDiscoveredDevice(ip: ip, mac: mac, model: model, deviceType: dtype, encryptType: enc, port: port, tls: tls))
                }
            }
            return found.sorted { $0.ip < $1.ip }
        }.value
    }
}

// MARK: - Native Swift TPAP (SPAKE2+) Client

final class TapoTPAPClient {
    private let host: String
    private let username: String
    private let password: String
    private var port: Int
    private var tls: Bool

    private var mac12 = ""
    private var pake: [Int] = []
    private var sessionID = ""
    private var seq: UInt32 = 1
    private var cipherID = "aes_128_ccm"
    private var useSHA512 = false
    private var sessionKey = Data()
    private var baseNonce = Data()

    private let session: URLSession

    private struct CipherLabels {
        let ks: Data; let ki: Data; let ns: Data; let ni: Data; let keyLen: Int
    }

    private static let cipherLabels: [String: CipherLabels] = [
        "aes_128_ccm": CipherLabels(
            ks: Data("tp-kdf-salt-aes128-key".utf8), ki: Data("tp-kdf-info-aes128-key".utf8),
            ns: Data("tp-kdf-salt-aes128-iv".utf8),  ni: Data("tp-kdf-info-aes128-iv".utf8), keyLen: 16
        ),
        "aes_256_ccm": CipherLabels(
            ks: Data("tp-kdf-salt-aes256-key".utf8), ki: Data("tp-kdf-info-aes256-key".utf8),
            ns: Data("tp-kdf-salt-aes256-iv".utf8),  ni: Data("tp-kdf-info-aes256-iv".utf8), keyLen: 32
        ),
        "chacha20_poly1305": CipherLabels(
            ks: Data("tp-kdf-salt-chacha20-key".utf8), ki: Data("tp-kdf-info-chacha20-key".utf8),
            ns: Data("tp-kdf-salt-chacha20-iv".utf8),  ni: Data("tp-kdf-info-chacha20-iv".utf8), keyLen: 32
        ),
    ]

    init(host: String, username: String, password: String, port: Int = 80, tls: Bool = false) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.port = port
        self.tls = tls
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: cfg)
    }

    deinit {
        session.invalidateAndCancel()
    }

    private var baseURL: String { "\(tls ? "https" : "http")://\(host):\(port)" }

    private func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else { throw TapoError.network("Invalid host: \(host)") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TapoError.network("HTTP \(http.statusCode) from \(host)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TapoError.protocolError("Invalid JSON response from plug")
        }
        return obj
    }

    private func postBinary(_ path: String, body: Data) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw TapoError.network("Invalid host: \(host)") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TapoError.network("HTTP \(http.statusCode) from \(host)")
        }
        return data
    }

    private func discover() async throws {
        let resp = try await postJSON("/", body: ["method": "login", "params": ["sub_method": "discover"]])
        guard let res = resp["result"] as? [String: Any] else {
            throw TapoError.protocolError("Unexpected discover response")
        }
        let rawMac = (res["mac"] as? String) ?? ""
        mac12 = rawMac.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").uppercased()
        let tpap = res["tpap"] as? [String: Any]
        pake = (tpap?["pake"] as? [Int]) ?? [2]
        if let p = tpap?["port"] as? Int, p > 0 { port = p }
        if let t = tpap?["tls"] as? Int { tls = (t == 1) }
    }

    private static func buildCredential(extra: [String: Any]?, user: String, pw: String, mac12: String) -> String {
        guard let extra, !extra.isEmpty else {
            return user.isEmpty ? pw : "\(user)/\(pw)"
        }
        let type = ((extra["type"] as? String) ?? "").lowercased()
        let params = (extra["params"] as? [String: Any]) ?? [:]
        if type == "password_shadow" {
            let pid = (params["passwd_id"] as? Int) ?? 0
            if pid == 2 { return TapoCrypto.sha1Hex(pw) }
            if pid == 3, !user.isEmpty, mac12.count == 12 {
                var parts: [String] = []
                for i in stride(from: 0, to: 12, by: 2) {
                    let s = mac12.index(mac12.startIndex, offsetBy: i)
                    let e = mac12.index(s, offsetBy: 2)
                    parts.append(String(mac12[s..<e]))
                }
                let macColons = parts.joined(separator: ":").uppercased()
                return TapoCrypto.sha1Hex("\(TapoCrypto.md5Hex(user))_\(macColons)")
            }
            return pw
        }
        if type == "password_sha_with_salt" {
            let shaName = (params["sha_name"] as? Int) ?? -1
            let name = shaName == 0 ? "admin" : "user"
            if let b64 = params["sha_salt"] as? String,
               let saltData = Data(base64Encoded: b64),
               let salt = String(data: saltData, encoding: .utf8) {
                return TapoCrypto.sha256Hex(name + salt + pw)
            }
            return pw
        }
        return user.isEmpty ? pw : "\(user)/\(pw)"
    }

    private static func l8(_ d: Data) -> Data {
        var lenLE = UInt64(d.count).littleEndian
        var out = Data(capacity: 8 + d.count)
        withUnsafeBytes(of: &lenLE) { out.append(contentsOf: $0) }
        out.append(d)
        return out
    }

    private static func encodeW(_ w: U256) -> Data {
        let be = w.bigEndianBytes
        let trimmed = be.drop { $0 == 0 }
        let bytes = trimmed.isEmpty ? Data([0]) : Data(trimmed)
        if (bytes.count % 2 != 0) && ((bytes[0] & 0x80) != 0) {
            return Data([0]) + bytes
        }
        return bytes
    }

    func authenticate() async throws {
        if pake.isEmpty { try await discover() }
        let ptype = pake.contains(0) ? "default_userpw" : pake.contains(2) ? "userpw" : pake.contains(3) ? "shared_token" : "userpw"
        let userRandom = TapoCrypto.randomBytes(32)

        let reg = try await postJSON("/", body: [
            "method": "login",
            "params": [
                "sub_method": "pake_register",
                "username": TapoCrypto.md5Hex("admin"),
                "user_random": userRandom.base64EncodedString(),
                "cipher_suites": [1],
                "encryption": ["aes_128_ccm", "chacha20_poly1305", "aes_256_ccm"],
                "passcode_type": ptype,
                "stok": NSNull(),
            ],
        ])
        if let code = reg["error_code"] as? Int, code != 0 {
            throw TapoError.authFailed("pake_register failed (error \(code))")
        }
        guard let r = reg["result"] as? [String: Any],
              let devSaltB64 = r["dev_salt"] as? String, let devSalt = Data(base64Encoded: devSaltB64),
              let devShareB64 = r["dev_share"] as? String, let devShare = Data(base64Encoded: devShareB64),
              let devRandomB64 = r["dev_random"] as? String, let devRandom = Data(base64Encoded: devRandomB64) else {
            throw TapoError.protocolError("Missing fields in pake_register response")
        }

        let suite = (r["cipher_suites"] as? Int) ?? 1
        let iterations = (r["iterations"] as? Int) ?? 10000
        cipherID = ((r["encryption"] as? String) ?? "aes_128_ccm").lowercased().replacingOccurrences(of: "-", with: "_")
        useSHA512 = [2, 4, 5, 7, 9].contains(suite)
        let useCMAC = [8, 9].contains(suite)
        let dlen = useSHA512 ? 64 : 32

        let cred = Self.buildCredential(extra: r["extra_crypt"] as? [String: Any], user: username, pw: password, mac12: mac12)
        let iD = 40
        let pbkdf = try TapoCrypto.pbkdf2SHA256(password: Data(cred.utf8), salt: devSalt, iterations: iterations, length: 2 * iD)
        let w = U256.fromBytesMod(pbkdf.prefix(iD), mod: TapoP256.n)
        let hVal = U256.fromBytesMod(pbkdf.suffix(iD), mod: TapoP256.n)

        var x = U256.fromBytesMod(TapoCrypto.randomBytes(32), mod: TapoP256.n)
        if x.isZero { x = .one }

        guard let L = TapoP256.add(TapoP256.mul(x, TapoP256.G), TapoP256.mul(w, TapoP256.M)) else {
            throw TapoError.cryptoError("Failed to compute SPAKE2+ share L")
        }
        let lEnc = TapoP256.encodeUncompressed(L)

        let R = try TapoP256.decodeSEC1(devShare)
        let rEnc = TapoP256.encodeUncompressed(R)
        guard let Rp = TapoP256.add(R, TapoP256.neg(TapoP256.mul(w, TapoP256.N))),
              let Z = TapoP256.mul(x, Rp),
              let V = TapoP256.mul(hVal, Rp) else {
            throw TapoError.cryptoError("Failed to compute SPAKE2+ shared points")
        }
        let zEnc = TapoP256.encodeUncompressed(Z)
        let vEnc = TapoP256.encodeUncompressed(V)

        func hash(_ d: Data) -> Data {
            useSHA512 ? Data(SHA512.hash(data: d)) : Data(SHA256.hash(data: d))
        }

        let ctx = hash(Data("PAKE V1".utf8) + userRandom + devRandom)
        var trans = Data()
        trans.append(Self.l8(ctx))
        trans.append(Self.l8(Data()))
        trans.append(Self.l8(Data()))
        trans.append(Self.l8(TapoP256.encodeUncompressed(TapoP256.M)))
        trans.append(Self.l8(TapoP256.encodeUncompressed(TapoP256.N)))
        trans.append(Self.l8(lEnc))
        trans.append(Self.l8(rEnc))
        trans.append(Self.l8(zEnc))
        trans.append(Self.l8(vEnc))
        trans.append(Self.l8(Self.encodeW(w)))
        let T = hash(trans)

        let ml = useCMAC ? 16 : 32
        let zeroSalt = Data(repeating: 0, count: dlen)
        let conf = TapoCrypto.hkdf(ikm: T, salt: zeroSalt, info: Data("ConfirmationKeys".utf8), length: ml * 2, sha512: useSHA512)
        let kcA = conf.prefix(ml)
        let kcB = conf.suffix(ml)
        let shared = TapoCrypto.hkdf(ikm: T, salt: zeroSalt, info: Data("SharedKey".utf8), length: dlen, sha512: useSHA512)

        let uConf: Data
        let eConf: Data
        if useCMAC {
            uConf = try TapoCrypto.aesCMAC(key: Data(kcA), message: rEnc)
            eConf = try TapoCrypto.aesCMAC(key: Data(kcB), message: lEnc)
        } else {
            uConf = TapoCrypto.hmacDigest(key: Data(kcA), data: rEnc, sha512: useSHA512)
            eConf = TapoCrypto.hmacDigest(key: Data(kcB), data: lEnc, sha512: useSHA512)
        }

        let share = try await postJSON("/", body: [
            "method": "login",
            "params": [
                "sub_method": "pake_share",
                "user_share": lEnc.base64EncodedString(),
                "user_confirm": uConf.base64EncodedString(),
            ],
        ])
        if let code = share["error_code"] as? Int, code != 0 {
            if code == -2203 {
                throw TapoError.authFailed("Incorrect TP-Link email or password.")
            }
            throw TapoError.authFailed("Authentication failed (error \(code))")
        }
        guard let s = share["result"] as? [String: Any] else {
            throw TapoError.protocolError("Missing result in pake_share response")
        }
        let devConfirm = ((s["dev_confirm"] as? String) ?? "").lowercased()
        guard devConfirm == eConf.base64EncodedString().lowercased() else {
            throw TapoError.authFailed("SPAKE2+ confirmation mismatch — check your TP-Link email and password.")
        }

        sessionID = (s["sessionId"] as? String) ?? (s["stok"] as? String) ?? ""
        seq = UInt32((s["start_seq"] as? Int) ?? 1)
        guard let labels = Self.cipherLabels[cipherID] else {
            throw TapoError.cryptoError("Unsupported TPAP cipher: \(cipherID)")
        }
        sessionKey = TapoCrypto.hkdf(ikm: shared, salt: labels.ks, info: labels.ki, length: labels.keyLen, sha512: useSHA512)
        baseNonce = TapoCrypto.hkdf(ikm: shared, salt: labels.ns, info: labels.ni, length: 12, sha512: useSHA512)
    }

    private func makeNonce(seq: UInt32) -> Data {
        var n = Data(baseNonce.prefix(8))
        var be = seq.bigEndian
        withUnsafeBytes(of: &be) { n.append(contentsOf: $0) }
        return n
    }

    private func encrypt(_ plaintext: Data, seq: UInt32) throws -> Data {
        let n = makeNonce(seq: seq)
        if cipherID.hasPrefix("aes_") {
            return try TapoCrypto.aesCCMEncrypt(key: sessionKey, nonce: n, plaintext: plaintext, tagLength: 16)
        }
        let sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: sessionKey), nonce: ChaChaPoly.Nonce(data: n))
        return sealed.ciphertext + sealed.tag
    }

    private func decrypt(_ ciphertextAndTag: Data, seq: UInt32) throws -> Data {
        let n = makeNonce(seq: seq)
        if cipherID.hasPrefix("aes_") {
            return try TapoCrypto.aesCCMDecrypt(key: sessionKey, nonce: n, ciphertextAndTag: ciphertextAndTag, tagLength: 16)
        }
        guard ciphertextAndTag.count >= 16 else { throw TapoError.cryptoError("Ciphertext too short") }
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: n),
            ciphertext: ciphertextAndTag.prefix(ciphertextAndTag.count - 16),
            tag: ciphertextAndTag.suffix(16)
        )
        return try ChaChaPoly.open(box, using: SymmetricKey(data: sessionKey))
    }

    func send(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        if sessionID.isEmpty { try await authenticate() }
        let pt = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let ct = try encrypt(pt, seq: seq)
        var payload = Data(capacity: 4 + ct.count)
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { payload.append(contentsOf: $0) }
        payload.append(ct)

        let raw = Data(try await postBinary("/stok=\(sessionID)/ds", body: payload))
        guard raw.count >= 20 else { throw TapoError.protocolError("Short encrypted response (\(raw.count) bytes)") }
        let rseq = (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
        let plain = try decrypt(Data(raw.dropFirst(4)), seq: rseq)
        seq &+= 1

        guard let resp = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw TapoError.protocolError("Invalid decrypted JSON")
        }
        if let code = resp["error_code"] as? Int, code != 0 {
            throw TapoError.protocolError("Device error \(code)")
        }
        return resp
    }

    // MARK: High-Level Plug Operations

    func getStatus() async throws -> TapoPlugStatus {
        let infoResp = try await send(method: "get_device_info")
        guard let r = infoResp["result"] as? [String: Any] else {
            throw TapoError.protocolError("Missing result in get_device_info")
        }
        let isOn = (r["device_on"] as? Bool) ?? false
        let model = (r["model"] as? String) ?? "Tapo Plug"
        let nickB64 = (r["nickname"] as? String) ?? ""
        let nickname = Data(base64Encoded: nickB64).flatMap { String(data: $0, encoding: .utf8) } ?? model
        let fwVer = (r["fw_ver"] as? String) ?? ""
        let hwVer = (r["hw_ver"] as? String) ?? ""
        let onTime = (r["on_time"] as? Int) ?? 0
        let rssi = r["rssi"] as? Int

        var watts: Double?
        if let pResp = try? await send(method: "get_current_power"),
           let pRes = pResp["result"] as? [String: Any],
           let mw = pRes["current_power"] as? Int {
            watts = Double(mw) / 1000.0
        }
        return TapoPlugStatus(isOn: isOn, model: model, nickname: nickname, fwVer: fwVer, hwVer: hwVer, onTime: onTime, rssi: rssi, currentPowerWatts: watts)
    }

    func setPower(_ on: Bool) async throws {
        _ = try await send(method: "set_device_info", params: ["device_on": on])
    }
}

private extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            data.append(b)
        }
        self = data
    }
}
