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
    /// Per-read in-flight state, published so cancel() (a different thread) can both cancel the
    /// background work and, crucially, unblock read()'s semaphore wait. AMSMB2's libsmb2 read is
    /// not cancellation-aware (only an internal ~60s timeout resolves the continuation), so
    /// task.cancel() alone could not wake the wait and teardown blocked up to 60s; cancel() now
    /// signals the semaphore directly and read() aborts.
    private final class Inflight: @unchecked Sendable {
        let task: Task<Void, Never>
        let semaphore: DispatchSemaphore
        var cancelled = false
        init(task: Task<Void, Never>, semaphore: DispatchSemaphore) {
            self.task = task
            self.semaphore = semaphore
        }
    }
    // Written on the demux thread (read()), read/mutated on a different thread (cancel()); guarded.
    private let inFlightLock = OSAllocatedUnfairLock<Inflight?>(initialState: nil)

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
        inFlightLock.withLock { $0 = Inflight(task: task, semaphore: semaphore) }
        semaphore.wait()
        // cancel() may have signalled to unblock teardown while the libsmb2 read is still running.
        // In that case do NOT read `outcome`: the background Task may still be writing it (the
        // semaphore's happens-before edge only covers the Task's own signal). Abort with -1 instead.
        let wasCancelled = inFlightLock.withLock { state -> Bool in
            let c = state?.cancelled ?? false
            state = nil
            return c
        }
        if wasCancelled { return -1 }

        switch outcome.result {
        case .failure(let error):
            // Log the underlying SMB error (auth failure, share gone, connection reset) before the
            // -1 sentinel; without it a NAS bug report has nothing to go on. .verbose = Release-retrievable.
            EngineLog.emit("[SMBIOReader] read failed at offset \(offset): \(error.localizedDescription)",
                           category: .demux, level: .verbose)
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
        inFlightLock.withLock { state in
            state?.cancelled = true
            state?.task.cancel()
            state?.semaphore.signal()   // wake read()'s wait; the libsmb2 op drains in the background
        }
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
