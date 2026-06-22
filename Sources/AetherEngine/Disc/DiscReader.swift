import Foundation

/// Detects a DVD-Video ISO and adapts it to the engine's normal demux path.
/// Given a raw ISO `IOReader`, returns a synthetic `IOReader` over the main
/// title's concatenated VOBs plus the demuxer format hint, or nil when the
/// source is not a playable DVD ISO (so the caller falls back to plain demux).
/// No decryption: encrypted retail ISOs parse but their streams will not
/// decode; that surfaces downstream as a normal demux/decode failure.
enum DiscReader {
    /// Cheap content sniff: the ISO9660 "CD001" signature at byte 0x8001.
    static func looksLikeISO9660(_ reader: IOReader) -> Bool {
        guard reader.seek(offset: 0x8001, whence: SEEK_SET) >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 5)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        return n == 5 && buf == Array("CD001".utf8)
    }

    /// Cheap UDF sniff: the Anchor Volume Descriptor Pointer (tag id 2) at
    /// logical sector 256 (offset 256 * 2048).
    static func looksLikeUDF(_ reader: IOReader) -> Bool {
        guard reader.seek(offset: 256 * 2048, whence: SEEK_SET) >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 2)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 2) }
        return n == 2 && (Int(buf[0]) | (Int(buf[1]) << 8)) == 2
    }

    /// Blu-ray: UDF filesystem with a BDMV directory. Returns (concatReader, "mpegts").
    static func wrapBluRay(_ reader: IOReader) throws -> (IOReader, String)? {
        guard looksLikeUDF(reader) else { return nil }
        let udf: UDFReader
        do { udf = try UDFReader(reader: reader) } catch DiscError.notUDF { return nil }
        let root = (try? udf.list(path: [])) ?? []
        guard root.contains(where: { $0.isDir && $0.name == "BDMV" }) else { return nil }
        let playlistDir = (try? udf.list(path: ["BDMV", "PLAYLIST"])) ?? []
        var parsed: [MPLSPlaylist] = []
        for e in playlistDir where e.name.hasSuffix(".mpls") {
            let exts = (try? udf.extents(of: e)) ?? []
            guard !exts.isEmpty else { continue }
            let bytes = readAll(reader, exts)
            if let pl = MPLSParser.parse(bytes) { parsed.append(pl) }
        }
        guard let title = BDTitleSelector.selectMainTitle(parsed) else { return nil }
        let streamDir = (try? udf.list(path: ["BDMV", "STREAM"])) ?? []
        var allExtents: [(offset: Int64, length: Int64)] = []
        for clip in title.clipIDs {
            guard let e = streamDir.first(where: { $0.name == "\(clip).m2ts" }),
                  let exts = try? udf.extents(of: e) else { continue }
            allExtents += exts
        }
        guard !allExtents.isEmpty else { return nil }
        return (ConcatIOReader(base: reader, extents: allExtents), "mpegts")
    }

    /// Read all bytes of an extent list into memory (small files only: mpls).
    private static func readAll(_ base: IOReader, _ exts: [(offset: Int64, length: Int64)]) -> [UInt8] {
        // Extent lengths are untrusted on-disc bytes (up to ~1 GB each). Cap the total before
        // allocating so a crafted .mpls cannot drive an arbitrary allocation (jetsam/DoS); 8 MB
        // matches UDFReader.readDirectory's guard and dwarfs any real playlist (KB-scale).
        let maxBytes: Int64 = 8 * 1024 * 1024
        let declared = exts.reduce(Int64(0)) { $0 + max(0, $1.length) }
        guard declared > 0, declared <= maxBytes else { return [] }
        let total = Int(declared)
        let r = ConcatIOReader(base: base, extents: exts)
        var out = [UInt8](repeating: 0, count: total); var got = 0
        out.withUnsafeMutableBufferPointer { p in
            while got < total {
                let n = r.read(p.baseAddress!.advanced(by: got), size: Int32(min(Int64(total - got), Int64(Int32.max))))
                if n <= 0 { break }; got += Int(n)
            }
        }
        if got < total { out.removeLast(total - got) }
        return out
    }

    /// Returns `(syntheticReader, formatHint)` for a DVD or Blu-ray ISO, else nil.
    static func wrap(_ reader: IOReader) throws -> (IOReader, String)? {
        guard looksLikeISO9660(reader) else { return try wrapBluRay(reader) }
        let iso: ISO9660Reader
        do {
            iso = try ISO9660Reader(reader: reader)
        } catch DiscError.notISO9660 {
            return try wrapBluRay(reader)
        }
        let files: [DiscFile]
        do {
            files = try iso.list(directory: "VIDEO_TS")
        } catch DiscError.directoryNotFound {
            return try wrapBluRay(reader)  // ISO9660 but not a DVD-Video disc (Blu-ray / data disc)
        }
        let titleVOBs = DVDTitleSelector.selectMainTitleVOBs(files)
        guard !titleVOBs.isEmpty else { return try wrapBluRay(reader) }
        let extents = titleVOBs.map {
            (offset: Int64($0.startSector * iso.sectorSize), length: Int64($0.length))
        }
        return (ConcatIOReader(base: reader, extents: extents), "mpeg")
    }
}
