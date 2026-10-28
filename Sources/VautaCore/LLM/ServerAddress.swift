// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Darwin
import Foundation

/// Classifies the host of a model server URL: loopback, private network or
/// public. IP literals are parsed into bytes (never compared as text), so
/// compressed IPv6 forms and IPv4 tricks such as leading zeros cannot pass.
enum ServerAddress {
    /// A parsed IP literal.
    enum IP: Equatable {
        case v4([UInt8])
        case v6([UInt8])
    }

    /// Parses a host as an IP literal. Brackets and an IPv6 zone (`%en0`) are
    /// accepted; IPv4 must be strict dotted-quad decimal (no leading zeros,
    /// which some resolvers would read as octal).
    static func ip(_ host: String) -> IP? {
        var h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        if h.contains(":") {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard inet_pton(AF_INET6, h, &bytes) == 1 else { return nil }
            return .v6(bytes)
        }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCIIDigit),
                  p == "0" || p.first != "0", let v = UInt8(p) else { return nil }
            octets.append(v)
        }
        return .v4(octets)
    }

    static func isIPLiteral(_ host: String) -> Bool { ip(host) != nil }

    /// 127.0.0.0/8, ::1, `localhost` and IPv4-mapped loopback.
    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        switch ip(h) {
        case .v4(let o): return o[0] == 127
        case .v6(let b):
            if let v4 = mappedIPv4(b) { return v4[0] == 127 }
            return b == [UInt8](repeating: 0, count: 15) + [1]
        case nil: return false
        }
    }

    /// Private addresses (RFC 1918, CGNAT/Tailscale 100.64/10, IPv4 link-local,
    /// IPv6 ULA fc00::/7 and link-local fe80::/10) or names that only exist on
    /// the local network.
    static func isPrivateNetworkHost(_ host: String) -> Bool {
        let h = host.lowercased()
        switch ip(h) {
        case .v4(let o): return isPrivateIPv4(o)
        case .v6(let b):
            if let v4 = mappedIPv4(b) { return isPrivateIPv4(v4) }
            return b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80)
        case nil: return isLocalName(h)
        }
    }

    /// Host names reserved for, or conventionally used on, private networks.
    static func isLocalName(_ h: String) -> Bool {
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
        else { return false }
        return [".local", ".lan", ".home.arpa", ".internal", ".ts.net"].contains { h.hasSuffix($0) }
    }

    /// The IP of a socket peer as reported by `URLSessionTaskMetrics`
    /// (`remoteAddress`), checked against the same rules.
    static func isPrivateOrLoopbackPeer(_ address: String) -> Bool {
        guard ip(address) != nil else { return false }
        return isLoopback(address) || isPrivateNetworkHost(address)
    }

    /// Whether the IPv6 `address` is on a subnet directly attached to one of this
    /// Mac's up, non-loopback, non-tunnel interfaces. A `.local` name usually
    /// resolves to the server's global IPv6 address, which is still on the LAN.
    /// IPv4 never counts (an IPv4 peer must be private): a Mac on a public IPv4
    /// subnet would otherwise accept any address on it, down to a /8.
    static func isOnLink(_ address: String, subnets: [(address: IP, mask: IP)]? = nil) -> Bool {
        guard let peer = ip(address).map(unmapped), case .v6 = peer else { return false }
        return (subnets ?? localSubnets()).contains { inSubnet(peer, $0.address, mask: $0.mask) }
    }

    /// An IPv6 literal that is not an IPv4-mapped address.
    static func isIPv6(_ address: String) -> Bool {
        if case .v6 = ip(address).map(unmapped) { return true }
        return false
    }

    /// Same family, same network bits, and a mask of at least /8 (IPv4) or
    /// /32 (IPv6) so a malformed or default-route mask never matches everything.
    static func inSubnet(_ peer: IP, _ local: IP, mask: IP) -> Bool {
        let (p, l, m): ([UInt8], [UInt8], [UInt8])
        switch (peer, local, mask) {
        case (.v4(let a), .v4(let b), .v4(let c)): (p, l, m) = (a, b, c)
        case (.v6(let a), .v6(let b), .v6(let c)): (p, l, m) = (a, b, c)
        default: return false
        }
        let prefix = m.reduce(0) { $0 + $1.nonzeroBitCount }
        guard prefix >= (m.count == 4 ? 8 : 32) else { return false }
        return zip(zip(p, l), m).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
    }

    /// `::ffff:a.b.c.d` is compared as IPv4.
    private static func unmapped(_ ip: IP) -> IP {
        if case .v6(let b) = ip, let v4 = mappedIPv4(b) { return .v4(v4) }
        return ip
    }

    private static func localSubnets() -> [(address: IP, mask: IP)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [(IP, IP)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask else { continue }
            let (offset, length): (Int, Int)
            switch Int32(addr.pointee.sa_family) {
            case AF_INET: (offset, length) = (MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!, 4)
            case AF_INET6: (offset, length) = (MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!, 16)
            default: continue
            }
            let a = bytes(addr, offset: offset, length: length)
            let m = bytes(mask, offset: offset, length: length)
            out.append(length == 4 ? (.v4(a), .v4(m)) : (.v6(a), .v6(m)))
        }
        return out
    }

    /// Reads `length` bytes at `offset`, as zero where the sockaddr is shorter
    /// (BSD netmask sockaddrs may be truncated after the last non-zero byte).
    private static func bytes(_ sa: UnsafeMutablePointer<sockaddr>, offset: Int, length: Int) -> [UInt8] {
        let available = Int(sa.pointee.sa_len)
        return UnsafeRawPointer(sa).withMemoryRebound(to: UInt8.self, capacity: max(available, 1)) { p in
            (0..<length).map { offset + $0 < available ? p[offset + $0] : 0 }
        }
    }

    private static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
            || (o[0] == 100 && (64...127).contains(o[1])) || (o[0] == 169 && o[1] == 254)
    }

    /// `::ffff:a.b.c.d` → `[a, b, c, d]`.
    private static func mappedIPv4(_ b: [UInt8]) -> [UInt8]? {
        guard b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF else { return nil }
        return Array(b[12..<16])
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
