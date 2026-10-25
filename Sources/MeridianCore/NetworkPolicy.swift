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
    public var sessionHosts: Set<String>
    public var gitHubEnabled: Bool

    public init(allowedHosts: Set<String> = [], sessionHosts: Set<String> = [], gitHubEnabled: Bool = false) {
        self.allowedHosts = allowedHosts
        self.sessionHosts = sessionHosts
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
        if isPreapproved(host) {
            return .allow
        }
        return .ask("它要联系 \(host)，端口 \(port)。")
    }

    public static func isModelHost(_ host: String) -> Bool {
        let host = HostSafety.normalize(host)
        return modelHosts.contains { hostMatches(host, rule: $0) }
    }

    public func isPreapproved(_ host: String) -> Bool {
        let host = HostSafety.normalize(host)
        if allowedHosts.contains(where: { hostMatches(host, rule: $0) }) { return true }
        if sessionHosts.contains(where: { hostMatches(host, rule: $0) }) { return true }
        if gitHubEnabled && Self.githubHosts.contains(where: { hostMatches(host, rule: $0) }) {
            return true
        }
        return false
    }
}

public func hostMatches(_ host: String, rule: String) -> Bool {
    let host = HostSafety.normalize(host)
    let rule = HostSafety.normalize(rule)
    return host == rule || host.hasSuffix("." + rule)
}
