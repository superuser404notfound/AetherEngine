import Foundation
import AetherLibavformat

/// The video random access points a fragmented MP4's
/// `mfra` declares, read before the open so the demuxer can index the file lazily.
///
/// libavformat indexes a fragmented MP4 by reading every top-level `moof` before the header
/// returns, one request per fragment over a network: a 2 hour file of 2.6 s fragments is about
/// 2,800 of them. movdec's `lazy_frag_index` (FFmpegBuild patch) stops the header behind the first
/// fragment and finds the others as seeks need them, but then the keyframe index holds only what
/// has been read, and the segment plan needs every keyframe up front. The `mfra` has them: each
/// `tfra` entry is a sync sample of its track, with the time it starts at. Those times become the
/// plan's boundaries the way a DASH source's sidx SAPs do (AE#1075). They are decode times; the
/// plan uses them as differences from the first, so a constant composition offset cancels.
///
/// The `mfra` is trusted for where the plan may cut and nothing else: seeks land through the
/// demuxer's own reading of the fragments, which checks every `moof` it uses.
struct FragmentedMP4RandomAccess: Equatable, Sendable {
    let trackID: UInt32
    let timescale: UInt32
    /// Ascending, without repeats, in the track's time scale.
    let times: [Int64]
    /// The `moof` each time's sync sample is in, parallel to `times`.
    let moofOffsets: [Int64]

    /// Seconds from the first random access point.
    var startsSeconds: [Double] {
        guard let first = times.first, timescale > 0 else { return [] }
        return times.map { Double($0 - first) / Double(timescale) }
    }

    enum Probe: Equatable, Sendable {
        /// Not an ISO BMFF file, or its `moov` declares no fragments: nothing to do.
        case notFragmented
        /// Fragmented, but the plan cannot come from its `mfra`: index it in full, as before.
        case unusable(String)
        case usable(FragmentedMP4RandomAccess)
    }

    static let maximumMoovBytes = 4 << 20
    static let maximumMfraBytes = 16 << 20

    // MARK: Reading through AVIO

