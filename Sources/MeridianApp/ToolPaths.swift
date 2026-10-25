import Foundation

enum ToolPaths {
    static func resource(_ file: String) -> URL? {
        let ns = file as NSString
        let ext = ns.pathExtension
        let name = ns.deletingPathExtension
        if let url = Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent("Scripts").appendingPathComponent(file),
            root.appendingPathComponent("Guest").appendingPathComponent(file),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
