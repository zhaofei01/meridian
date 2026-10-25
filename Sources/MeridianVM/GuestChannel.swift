import Darwin
import Foundation
import MeridianCore
import Virtualization

/// Multiplexed virtio-socket session. The guest opens service and TCP streams.
/// The host opens the shell. Nothing on this channel is a credential.
public final class GuestChannel: @unchecked Sendable {
    public var onReady: ((StreamOpen) -> Void)?
    public var onShellOutput: ((Data) -> Void)?
    public var onShellClose: ((StreamOpen?) -> Void)?
    public var onService: ((StreamOpen, BufferReader, @escaping (Data) -> Void, @escaping () -> Void) -> Void)?
    public var onTCP: ((String, Int, BufferReader, @escaping (Data) -> Void, @escaping () -> Void, @escaping () -> Void) -> Void)?

    private var retained: VZVirtioSocketConnection?
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var readers: [UInt32: BufferReader] = [:]
    private var nextHostID: UInt32 = 2
    private var shellID: UInt32?
    private var ready = false
    private var pendingShell: StreamOpen?
    private var stopped = false

    public init() {}

    public func accept(_ connection: VZVirtioSocketConnection) {
        stateLock.lock()
        if retained != nil || stopped {
            stateLock.unlock()
            connection.close()
            return
        }
        retained = connection
        fd = connection.fileDescriptor
        stateLock.unlock()
        Thread.detachNewThread { [weak self] in
            self?.readLoop()
        }
    }

    public func sendHello(github: Bool) {
        let hello = StreamOpen(kind: "hello", github: github, version: GuestProtocol.version, role: "host")
        write(GuestFrame(streamID: 0, flags: GuestProtocol.flagHello, payload: hello.jsonData))
    }

    public func openShell(argv: [String], cwd: String, cols: Int, rows: Int) {
        let open = StreamOpen(kind: "shell", argv: argv, cwd: cwd, cols: cols, rows: rows)
        stateLock.lock()
        if !ready {
            pendingShell = open
            stateLock.unlock()
            return
        }
        let id = allocateLocked()
        shellID = id
        stateLock.unlock()
        write(GuestFrame(streamID: id, flags: GuestProtocol.flagOpen, payload: open.jsonData))
    }

    public func sendInput(_ data: Data) {
        stateLock.lock()
        let id = shellID
        stateLock.unlock()
        guard let id, !data.isEmpty else { return }
        write(GuestFrame(streamID: id, flags: GuestProtocol.flagData, payload: data))
    }

    public func resize(cols: Int, rows: Int) {
        stateLock.lock()
        let id = shellID
        stateLock.unlock()
        guard let id else { return }
        let payload = StreamOpen(kind: "resize", cols: cols, rows: rows).jsonData
        write(GuestFrame(streamID: id, flags: GuestProtocol.flagResize, payload: payload))
    }

    public func close() {
        stateLock.lock()
        stopped = true
        let connection = retained
        let openReaders = readers
        readers = [:]
        retained = nil
        fd = -1
        stateLock.unlock()
        for reader in openReaders.values {
            reader.finish()
        }
        connection?.close()
    }

    private func readLoop() {
        while !stopped {
            guard let header = readExactly(GuestProtocol.headerSize) else { break }
            let length = header.dropFirst(6).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length > GuestProtocol.maxFrame { break }
            var buffer = header
            if length > 0 {
                guard let payload = readExactly(Int(length)) else { break }
                buffer.append(payload)
            }
            let frame: GuestFrame
            do {
                guard let decoded = try FrameCodec.decode(&buffer) else { break }
                frame = decoded
            } catch {
                break
            }
            handle(frame)
        }
        close()
    }

    private func handle(_ frame: GuestFrame) {
        if frame.flags & GuestProtocol.flagHello != 0 {
            let hello = StreamOpen.parse(frame.payload) ?? StreamOpen(kind: "hello", version: 0, role: "guest")
            stateLock.lock()
            ready = true
            let pending = pendingShell
            pendingShell = nil
            if let pending {
                let id = allocateLocked()
                shellID = id
                stateLock.unlock()
                write(GuestFrame(streamID: id, flags: GuestProtocol.flagOpen, payload: pending.jsonData))
            } else {
                stateLock.unlock()
            }
            onReady?(hello)
            return
        }
        if frame.flags & GuestProtocol.flagOpen != 0 {
            guard let open = StreamOpen.parse(frame.payload) else { return }
            let reader = BufferReader()
            stateLock.lock()
            readers[frame.streamID] = reader
            stateLock.unlock()
            let streamID = frame.streamID
            let send: (Data) -> Void = { [weak self] data in
                self?.write(GuestFrame(streamID: streamID, flags: GuestProtocol.flagData, payload: data))
            }
            let closeStream: () -> Void = { [weak self] in
                self?.write(GuestFrame(streamID: streamID, flags: GuestProtocol.flagClose, payload: Data()))
                self?.finish(streamID)
            }
            let accept: () -> Void = { [weak self] in
                let ack = StreamOpen(kind: "ok")
                self?.write(GuestFrame(streamID: streamID, flags: GuestProtocol.flagOpen, payload: ack.jsonData))
            }
            if open.kind == "tcp" {
                onTCP?(open.host ?? "", open.port ?? 0, reader, send, closeStream, accept)
            } else {
                onService?(open, reader, send, closeStream)
            }
            return
        }
        if frame.flags & GuestProtocol.flagData != 0 {
            stateLock.lock()
            let reader = readers[frame.streamID]
            let shell = shellID
            stateLock.unlock()
            if frame.streamID == shell {
                onShellOutput?(frame.payload)
            } else {
                reader?.append(frame.payload)
            }
        }
        if frame.flags & GuestProtocol.flagClose != 0 {
            stateLock.lock()
            let shell = shellID
            stateLock.unlock()
            if frame.streamID == shell {
                shellID = nil
                onShellClose?(StreamOpen.parse(frame.payload))
            }
            finish(frame.streamID)
        }
    }

    private func finish(_ streamID: UInt32) {
        stateLock.lock()
        let reader = readers.removeValue(forKey: streamID)
        stateLock.unlock()
        reader?.finish()
    }

    private func allocateLocked() -> UInt32 {
        let id = nextHostID
        nextHostID += 2
        return id
    }

    private func write(_ frame: GuestFrame) {
        let bytes = FrameCodec.encode(frame)
        writeLock.lock()
        let fd = self.fd
        writeLock.unlock()
        guard fd >= 0 else { return }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
                if n > 0 {
                    sent += n
                } else if errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while got < count {
                if stopped { return false }
                let n = Darwin.read(fd, base.advanced(by: got), count - got)
                if n > 0 {
                    got += n
                } else if n == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }
}
