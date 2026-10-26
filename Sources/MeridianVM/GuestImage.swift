import Foundation
import MeridianCore

public struct GuestImageManifest: Codable, Equatable {
    public var hasClaude: Bool
    public var hasCodex: Bool
    public var hasNode: Bool
    public var hasGit: Bool
    public var builtAt: String
    public var kernelName: String
    public var initramfsName: String
    public var note: String

    public init(
        hasClaude: Bool,
        hasCodex: Bool,
        hasNode: Bool,
        hasGit: Bool,
        builtAt: String,
        kernelName: String,
        initramfsName: String,
        note: String
    ) {
        self.hasClaude = hasClaude
        self.hasCodex = hasCodex
        self.hasNode = hasNode
        self.hasGit = hasGit
        self.builtAt = builtAt
        self.kernelName = kernelName
        self.initramfsName = initramfsName
        self.note = note
    }
}

public struct LoadedGuestImage: Equatable {
    public var kernel: URL
    public var initramfs: URL
    public var manifest: GuestImageManifest

    public init(kernel: URL, initramfs: URL, manifest: GuestImageManifest) {
        self.kernel = kernel
        self.initramfs = initramfs
        self.manifest = manifest
    }
}

public enum GuestImageStore {
    public static func load(from directory: URL = MeridianPaths.guestImage) -> LoadedGuestImage? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(GuestImageManifest.self, from: data) else {
            return nil
        }
        guard isSafeImageName(manifest.kernelName), isSafeImageName(manifest.initramfsName) else {
            return nil
        }
        let kernel = directory.appendingPathComponent(manifest.kernelName)
        let initramfs = directory.appendingPathComponent(manifest.initramfsName)
        guard FileManager.default.isReadableFile(atPath: kernel.path),
              FileManager.default.isReadableFile(atPath: initramfs.path) else {
            return nil
        }
        return LoadedGuestImage(kernel: kernel, initramfs: initramfs, manifest: manifest)
    }

    static func isSafeImageName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !name.isEmpty
            && name == (name as NSString).lastPathComponent
            && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
