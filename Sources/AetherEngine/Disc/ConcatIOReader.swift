import Foundation

/// A synthetic `IOReader` that presents an ordered list of byte extents of one
/// base reader as a single continuous, seekable stream. Used to concatenate a
/// DVD title set's VOBs (their absolute offsets inside the ISO) into the
/// contiguous MPEG-PS stream the demuxer expects.
final class ConcatIOReader: IOReader, @unchecked Sendable {
    /// An extent in the base reader: absolute byte `offset` and `length`.
    struct Extent { let offset: Int64; let length: Int64 }

    private let base: IOReader
    private let extents: [Extent]
    private let totalLength: Int64
    private var position: Int64 = 0
    private let lock = NSLock()

    init(base: IOReader, extents: [(offset: Int64, length: Int64)]) {
        self.base = base
        self.extents = extents.map { Extent(offset: $0.offset, length: $0.length) }
        self.totalLength = self.extents.reduce(0) { $0 + $1.length }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        if position >= totalLength { return 0 }                 // EOF
        // Locate the extent containing `position`.
        var remaining = position
        var idx = 0
        while idx < extents.count, remaining >= extents[idx].length {
            remaining -= extents[idx].length
            idx += 1
        }
        guard idx < extents.count else { return 0 }
        // Span across extent boundaries until `size` bytes filled or EOF.
        var totalGot: Int64 = 0
        let toRead = min(Int64(size), totalLength - position)
        while totalGot < toRead, idx < extents.count {
            let ext = extents[idx]
            let intra = remaining                               // offset within this extent
            let avail = ext.length - intra
            let want = min(toRead - totalGot, avail)
            let absolute = ext.offset + intra
            guard base.seek(offset: absolute, whence: SEEK_SET) >= 0 else {
                return totalGot > 0 ? Int32(totalGot) : -1
            }
            var got: Int64 = 0
            while got < want {
                let n = base.read(buffer.advanced(by: Int(totalGot + got)), size: Int32(want - got))
                if n == 0 { break }
                if n < 0 { return totalGot > 0 ? Int32(totalGot) : -1 }
                got += Int64(n)
            }
            totalGot += got
            if got < want { break }                             // base returned short read
            idx += 1
            remaining = 0                                       // subsequent extents start at offset 0
        }
        position += totalGot
        return Int32(totalGot)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return totalLength }               // AVSEEK_SIZE
        lock.lock(); defer { lock.unlock() }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = totalLength + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, totalLength)
        return position
    }

    func close() {}  // base reader is owned by the engine lifecycle

    // Forward cancel to the base (mirrors makeIndependentReader) so teardown unblocks a
    // read parked inside base.read() on a network source; close() being a no-op does not.
    func cancel() { base.cancel() }

    /// Vend a second concat reader over an independent cursor of the base, so
    /// the engine's side demuxer (embedded subtitles) and scrub preview can read
    /// concurrently. Nil if the base cannot fork a cursor.
    func makeIndependentReader() -> IOReader? {
        guard let forked = base.makeIndependentReader() else { return nil }
        return ConcatIOReader(base: forked,
                              extents: extents.map { (offset: $0.offset, length: $0.length) })
    }
}
