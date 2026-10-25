import Darwin
import Foundation

public enum TCPBridge {
    public static func run(host: String, port: Int, reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        guard !HostSafety.isObviouslyInternal(host), HostSafety.resolvesToPublicInternet(host) else {
            close()
            return
        }
        let fd: Int32
        do {
            fd = try connect(host: host, port: port)
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

    static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let info else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(info) }
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        var lastError = errno
        while let node = cursor {
            let fd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, node.pointee.ai_addr, node.pointee.ai_addrlen) == 0 {
                    return fd
                }
                lastError = errno
                Darwin.close(fd)
            }
            cursor = node.pointee.ai_next
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
