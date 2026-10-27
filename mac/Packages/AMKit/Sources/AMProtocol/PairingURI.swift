import Foundation
import SwiftProtobuf

public enum PairingURIError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformed
}

/// The content of the pairing QR code. Rules: protocol/SPEC.md section 5.2.
public struct PairingURI: Equatable, Sendable {
    public var version: Int
    public var macFingerprint: Data
    public var secret: Data
    public var hosts: [String]
    public var port: UInt16
    public var macName: String

    public init(version: Int = 1, macFingerprint: Data, secret: Data, hosts: [String], port: UInt16, macName: String) {
        self.version = version
        self.macFingerprint = macFingerprint
        self.secret = secret
        self.hosts = hosts
        self.port = port
        self.macName = macName
    }

    private static let prefix = "anmirror://pair?"

    public static func parse(_ string: String) throws(PairingURIError) -> PairingURI {
        guard string.hasPrefix(prefix) else { throw .malformed }
        var params: [String: String] = [:]
        for part in string.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: true) {
            let key: String, value: String
            if let eq = part.firstIndex(of: "=") {
                key = String(part[..<eq])
                value = String(part[part.index(after: eq)...])
            } else {
                key = String(part)
                value = ""
            }
            if params[key] != nil { throw .malformed }
            params[key] = value
        }

        // The version is checked before any other field.
        guard let vText = params["v"], let version = canonicalUInt(vText) else { throw .malformed }
        guard version == 1 else { throw .unsupportedVersion(version) }

        guard let fpText = params["fp"], let fp = base64URLDecode(fpText), fp.count == 32,
              let sText = params["s"], let secret = base64URLDecode(sText), secret.count == 32,
              let hText = params["h"]
        else { throw .malformed }
        let hosts = hText.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !hosts.isEmpty, !hosts.contains(where: \.isEmpty) else { throw .malformed }
        guard let pText = params["p"], let p = canonicalUInt(pText), (1...65535).contains(p) else { throw .malformed }
        guard let name = percentDecode(params["n"] ?? "") else { throw .malformed }

        return PairingURI(version: 1, macFingerprint: fp, secret: secret, hosts: hosts,
                          port: UInt16(p), macName: name)
    }

    public var string: String {
        "\(Self.prefix)v=\(version)&fp=\(Self.base64URLEncode(macFingerprint))&s=\(Self.base64URLEncode(secret))"
            + "&h=\(hosts.joined(separator: ","))&p=\(port)&n=\(Self.percentEncode(macName))"
    }

    // MARK: helpers

    /// ASCII `0|[1-9][0-9]*`. Values too large for Int saturate (still "canonical").
    private static func canonicalUInt(_ s: String) -> Int? {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        if bytes.count > 1 && bytes[0] == 0x30 { return nil }
        return Int(s) ?? Int.max
    }

    private static let b64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    private static func base64URLEncode(_ data: Data) -> String {
        var out = [UInt8]()
        var i = 0
        let b = [UInt8](data)
        while i + 2 < b.count {
            let n = Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2])
            out += [b64Alphabet[n >> 18], b64Alphabet[(n >> 12) & 63], b64Alphabet[(n >> 6) & 63], b64Alphabet[n & 63]]
            i += 3
        }
        if b.count - i == 1 {
            let n = Int(b[i]) << 16
            out += [b64Alphabet[n >> 18], b64Alphabet[(n >> 12) & 63]]
        } else if b.count - i == 2 {
            let n = Int(b[i]) << 16 | Int(b[i + 1]) << 8
            out += [b64Alphabet[n >> 18], b64Alphabet[(n >> 12) & 63], b64Alphabet[(n >> 6) & 63]]
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Canonical unpadded base64url only: re-encoding must reproduce the input.
    private static func base64URLDecode(_ s: String) -> Data? {
        var lookup = [UInt8: Int]()
        for (i, c) in b64Alphabet.enumerated() { lookup[c] = i }
        let chars = Array(s.utf8)
        guard chars.count % 4 != 1 else { return nil }
        var out = Data()
        var acc = 0, bits = 0
        for c in chars {
            guard let v = lookup[c] else { return nil }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xFF))
                acc &= (1 << bits) - 1
            }
        }
        guard base64URLEncode(out) == s else { return nil }
        return out
    }

    private static func percentEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private static func percentDecode(_ s: String) -> String? {
        let b = Array(s.utf8)
        var out = [UInt8]()
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x25 {
                guard i + 2 < b.count, let hi = hexValue(b[i + 1]), let lo = hexValue(b[i + 2]) else { return nil }
                out.append(hi << 4 | lo)
                i += 3
            } else if c >= 0x80 {
                return nil // raw non-ASCII
            } else {
                out.append(c)
                i += 1
            }
        }
        // Validate the byte array itself (not a NUL-terminated C string), so %00 cannot hide later bytes.
        return String(bytes: out, encoding: .utf8)
    }
}

extension AMEnvelope {
    public init(channel: AMChannel, id: UInt64, replyTo: UInt64 = 0, type: MessageType,
                payload: some SwiftProtobuf.Message) throws {
        self.init()
        self.channel = channel
        self.id = id
        self.replyTo = replyTo
        self.type = type.rawValue
        self.payload = try payload.serializedData()
    }
}
