import Foundation

/// AE#859: lays the selected representations of an on-demand DASH presentation out as ONE fragmented
/// MP4 the mov demuxer reads like any other file, so nothing downstream (native path, software host,
/// seeks, audio switching, scrub previews) needs to know the source was DASH.
///
/// ```
/// ftyp | moov (one trak per representation track, renumbered) | sidx per representation | fragments
/// ```
///
/// The fragments are each representation's own subsegments, byte for byte, interleaved by start time.
/// A synthesized `sidx` per representation points at that representation's subsegments in the
/// interleaved order: an entry's `referenced_size` reaches to the representation's NEXT subsegment
/// (the last one to the end of the file), so the other tracks' fragments in between are inside the
/// range and every offset lands on a moof. The sidx that indexes the first fragment comes last, so its
/// `first_offset` is 0, which is what makes libavformat mark the fragment index complete and seek by
/// it. What the bytes cannot keep is each file's own track IDs and absolute offsets; the reader
/// rewrites those inside each moof as it serves it (`DASHFragmentPatcher`).
struct DASHVirtualLayout: Sendable {

    /// One source subsegment placed in the virtual file.
    struct Piece: Equatable, Sendable {
        var virtualOffset: Int64
        var source: Int
        var sourceOffset: Int64
        var size: Int64
        var startSeconds: Double
    }

    let header: [UInt8]
    let pieces: [Piece]
    let totalSize: Int64
    /// Per source: its own track_ID to the virtual file's.
    let trackIDMaps: [[UInt32: UInt32]]
    /// AE#1075: the video representation's random-access points as its sidx declares them, in seconds
    /// from the first one. Empty unless EVERY subsegment starts with a closed-GOP SAP (type 1 or 2),
    /// because one subsegment without one would put a plan boundary where no keyframe is.
    var randomAccessStartsSeconds: [Double] = []
    /// AE#1075: the longest subsegment of any other representation. Pieces are interleaved by START
    /// time, so an audio subsegment that starts just before a video one is read whole before it: audio
    /// can run this far ahead of the video in read order, and a plan segment shorter than that loses
    /// its keyframe to the next segment because the audio has already cut past it.
    var interleaveLeadSeconds: Double = 0

    /// One representation's parsed head.
    struct Source: Sendable {
        var initialization: [UInt8]
        var index: [UInt8]
        /// File offset of the first byte of `index`.
        var indexOffset: Int64
        /// ISO 639-2/T code from the manifest, written into a track that says `und`.
        var language: String?
        /// The representation is the video one, whose sidx declares the plan's random-access points.
        var isVideo = false
    }

