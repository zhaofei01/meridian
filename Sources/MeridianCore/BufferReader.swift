import Foundation

/// Byte queue with backpressure. `append` waits when the buffer is past the limit
/// so a slow consumer stalls the producer instead of growing without bound.
public final class BufferReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()
    private var eof = false
    private let limit: Int

    public init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    public func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        condition.lock()
        while data.count > limit && !eof {
            condition.wait()
        }
        if !eof {
            data.append(chunk)
            condition.signal()
        }
        condition.unlock()
    }

    public func finish() {
        condition.lock()
        eof = true
        condition.broadcast()
        condition.unlock()
    }

    /// nil means the producer finished and no bytes remain.
    public func read(upTo count: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while data.isEmpty && !eof {
            condition.wait()
        }
        if data.isEmpty && eof {
            return nil
        }
        let n = min(count, data.count)
        let out = data.prefix(n)
        data.removeFirst(n)
        condition.signal()
        return Data(out)
    }

    public var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return eof && data.isEmpty
    }
}
