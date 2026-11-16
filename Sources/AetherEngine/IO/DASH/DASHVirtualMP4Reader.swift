import Foundation

/// AE#859: serves a `DASHVirtualLayout` as one seekable byte stream. The header is in memory; every
/// other byte comes from the representation file that holds it, through one seekable reader per
/// representation and a small block cache in front of each.
///
/// The cache is what keeps the request count at what a DASH player would spend. libavformat reads
/// an interleaved file sample by sample in decode order, which in this layout alternates between a
/// video fragment and the audio fragments next to it, and every switch is an AVIO seek and a fresh
/// buffer fill. A ranged reader with one window answers each return to the video fragment with a new
/// request a few kilobytes behind the last one (measured: 1042 requests for 45 s of one video file).
/// With the last few blocks of each file kept, those returns are memory reads, and each file is
/// fetched forward once, in requests that grow the way they do for any single file.
///
/// The moofs are rewritten on the way out (`DASHFragmentPatcher`). Their positions are only known
/// once read, so each piece is scanned box by box up to the end of whatever range is being read,
/// through the same cache and just ahead of the bytes the read is about to return anyway.
final class DASHVirtualMP4Reader: IOReader, SourceTransferCounting, @unchecked Sendable {

    private let layout: DASHVirtualLayout
    private let sources: [IOReader]
    private let caches: [BlockCache]
    private let lock = NSLock()
    private var position: Int64 = 0

    /// Per piece: the offset (relative to the piece) of the first box not scanned yet, and the
    /// patches found in front of it. Only touched under `lock`.
    private var scans: [Int: (next: Int64, patches: [DASHFragmentPatcher.Patch])] = [:]

    /// A moof larger than this is not one, the scan stops trusting the piece.
    private static let moofCeiling: Int64 = 32 * 1024 * 1024

    init(layout: DASHVirtualLayout, sources: [IOReader]) {
        precondition(sources.count == layout.trackIDMaps.count)
        self.layout = layout
        self.sources = sources
        caches = sources.map { BlockCache(reader: $0) }
    }

    var totalSize: Int64 { layout.totalSize }

    /// AE#1075: see `DASHVirtualLayout.randomAccessStartsSeconds`.
    var randomAccessStartsSeconds: [Double] { layout.randomAccessStartsSeconds }
    var interleaveLeadSeconds: Double { layout.interleaveLeadSeconds }

    var discImageProbeEnabled: Bool { false }

    var sourceBytesFetched: Int64 {
        sources.reduce(0) { $0 + (($1 as? SourceTransferCounting)?.sourceBytesFetched ?? 0) }
    }

