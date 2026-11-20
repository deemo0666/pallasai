@preconcurrency import Citadel
import CCitadelBcrypt
import CommonCrypto
import Crypto
import _CryptoExtras
import Foundation
import NIO
import NIOSSH

/// A private key pasted or imported for an SSH host: OpenSSH (`openssh-key-v1`,
/// optionally protected with bcrypt + AES), PKCS#1 RSA, SEC1 EC or an unencrypted
/// PKCS#8 key. Ed25519 and ECDSA sign through swift-nio-ssh directly; RSA signs
/// with SHA-2 (`rsa-sha2-512`, then `rsa-sha2-256`) because OpenSSH 8.8 and later
/// refuse the SHA-1 `ssh-rsa` signatures Citadel 0.12.1 produces.
enum SSHUserKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(_RSA.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    /// What the form and 网络详情 show: 「Ed25519」「RSA 3072」「ECDSA P-256」.
    var label: String {
        switch self {
        case .ed25519: "Ed25519"
        case .rsa(let key): "RSA \(key.keySizeInBits)"
        case .p256: "ECDSA P-256"
        case .p384: "ECDSA P-384"
        case .p521: "ECDSA P-521"
        }
    }

    /// The SHA256 fingerprint of the public key, as `ssh-keygen -lf` prints it.
    var fingerprint: String {
        var buffer = ByteBufferAllocator().buffer(capacity: 600)
        switch self {
        case .rsa(let key):
            buffer.putSSHString(Data("ssh-rsa".utf8))
            if let numbers = try? key.publicKey.getKeyPrimitives() {
                buffer.writeSSHMPInt(numbers.publicExponent)
                buffer.writeSSHMPInt(numbers.modulus)
            }
        default:
            if let key = sshPrivateKey { key.publicKey.write(to: &buffer) }
        }
        let blob = Data(buffer.readableBytesView)
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private var sshPrivateKey: NIOSSHPrivateKey? {
        switch self {
        case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): NIOSSHPrivateKey(p521Key: key)
        case .rsa: nil
        }
    }

    func authentication(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let key): .ed25519(username: username, privateKey: key)
        case .p256(let key): .p256(username: username, privateKey: key)
        case .p384(let key): .p384(username: username, privateKey: key)
        case .p521(let key): .p521(username: username, privateKey: key)
        case .rsa(let key): .custom(RSAOffers(username: username, key: key))
        }
    }

    /// True for text that looks like any private key the parser knows.
    static func looksLikePrivateKey(_ text: String) -> Bool {
        text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----")
    }

    static func parse(_ text: String, passphrase: String) throws -> SSHUserKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let armor = PEMArmor(trimmed) else { throw HostError(String(localized: "私钥格式不对"), detail: String(localized: "粘贴以 -----BEGIN 开头、-----END 结尾的整段私钥。")) }
        switch armor.label {
        case "OPENSSH PRIVATE KEY":
            return try OpenSSHKeyFile.parse(armor.body, passphrase: passphrase)
        case "RSA PRIVATE KEY":
            if armor.encrypted { throw unsupportedEncryptedPEM }
            return .rsa(try rsa { try _RSA.Signing.PrivateKey(pemRepresentation: trimmed) })
        case "EC PRIVATE KEY":
            if armor.encrypted { throw unsupportedEncryptedPEM }
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return .p256(key) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) { return .p384(key) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) { return .p521(key) }
            throw HostError(String(localized: "没能读取这把 EC 私钥"), detail: String(localized: "只支持 P-256、P-384 和 P-521 曲线。"))
        case "PRIVATE KEY":
            if let key = try? _RSA.Signing.PrivateKey(pemRepresentation: trimmed) { return .rsa(key) }
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return .p256(key) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) { return .p384(key) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) { return .p521(key) }
            if let key = PKCS8Ed25519.parse(armor.body) { return .ed25519(key) }
            throw HostError(String(localized: "没能读取这把 PKCS#8 私钥"), detail: String(localized: "支持 RSA（2048 位起）、ECDSA 和 Ed25519。"))
        case "ENCRYPTED PRIVATE KEY":
            throw unsupportedEncryptedPEM
        default:
            throw HostError(String(localized: "不支持「\(armor.label)」"), detail: String(localized: "支持 OpenSSH、RSA、EC 和 PKCS#8 格式的私钥。"))
        }
    }

    private static var unsupportedEncryptedPEM: HostError {
        HostError(String(localized: "暂不支持加了密码的 PEM 私钥"), detail: String(localized: "在电脑上运行 ssh-keygen -p -f <私钥文件> 转成 OpenSSH 格式（可以保留密码），再导入。"))
    }

    static func rsa(_ make: () throws -> _RSA.Signing.PrivateKey) throws -> _RSA.Signing.PrivateKey {
        do { return try make() } catch {
            throw HostError(String(localized: "没能读取这把 RSA 私钥"), detail: String(localized: "需要 2048 位或更长的 RSA 私钥。"))
        }
    }
}

