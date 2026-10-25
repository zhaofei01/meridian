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
        let host = normalize(host)
        if isObviouslyInternal(host) {
            return false
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &info)
        guard rc == 0, let info else { return false }
        defer { freeaddrinfo(info) }
        var sawAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let node = cursor {
            sawAddress = true
            if node.pointee.ai_family == AF_INET, let addr = node.pointee.ai_addr {
                let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var copy = value
                inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
                let text = String(cString: buffer)
                if IPv4(text)?.isPublic != true {
                    return false
                }
            } else if node.pointee.ai_family == AF_INET6, let addr = node.pointee.ai_addr {
                let value = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var copy = value
                inet_ntop(AF_INET6, &copy, &buffer, socklen_t(INET6_ADDRSTRLEN))
                let text = String(cString: buffer)
                if IPv6(text)?.isPublic != true {
                    return false
                }
            } else {
                return false
            }
            cursor = node.pointee.ai_next
        }
        return sawAddress
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
        let allZero = bytes.allSatisfy { $0 == 0 }
        if allZero { return false }
        if allZero && bytes[15] == 1 { return false }
        if bytes[0] == 0 && bytes[1] == 0 && bytes[15] == 1 && bytes.dropLast().allSatisfy({ $0 == 0 }) {
            return false
        }
        // fc00::/7 unique local, fe80::/10 link local, ff00::/8 multicast
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        // IPv4-mapped
        let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        if mapped {
            let v4 = bytes[12...15].map(String.init).joined(separator: ".")
            return IPv4(v4)?.isPublic == true
        }
        return true
    }
}