    /// Never reads across a piece boundary, so a buffer fill that starts in one track's fragment
    /// does not pull the next track's reader ahead of where its own samples are read. A short read
    /// is part of the AVIO contract.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard position < layout.totalSize else { return 0 }
        let want = Int64(size)
        let headerCount = Int64(layout.header.count)
        if position < headerCount {
            let n = min(want, headerCount - position)
            layout.header.withUnsafeBufferPointer { src in
                buffer.update(from: src.baseAddress! + Int(position), count: Int(n))
            }
            position += n
            return Int32(n)
        }
        guard let index = layout.pieceIndex(containing: position) else { return 0 }
        let piece = layout.pieces[index]
        let within = position - piece.virtualOffset
        let n = min(want, piece.size - within)
        let patches = scan(index, through: within + n)
        let got = caches[piece.source].copy(at: piece.sourceOffset + within, into: buffer, count: n)
        guard got > 0 else { return -1 }
        for patch in patches {
            let lo = max(patch.offset, within)
            let hi = min(patch.offset + Int64(patch.bytes.count), within + got)
            guard lo < hi else { continue }
            for k in lo..<hi {
                buffer[Int(k - within)] = patch.bytes[Int(k - patch.offset)]
            }
        }
        position += got
        return Int32(got)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let target: Int64
        switch whence {
        case 65536: return layout.totalSize  // AVSEEK_SIZE
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = layout.totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    func close() {
        sources.forEach { $0.close() }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
    }

    func makeIndependentReader() -> IOReader? {
        var forks: [IOReader] = []
        for source in sources {
            guard let fork = source.makeIndependentReader() else {
                forks.forEach { $0.close() }
                return nil
            }
            forks.append(fork)
        }
        return DASHVirtualMP4Reader(layout: layout, sources: forks)
    }

    // MARK: - Private

    private func readBytes(_ source: Int, at offset: Int64, count: Int64) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: Int(count))
        let got = bytes.withUnsafeMutableBufferPointer {
            caches[source].copy(at: offset, into: $0.baseAddress!, count: count)
        }
        return got == count ? bytes : nil
    }

    /// The patches of piece `index` that start before `end`, scanning further into the piece first
    /// if it has not been scanned that far.
    private func scan(_ index: Int, through end: Int64) -> [DASHFragmentPatcher.Patch] {
        let piece = layout.pieces[index]
        var state = scans[index] ?? (0, [])
        while state.next < end, state.next + 8 <= piece.size {
            let at = piece.sourceOffset + state.next
            guard let head = readBytes(piece.source, at: at, count: min(16, piece.size - state.next)) else { break }
            var size = Int64(MP4Box.u32(head, 0))
            if size == 1, head.count >= 16 { size = Int64(bitPattern: MP4Box.u64(head, 8)) }
            if size == 0 { size = piece.size - state.next }
            guard size >= 8, state.next + size <= piece.size else {
                EngineLog.emit("[DASH] piece \(index): a box at +\(state.next) runs past its subsegment; "
                               + "the rest of it is served unpatched", category: .demux)
                state.next = piece.size
                break
            }
            let type = MP4Box.fourCC(head, 4)
            if type == "moof" {
                guard size <= Self.moofCeiling, let moof = readBytes(piece.source, at: at, count: size) else { break }
                let delta = piece.virtualOffset - piece.sourceOffset
                state.patches += DASHFragmentPatcher.moofPatches(
                    moof, idMap: layout.trackIDMaps[piece.source], sourceToVirtualDelta: delta
                ).map { .init(offset: $0.offset + state.next, bytes: $0.bytes) }
            } else if DASHFragmentPatcher.retypedTopLevelBoxes.contains(type) {
                state.patches.append(.init(offset: state.next + 4, bytes: Array("free".utf8)))
            }
            state.next += size
        }
        scans[index] = state
        return state.patches
    }

    /// The last few aligned blocks of one representation file. Only used under the reader's lock.
    private final class BlockCache {
        static let blockSize: Int64 = 1024 * 1024
        static let capacity = 8

        private let reader: IOReader
        private let fileSize: Int64
        private var blocks: [Int64: [UInt8]] = [:]
        private var recency: [Int64] = []

        init(reader: IOReader) {
            self.reader = reader
            fileSize = reader.seek(offset: 0, whence: 65536)
        }

        /// Copies up to `count` bytes from `offset`; returns how many, or -1 when the first byte
        /// cannot be read.
        func copy(at offset: Int64, into out: UnsafeMutablePointer<UInt8>, count: Int64) -> Int64 {
            var done: Int64 = 0
            while done < count {
                let at = offset + done
                let start = at - at % Self.blockSize
                guard let block = block(at: start), at - start < Int64(block.count) else { break }
                let n = min(count - done, Int64(block.count) - (at - start))
                block.withUnsafeBufferPointer { src in
                    (out + Int(done)).update(from: src.baseAddress! + Int(at - start), count: Int(n))
                }
                done += n
            }
            return done > 0 ? done : -1
        }

        private func block(at start: Int64) -> [UInt8]? {
            if let hit = blocks[start] {
                if recency.last != start {
                    recency.removeAll { $0 == start }
                    recency.append(start)
                }
                return hit
            }
            let length = fileSize > 0 ? min(Self.blockSize, fileSize - start) : Self.blockSize
            guard length > 0, reader.seek(offset: start, whence: SEEK_SET) == start else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(length))
            var got = 0
            while got < Int(length) {
                let r = bytes.withUnsafeMutableBufferPointer { buf in
                    autoreleasepool { reader.read(buf.baseAddress! + got, size: Int32(Int(length) - got)) }
                }
                if r <= 0 { break }
                got += Int(r)
            }
            guard got > 0 else { return nil }
            if got < bytes.count { bytes.removeSubrange(got...) }
            blocks[start] = bytes
            recency.append(start)
            if recency.count > Self.capacity {
                blocks[recency.removeFirst()] = nil
            }
            return bytes
        }
    }
}
