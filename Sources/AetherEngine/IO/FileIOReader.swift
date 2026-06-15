import Foundation

/// Seekable `IOReader` over a local file, backed by a `FileHandle`. Reads on
/// demand (no whole-file load), so it suits multi-GB ISO images. Threading:
/// the lock makes read/seek safe off the engine's demux thread.
final class FileIOReader: IOReader, @unchecked Sendable {
    private let handle: FileHandle
    private let url: URL
    private let size: Int64
    private let lock = NSLock()

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let sz = (attrs?[.size] as? NSNumber)?.int64Value
        self.handle = h
        self.url = url
        self.size = sz ?? 0
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size n: Int32) -> Int32 {
        guard let buffer, n > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? handle.read(upToCount: Int(n)) else { return -1 }
        if data.isEmpty { return 0 }
        data.copyBytes(to: buffer, count: data.count)
        return Int32(data.count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return size }
        lock.lock(); defer { lock.unlock() }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = Int64((try? handle.offset()) ?? 0) + offset
        case SEEK_END: target = size + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        do { try handle.seek(toOffset: UInt64(target)); return target }
        catch { return -1 }
    }

    func close() { try? handle.close() }

    func makeIndependentReader() -> IOReader? { FileIOReader(url: url) }
}
