import Darwin
import Foundation

public enum TCPBridge {
    public static func run(host: String, port: Int, reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        guard let endpoints = HostSafety.resolvePublic(host: host, port: port) else {
            close()
            return
        }
        run(endpoints: endpoints, reader: reader, writer: writer, close: close)
    }

    public static func run(endpoints: [PublicEndpoint], reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        let fd: Int32
        do {
            fd = try connect(endpoints: endpoints)
        } catch {
            close()
            return
        }
        let lock = NSLock()
        var closed = false
        let finish = {
            lock.lock()
            let first = !closed
            closed = true
            lock.unlock()
            if first {
                reader.finish()
                Darwin.close(fd)
                close()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = reader.read(upTo: 32 * 1024) {
                if !writeAll(fd, chunk) {
                    break
                }
            }
            shutdown(fd, SHUT_WR)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    writer(Data(buffer.prefix(count)))
                } else {
                    break
                }
            }
            finish()
        }
    }

    static func connect(endpoints: [PublicEndpoint]) throws -> Int32 {
        var lastError = errno
        for endpoint in endpoints {
            let fd = socket(endpoint.family, endpoint.socktype, endpoint.proto)
            guard fd >= 0 else {
                lastError = errno
                continue
            }
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = endpoint.address.withUnsafeBytes { raw -> Bool in
                guard let base = raw.bindMemory(to: sockaddr.self).baseAddress else { return false }
                return Darwin.connect(fd, base, socklen_t(endpoint.address.count)) == 0
            }
            if connected {
                return fd
            }
            lastError = errno
            Darwin.close(fd)
        }
        throw POSIXError(POSIXErrorCode(rawValue: lastError) ?? .ECONNREFUSED)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n > 0 {
                    sent += n
                } else if errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