    static func build(sources: [Source], durationSeconds: Double?) throws -> DASHVirtualLayout {
        guard !sources.isEmpty else { throw DASHSourceError.noPlayableRepresentation("nothing selected") }
        let inits = try sources.map { try MP4Init(bytes: $0.initialization) }
        let indexes = try sources.map { try SegmentIndex(bytes: $0.index, fileOffset: $0.indexOffset) }

        var maps: [[UInt32: UInt32]] = []
        var nextID: UInt32 = 1
        for initSegment in inits {
            var map: [UInt32: UInt32] = [:]
            for trak in initSegment.traks {
                map[trak.trackID] = nextID
                nextID += 1
            }
            maps.append(map)
        }

        let movieTimescale = inits[0].movieTimescale
        var traks: [UInt8] = []
        var trexes: [UInt8] = []
        for (s, initSegment) in inits.enumerated() {
            for trak in initSegment.traks {
                let newID = maps[s][trak.trackID]!
                traks += trak.rewritten(trackID: newID, fromMovieTimescale: initSegment.movieTimescale,
                                        toMovieTimescale: movieTimescale, language: sources[s].language)
                trexes += initSegment.trex[trak.trackID].map { MP4Box.rewritingUInt32($0, at: 12, to: newID) }
                    ?? MP4Box.fullBox("trex", version: 0, flags: 0,
                                      payload: MP4Box.be32(newID) + MP4Box.be32(1) + [UInt8](repeating: 0, count: 12))
            }
        }
        let fragmentDuration = UInt64(max(0, (durationSeconds ?? indexes.map(\.endSeconds).max() ?? 0)
                                          * Double(movieTimescale)).rounded())
        let mehd = MP4Box.fullBox("mehd", version: 1, flags: 0, payload: MP4Box.be64(fragmentDuration))
        let mvhd = MP4Box.rewritingUInt32(inits[0].mvhd, at: inits[0].mvhd.count - 4, to: nextID)
        let moov = MP4Box.box("moov", mvhd + MP4Box.box("mvex", mehd + trexes) + traks)
        let ftyp = inits.lazy.compactMap(\.ftyp).first
            ?? MP4Box.box("ftyp", Array("iso6".utf8) + MP4Box.be32(0) + Array("iso6dashisom".utf8))

        // Interleave every subsegment of every source by start time; ties keep source order (video first).
        var order: [(seconds: Double, source: Int, ref: Int)] = []
        for (s, index) in indexes.enumerated() {
            for (r, ref) in index.references.enumerated() {
                order.append((ref.startSeconds, s, r))
            }
        }
        order.sort { ($0.seconds, $0.source, $0.ref) < ($1.seconds, $1.source, $1.ref) }
        let firstSource = order[0].source

        for index in indexes where index.references.count > Int(UInt16.max) {
            throw DASHSourceError.tooManySubsegments(index.references.count)
        }
        let sidxSizes = indexes.map { Int64(40 + 12 * $0.references.count) }
        let sidxOrder = indexes.indices.filter { $0 != firstSource } + [firstSource]
        let fragmentsStart = Int64(ftyp.count + moov.count) + sidxSizes.reduce(0, +)

        var pieces: [Piece] = []
        pieces.reserveCapacity(order.count)
        var cursor = fragmentsStart
        var firstPiece = [Int](repeating: -1, count: indexes.count)
        var pieceOf = [[Int]](repeating: [], count: indexes.count)
        for entry in order {
            let ref = indexes[entry.source].references[entry.ref]
            if firstPiece[entry.source] < 0 { firstPiece[entry.source] = pieces.count }
            pieceOf[entry.source].append(pieces.count)
            pieces.append(.init(virtualOffset: cursor, source: entry.source, sourceOffset: ref.offset,
                                size: ref.size, startSeconds: ref.startSeconds))
            cursor += ref.size
        }
        let total = cursor

        var sidxBytes: [UInt8] = []
        var sidxEnd = Int64(ftyp.count + moov.count)
        for s in sidxOrder {
            sidxEnd += sidxSizes[s]
            let index = indexes[s]
            let own = pieceOf[s]
            // AE#883: appended piece by piece, Swift 6.2 times out type-checking this as one `+` chain.
            let referenceID: UInt32 = maps[s][index.referenceID] ?? maps[s].values.min() ?? 1
            var payload = MP4Box.be32(referenceID)
            payload += MP4Box.be32(index.timescale)
            payload += MP4Box.be64(index.earliestPresentationTime)
            payload += MP4Box.be64(UInt64(pieces[own[0]].virtualOffset - sidxEnd))
            payload += [0, 0]
            payload += MP4Box.be16(UInt16(own.count))
            for (k, p) in own.enumerated() {
                let end = k + 1 < own.count ? pieces[own[k + 1]].virtualOffset : total
                let span = end - pieces[p].virtualOffset
                guard span < 0x8000_0000 else {
                    throw DASHSourceError.malformedIndex("a subsegment span exceeds 2 GiB")
                }
                payload += MP4Box.be32(UInt32(span))
                payload += MP4Box.be32(index.references[k].duration)
                payload += MP4Box.be32(0x9000_0000)
            }
            let box = MP4Box.fullBox("sidx", version: 1, flags: 0, payload: payload)
            assert(Int64(box.count) == sidxSizes[s])
            sidxBytes += box
        }

        let video = sources.firstIndex(where: \.isVideo)
        return DASHVirtualLayout(header: ftyp + moov + sidxBytes, pieces: pieces, totalSize: total,
                                 trackIDMaps: maps,
                                 randomAccessStartsSeconds: video.map { randomAccessStarts(indexes[$0]) } ?? [],
                                 interleaveLeadSeconds: indexes.indices.filter { $0 != video }
                                    .flatMap { s in indexes[s].references.map { Double($0.duration) / Double(indexes[s].timescale) } }
                                    .max() ?? 0)
    }

