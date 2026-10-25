import Darwin
import Foundation

public enum HostSafety {
    public static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Names that are obviously not a public service: loopback, LAN, metadata, mDNS.
    public static func isObviouslyInternal(_ host: String) -> Bool {
        let host = normalize(host)
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return true
        }
        if let ip = IPv4(host) {
            return !ip.isPublic
        }
        if let ip = IPv6(host) {
            return !ip.isPublic
        }
        return false
    }

    public static func resolvesToPublicInternet(_ host: String) -> Bool {
        resolvePublic(host: host, port: 443) != nil
    }

    /// One DNS lookup. Every address must be public. Connect only to these.
    public static func resolvePublic(host: String, port: Int) -> [PublicEndpoint]? {
        let host = normalize(host)
        guard (1...65535).contains(port), !isObviouslyInternal(host) else { return nil }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var endpoints: [PublicEndpoint] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let node = cursor {
            guard let addr = node.pointee.ai_addr else { return nil }
            let family = node.pointee.ai_family
            let text = addressText(family: family, addr: addr)
            guard isPublicAddress(family: family, text: text) else { return nil }
            let length = Int(node.pointee.ai_addrlen)
            let bytes = Data(bytes: addr, count: length)
            endpoints.append(PublicEndpoint(
                family: family,
                socktype: node.pointee.ai_socktype,
                proto: node.pointee.ai_protocol,
                address: bytes
            ))
            cursor = node.pointee.ai_next
        }
        return endpoints.isEmpty ? nil : endpoints
    }

    public static func isPublicAddress(family: Int32, text: String) -> Bool {
        if family == AF_INET {
            return IPv4(text)?.isPublic == true
        }
        if family == AF_INET6 {
            return IPv6(text)?.isPublic == true
        }
        return false
    }

    private static func addressText(family: Int32, addr: UnsafeMutablePointer<sockaddr>) -> String {
        if family == AF_INET {
            let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var copy = value
            inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        }
        if family == AF_INET6 {
            let value = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var copy = value
            inet_ntop(AF_INET6, &copy, &buffer, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buffer)
        }
        return ""
    }
}

public struct PublicEndpoint: Equatable, Sendable {
    public var family: Int32
    public var socktype: Int32
    public var proto: Int32
    public var address: Data

    public init(family: Int32, socktype: Int32, proto: Int32, address: Data) {
        self.family = family
        self.socktype = socktype
        self.proto = proto
        self.address = address
    }
}

struct IPv4 {
    var octets: (UInt8, UInt8, UInt8, UInt8)

    init?(_ text: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        let value = UInt32(bigEndian: addr.s_addr)
        octets = (
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        )
    }

    var isPublic: Bool {
        let a = octets.0
        let b = octets.1
        if a == 0 || a == 10 || a == 127 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a >= 224 { return false }
        return true
    }
}

struct IPv6 {
    var bytes: [UInt8]

    init?(_ text: String) {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, text, &addr) == 1 else { return nil }
        bytes = withUnsafeBytes(of: addr) { Array($0) }
    }

    var isPublic: Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[15] == 1 && bytes.dropLast().allSatisfy({ $0 == 0 }) { return false }
        // fc00::/7 unique local, fe80::/10 link local, ff00::/8 multicast
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if let embedded = embeddedIPv4 {
            return embedded.isPublic
        }
        return true
    }

    private var embeddedIPv4: IPv4? {
        let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        if mapped {
            return ipv4(from: Array(bytes[12...15]))
        }
        // IPv4-compatible ::a.b.c.d
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return ipv4(from: Array(bytes[12...15]))
        }
        // 6to4 2002:xxxx:xxxx::
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return ipv4(from: Array(bytes[2...5]))
        }
        // NAT64 64:ff9b::
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b {
            return ipv4(from: Array(bytes[12...15]))
        }
        // Teredo 2001:0000: the client IPv4 is inverted in the last 4 bytes
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0 {
            return ipv4(from: bytes[12...15].map { ~$0 })
        }
        return nil
    }

    private func ipv4(from octets: [UInt8]) -> IPv4? {
        guard octets.count == 4 else { return nil }
        return IPv4(octets.map(String.init).joined(separator: "."))
    }
}