// MARK: - RSA with SHA-2 signatures

/// The hash an `rsa-sha2-*` offer signs with.
protocol RSASHA2Hash {
    static var name: String { get }
    static func sign(_ data: Data, with key: _RSA.Signing.PrivateKey) throws -> Data
    static func verify(_ signature: Data, for data: Data, with key: _RSA.Signing.PublicKey) -> Bool
}

enum RSASHA512: RSASHA2Hash {
    static var name: String { "rsa-sha2-512" }
    static func sign(_ data: Data, with key: _RSA.Signing.PrivateKey) throws -> Data {
        try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    static func verify(_ signature: Data, for data: Data, with key: _RSA.Signing.PublicKey) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

enum RSASHA256: RSASHA2Hash {
    static var name: String { "rsa-sha2-256" }
    static func sign(_ data: Data, with key: _RSA.Signing.PrivateKey) throws -> Data {
        try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    static func verify(_ signature: Data, for data: Data, with key: _RSA.Signing.PublicKey) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

/// swift-nio-ssh names the offer after the key and also writes that name as the
/// key blob's type. OpenSSH reads `rsa-sha2-256` / `rsa-sha2-512` there as an RSA
/// key (they are its signature-only aliases of `ssh-rsa`), so the blob carries the
/// usual `e` and `n` after it.
struct RSASHA2PublicKey<Hash: RSASHA2Hash>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Hash.name }
    let modulus: Data
    let exponent: Data

    var rawRepresentation: Data {
        var buffer = ByteBufferAllocator().buffer(capacity: modulus.count + 16)
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASHA2Signature<Hash>,
              let key = try? _RSA.Signing.PublicKey(n: modulus, e: exponent) else { return false }
        return Hash.verify(signature.rawRepresentation, for: Data(data), with: key)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHMPInt(exponent) + buffer.writeSSHMPInt(modulus)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let e = buffer.takeSSHBytes(), let n = buffer.takeSSHBytes() else { throw HostError(String(localized: "RSA 公钥格式不对")) }
        return Self(modulus: n.strippingLeadingZeros, exponent: e.strippingLeadingZeros)
    }
}

struct RSASHA2Signature<Hash: RSASHA2Hash>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Hash.name }
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int { buffer.putSSHString(rawRepresentation) }
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let blob = buffer.takeSSHBytes() else { throw HostError(String(localized: "RSA 签名格式不对")) }
        return Self(rawRepresentation: blob)
    }
}

struct RSASHA2PrivateKey<Hash: RSASHA2Hash>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Hash.name }
    let key: _RSA.Signing.PrivateKey
    let numbers: RSASHA2PublicKey<Hash>

    init(_ key: _RSA.Signing.PrivateKey) throws {
        self.key = key
        let primitives = try key.publicKey.getKeyPrimitives()
        numbers = .init(modulus: primitives.modulus.strippingLeadingZeros, exponent: primitives.publicExponent.strippingLeadingZeros)
    }

    var publicKey: NIOSSHPublicKeyProtocol { numbers }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASHA2Signature<Hash>(rawRepresentation: try Hash.sign(Data(data), with: key))
    }
}

