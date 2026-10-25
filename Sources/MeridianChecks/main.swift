import Darwin
import Foundation
import MeridianCore

struct CheckError: Error, CustomStringConvertible {
    var description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String = "检查没有通过", file: StaticString = #file, line: UInt = #line) throws {
    if !condition() {
        throw CheckError(description: "\(file):\(line) \(message)")
    }
}

@main
struct MeridianChecks {
    static func main() async {
        do {
            try policy()
            try frame()
            try rewriter()
            try placeholder()
            try http()
            try mirror()
            try await modelGateway()
            try await githubTool()
            print("ok")
        } catch {
            fputs("\(error)\n", stderr)
            Darwin.exit(1)
        }
    }

    static func policy() throws {
        try check(SensitivePath.verdict(relativePath: ".env") == .envFile)
        try check(SensitivePath.verdict(relativePath: "config/.env.local") == .envFile)
        try check(SensitivePath.verdict(relativePath: ".ssh/id_rsa") == .secretDirectory)
        try check(SensitivePath.verdict(relativePath: "keys/server.pem") == .privateKey)
        try check(SensitivePath.verdict(relativePath: "credentials.json") == .credentialFile)
        try check(SensitivePath.verdict(relativePath: "README.md") == nil)
        try check(SensitivePath.verdict(relativePath: "../.ssh/id_rsa") == .escapesProject)
        try check(HostSafety.isObviouslyInternal("127.0.0.1"))
        try check(HostSafety.isObviouslyInternal("10.1.2.3"))
        try check(HostSafety.isObviouslyInternal("192.168.1.20"))
        try check(HostSafety.isObviouslyInternal("172.16.5.1"))
        try check(HostSafety.isObviouslyInternal("169.254.169.254"))
        try check(HostSafety.isObviouslyInternal("localhost"))
        try check(HostSafety.isObviouslyInternal("printer.local"))
        try check(HostSafety.isObviouslyInternal("::1"))
        try check(!HostSafety.isObviouslyInternal("8.8.8.8"))
        try check(!HostSafety.isObviouslyInternal("github.com"))
        let policy = NetworkPolicy(allowedHosts: ["api.anthropic.com"], gitHubEnabled: true)
        if case .deny = policy.decide(host: "api.anthropic.com", port: 443) {} else { try check(false, "模型域名必须拒绝") }
        if case .deny = policy.decide(host: "API.OpenAI.com", port: 443) {} else { try check(false, "模型域名必须拒绝") }
        try check(policy.decide(host: "github.com", port: 443) == .allow)
        if case .ask = policy.decide(host: "registry.npmjs.org", port: 443) {} else { try check(false, "未知网站应该询问") }
        if case .deny = policy.decide(host: "192.168.0.5", port: 443) {} else { try check(false, "内网必须拒绝") }
    }

    static func frame() throws {
        let frame = GuestFrame(streamID: 1, flags: GuestProtocol.flagData, payload: Data("hi".utf8))
        let encoded = FrameCodec.encode(frame)
        try check(encoded == Data([0, 0, 0, 1, 0, 2, 0, 0, 0, 2, 0x68, 0x69]))
        var buffer = encoded
        let decoded = try FrameCodec.decode(&buffer)
        try check(decoded == frame)
        try check(buffer.isEmpty)
        var short = Data([0, 0, 0, 1])
        let incomplete = try FrameCodec.decode(&short)
        try check(incomplete == nil)
    }

    static func rewriter() throws {
        var request = HTTPRequest(
            method: "POST",
            target: "/v1/messages",
            headers: [
                ("x-api-key", "sk-attacker"),
                ("Authorization", "Bearer meridian-local"),
                ("anthropic-version", "2023-06-01"),
            ],
            body: Data("hi".utf8)
        )
        CredentialRewriter.rewrite(&request, provider: .anthropic, secret: "sk-real-host-key")
        try check(request.value(for: "x-api-key") == "sk-real-host-key")
        try check(!request.headers.contains { $0.1.contains("sk-attacker") || $0.1.contains("meridian-local") })
        try check(CredentialRewriter.upstreamURL(provider: .anthropic, target: "/v1/messages")?.absoluteString == "https://api.anthropic.com/v1/messages")
        try check(GitHubRoutes.gitURL(target: "/github/octo/repo.git/info/refs?service=git-upload-pack")?.absoluteString == "https://github.com/octo/repo.git/info/refs?service=git-upload-pack")
        try check(GitHubRoutes.gitURL(target: "https://evil.example/github/octo/repo.git")?.host == "github.com")
        try check(GitHubRoutes.gitURL(target: "/v1/messages") == nil)
        let note = Redaction.redact(CredentialRewriter.attachmentNote(provider: .anthropic), secrets: ["sk-real-host-key"])
        try check(!note.contains("sk-real-host-key"))
    }

