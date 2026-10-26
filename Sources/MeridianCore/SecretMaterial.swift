import Foundation

public enum SecretMaterial {
    /// Guest-visible stand-in. It is not a credential and must never be forwarded.
    public static let placeholder = "meridian-local"

    public static func isUsable(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != placeholder
    }
}

public enum Redaction {
    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty && secret != SecretMaterial.placeholder {
            result = result.replacingOccurrences(of: secret, with: "•••")
        }
        return result
    }
}
