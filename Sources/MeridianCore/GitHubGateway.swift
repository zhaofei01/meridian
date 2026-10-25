import Foundation

public final class GitHubGateway: @unchecked Sendable {
    public var token: () -> String?
    public var authorize: (String) async -> Bool
    public var log: (String) -> Void
    private let session: URLSession
    private let lock = NSLock()
    private var sessionAllowed = false

    public init(
        session: URLSession = ModelGateway.makeSession(),
        token: @escaping () -> String?,
        authorize: @escaping (String) async -> Bool = { _ in true },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.session = session
        self.token = token
        self.authorize = authorize
        self.log = log
    }

    public func serveGit(reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        Task { await self.handleGit(reader: reader, writer: writer, close: close) }
    }

    public func serveMCP(reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        Task { await self.handleMCP(reader: reader, writer: writer, close: close) }
    }

    private func handleGit(reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) async {
        defer { close() }
        do {
            guard let request = try HTTPCodec.readRequest(from: reader) else { return }
            guard let upstream = GitHubRoutes.gitURL(target: request.target) else {
                writer(HTTPCodec.response(status: 404, reason: "Not Found", body: Data("这个地址不是 GitHub 仓库。".utf8)))
                return
            }
            guard SecretMaterial.isUsable(token()), let token = token() else {
                writer(HTTPCodec.response(status: 401, reason: "Unauthorized", body: Data("请先在 Meridian 里连接 GitHub。".utf8)))
                log("还没有连接 GitHub，已拦住仓库访问。")
                return
            }
            let repo = GitHubRoutes.repositoryDescription(target: request.target)
            let allowed = await ensureGitAccess(repo: repo)
            guard allowed else {
                writer(HTTPCodec.response(status: 403, reason: "Forbidden", body: Data("这次没有允许使用 GitHub。".utf8)))
                log("拒绝使用 GitHub 访问 \(repo)。")
                return
            }
            var urlRequest = URLRequest(url: upstream)
            urlRequest.httpMethod = request.method
            urlRequest.httpBody = request.body
            for (name, value) in request.headers {
                let lower = name.lowercased()
                if ["host", "authorization", "content-length", "connection", "accept-encoding"].contains(lower) {
                    continue
                }
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("github.com", forHTTPHeaderField: "Host")
            let (data, response) = try await session.data(for: urlRequest)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            var headers: [(String, String)] = []
            if let type = http?.value(forHTTPHeaderField: "Content-Type") {
                headers.append(("Content-Type", type))
            }
            writer(HTTPCodec.response(status: status, reason: "OK", headers: headers, body: data))
            log(Redaction.redact("使用已连接的 GitHub 访问 \(repo)。仓库密码没有进沙箱。", secrets: [token]))
        } catch {
            writer(HTTPCodec.response(status: 502, reason: "Bad Gateway", body: Data("转交 GitHub 失败。".utf8)))
            log("转交 GitHub 失败。")
        }
    }

    private func ensureGitAccess(repo: String) async -> Bool {
        lock.lock()
        let already = sessionAllowed
        lock.unlock()
        if already { return true }
        let allowed = await authorize("它要使用你已连接的 GitHub，范围是 \(repo)。")
        if allowed {
            lock.lock()
            sessionAllowed = true
            lock.unlock()
        }
        return allowed
    }

    private func handleMCP(reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) async {
        defer { close() }
        do {
            guard let request = try HTTPCodec.readRequest(from: reader) else { return }
            if request.method == "DELETE" {
                writer(HTTPCodec.response(status: 204, reason: "No Content", body: Data()))
                return
            }
            guard request.method == "POST" else {
                writer(HTTPCodec.response(status: 405, reason: "Method Not Allowed"))
                return
            }
            let token = token()
            let payload = try await MCPExchange.respond(body: request.body, token: token, session: session)
            let accept = request.value(for: "accept")?.lowercased() ?? ""
            if accept.contains("text/event-stream") {
                let json = String(data: payload, encoding: .utf8) ?? "{}"
                let sse = "event: message\ndata: \(json)\n\n"
                writer(HTTPCodec.response(
                    status: 200,
                    reason: "OK",
                    headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")],
                    body: Data(sse.utf8)
                ))
            } else {
                writer(HTTPCodec.response(
                    status: 200,
                    reason: "OK",
                    headers: [("Content-Type", "application/json")],
                    body: payload
                ))
            }
            log("沙箱调用了 GitHub 工具。令牌留在这台电脑上。")
        } catch {
            writer(HTTPCodec.response(status: 400, reason: "Bad Request", body: Data("GitHub 工具没有完成。".utf8)))
        }
    }
}

enum MCPExchange {
    static func respond(body: Data, token: String?, session: URLSession) async throws -> Data {
        let message = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let method = message?["method"] as? String ?? ""
        let id = message?["id"]
        if method == "notifications/initialized" || id == nil {
            return Data("{}".utf8)
        }
        let result: Any
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "meridian-github", "version": "0.1.0"],
            ]
        case "tools/list":
            result = ["tools": tools]
        case "tools/call":
            result = try await call(message: message ?? [:], token: token, session: session)
        case "ping":
            result = [:] as [String: Any]
        default:
            let error: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "unknown method"]]
            return try JSONSerialization.data(withJSONObject: error)
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private static var tools: [[String: Any]] {
        [
            [
                "name": "github_whoami",
                "description": "查看当前连接的 GitHub 账号",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "github_list_repos",
                "description": "列出当前账号看得到的仓库",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "github_list_issues",
                "description": "列出一个仓库里的议题",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "owner": ["type": "string"],
                        "repo": ["type": "string"],
                    ],
                    "required": ["owner", "repo"],
                ],
            ],
        ]
    }

    private static func call(message: [String: Any], token: String?, session: URLSession) async throws -> [String: Any] {
        guard SecretMaterial.isUsable(token), let token else {
            return toolText("GitHub 还没有在 Meridian 里连接。", error: true)
        }
        let params = message["params"] as? [String: Any]
        let name = params?["name"] as? String ?? ""
        let args = params?["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "github_whoami":
            let json = try await get(path: "/user", token: token, session: session)
            let login = (json as? [String: Any])?["login"] as? String ?? ""
            return toolText(login.isEmpty ? "已连接 GitHub。" : "当前 GitHub 账号是 \(login)。")
        case "github_list_repos":
            let json = try await get(path: "/user/repos?per_page=20&sort=updated", token: token, session: session)
            let names = ((json as? [[String: Any]]) ?? []).compactMap { $0["full_name"] as? String }
            return toolText(names.isEmpty ? "没有看到仓库。" : names.joined(separator: "\n"))
        case "github_list_issues":
            let owner = args["owner"] as? String ?? ""
            let repo = args["repo"] as? String ?? ""
            guard isName(owner), isName(repo) else {
                return toolText("仓库名不合规则。", error: true)
            }
            let json = try await get(path: "/repos/\(owner)/\(repo)/issues?per_page=20", token: token, session: session)
            let lines = ((json as? [[String: Any]]) ?? []).compactMap { item -> String? in
                guard let number = item["number"] as? Int, let title = item["title"] as? String else { return nil }
                return "#\(number) \(title)"
            }
            return toolText(lines.isEmpty ? "没有议题。" : lines.joined(separator: "\n"))
        default:
            return toolText("没有这个工具。", error: true)
        }
    }

    private static func get(path: String, token: String, session: URLSession) async throws -> Any {
        guard let url = URL(string: "https://api.github.com" + path) else {
            throw HTTPError.malformed
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Meridian", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HTTPError.unsupported
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func toolText(_ text: String, error: Bool = false) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": error,
        ]
    }

    private static func isName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count < 120 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }
}