    /// The SAP times of `index` relative to the first, or empty when a subsegment does not start with a
    /// SAP of type 1 or 2. Type 3 and up (open GOP, gradual refresh) leave pictures the producer cannot
    /// decode at a cut, so they do not count.
    static func randomAccessStarts(_ index: SegmentIndex) -> [Double] {
        var times: [Double] = []
        times.reserveCapacity(index.references.count)
        for ref in index.references {
            guard let sap = ref.sapSeconds else { return [] }
            if let last = times.last, sap <= last { return [] }
            times.append(sap)
        }
        guard let first = times.first else { return [] }
        return times.map { $0 - first }
    }

    /// Index of the piece holding virtual byte `offset`, nil inside the header or past the end.
    func pieceIndex(containing offset: Int64) -> Int? {
        guard offset >= Int64(header.count), offset < totalSize else { return nil }
        var lo = 0, hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pieces[mid].virtualOffset <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - Boxes

enum MP4Box {
    struct Header {
        var type: String
        var start: Int
        var headerSize: Int
        var end: Int
        var bodyStart: Int { start + headerSize }
    }

    /// The boxes directly inside `range` of `bytes`. A size that runs past the range is an error,
    /// never a truncation: the caller is about to copy these spans into another file.
    static func children(_ bytes: [UInt8], in range: Range<Int>) throws -> [Header] {
        var out: [Header] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            var size = Int(u32(bytes, p))
            var headerSize = 8
            if size == 1 {
                guard p + 16 <= range.upperBound else { throw DASHSourceError.malformedInitialization("truncated box header") }
                let large = u64(bytes, p + 8)
                guard large <= UInt64(Int.max) else { throw DASHSourceError.malformedInitialization("box too large") }
                size = Int(large)
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - p
            }
            guard size >= headerSize, p + size <= range.upperBound else {
                throw DASHSourceError.malformedInitialization("box at \(p) runs past its parent")
            }
            out.append(Header(type: fourCC(bytes, p + 4), start: p, headerSize: headerSize, end: p + size))
            p += size
        }
        return out
    }

    static func first(_ type: String, in bytes: [UInt8], range: Range<Int>) throws -> Header? {
        try children(bytes, in: range).first { $0.type == type }
    }

    static func fourCC(_ b: [UInt8], _ p: Int) -> String {
        String(decoding: b[p..<(p + 4)], as: UTF8.self)
    }

    static func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) << 8 | UInt16(b[p + 1]) }
    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
    }
    static func u64(_ b: [UInt8], _ p: Int) -> UInt64 { UInt64(u32(b, p)) << 32 | UInt64(u32(b, p + 4)) }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xFF) } }
    static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - 8 * UInt64($0))) & 0xFF) } }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    static func fullBox(_ type: String, version: UInt8, flags: UInt32, payload: [UInt8]) -> [UInt8] {
        box(type, [version] + Array(be32(flags).dropFirst()) + payload)
    }

    static func rewritingUInt32(_ bytes: [UInt8], at p: Int, to value: UInt32) -> [UInt8] {
        var copy = bytes
        copy.replaceSubrange(p..<(p + 4), with: be32(value))
        return copy
    }
}

/// The parts of a representation's initialization segment the virtual moov is built from.
struct MP4Init {
    struct Trak {
        var bytes: [UInt8]
        var trackID: UInt32

