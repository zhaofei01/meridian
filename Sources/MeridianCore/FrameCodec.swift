import Foundation

public enum GuestProtocol {
    public static let hostPort: UInt32 = 5000
    public static let version = 1
    public static let flagOpen: UInt16 = 1
    public static let flagData: UInt16 = 2
    public static let flagClose: UInt16 = 4
    public static let flagHello: UInt16 = 8
    public static let flagResize: UInt16 = 16
    public static let maxFrame = 8 * 1024 * 1024
    public static let headerSize = 10
}

public struct GuestFrame: Equatable {
    public var streamID: UInt32
    public var flags: UInt16
    public var payload: Data

    public init(streamID: UInt32, flags: UInt16, payload: Data) {
        self.streamID = streamID
        self.flags = flags
        self.payload = payload
    }

    public var payloadText: String {
        String(data: payload, encoding: .utf8) ?? ""
    }
}

public enum FrameCodec {
    public static func encode(_ frame: GuestFrame) -> Data {
        var data = Data(capacity: GuestProtocol.headerSize + frame.payload.count)
        var stream = frame.streamID.bigEndian
        var flags = frame.flags.bigEndian
        var length = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &stream) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    /// Returns nil when more bytes are required. Throws when the frame is illegal.
    public static func decode(_ buffer: inout Data) throws -> GuestFrame? {
        guard buffer.count >= GuestProtocol.headerSize else { return nil }
        let stream = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let flags = buffer.dropFirst(4).prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        let length = buffer.dropFirst(6).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if length > GuestProtocol.maxFrame {
            throw FrameError.tooLarge
        }
        let total = GuestProtocol.headerSize + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: GuestProtocol.headerSize..<total)
        buffer.removeFirst(total)
        return GuestFrame(streamID: stream, flags: flags, payload: payload)
    }
}

public enum FrameError: Error, Equatable {
    case tooLarge
    case closed
}

public struct StreamOpen: Codable, Equatable {
    public var kind: String
    public var host: String?
    public var port: Int?
    public var name: String?
    public var argv: [String]?
    public var cwd: String?
    public var cols: Int?
    public var rows: Int?
    public var github: Bool?
    public var workspace: Bool?
    public var version: Int?
    public var role: String?
    public var error: String?
    public var code: Int?
    public var ready: Bool?

    public init(
        kind: String,
        host: String? = nil,
        port: Int? = nil,
        name: String? = nil,
        argv: [String]? = nil,
        cwd: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        github: Bool? = nil,
        workspace: Bool? = nil,
        version: Int? = nil,
        role: String? = nil,
        error: String? = nil,
        code: Int? = nil,
        ready: Bool? = nil
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.name = name
        self.argv = argv
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.github = github
        self.workspace = workspace
        self.version = version
        self.role = role
        self.error = error
        self.code = code
        self.ready = ready
    }

    public var jsonData: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func parse(_ data: Data) -> StreamOpen? {
        try? JSONDecoder().decode(StreamOpen.self, from: data)
    }
}
