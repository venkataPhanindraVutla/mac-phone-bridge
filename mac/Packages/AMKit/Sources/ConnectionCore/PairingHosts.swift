import Darwin
import Foundation
import SystemConfiguration

/// The hosts put in the pairing URI, in the order the phone should try them:
/// non-loopback IPv4 addresses (Ethernet/Wi-Fi `en*` first), then `<LocalHostName>.local`.
public enum PairingHosts {
    public static func current() -> [String] {
        order(interfaces: ipv4Interfaces(), localHostName: localHostName())
    }

    static func order(interfaces: [(String, String)], localHostName: String?) -> [String] {
        let usable = interfaces.filter { !$0.1.hasPrefix("127.") && !$0.1.hasPrefix("169.254.") }
        let preferred = usable.filter { $0.0.hasPrefix("en") }.map(\.1)
        let others = usable.filter { !$0.0.hasPrefix("en") }.map(\.1)
        var hosts: [String] = []
        for h in preferred + others where !hosts.contains(h) { hosts.append(h) }
        if let name = localHostName, !name.isEmpty { hosts.append(name + ".local") }
        return hosts.isEmpty ? ["localhost"] : hosts
    }

    /// (interface name, dotted IPv4) for every interface that is up and not loopback.
    static func ipv4Interfaces() -> [(String, String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            result.append((name, ip))
        }
        return result
    }

    static func localHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }
}