    /// Reads the head boxes, the `moov` and the `mfra` through `pb`, then puts `pb` back at 0.
    /// A faststart MP4 costs a few 16 byte reads inside the head the open fetches anyway.
    static func probe(_ pb: UnsafeMutablePointer<AVIOContext>) -> Probe {
        defer { _ = avio_seek(pb, 0, SEEK_SET) }
        let size = avio_size(pb)
        guard size > 32 else { return .notFragmented }
        func read(_ offset: Int64, _ count: Int) -> Data? {
            guard count > 0, offset >= 0, offset + Int64(count) <= size,
                  avio_seek(pb, offset, SEEK_SET) == offset else { return nil }
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return avio_read(pb, base, Int32(count))
            }
            return n == Int32(count) ? data : nil
        }
        // Top-level boxes up to the moov. The first one is an ftyp in every file this applies to.
        var offset: Int64 = 0
        var moov: (offset: Int64, size: Int64, header: Int)?
        for index in 0..<32 where offset + 8 <= size {
            guard let head = read(offset, Int(min(16, size - offset))),
                  let box = boxHeader(head, at: 0, available: Int64(head.count)) else { return .notFragmented }
            if index == 0, box.type != "ftyp" { return .notFragmented }
            if box.type == "moov" { moov = (offset, box.size == 0 ? size - offset : box.size, box.headerSize); break }
            guard box.size > 0 else { return .notFragmented }
            offset += box.size
        }
        guard let moov else { return .notFragmented }
        // mvex by child headers first, so an ordinary MP4 never reads its (often large) moov.
        var child = moov.offset + Int64(moov.header)
        let moovEnd = moov.offset + moov.size
        var fragmented = false
        for _ in 0..<512 where child + 8 <= moovEnd {
            guard let head = read(child, 8), let box = boxHeader(head, at: 0, available: 8), box.size >= 8 else { break }
            if box.type == "mvex" { fragmented = true; break }
            child += box.size
        }
        guard fragmented else { return .notFragmented }
        guard moov.size <= Int64(maximumMoovBytes), let moovBytes = read(moov.offset, Int(moov.size)) else {
            return .unusable("the moov is larger than \(maximumMoovBytes >> 20) MB")
        }
        let videos = videoTracks(moov: moovBytes)
        guard videos.count == 1, let video = videos.first else {
            return .unusable(videos.isEmpty ? "no video track" : "\(videos.count) video tracks")
        }
        guard let mfro = read(size - 16, 16), let mfraSize = mfraSize(mfro: mfro) else {
            return .unusable("no mfra at the end of the file")
        }
        guard mfraSize <= Int64(maximumMfraBytes), mfraSize <= size,
              let mfra = read(size - mfraSize, Int(mfraSize)) else {
            return .unusable("the mfra (\(mfraSize) B) is out of bounds")
        }
        guard let entries = tfraEntries(mfra: mfra, trackID: video.trackID) else {
            return .unusable("the mfra has no tfra for the video track")
        }
        guard entries.count >= 2 else { return .unusable("the video tfra lists \(entries.count) entry") }
        return .usable(FragmentedMP4RandomAccess(trackID: video.trackID, timescale: video.timescale,
                                                 times: entries.map(\.time), moofOffsets: entries.map(\.moofOffset)))
    }

    /// The shift that puts the mfra's times on the demuxer's index axis, or nil when they do not
    /// describe the same keyframes. A tfra time is the sync sample's presentation time; the mov
    /// index holds decode times, so the two differ by the encoder's reorder delay (512 ticks on a
    /// 1/12288 B-frame file). The first indexed keyframe sets the shift. The lazy index holds the
    /// fragments it has read (the first, and the last for the durations), and every tfra entry
    /// whose fragment was read (an indexed keyframe falls between it and the next entry) must,
    /// shifted, be an indexed keyframe: a delay that changes along the file fails here. Extra
    /// indexed keyframes inside a fragment are fine, a tfra may list only the first of each.
    static func shiftOntoIndex(times: [Int64], indexedKeyframes indexed: [Int64]) -> Int64? {
        guard let first = times.first, let firstIndexed = indexed.min() else { return nil }
        let shift = firstIndexed - first
        let keyframes = Set(indexed)
        let sorted = indexed.sorted()
        var checked = 0
        for (i, raw) in times.enumerated() {
            let time = raw + shift
            let next = i + 1 < times.count ? times[i + 1] + shift : Int64.max
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < time { lo = mid + 1 } else { hi = mid } }
            guard lo < sorted.count, sorted[lo] < next else { continue }   // fragment not read
            guard keyframes.contains(time) else { return nil }
            checked += 1
        }
        // An indexed keyframe before the first entry or past the last entry's fragment would be one
        // the mfra does not know about.
        guard let lastIndexed = sorted.last, sorted.first == first + shift, checked >= 1,
              lastIndexed >= first + shift else { return nil }
        return shift
    }

    // MARK: Parsing (pure, unit tested)

    struct BoxHeader: Equatable {
        let type: String
        /// 0 means "to the end of the enclosing space".
        let size: Int64
        let headerSize: Int
    }

    static func boxHeader(_ data: Data, at: Int, available: Int64) -> BoxHeader? {
        guard at >= 0, at + 8 <= data.count else { return nil }
        let size32 = be32(data, at)
        let type = String(decoding: data[(data.startIndex + at + 4)..<(data.startIndex + at + 8)], as: UTF8.self)
        if size32 == 1 {
            guard at + 16 <= data.count else { return nil }
            let size = be64(data, at + 8)
            return size >= 16 ? BoxHeader(type: type, size: size, headerSize: 16) : nil
        }
        if size32 == 0 { return BoxHeader(type: type, size: 0, headerSize: 8) }
        return size32 >= 8 ? BoxHeader(type: type, size: size32, headerSize: 8) : nil
    }

    /// The children of the box payload `data[start..<end]`, as (type, payload range).
    static func children(_ data: Data, from start: Int, to end: Int) -> [(type: String, payload: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var p = start
        while p + 8 <= end, out.count < 4096 {
            guard let box = boxHeader(data, at: p, available: Int64(end - p)) else { break }
            let size = box.size == 0 ? Int64(end - p) : box.size
            guard size >= Int64(box.headerSize), Int64(p) + size <= Int64(end) else { break }
            out.append((box.type, (p + box.headerSize)..<(p + Int(size))))
            p += Int(size)
        }
        return out
    }

    /// The `vide` tracks of a `moov` (the whole box, header included): track ID and media time scale.
    static func videoTracks(moov: Data) -> [(trackID: UInt32, timescale: UInt32)] {
        guard let header = boxHeader(moov, at: 0, available: Int64(moov.count)), header.type == "moov" else { return [] }
        var result: [(UInt32, UInt32)] = []
        for trak in children(moov, from: header.headerSize, to: moov.count) where trak.type == "trak" {
            var trackID: UInt32?, timescale: UInt32?, handler: String?
            for box in children(moov, from: trak.payload.lowerBound, to: trak.payload.upperBound) {
                if box.type == "tkhd", box.payload.count >= 4 {
                    let version = moov[moov.startIndex + box.payload.lowerBound]
                    let idAt = box.payload.lowerBound + (version == 1 ? 20 : 12)
                    if idAt + 4 <= box.payload.upperBound { trackID = UInt32(be32(moov, idAt)) }
                } else if box.type == "mdia" {
                    for media in children(moov, from: box.payload.lowerBound, to: box.payload.upperBound) {
                        if media.type == "mdhd", media.payload.count >= 4 {
                            let version = moov[moov.startIndex + media.payload.lowerBound]
                            let scaleAt = media.payload.lowerBound + (version == 1 ? 20 : 12)
                            if scaleAt + 4 <= media.payload.upperBound { timescale = UInt32(be32(moov, scaleAt)) }
                        } else if media.type == "hdlr", media.payload.count >= 12 {
                            let at = moov.startIndex + media.payload.lowerBound + 8
                            handler = String(decoding: moov[at..<(at + 4)], as: UTF8.self)
                        }
                    }
                }
            }
            if handler == "vide", let trackID, let timescale, timescale > 0 { result.append((trackID, timescale)) }
        }
        return result
    }

    /// The size of the whole `mfra` an `mfro` (the file's last 16 bytes) names.
    static func mfraSize(mfro: Data) -> Int64? {
        guard mfro.count == 16, be32(mfro, 0) == 16,
              String(decoding: mfro[(mfro.startIndex + 4)..<(mfro.startIndex + 8)], as: UTF8.self) == "mfro" else { return nil }
        let size = be32(mfro, 12)
        return size > 16 ? size : nil
    }

    /// The `tfra` entries of one track in an `mfra` (the whole box, header included): ascending in
    /// time, repeats dropped. nil when the track has no `tfra`, the box does not parse in full or
    /// its times go backwards.
    static func tfraEntries(mfra: Data, trackID: UInt32) -> [(time: Int64, moofOffset: Int64)]? {
        guard let header = boxHeader(mfra, at: 0, available: Int64(mfra.count)), header.type == "mfra" else { return nil }
        for box in children(mfra, from: header.headerSize, to: mfra.count) where box.type == "tfra" {
            let p = box.payload.lowerBound, end = box.payload.upperBound
            guard p + 16 <= end, UInt32(be32(mfra, p + 4)) == trackID else { continue }
            let version = mfra[mfra.startIndex + p]
            let lengths = be32(mfra, p + 8)
            let trafBytes = Int((lengths >> 4) & 3) + 1, trunBytes = Int((lengths >> 2) & 3) + 1
            let sampleBytes = Int(lengths & 3) + 1
            let count = Int(be32(mfra, p + 12))
            let entryBytes = (version == 1 ? 16 : 8) + trafBytes + trunBytes + sampleBytes
            guard count >= 0, count <= (end - p - 16) / max(entryBytes, 1) else { return nil }
            var entries: [(time: Int64, moofOffset: Int64)] = []
            entries.reserveCapacity(count)
            var at = p + 16
            for _ in 0..<count {
                let time = version == 1 ? be64(mfra, at) : be32(mfra, at)
                let moof = version == 1 ? be64(mfra, at + 8) : be32(mfra, at + 4)
                at += entryBytes
                if let last = entries.last {
                    guard time >= last.time else { return nil }   // out of order: not trusted for a plan
                    if time == last.time { continue }
                }
                entries.append((time, moof))
            }
            return entries
        }
        return nil
    }

    private static func be32(_ d: Data, _ at: Int) -> Int64 {
        let i = d.startIndex + at
        return Int64(d[i]) << 24 | Int64(d[i + 1]) << 16 | Int64(d[i + 2]) << 8 | Int64(d[i + 3])
    }

    private static func be64(_ d: Data, _ at: Int) -> Int64 {
        (be32(d, at) << 32) | be32(d, at + 4)
    }
}
