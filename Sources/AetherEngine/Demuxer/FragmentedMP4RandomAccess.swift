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
/// plan's boundaries the way a DASH source's sidx SAPs do (AE#1075). They are presentation times
/// (the sync sample's, ISO/IEC 14496-12 8.8.10); the index holds decode times, so
/// `shiftOntoIndex` aligns them, and a declared-boundary plan uses them as differences from the
/// first, where a constant composition offset cancels.
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
    static let maximumMoofBytes = 4 << 20
    /// How many tfra entries the probe checks against their moof, spread over the file. Each is one
    /// side request of about 32 KB through the reader.
    static let checkedEntries = 4

    // MARK: Reading through AVIO

    /// Reads the head boxes, the `moov` and the `mfra` through `pb`, then puts `pb` back at 0.
    /// A faststart MP4 costs a few 16 byte reads inside the head the open fetches anyway; an MP4
    /// whose `mdat` comes before its `moov` stops at that `mdat`.
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
            // A fragmented file's moov comes before any media data. Media first is a classic MP4
            // (moov at the end, read by the open's own trailing-index pass): nothing more is read
            // here, so its tail costs no extra request.
            if box.type == "mdat" || box.type == "moof" { return .notFragmented }
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
        // A tfra entry is meant to be a sync sample, but ffmpeg's mp4 muxer writes the first sample
        // of every fragment, sync or not. A file cut at fixed durations (-frag_duration without
        // frag_keyframe) then lists a "keyframe" every fragment, the plan cuts between real ones and
        // seeks land seconds off. The lazy index has read only the first fragment, so nothing else
        // would catch it: look at a few of the fragments the entries name.
        let trexFlags = defaultSampleFlags(moov: moovBytes, trackID: video.trackID)
        for i in sampleIndices(count: entries.count) {
            let entry = entries[i]
            guard let head = read(entry.moofOffset, 8), let box = boxHeader(head, at: 0, available: 8),
                  box.type == "moof", box.size >= 16, box.size <= Int64(maximumMoofBytes),
                  let moof = read(entry.moofOffset, Int(box.size)) else {
                return .unusable("tfra entry \(i) does not point at a moof")
            }
            switch sampleIsSync(moof: moof, trackID: video.trackID, trunNumber: entry.trun,
                                sampleNumber: entry.sample, defaultFlags: trexFlags) {
            case true?:
                continue
            case false?:
                return .unusable("tfra entry \(i) (moof at \(entry.moofOffset)) names a sample that is not a sync sample")
            case nil:
                return .unusable("tfra entry \(i) names a sample its moof does not have")
            }
        }
        return .usable(FragmentedMP4RandomAccess(trackID: video.trackID, timescale: video.timescale,
                                                 times: entries.map(\.time), moofOffsets: entries.map(\.moofOffset)))
    }

    /// The shift that puts the mfra's times on the demuxer's index axis, or nil when they do not
    /// describe the same keyframes. A tfra time is the sync sample's presentation time; the mov
    /// index holds decode times, so the two differ by the encoder's reorder delay (512 ticks on a
    /// 1/12288 B-frame file). The first indexed keyframe sets the shift. The lazy index holds the
    /// fragments it has read (at the open only the first: the last is parsed for the durations but
    /// not indexed, which is why `probe` checks a few entries against their moof), and every tfra entry
    /// whose fragment was read (an indexed keyframe falls between it and the next entry) must,
    /// shifted, be an indexed keyframe: a delay that changes along the file fails here. Extra
    /// indexed keyframes inside a fragment are fine, a tfra may list only the first of each.
    static func shiftOntoIndex(times: [Int64], indexedKeyframes indexed: [Int64]) -> Int64? {
        guard let first = times.first, let firstIndexed = indexed.min() else { return nil }
        let shift = firstIndexed - first
        let keyframes = Set(indexed)
        let sorted = indexed.sorted()
        for (i, raw) in times.enumerated() {
            let time = raw + shift
            let next = i + 1 < times.count ? times[i + 1] + shift : Int64.max
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < time { lo = mid + 1 } else { hi = mid } }
            guard lo < sorted.count, sorted[lo] < next else { continue }   // fragment not read
            guard keyframes.contains(time) else { return nil }
        }
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
    static func tfraEntries(mfra: Data, trackID: UInt32)
        -> [(time: Int64, moofOffset: Int64, trun: Int, sample: Int)]? {
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
            var entries: [(time: Int64, moofOffset: Int64, trun: Int, sample: Int)] = []
            entries.reserveCapacity(count)
            var at = p + 16
            for _ in 0..<count {
                let time = version == 1 ? be64(mfra, at) : be32(mfra, at)
                let moof = version == 1 ? be64(mfra, at + 8) : be32(mfra, at + 4)
                let numbers = at + (version == 1 ? 16 : 8) + trafBytes
                let trun = Int(beN(mfra, numbers, trunBytes))
                let sample = Int(beN(mfra, numbers + trunBytes, sampleBytes))
                at += entryBytes
                if let last = entries.last {
                    guard time >= last.time else { return nil }   // out of order: not trusted for a plan
                    if time == last.time { continue }
                }
                entries.append((time, moof, trun, sample))
            }
            return entries
        }
        return nil
    }

    /// The entries the probe checks: up to `checkedEntries`, spread from the second to the last
    /// (the first fragment is the one the lazy index reads anyway).
    static func sampleIndices(count: Int) -> [Int] {
        guard count >= 2 else { return [] }
        let n = min(checkedEntries, count - 1)
        return Array(Set((1...n).map { 1 + ($0 * (count - 2)) / n })).sorted()
    }

    /// trex's default_sample_flags for the track, from the moov (the whole box).
    static func defaultSampleFlags(moov: Data, trackID: UInt32) -> UInt32? {
        guard let header = boxHeader(moov, at: 0, available: Int64(moov.count)), header.type == "moov" else { return nil }
        for mvex in children(moov, from: header.headerSize, to: moov.count) where mvex.type == "mvex" {
            for trex in children(moov, from: mvex.payload.lowerBound, to: mvex.payload.upperBound) where trex.type == "trex" {
                let p = trex.payload.lowerBound
                guard p + 24 <= trex.payload.upperBound, UInt32(be32(moov, p + 4)) == trackID else { continue }
                return UInt32(be32(moov, p + 20))
            }
        }
        return nil
    }

    /// Whether sample `sampleNumber` of run `trunNumber` (both from 1) in the track's traf of this
    /// moof (the whole box) is a sync sample, nil when the moof has no such sample. The flags are
    /// the run's first-sample flags for its first sample, else the sample's own, else the traf's
    /// default, else trex's; sample_is_non_sync_sample is bit 16.
    static func sampleIsSync(moof: Data, trackID: UInt32, trunNumber: Int, sampleNumber: Int,
                             defaultFlags: UInt32?) -> Bool? {
        guard trunNumber >= 1, sampleNumber >= 1,
              let header = boxHeader(moof, at: 0, available: Int64(moof.count)), header.type == "moof" else { return nil }
        for traf in children(moof, from: header.headerSize, to: moof.count) where traf.type == "traf" {
            let boxes = children(moof, from: traf.payload.lowerBound, to: traf.payload.upperBound)
            guard let tfhd = boxes.first(where: { $0.type == "tfhd" }), tfhd.payload.count >= 8,
                  UInt32(be32(moof, tfhd.payload.lowerBound + 4)) == trackID else { continue }
            let tfhdFlags = UInt32(be32(moof, tfhd.payload.lowerBound) & 0xFFFFFF)
            var trafFlags = defaultFlags
            if tfhdFlags & 0x20 != 0 {
                var at = tfhd.payload.lowerBound + 8
                if tfhdFlags & 0x01 != 0 { at += 8 }
                if tfhdFlags & 0x02 != 0 { at += 4 }
                if tfhdFlags & 0x08 != 0 { at += 4 }
                if tfhdFlags & 0x10 != 0 { at += 4 }
                guard at + 4 <= tfhd.payload.upperBound else { return nil }
                trafFlags = UInt32(be32(moof, at))
            }
            let runs = boxes.filter { $0.type == "trun" }
            guard trunNumber <= runs.count else { return nil }
            let trun = runs[trunNumber - 1]
            let p = trun.payload.lowerBound
            guard p + 8 <= trun.payload.upperBound else { return nil }
            let flags = UInt32(be32(moof, p) & 0xFFFFFF)
            let count = Int(be32(moof, p + 4))
            guard sampleNumber <= count else { return nil }
            var at = p + 8
            if flags & 0x001 != 0 { at += 4 }
            var firstFlags: UInt32?
            if flags & 0x004 != 0 {
                guard at + 4 <= trun.payload.upperBound else { return nil }
                firstFlags = UInt32(be32(moof, at))
                at += 4
            }
            var sampleFlags: UInt32?
            if sampleNumber == 1, let firstFlags {
                sampleFlags = firstFlags        // overrides the run's own first entry (8.8.8.2)
            } else if flags & 0x400 != 0 {
                var offset = 0
                if flags & 0x100 != 0 { offset += 4 }
                if flags & 0x200 != 0 { offset += 4 }
                let entry = offset + 4 + (flags & 0x800 != 0 ? 4 : 0)
                let flagsAt = at + (sampleNumber - 1) * entry + offset
                guard flagsAt + 4 <= trun.payload.upperBound else { return nil }
                sampleFlags = UInt32(be32(moof, flagsAt))
            } else {
                sampleFlags = trafFlags
            }
            guard let sampleFlags else { return nil }
            return sampleFlags & 0x0001_0000 == 0
        }
        return nil
    }

    private static func beN(_ d: Data, _ at: Int, _ n: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<n { v = v << 8 | Int64(d[d.startIndex + at + i]) }
        return v
    }

    private static func be32(_ d: Data, _ at: Int) -> Int64 {
        let i = d.startIndex + at
        return Int64(d[i]) << 24 | Int64(d[i + 1]) << 16 | Int64(d[i + 2]) << 8 | Int64(d[i + 3])
    }

    private static func be64(_ d: Data, _ at: Int) -> Int64 {
        (be32(d, at) << 32) | be32(d, at + 4)
    }
}