        /// The trak with its track_ID replaced, edit-list durations moved onto the virtual movie
        /// timescale (they are in the SOURCE movie's, which can differ per representation), and an
        /// undetermined media language replaced by the manifest's.
        func rewritten(trackID newID: UInt32, fromMovieTimescale from: UInt32, toMovieTimescale to: UInt32,
                       language: String?) -> [UInt8] {
            var b = bytes
            guard let children = try? MP4Box.children(b, in: 8..<b.count) else { return b }
            if let tkhd = children.first(where: { $0.type == "tkhd" }) {
                let version = b[tkhd.bodyStart]
                let idAt = tkhd.bodyStart + 4 + (version == 1 ? 16 : 8)
                if idAt + 4 <= tkhd.end { b.replaceSubrange(idAt..<(idAt + 4), with: MP4Box.be32(newID)) }
            }
            if from != to, from > 0,
               let edts = children.first(where: { $0.type == "edts" }),
               let elst = try? MP4Box.first("elst", in: b, range: edts.bodyStart..<edts.end) {
                let version = b[elst.bodyStart]
                let count = Int(MP4Box.u32(b, elst.bodyStart + 4))
                let stride = version == 1 ? 20 : 12
                var p = elst.bodyStart + 8
                for _ in 0..<count where p + stride <= elst.end {
                    if version == 1 {
                        let d = MP4Box.u64(b, p)
                        b.replaceSubrange(p..<(p + 8), with: MP4Box.be64(d.multipliedReportingOverflow(by: UInt64(to)).partialValue / UInt64(from)))
                    } else {
                        let d = UInt64(MP4Box.u32(b, p)) * UInt64(to) / UInt64(from)
                        b.replaceSubrange(p..<(p + 4), with: MP4Box.be32(UInt32(min(d, UInt64(UInt32.max)))))
                    }
                    p += stride
                }
            }
            if let packed = language.flatMap(MP4Init.packedLanguage),
               let mdia = children.first(where: { $0.type == "mdia" }),
               let mdhd = try? MP4Box.first("mdhd", in: b, range: mdia.bodyStart..<mdia.end) {
                let version = b[mdhd.bodyStart]
                let at = mdhd.bodyStart + 4 + (version == 1 ? 28 : 16)
                if at + 2 <= mdhd.end, MP4Box.u16(b, at) & 0x7FFF == MP4Init.undetermined {
                    b.replaceSubrange(at..<(at + 2), with: MP4Box.be16(packed))
                }
            }
            return b
        }
    }

    var ftyp: [UInt8]?
    var mvhd: [UInt8]
    var movieTimescale: UInt32
    var traks: [Trak]
    var trex: [UInt32: [UInt8]]

    static let encryptedSampleEntries: Set<String> = ["encv", "enca", "enct", "encs"]
    /// `und` packed as three 5-bit letters.
    static let undetermined: UInt16 = 0x55C4

    init(bytes b: [UInt8]) throws {
        let top = try MP4Box.children(b, in: 0..<b.count)
        ftyp = top.first { $0.type == "ftyp" }.map { Array(b[$0.start..<$0.end]) }
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw DASHSourceError.malformedInitialization("no moov")
        }
        let inMoov = try MP4Box.children(b, in: moov.bodyStart..<moov.end)
        if inMoov.contains(where: { $0.type == "pssh" }) {
            throw DASHSourceError.noPlayableRepresentation("a representation is encrypted (pssh)")
        }
        guard let mvhdBox = inMoov.first(where: { $0.type == "mvhd" }) else {
            throw DASHSourceError.malformedInitialization("no mvhd")
        }
        mvhd = Array(b[mvhdBox.start..<mvhdBox.end])
        let mvhdVersion = b[mvhdBox.bodyStart]
        let timescaleAt = mvhdBox.bodyStart + 4 + (mvhdVersion == 1 ? 16 : 8)
        guard timescaleAt + 4 <= mvhdBox.end, mvhd.count >= 32 else {
            throw DASHSourceError.malformedInitialization("short mvhd")
        }
        movieTimescale = MP4Box.u32(b, timescaleAt)

        traks = []
        for trakBox in inMoov where trakBox.type == "trak" {
            let inTrak = try MP4Box.children(b, in: trakBox.bodyStart..<trakBox.end)
            guard let tkhd = inTrak.first(where: { $0.type == "tkhd" }) else {
                throw DASHSourceError.malformedInitialization("trak without tkhd")
            }
            let idAt = tkhd.bodyStart + 4 + (b[tkhd.bodyStart] == 1 ? 16 : 8)
            guard idAt + 4 <= tkhd.end else { throw DASHSourceError.malformedInitialization("short tkhd") }
            if let entry = try Self.firstSampleEntry(b, trak: inTrak), Self.encryptedSampleEntries.contains(entry) {
                throw DASHSourceError.noPlayableRepresentation("a representation is encrypted (\(entry))")
            }
            traks.append(Trak(bytes: Array(b[trakBox.start..<trakBox.end]), trackID: MP4Box.u32(b, idAt)))
        }
        guard !traks.isEmpty else { throw DASHSourceError.malformedInitialization("no trak") }

