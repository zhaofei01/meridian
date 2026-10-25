import CoreServices
import Darwin
import Foundation

public final class WorkspaceMirror {
    public let project: URL
    public let mirror: URL
    public private(set) var blocked: [BlockedFile] = []
    public var onChange: (([BlockedFile]) -> Void)?

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var expected: Set<String> = []
    private var stream: FSEventStreamRef?
    private var contextPointer: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "meridian.mirror")

    public init(project: URL, mirror: URL) {
        self.project = project.standardizedFileURL
        self.mirror = mirror.standardizedFileURL
    }

    deinit {
        stop()
    }

    public func rebuild() throws {
        if fileManager.fileExists(atPath: mirror.path) {
            try fileManager.removeItem(at: mirror)
        }
        try fileManager.createDirectory(at: mirror, withIntermediateDirectories: true)
        blocked = []
        try seed(directory: project, relative: "")
        onChange?(blocked)
    }

    public func startWatching() {
        stop()
        let pointer = Unmanaged.passRetained(self).toOpaque()
        contextPointer = pointer
        var context = FSEventStreamContext(
            version: 0,
            info: pointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [project.path, mirror.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, eventPaths, eventFlags, _ in
                guard let info else { return }
                let mirror = Unmanaged<WorkspaceMirror>.fromOpaque(info).takeUnretainedValue()
                let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let count = CFArrayGetCount(cfArray)
                var paths: [String] = []
                paths.reserveCapacity(count)
                var flags: [FSEventStreamEventFlags] = []
                flags.reserveCapacity(count)
                for index in 0..<count {
                    let value = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, index), to: CFString.self)
                    paths.append(value as String)
                    flags.append(eventFlags[index])
                }
                mirror.accept(paths: paths, flags: flags)
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            Unmanaged<WorkspaceMirror>.fromOpaque(pointer).release()
            contextPointer = nil
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let contextPointer {
            Unmanaged<WorkspaceMirror>.fromOpaque(contextPointer).release()
            self.contextPointer = nil
        }
    }

    public func accept(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            let removed = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
            accept(absolutePath: path, removed: removed)
        }
    }

    public func accept(absolutePath: String, removed: Bool) {
        let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        if consumeExpected(path) { return }
        guard let side = classify(path) else { return }
        if removed {
            handleRemoved(side)
        } else {
            handleUpsert(side)
        }
    }

    private struct Side {
        enum Root { case project, mirror }
        var root: Root
        var relative: String
        var url: URL
    }

    private func classify(_ path: String) -> Side? {
        if let relative = relativePath(from: project.path, to: path) {
            return Side(root: .project, relative: relative, url: URL(fileURLWithPath: path))
        }
        if let relative = relativePath(from: mirror.path, to: path) {
            return Side(root: .mirror, relative: relative, url: URL(fileURLWithPath: path))
        }
        return nil
    }

    private func relativePath(from root: String, to path: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func handleRemoved(_ side: Side) {
        guard !side.relative.isEmpty else { return }
        if SensitivePath.verdict(relativePath: side.relative) != nil {
            if side.root == .mirror {
                try? fileManager.removeItem(at: side.url)
            }
            return
        }
        switch side.root {
        case .mirror:
            let projectURL = project.appendingPathComponent(side.relative)
            expect(projectURL.path)
            try? fileManager.removeItem(at: projectURL)
        case .project:
            let mirrorURL = mirror.appendingPathComponent(side.relative)
            expect(mirrorURL.path)
            try? fileManager.removeItem(at: mirrorURL)
        }
    }

    private func handleUpsert(_ side: Side) {
        guard !side.relative.isEmpty else { return }
        if let reason = SensitivePath.verdict(relativePath: side.relative) {
            let mirrorURL = mirror.appendingPathComponent(side.relative)
            if fileManager.fileExists(atPath: mirrorURL.path) {
                expect(mirrorURL.path)
                try? fileManager.removeItem(at: mirrorURL)
            }
            remember(BlockedFile(path: side.relative, reason: reason))
            return
        }
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: side.url.path, isDirectory: &isDir)
        guard exists else { return }
        switch side.root {
        case .project:
            if isDir.boolValue {
                let dest = mirror.appendingPathComponent(side.relative)
                expect(dest.path)
                try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                try? seed(directory: side.url, relative: side.relative)
            } else {
                try? install(projectFile: side.url, relative: side.relative)
            }
        case .mirror:
            let projectURL = project.appendingPathComponent(side.relative)
            if isDir.boolValue {
                expect(projectURL.path)
                try? fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            } else if sameInode(side.url, projectURL) {
                return
            } else {
                try? adopt(mirrorFile: side.url, projectFile: projectURL, relative: side.relative)
            }
        }
    }

    private func seed(directory: URL, relative: String) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        )
        for child in children {
            let name = child.lastPathComponent
            let rel = relative.isEmpty ? name : relative + "/" + name
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                try mirrorSymlink(at: child, relative: rel)
            } else if values.isDirectory == true {
                if let reason = SensitivePath.verdict(relativePath: rel) {
                    remember(BlockedFile(path: rel, reason: reason))
                    continue
                }
                try fileManager.createDirectory(
                    at: mirror.appendingPathComponent(rel),
                    withIntermediateDirectories: true
                )
                try seed(directory: child, relative: rel)
            } else {
                try install(projectFile: child, relative: rel)
            }
        }
    }

    private func mirrorSymlink(at source: URL, relative: String) throws {
        let destination = source.resolvingSymlinksInPath().standardizedFileURL
        guard destination.path == project.path || destination.path.hasPrefix(project.path + "/") else {
            remember(BlockedFile(path: relative, reason: .escapesProject))
            return
        }
        let targetRelative = String(destination.path.dropFirst(project.path.count + (destination.path == project.path ? 0 : 1)))
        if let reason = SensitivePath.verdict(relativePath: targetRelative) ?? SensitivePath.verdict(relativePath: relative) {
            remember(BlockedFile(path: relative, reason: reason))
            return
        }
        let linkURL = mirror.appendingPathComponent(relative)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: linkURL.path) { return }
        let original = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: original)
    }

    private func install(projectFile: URL, relative: String) throws {
        if let reason = SensitivePath.verdict(relativePath: relative) {
            remember(BlockedFile(path: relative, reason: reason))
            return
        }
        let dest = mirror.appendingPathComponent(relative)
        if sameInode(projectFile, dest) { return }
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: dest.path) {
            expect(dest.path)
            try fileManager.removeItem(at: dest)
        }
        expect(dest.path)
        if Darwin.link(projectFile.path, dest.path) != 0 {
            let error = errno
            if error == EXDEV {
                try fileManager.copyItem(at: projectFile, to: dest)
            } else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
            }
        }
    }

    private func adopt(mirrorFile: URL, projectFile: URL, relative: String) throws {
        if let reason = SensitivePath.verdict(relativePath: relative) {
            expect(mirrorFile.path)
            try? fileManager.removeItem(at: mirrorFile)
            remember(BlockedFile(path: relative, reason: reason))
            return
        }
        try fileManager.createDirectory(at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: projectFile.path) {
            expect(projectFile.path)
            try fileManager.removeItem(at: projectFile)
        }
        expect(projectFile.path)
        try fileManager.copyItem(at: mirrorFile, to: projectFile)
        expect(mirrorFile.path)
        try fileManager.removeItem(at: mirrorFile)
        try install(projectFile: projectFile, relative: relative)
    }

    private func remember(_ entry: BlockedFile) {
        if !blocked.contains(where: { $0.path == entry.path }) {
            blocked.append(entry)
            blocked.sort { $0.path < $1.path }
            onChange?(blocked)
        }
    }

    private func expect(_ path: String) {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock()
        expected.insert(standard)
        lock.unlock()
    }

    private func consumeExpected(_ path: String) -> Bool {
        lock.lock()
        let had = expected.remove(path) != nil
        lock.unlock()
        return had
    }

    private func sameInode(_ a: URL, _ b: URL) -> Bool {
        var left = Darwin.stat()
        var right = Darwin.stat()
        guard stat(a.path, &left) == 0, stat(b.path, &right) == 0 else { return false }
        return left.st_ino == right.st_ino && left.st_dev == right.st_dev
    }
}

public enum ProjectScan {
    public static func blockedFiles(in project: URL) -> [BlockedFile] {
        let root = project.standardizedFileURL
        var blocked: [BlockedFile] = []
        func walk(_ directory: URL, _ relative: String) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: []
            ) else { return }
            for child in children {
                let rel = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    let destination = child.resolvingSymlinksInPath().standardizedFileURL
                    let inside = destination.path == root.path || destination.path.hasPrefix(root.path + "/")
                    if !inside {
                        blocked.append(BlockedFile(path: rel, reason: .escapesProject))
                        continue
                    }
                }
                if let reason = SensitivePath.verdict(relativePath: rel) {
                    blocked.append(BlockedFile(path: rel, reason: reason))
                    continue
                }
                if values?.isDirectory == true && values?.isSymbolicLink != true {
                    walk(child, rel)
                }
            }
        }
        walk(root, "")
        return blocked.sorted { $0.path < $1.path }
    }
}
