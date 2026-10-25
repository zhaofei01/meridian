import Foundation

public struct ProjectRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var createdAt: Date
    public var gitHubEnabled: Bool
    public var allowedHosts: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        createdAt: Date = Date(),
        gitHubEnabled: Bool = false,
        allowedHosts: [String] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.gitHubEnabled = gitHubEnabled
        self.allowedHosts = allowedHosts
    }
}

public struct ActivityEvent: Codable, Identifiable, Equatable {
    public enum Level: String, Codable {
        case info
        case allow
        case deny
    }

    public var id: UUID
    public var date: Date
    public var projectID: UUID?
    public var level: Level
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), projectID: UUID?, level: Level, message: String) {
        self.id = id
        self.date = date
        self.projectID = projectID
        self.level = level
        self.message = message
    }
}

public enum MeridianPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Meridian", isDirectory: true)
    }

    public static var projectsFile: URL {
        support.appendingPathComponent("projects.json")
    }

    public static var activityFile: URL {
        support.appendingPathComponent("activity.json")
    }

    public static var guestImage: URL {
        support.appendingPathComponent("GuestImage", isDirectory: true)
    }

    public static func mirror(for project: UUID) -> URL {
        support.appendingPathComponent("Mirrors", isDirectory: true).appendingPathComponent(project.uuidString, isDirectory: true)
    }

    public static func machine(for project: UUID) -> URL {
        support.appendingPathComponent("Machines", isDirectory: true).appendingPathComponent(project.uuidString, isDirectory: true)
    }

    public static func ensure() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

public final class ProjectStore {
    private let file: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(file: URL = MeridianPaths.projectsFile) {
        self.file = file
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> [ProjectRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        return try decoder.decode([ProjectRecord].self, from: data)
    }

    public func save(_ projects: [ProjectRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(projects)
        try data.write(to: file, options: .atomic)
    }
}

public final class ActivityLog {
    private let file: URL
    private let lock = NSLock()
    private let limit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var events: [ActivityEvent]

    public init(file: URL = MeridianPaths.activityFile, limit: Int = 400) {
        self.file = file
        self.limit = limit
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        if let data = try? Data(contentsOf: file), let decoded = try? decoder.decode([ActivityEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
    }

    @discardableResult
    public func append(projectID: UUID?, level: ActivityEvent.Level, message: String, secrets: [String] = []) -> ActivityEvent {
        let event = ActivityEvent(
            projectID: projectID,
            level: level,
            message: Redaction.redact(message, secrets: secrets)
        )
        lock.lock()
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
        let snapshot = events
        lock.unlock()
        persist(snapshot)
        return event
    }

    private func persist(_ snapshot: [ActivityEvent]) {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
