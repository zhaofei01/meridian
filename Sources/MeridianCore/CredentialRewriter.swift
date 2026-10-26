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

    public static func allows(provider: ModelProvider, method: String, target: String) -> Bool {
        let method = method.uppercased()
        let path = HTTPRequest(method: method, target: target).pathAndQuery
        let pathOnly = path.split(separator: "?").first.map(String.init) ?? path
        guard pathOnly.hasPrefix("/v1/"), !pathOnly.contains("..") else { return false }
        switch provider {
        case .anthropic:
            return method == "POST" && (
                pathOnly == "/v1/messages"
                    || pathOnly == "/v1/complete"
                    || pathOnly == "/v1/messages/count_tokens"
                    || pathOnly.hasPrefix("/v1/messages/")
            )
        case .openai:
            if method == "GET" { return pathOnly == "/v1/models" }
            return method == "POST" && (
                pathOnly == "/v1/chat/completions"
                    || pathOnly == "/v1/completions"
                    || pathOnly == "/v1/responses"
                    || pathOnly == "/v1/embeddings"
            )
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
    public static func gitURL(target: String, method: String = "GET") -> URL? {
        let raw = HTTPRequest(method: method, target: target).pathAndQuery
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let path = parts[0]
        let query = parts.count > 1 ? parts[1] : nil
        guard path.hasPrefix("/github/") else { return nil }
        let rest = String(path.dropFirst("/github".count))
        let pieces = rest.split(separator: "/").map(String.init)
        guard pieces.count >= 3 else { return nil }
        guard GitHubName.isOwner(pieces[0]), GitHubName.isRepository(pieces[1]) else { return nil }
        let verb = method.uppercased()
        if pieces.count == 4 && pieces[2] == "info" && pieces[3] == "refs" {
            guard verb == "GET" || verb == "HEAD" else { return nil }
            if let query, !query.isEmpty {
                let service = query.split(separator: "&").compactMap { item -> String? in
                    let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                    return pair.first == "service" ? pair.dropFirst().first : nil
                }.first
                if let service, service != "git-upload-pack" && service != "git-receive-pack" {
                    return nil
                }
            }
            let suffix = query.map { rest + "?" + $0 } ?? rest
            return URL(string: "https://github.com" + suffix)
        }
        if pieces.count == 3 && (pieces[2] == "git-upload-pack" || pieces[2] == "git-receive-pack") {
            guard verb == "POST" else { return nil }
            return URL(string: "https://github.com" + rest)
        }
        return nil
    }

    public static func repositoryDescription(target: String) -> String {
        let path = HTTPRequest(method: "GET", target: target).pathAndQuery
        let rest = path.hasPrefix("/github/") ? String(path.dropFirst("/github/".count)) : path
        let noQuery = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
        let pieces = noQuery.split(separator: "/").map(String.init)
        if pieces.count >= 2 {
            return "\(pieces[0])/\(GitHubName.stripGitSuffix(pieces[1]))"
        }
        return "GitHub"
    }
}

public enum GitHubName {
    public static func isOwner(_ value: String) -> Bool {
        isName(value)
    }

    public static func isRepository(_ value: String) -> Bool {
        isName(stripGitSuffix(value))
    }

    public static func stripGitSuffix(_ value: String) -> String {
        value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    public static func isName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count < 120, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        } && !value.contains("..")
    }
}