    static func placeholder() throws {
        let store = MemorySecretStore()
        try check((try? store.save(account: "anthropic", secret: "meridian-local")) == nil)
        try check((try? store.save(account: "anthropic", secret: "   ")) == nil)
        try store.save(account: "anthropic", secret: "sk-real-host-key")
        let loaded = try store.load(account: "anthropic")
        try check(loaded == "sk-real-host-key")
    }

    static func http() throws {
        let raw = Data("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:8787\r\nContent-Length: 2\r\n\r\nhi".utf8)
        let reader = BufferReader()
        reader.append(raw)
        reader.finish()
        let request = try checkUnwrap(try HTTPCodec.readRequest(from: reader))
        try check(request.method == "POST")
        try check(request.body == Data("hi".utf8))
        try check(request.pathAndQuery == "/v1/messages")
    }

    static func mirror() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meridian-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: project.appendingPathComponent("README.md"))
        try Data("SECRET=1".utf8).write(to: project.appendingPathComponent(".env"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("key".utf8).write(to: project.appendingPathComponent(".ssh/id_rsa"))
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("outside").path, withDestinationPath: "/etc/passwd")
        let box = WorkspaceMirror(project: project, mirror: mirror)
        try box.rebuild()
        try check(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("README.md").path))
        try check(!FileManager.default.fileExists(atPath: mirror.appendingPathComponent(".env").path))
        try check(!FileManager.default.fileExists(atPath: mirror.appendingPathComponent(".ssh").path))
        try check(!FileManager.default.fileExists(atPath: mirror.appendingPathComponent("outside").path))
        try check(box.blocked.contains { $0.path == ".env" })
        var source = Darwin.stat()
        var linked = Darwin.stat()
        try check(stat(project.appendingPathComponent("README.md").path, &source) == 0)
        try check(stat(mirror.appendingPathComponent("README.md").path, &linked) == 0)
        try check(source.st_ino == linked.st_ino)
        let created = mirror.appendingPathComponent("note.txt")
        try Data("from guest".utf8).write(to: created)
        box.accept(absolutePath: created.path, removed: false)
        let adopted = try String(contentsOf: project.appendingPathComponent("note.txt"), encoding: .utf8)
        try check(adopted == "from guest")
        let leaked = mirror.appendingPathComponent("id_rsa")
        try Data("nope".utf8).write(to: leaked)
        box.accept(absolutePath: leaked.path, removed: false)
        try check(!FileManager.default.fileExists(atPath: leaked.path))
        try check(!FileManager.default.fileExists(atPath: project.appendingPathComponent("id_rsa").path))
    }

    static func modelGateway() async throws {
        let token = "sk-real-host-key"
        StubURL.last = nil
        StubURL.body = Data("{\"ok\":true}".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURL.self]
        let session = URLSession(configuration: config)
        let messages = LockedMessages()
        let gateway = ModelGateway(provider: .anthropic, session: session, secret: { token }, log: { messages.add($0) })
        let reader = BufferReader()
        reader.append(Data("POST /v1/messages HTTP/1.1\r\nx-api-key: meridian-local\r\nContent-Length: 2\r\n\r\nhi".utf8))
        reader.finish()
        var written = Data()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gateway.serve(reader: reader, writer: { written.append($0) }, close: { continuation.resume() })
        }
        let outgoing = try checkUnwrap(StubURL.last?.value(forHTTPHeaderField: "x-api-key"))
        try check(outgoing == token)
        let text = String(data: written, encoding: .utf8) ?? ""
        try check(!text.contains(token))
        try check(!text.contains("meridian-local"))
        try check(!messages.all.contains { $0.contains(token) })
    }

    static func githubTool() async throws {
        let token = "ghp_secret_value"
        StubURL.last = nil
        StubURL.body = Data("{\"login\":\"octocat\"}".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURL.self]
        let session = URLSession(configuration: config)
        let gateway = GitHubGateway(session: session, token: { token }, authorize: { _ in true })
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"github_whoami\",\"arguments\":{}}}".utf8)
        var raw = Data("POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        raw.append(body)
        let reader = BufferReader()
        reader.append(raw)
        reader.finish()
        var written = Data()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gateway.serveMCP(reader: reader, writer: { written.append($0) }, close: { continuation.resume() })
        }
        let text = String(data: written, encoding: .utf8) ?? ""
        try check(text.contains("octocat"))
        try check(!text.contains(token))
        try check(StubURL.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }
}

func checkUnwrap<T>(_ value: T?, _ message: String = "值为空", file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { throw CheckError(description: "\(file):\(line) \(message)") }
    return value
}

final class StubURL: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var last: URLRequest?
    static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURL.lock.lock()
        StubURL.last = request
        let body = StubURL.body
        StubURL.lock.unlock()
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://example.com")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
    func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