        trex = [:]
        if let mvex = inMoov.first(where: { $0.type == "mvex" }) {
            for box in try MP4Box.children(b, in: mvex.bodyStart..<mvex.end) where box.type == "trex" && box.end - box.start >= 32 {
                trex[MP4Box.u32(b, box.bodyStart + 4)] = Array(b[box.start..<box.end])
            }
        }
    }

    private static func firstSampleEntry(_ b: [UInt8], trak: [MP4Box.Header]) throws -> String? {
        guard let mdia = trak.first(where: { $0.type == "mdia" }),
              let minf = try MP4Box.first("minf", in: b, range: mdia.bodyStart..<mdia.end),
              let stbl = try MP4Box.first("stbl", in: b, range: minf.bodyStart..<minf.end),
              let stsd = try MP4Box.first("stsd", in: b, range: stbl.bodyStart..<stbl.end),
              stsd.bodyStart + 16 <= stsd.end else { return nil }
        return MP4Box.fourCC(b, stsd.bodyStart + 12)
    }

    /// ISO 639-2/T, three lowercase letters, packed for mdhd. Two-letter and regional tags go
    /// through Foundation's alpha-3 mapping; anything it does not know stays unwritten.
    static func packedLanguage(_ tag: String) -> UInt16? {
        let primary = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        let code: String?
        if primary.count == 3 {
            code = primary
        } else {
            code = Locale.Language(identifier: primary).languageCode?.identifier(.alpha3)
        }
        guard let code, code.count == 3, code != "und" else { return nil }
        var packed: UInt16 = 0
        for scalar in code.unicodeScalars {
            guard scalar.value >= 0x61, scalar.value <= 0x7A else { return nil }
            packed = packed << 5 | UInt16(scalar.value - 0x60)
        }
        return packed
    }
}

/// A representation's top-level `sidx`: where each of its subsegments sits in its own file.
struct SegmentIndex {
    struct Reference {
        var offset: Int64
        var size: Int64
        var duration: UInt32
        var startSeconds: Double
        /// Presentation time of the SAP this subsegment starts with (its earliest presentation time
        /// plus `SAP_delta_time`), nil unless `starts_with_SAP` is set with SAP type 1 or 2.
        var sapSeconds: Double? = nil
    }

    var referenceID: UInt32
    var timescale: UInt32
    var earliestPresentationTime: UInt64
    var references: [Reference]
    var endSeconds: Double

