import Foundation

public struct HTTPRequest {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [(String, String)]
    public var body: Data

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: [(String, String)] = [], body: Data = Data()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
    }

    public func value(for name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public mutating func remove(name: String) {
        headers.removeAll { $0.0.lowercased() == name.lowercased() }
    }

    public mutating func set(name: String, value: String) {
        remove(name: name)
        headers.append((name, value))
    }

    public var pathAndQuery: String {
        if target.hasPrefix("http://") || target.hasPrefix("https://"), let url = URL(string: target) {
            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query, !query.isEmpty {
                path += "?" + query
            }
            return path
        }
        return target.isEmpty ? "/" : target
    }
}

public enum HTTPError: Error, Equatable {
    case malformed
    case tooLarge
    case unsupported
}

public enum HTTPCodec {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 256 * 1024 * 1024

    public static func readRequest(from reader: BufferReader) throws -> HTTPRequest? {
        guard var head = try readUntilHeaderEnd(from: reader) else { return nil }
        guard let separator = head.range(of: Data([13, 10, 13, 10])) else {
            throw HTTPError.malformed
        }
        let headerData = head.subdata(in: 0..<separator.lowerBound)
        let leftover = head.subdata(in: separator.upperBound..<head.count)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPError.malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw HTTPError.malformed }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw HTTPError.malformed
        }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        var request = HTTPRequest(method: parts[0], target: parts[1], version: parts[2], headers: headers)
        request.body = try readBody(headers: headers, already: leftover, from: reader)
        return request
    }

    public static func response(status: Int, reason: String, headers: [(String, String)] = [], body: Data = Data()) -> Data {
        var fields = headers
        if !fields.contains(where: { $0.0.lowercased() == "content-length" }) {
            fields.append(("Content-Length", String(body.count)))
        }
        if !fields.contains(where: { $0.0.lowercased() == "connection" }) {
            fields.append(("Connection", "close"))
        }
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in fields {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    public static func chunk(_ data: Data) -> Data {
        var out = Data("\(String(data.count, radix: 16))\r\n".utf8)
        out.append(data)
        out.append(Data("\r\n".utf8))
        return out
    }

    public static func lastChunk() -> Data {
        Data("0\r\n\r\n".utf8)
    }

    private static func readUntilHeaderEnd(from reader: BufferReader) throws -> Data? {
        var buffer = Data()
        while buffer.range(of: Data([13, 10, 13, 10])) == nil {
            if buffer.count > maxHeaderBytes { throw HTTPError.tooLarge }
            guard let chunk = reader.read(upTo: 4096) else {
                if buffer.isEmpty { return nil }
                throw HTTPError.malformed
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func readBody(headers: [(String, String)], already: Data, from reader: BufferReader) throws -> Data {
        let encoding = headers.first { $0.0.lowercased() == "transfer-encoding" }?.1.lowercased() ?? ""
        if encoding.contains("chunked") {
            return try readChunked(already: already, from: reader)
        }
        let lengthText = headers.first { $0.0.lowercased() == "content-length" }?.1 ?? "0"
        guard let length = Int(lengthText), length >= 0 else { throw HTTPError.malformed }
        if length > maxBodyBytes { throw HTTPError.tooLarge }
        var body = already
        while body.count < length {
            guard let chunk = reader.read(upTo: length - body.count) else {
                throw HTTPError.malformed
            }
            body.append(chunk)
        }
        if body.count > length {
            body = body.prefix(length)
        }
        return body
    }

    private static func readChunked(already: Data, from reader: BufferReader) throws -> Data {
        var pending = already
        var body = Data()
        func take(_ n: Int) throws -> Data {
            while pending.count < n {
                guard let chunk = reader.read(upTo: max(n - pending.count, 1024)) else {
                    throw HTTPError.malformed
                }
                pending.append(chunk)
            }
            let out = pending.prefix(n)
            pending.removeFirst(n)
            return Data(out)
        }
        func readLine() throws -> String {
            while true {
                if let range = pending.range(of: Data([13, 10])) {
                    let line = pending.subdata(in: 0..<range.lowerBound)
                    pending.removeFirst(range.upperBound)
                    return String(data: line, encoding: .utf8) ?? ""
                }
                guard let chunk = reader.read(upTo: 1024) else { throw HTTPError.malformed }
                pending.append(chunk)
                if pending.count > maxHeaderBytes { throw HTTPError.tooLarge }
            }
        }
        while true {
            let line = try readLine()
            let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16) else { throw HTTPError.malformed }
            if size == 0 {
                _ = try readLine()
                return body
            }
            if body.count + size > maxBodyBytes { throw HTTPError.tooLarge }
            body.append(try take(size))
            let crlf = try take(2)
            guard crlf == Data([13, 10]) else { throw HTTPError.malformed }
        }
    }
}