/// Offers the RSA key with SHA-512 first and SHA-256 if the server refuses it.
final class RSAOffers: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var offers: [NIOSSHPrivateKey]

    init(username: String, key: _RSA.Signing.PrivateKey) {
        self.username = username
        var offers: [NIOSSHPrivateKey] = []
        if let strong = try? RSASHA2PrivateKey<RSASHA512>(key) { offers.append(NIOSSHPrivateKey(custom: strong)) }
        if let fallback = try? RSASHA2PrivateKey<RSASHA256>(key) { offers.append(NIOSSHPrivateKey(custom: fallback)) }
        self.offers = offers
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !offers.isEmpty else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        let key = offers.removeFirst()
        let offer = NIOSSHUserAuthenticationOffer.Offer.PrivateKey(privateKey: key)
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(offer)))
    }
}

// MARK: - File formats

private struct PEMArmor {
    let label: String
    let body: Data
    let encrypted: Bool

    init?(_ text: String) {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("-----BEGIN "), first.hasSuffix("-----"),
              let last = lines.last, last.hasPrefix("-----END ") else { return nil }
        label = String(first.dropFirst(11).dropLast(5))
        let inner = lines.dropFirst().dropLast()
        encrypted = inner.contains { $0.hasPrefix("Proc-Type:") && $0.contains("ENCRYPTED") }
        guard let data = Data(base64Encoded: inner.filter { !$0.contains(":") }.joined()) else { return nil }
        body = data
    }
}

/// `openssh-key-v1`, as `ssh-keygen` writes it since OpenSSH 7.8.
enum OpenSSHKeyFile {
    static func parse(_ data: Data, passphrase: String) throws -> SSHUserKey {
        var reader = SSHWireReader(data)
        guard reader.take(15) == Data("openssh-key-v1\0".utf8) else { throw HostError(String(localized: "不是 OpenSSH 私钥")) }
        let cipher = try reader.string()
        let kdf = try reader.string()
        var options = SSHWireReader(try reader.bytes())
        guard try reader.uint32() == 1 else { throw HostError(String(localized: "这个文件里有多把私钥，请只导入一把")) }
        _ = try reader.bytes()
        var secret = try reader.bytes()
        if cipher != "none" {
            guard kdf == "bcrypt" else { throw HostError(String(localized: "不支持的私钥加密方式（\(kdf)）")) }
            guard !passphrase.isEmpty else { throw HostError(String(localized: "这把私钥设了密码，请填写私钥密码")) }
            let salt = try options.bytes()
            let rounds = try options.uint32()
            secret = try decrypt(secret, cipher: cipher, passphrase: passphrase, salt: salt, rounds: rounds)
        }
        var inner = SSHWireReader(secret)
        guard try inner.uint32() == (try inner.uint32()) else {
            throw HostError(cipher == "none" ? String(localized: "私钥文件已损坏") : String(localized: "私钥密码不对"), code: "ssh/key-passphrase")
        }
        let type = try inner.string()
        switch type {
        case "ssh-ed25519":
            _ = try inner.bytes()
            let pair = try inner.bytes()
            guard pair.count == 64 else { throw HostError(String(localized: "Ed25519 私钥长度不对")) }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: pair.prefix(32)))
        case "ssh-rsa":
            let n = try inner.bytes(), e = try inner.bytes(), d = try inner.bytes()
            _ = try inner.bytes()
            let p = try inner.bytes(), q = try inner.bytes()
            return .rsa(try SSHUserKey.rsa {
                try _RSA.Signing.PrivateKey(n: n.strippingLeadingZeros, e: e.strippingLeadingZeros, d: d.strippingLeadingZeros,
                                             p: p.strippingLeadingZeros, q: q.strippingLeadingZeros)
            })
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try inner.string()
            _ = try inner.bytes()
            let scalar = try inner.bytes().strippingLeadingZeros
            switch type {
            case "ecdsa-sha2-nistp256": return .p256(try P256.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 32)))
            case "ecdsa-sha2-nistp384": return .p384(try P384.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 48)))
            default: return .p521(try P521.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 66)))
            }
        default:
            throw HostError(String(localized: "不支持「\(type)」类型的私钥"), detail: String(localized: "支持 Ed25519、RSA 和 ECDSA（P-256、P-384、P-521）。"))
        }
    }

    private static let sha512: Void = {
        citadel_set_crypto_hash_sha512 { output, input, length in
            _ = CC_SHA512(input, CC_LONG(length), output)
        }
    }()

    private static func decrypt(_ data: Data, cipher: String, passphrase: String, salt: Data, rounds: UInt32) throws -> Data {
        let mode: CCMode
        let keyLength: Int
        switch cipher {
        case "aes128-ctr": (mode, keyLength) = (CCMode(kCCModeCTR), 16)
        case "aes192-ctr": (mode, keyLength) = (CCMode(kCCModeCTR), 24)
        case "aes256-ctr": (mode, keyLength) = (CCMode(kCCModeCTR), 32)
        case "aes128-cbc": (mode, keyLength) = (CCMode(kCCModeCBC), 16)
        case "aes256-cbc": (mode, keyLength) = (CCMode(kCCModeCBC), 32)
        default: throw HostError(String(localized: "不支持的私钥加密算法（\(cipher)）"), detail: String(localized: "用 ssh-keygen -p -Z aes256-ctr -f <私钥文件> 改用 aes256-ctr。"))
        }
        guard data.count % 16 == 0 else { throw HostError(String(localized: "私钥文件已损坏")) }
        _ = sha512
        var material = [UInt8](repeating: 0, count: keyLength + 16)
        let password = Array(passphrase.utf8)
        let saltBytes = Array(salt)
        guard citadel_bcrypt_pbkdf(password, password.count, saltBytes, saltBytes.count, &material, material.count, rounds) == 0 else {
            throw HostError(String(localized: "没能解开私钥"))
        }
        let key = Array(material[..<keyLength]), iv = Array(material[keyLength...])
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                      iv, key, key.count, nil, 0, 0, CCModeOptions(mode == CCMode(kCCModeCTR) ? kCCModeOptionCTR_BE : 0),
                                      &cryptor) == kCCSuccess, let cryptor else { throw HostError(String(localized: "没能解开私钥")) }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let input = Array(data)
        guard CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved) == kCCSuccess, moved == data.count else {
            throw HostError(String(localized: "没能解开私钥"))
        }
        return Data(output)
    }
}

