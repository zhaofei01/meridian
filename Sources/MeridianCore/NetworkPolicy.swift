import Foundation

public enum PolicyDecision: Equatable {
    case allow
    case deny(String)
    case ask(String)
}

public struct NetworkPolicy: Equatable {
    public static let modelHosts: Set<String> = [
        "api.anthropic.com",
        "anthropic.com",
        "api.openai.com",
        "openai.com",
        "chatgpt.com",
    ]

    public static let githubHosts: [String] = [
        "github.com",
        "api.github.com",
        "codeload.github.com",
        "objects.githubusercontent.com",
        "githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    public var allowedHosts: Set<String>
    public var sessionEndpoints: Set<String>
    public var gitHubEnabled: Bool

    public init(allowedHosts: Set<String> = [], sessionEndpoints: Set<String> = [], gitHubEnabled: Bool = false) {
        self.allowedHosts = allowedHosts
        self.sessionEndpoints = sessionEndpoints
        self.gitHubEnabled = gitHubEnabled
    }

    public func decide(host: String, port: Int) -> PolicyDecision {
        let host = HostSafety.normalize(host)
        guard (1...65535).contains(port) else {
            return .deny("拒绝了一个没有端口的连接。")
        }
        if Self.isModelHost(host) {
            return .deny("拒绝直接联系 \(host)。模型请求只走这台电脑上的通道，钥匙不会进沙箱。")
        }
        if HostSafety.isObviouslyInternal(host) {
            return .deny("拒绝联系 \(host)。沙箱不能碰这台电脑的内部网络。")
        }
        if isPreapproved(host, port: port) {
            return .allow
        }
        return .ask("它要联系 \(host)，端口 \(port)。")
    }

    public static func isModelHost(_ host: String) -> Bool {
        let host = HostSafety.normalize(host)
        return modelHosts.contains { hostMatches(host, rule: $0) }
    }

    public func isPreapproved(_ host: String, port: Int) -> Bool {
        let host = HostSafety.normalize(host)
        if allowedHosts.contains(where: { matchesAllowed($0, host: host, port: port) }) { return true }
        if sessionEndpoints.contains(Self.endpointKey(host: host, port: port)) { return true }
        if gitHubEnabled && Self.githubHosts.contains(where: { hostMatches(host, rule: $0) }) {
            return true
        }
        return false
    }

    public static func endpointKey(host: String, port: Int) -> String {
        let host = HostSafety.normalize(host)
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    private func matchesAllowed(_ rule: String, host: String, port: Int) -> Bool {
        if let parsed = Self.parseEndpoint(rule) {
            return hostMatches(host, rule: parsed.host) && parsed.port == port
        }
        return hostMatches(host, rule: rule)
    }

    public static func parseEndpoint(_ value: String) -> (host: String, port: Int)? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = String(value[value.index(after: close)...])
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else {
                return nil
            }
            return (HostSafety.normalize(host), port)
        }
        guard let colon = value.lastIndex(of: ":"), !value[..<colon].contains(":") else { return nil }
        let host = String(value[..<colon])
        guard let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else {
            return nil
        }
        return (HostSafety.normalize(host), port)
    }
}

public func hostMatches(_ host: String, rule: String) -> Bool {
    let host = HostSafety.normalize(host)
    let rule = HostSafety.normalize(rule)
    if host == rule { return true }
    guard rule.contains(".") || IPv4(rule) != nil || IPv6(rule) != nil else { return false }
    guard host.hasSuffix("." + rule) else { return false }
    let prefix = String(host.dropLast(rule.count + 1))
    return !prefix.isEmpty && !prefix.contains(".")
}