    init(bytes b: [UInt8], fileOffset: Int64) throws {
        // indexRange may reach past the sidx (indexRangeExact="false"), so the box after it can be cut.
        var sidxBox: MP4Box.Header?
        var q = 0
        while sidxBox == nil, q + 8 <= b.count {
            let size = Int(MP4Box.u32(b, q))
            guard size >= 8 else { break }
            if MP4Box.fourCC(b, q + 4) == "sidx", q + size <= b.count {
                sidxBox = MP4Box.Header(type: "sidx", start: q, headerSize: 8, end: q + size)
            }
            q += size
        }
        guard let sidx = sidxBox else {
            throw DASHSourceError.malformedIndex("indexRange holds no sidx")
        }
        var p = sidx.bodyStart
        guard p + 4 <= sidx.end else { throw DASHSourceError.malformedIndex("short sidx") }
        let version = b[p]
        p += 4
        func need(_ n: Int) throws { if p + n > sidx.end { throw DASHSourceError.malformedIndex("short sidx") } }
        try need(8)
        referenceID = MP4Box.u32(b, p)
        timescale = MP4Box.u32(b, p + 4)
        p += 8
        guard timescale > 0 else { throw DASHSourceError.malformedIndex("sidx timescale 0") }
        let firstOffset: UInt64
        if version == 0 {
            try need(8)
            earliestPresentationTime = UInt64(MP4Box.u32(b, p))
            firstOffset = UInt64(MP4Box.u32(b, p + 4))
            p += 8
        } else {
            try need(16)
            earliestPresentationTime = MP4Box.u64(b, p)
            firstOffset = MP4Box.u64(b, p + 8)
            p += 16
        }
        try need(4)
        let count = Int(MP4Box.u16(b, p + 2))
        p += 4
        guard count > 0 else { throw DASHSourceError.malformedIndex("sidx has no references") }
        try need(12 * count)
        guard firstOffset < UInt64(Int64.max / 2) else { throw DASHSourceError.malformedIndex("sidx first_offset out of range") }
        // The anchor is the first byte after the sidx box, in the representation's own file.
        var offset = fileOffset + Int64(sidx.end) + Int64(firstOffset)
        var time = earliestPresentationTime
        var refs: [Reference] = []
        refs.reserveCapacity(count)
        for _ in 0..<count {
            let sizeWord = MP4Box.u32(b, p)
            if sizeWord & 0x8000_0000 != 0 {
                throw DASHSourceError.malformedIndex("hierarchical sidx (reference_type 1) is not supported")
            }
            let duration = MP4Box.u32(b, p + 4)
            let sapWord = MP4Box.u32(b, p + 8)
            let startsWithSAP = sapWord & 0x8000_0000 != 0
            let sapType = (sapWord >> 28) & 0x7
            let sapDelta = UInt64(sapWord & 0x0FFF_FFFF)
            refs.append(Reference(offset: offset, size: Int64(sizeWord), duration: duration,
                                  startSeconds: Double(time) / Double(timescale),
                                  sapSeconds: startsWithSAP && (sapType == 1 || sapType == 2)
                                    ? Double(time + sapDelta) / Double(timescale) : nil))
            offset += Int64(sizeWord)
            time += UInt64(duration)
            p += 12
        }
        references = refs
        endSeconds = Double(time) / Double(timescale)
    }
}

/// Rewrites a source moof for its place in the virtual file: track_IDs onto the virtual numbering,
/// and an explicit `base_data_offset` (an absolute offset in the SOURCE file) onto the virtual one.
/// Top-level boxes inside a subsegment that libavformat would treat as structure of the virtual file
/// (a nested `sidx` above all, whose offsets point into the source file) are retyped to `free`, which
/// keeps every byte where it was.
enum DASHFragmentPatcher {
    struct Patch: Equatable {
        var offset: Int64
        var bytes: [UInt8]
    }

    static let retypedTopLevelBoxes: Set<String> = ["styp", "sidx", "ssix", "emsg", "prft"]

    /// Patches for one `moof`, `moof` holding the whole box, offsets relative to the box start.
    static func moofPatches(_ moof: [UInt8], idMap: [UInt32: UInt32], sourceToVirtualDelta: Int64) -> [Patch] {
        var patches: [Patch] = []
        guard let boxes = try? MP4Box.children(moof, in: 8..<moof.count) else { return [] }
        for traf in boxes where traf.type == "traf" {
            guard let tfhd = try? MP4Box.first("tfhd", in: moof, range: traf.bodyStart..<traf.end),
                  tfhd.bodyStart + 8 <= tfhd.end else { continue }
            let flags = MP4Box.u32(moof, tfhd.bodyStart) & 0x00FF_FFFF
            let idAt = tfhd.bodyStart + 4
            if let newID = idMap[MP4Box.u32(moof, idAt)] {
                patches.append(Patch(offset: Int64(idAt), bytes: MP4Box.be32(newID)))
            }
            if flags & 0x01 != 0, idAt + 12 <= tfhd.end {
                let base = Int64(bitPattern: MP4Box.u64(moof, idAt + 4))
                patches.append(Patch(offset: Int64(idAt + 4),
                                     bytes: MP4Box.be64(UInt64(bitPattern: base + sourceToVirtualDelta))))
            }
        }
        return patches
    }
}
