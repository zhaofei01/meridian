import Foundation

public enum SensitiveReason: String, Codable, Equatable {
    case envFile = "环境文件"
    case privateKey = "私钥"
    case credentialFile = "凭据文件"
    case secretDirectory = "密钥目录"
    case escapesProject = "指向项目外面"
}

public struct BlockedFile: Equatable, Identifiable, Codable {
    public var path: String
    public var reason: SensitiveReason

    public var id: String { path }

    public init(path: String, reason: SensitiveReason) {
        self.path = path
        self.reason = reason
    }
}

public enum SensitivePath {
    private static let secretDirectories: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".kube", "secrets",
    ]

    private static let credentialNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials",
        "credentials.json", "secrets.json", "service-account.json",
        "gcloud.json",
    ]

    private static let privateKeyNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    ]

    private static let keyExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "kdbx", "keystore",
    ]

    /// `relativePath` uses "/" and must not contain ".." components.
    public static func verdict(relativePath: String) -> SensitiveReason? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains("") else {
            return parts.contains("..") ? .escapesProject : nil
        }
        if parts.contains(where: { secretDirectories.contains($0.lowercased()) }) {
            return .secretDirectory
        }
        if parts.count >= 2,
           parts[parts.count - 2].lowercased() == ".config",
           parts[parts.count - 1].lowercased() == "gh" {
            return .secretDirectory
        }
        // .config/gh/<file>
        if let config = parts.firstIndex(where: { $0.lowercased() == ".config" }),
           config + 1 < parts.count,
           parts[config + 1].lowercased() == "gh" {
            return .secretDirectory
        }
        let name = parts[parts.count - 1]
        let lower = name.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") {
            return .envFile
        }
        if credentialNames.contains(lower) || lower.hasSuffix(".tfvars") {
            return .credentialFile
        }
        if privateKeyNames.contains(lower) {
            return .privateKey
        }
        if let dot = lower.lastIndex(of: ".") {
            let ext = String(lower[lower.index(after: dot)...])
            if keyExtensions.contains(ext) {
                return .privateKey
            }
        }
        return nil
    }
}
