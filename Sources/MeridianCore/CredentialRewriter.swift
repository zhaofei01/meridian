import Foundation

public enum ModelProvider: String, Codable, Equatable {
    case anthropic
    case openai

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    public var upstreamOrigin: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        }
    }

    public var keychainAccount: String { rawValue }
}

public enum CredentialRewriter {
    private static let stripped = [
        "authorization", "x-api-key", "api-key", "proxy-authorization",
    ]

    /// Drops whatever the guest sent and attaches the host credential.
    public static func rewrite(_ request: inout HTTPRequest, provider: ModelProvider, secret: String) {
        for name in stripped {
            request.remove(name: name)
        }
        request.remove(name: "host")
        request.remove(name: "content-length")
        request.remove(name: "accept-encoding")
        switch provider {
        case .anthropic:
            request.set(name: "x-api-key", value: secret)
            if request.value(for: "anthropic-version") == nil {
                request.set(name: "anthropic-version", value: "2023-06-01")
            }
        case .openai:
            request.set(name: "Authorization", value: "Bearer \(secret)")
        }
    }

    public static func upstreamURL(provider: ModelProvider, target: String) -> URL? {
        let path = HTTPRequest(method: "GET", target: target).pathAndQuery
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: provider.upstreamOrigin + suffix)
    }

    public static func attachmentNote(provider: ModelProvider) -> String {
        "联系了 \(provider.displayName)，钥匙留在这台电脑上。"
    }
}

public enum GitHubRoutes {
    public static func gitURL(target: String) -> URL? {
        let path = HTTPRequest(method: "GET", target: target).pathAndQuery
        guard path == "/github" || path.hasPrefix("/github/") else { return nil }
        let rest = String(path.dropFirst("/github".count))
        let suffix = rest.isEmpty ? "/" : rest
        return URL(string: "https://github.com" + suffix)
    }

    public static func repositoryDescription(target: String) -> String {
        let path = HTTPRequest(method: "GET", target: target).pathAndQuery
        let rest = path.hasPrefix("/github/") ? String(path.dropFirst("/github/".count)) : path
        let noQuery = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
        let pieces = noQuery.split(separator: "/").map(String.init)
        if pieces.count >= 2 {
            return "\(pieces[0])/\(pieces[1].replacingOccurrences(of: ".git", with: ""))"
        }
        return "GitHub"
    }
}
