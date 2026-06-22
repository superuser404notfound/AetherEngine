import Foundation
import os
import AetherEngine

/// One-shot holder for a blocking read's result. Written once inside the bridging Task, read once after the semaphore wait; the DispatchSemaphore provides the happens-before edge that makes @unchecked Sendable safe.
private final class ReadOutcome: @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data())
}

/// Bridges a `ByteRangeSource` into the engine's `IOReader`. `read`/`seek`
/// are synchronous blocking calls on the engine's demux thread; the async
/// source is driven through a `DispatchSemaphore`.
public final class SMBIOReader: IOReader, @unchecked Sendable {
    private let source: ByteRangeSource
    private let ownsSource: Bool
    // `position` and `didClose` are only accessed on the demux/teardown thread
    // per the IOReader contract; no lock needed.
    private var position: Int64 = 0
    private var didClose = false
    // `inFlight` is written on the demux thread (read()) and read on a
    // different thread (cancel()), so it needs its own lock.
    private let inFlightLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// `AVSEEK_SIZE` from FFmpeg: return total size, do not move.
    private let avseekSize: Int32 = 65536

    public init(source: ByteRangeSource, ownsSource: Bool = true) {
        self.source = source
        self.ownsSource = ownsSource
    }

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let offset = position
        let want = Int(size)

        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ReadOutcome()
        let task = Task { [source] in
            do { outcome.result = .success(try await source.read(at: offset, length: want)) }
            catch { outcome.result = .failure(error) }
            semaphore.signal()
        }
        inFlightLock.withLock { $0 = task }
        semaphore.wait()
        inFlightLock.withLock { $0 = nil }

        switch outcome.result {
        case .failure:
            return -1
        case .success(let data):
            if data.isEmpty { return 0 } // EOF
            let n = min(data.count, want)
            data.copyBytes(to: buffer, count: n)
            position += Int64(n)
            return Int32(n)
        }
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        let candidate: Int64
        switch whence {
        case Int32(SEEK_SET): candidate = offset
        case Int32(SEEK_CUR): candidate = position + offset
        case Int32(SEEK_END): candidate = source.byteSize + offset
        case avseekSize:      return source.byteSize
        default:              return -1
        }
        guard candidate >= 0 else { return -1 }
        position = candidate
        return position
    }

    public func cancel() {
        let task = inFlightLock.withLock { $0 }
        task?.cancel()
    }

    public func makeIndependentReader() -> IOReader? {
        // Range reads are stateless and SMB2Manager is thread safe, so the
        // independent reader shares the connection but never owns its teardown.
        SMBIOReader(source: source, ownsSource: false)
    }

    public func close() {
        guard !didClose else { return }
        didClose = true
        if ownsSource { source.close() }
    }
}
