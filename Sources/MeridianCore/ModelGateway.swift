import Foundation

public final class ModelGateway: @unchecked Sendable {
    public let provider: ModelProvider
    public var secret: () -> String?
    public var log: (String) -> Void
    private let session: URLSession

    public init(provider: ModelProvider, session: URLSession = ModelGateway.makeSession(), secret: @escaping () -> String?, log: @escaping (String) -> Void = { _ in }) {
        self.provider = provider
        self.session = session
        self.secret = secret
        self.log = log
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    public func serve(reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        Task {
            await self.handle(reader: reader, writer: writer, close: close)
        }
    }

    private func handle(reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) async {
        defer { close() }
        let secret = secret()
        do {
            guard var request = try HTTPCodec.readRequest(from: reader) else { return }
            guard SecretMaterial.isUsable(secret), let secret else {
                writer(HTTPCodec.response(status: 401, reason: "Unauthorized", body: Data("请先在 Meridian 里连接 \(provider.displayName) 账号。钥匙不会写进沙箱。".utf8)))
                log("还没有连接 \(provider.displayName)，已拦住这次模型请求。")
                return
            }
            guard let url = CredentialRewriter.upstreamURL(provider: provider, target: request.target) else {
                writer(HTTPCodec.response(status: 400, reason: "Bad Request", body: Data("无法转交这个请求。".utf8)))
                return
            }
            CredentialRewriter.rewrite(&request, provider: provider, secret: secret)
            var upstream = URLRequest(url: url)
            upstream.httpMethod = request.method
            upstream.httpBody = request.body
            for (name, value) in request.headers {
                upstream.setValue(value, forHTTPHeaderField: name)
            }
            let (bytes, response) = try await session.bytes(for: upstream)
            guard let http = response as? HTTPURLResponse else {
                writer(HTTPCodec.response(status: 502, reason: "Bad Gateway", body: Data("模型服务没有返回。".utf8)))
                return
            }
            var head = "HTTP/1.1 \(http.statusCode) \(statusText(http.statusCode))\r\n"
            head += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "application/json")\r\n"
            head += "Transfer-Encoding: chunked\r\n"
            head += "Connection: close\r\n\r\n"
            writer(Data(head.utf8))
            var pending = Data()
            for try await byte in bytes {
                pending.append(byte)
                if pending.count >= 16 * 1024 {
                    writer(HTTPCodec.chunk(pending))
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {
                writer(HTTPCodec.chunk(pending))
            }
            writer(HTTPCodec.lastChunk())
            log(Redaction.redact(CredentialRewriter.attachmentNote(provider: provider), secrets: [secret]))
        } catch {
            writer(HTTPCodec.response(status: 502, reason: "Bad Gateway", body: Data("转交模型请求失败。".utf8)))
            log("转交 \(provider.displayName) 失败。")
        }
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Status"
        }
    }
}