/// An unencrypted PKCS#8 Ed25519 key (`openssl genpkey -algorithm ed25519`):
/// the 32-byte seed is the last OCTET STRING.
private enum PKCS8Ed25519 {
    static let prefix: [UInt8] = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
    static func parse(_ der: Data) -> Curve25519.Signing.PrivateKey? {
        guard der.count == 48, Array(der.prefix(16)) == prefix else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
    }
}

/// Reads the SSH wire encoding (RFC 4251 §5).
struct SSHWireReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = Data(data); offset = 0 }

    mutating func take(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func uint32() throws -> UInt32 {
        guard let bytes = take(4) else { throw HostError(String(localized: "私钥文件不完整")) }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func bytes() throws -> Data {
        let length = Int(try uint32())
        guard length <= 1 << 20, let bytes = take(length) else { throw HostError(String(localized: "私钥文件不完整")) }
        return bytes
    }

    mutating func string() throws -> String {
        guard let text = String(data: try bytes(), encoding: .utf8) else { throw HostError(String(localized: "私钥文件不完整")) }
        return text
    }
}

extension Data {
    var strippingLeadingZeros: Data {
        let trimmed = drop { $0 == 0 }
        return trimmed.isEmpty ? Data([0]) : Data(trimmed)
    }

    func leftPadded(to length: Int) -> Data {
        count >= length ? Data(suffix(length)) : Data(repeating: 0, count: length - count) + self
    }
}

extension ByteBuffer {
    /// An SSH `mpint`: big-endian, with a leading zero byte when the top bit is set.
    @discardableResult
    mutating func writeSSHMPInt(_ magnitude: Data) -> Int {
        let digits = magnitude.strippingLeadingZeros
        let body = (digits.first ?? 0) & 0x80 != 0 ? Data([0]) + digits : digits
        return putSSHString(body)
    }

    @discardableResult
    mutating func putSSHString(_ bytes: Data) -> Int {
        writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }

    mutating func takeSSHBytes() -> Data? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self), Int(length) <= readableBytes - 4 else { return nil }
        moveReaderIndex(forwardBy: 4)
        return readBytes(length: Int(length)).map { Data($0) }
    }
}
