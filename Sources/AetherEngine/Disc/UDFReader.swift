import Foundation

/// An entry discovered in a UDF directory.
struct UDFEntry: Equatable {
    let name: String
    let isDir: Bool
    let icbBlock: Int     // child (E)FE logical block
    let icbPartRef: Int   // child (E)FE partition reference
}

/// Read-only UDF 2.50 reader for Blu-ray BDMV. Resolves metadata partition and
/// fragmented-file allocation descriptors. Sector size 2048. Tag-id validated (not CRC).
final class UDFReader {
    /// Verbose volume-structure dump for `aetherctl disc-inspect --dump`. Off in playback.
    nonisolated(unsafe) static var diagnostics = false
    private func dbg(_ line: @autoclosure () -> String) {
        if UDFReader.diagnostics { EngineLog.emit("[udf] \(line())", category: .demux) }
    }

    private let reader: IOReader
    private let ss = 2048

    private var physPartStart: [Int: Int] = [:]        // physical partition number -> start sector
    private struct PartMap { let isMetadata: Bool; let physicalPartNumber: Int; let metadataFileBlock: Int }
    private var partMaps: [PartMap] = []               // index = partition reference number
    private var metaExtents: [(start: Int, blocks: Int)] = []  // metadata partition physical blocks
    private var fsdBlock = 0
    private var fsdPartRef = 0
    private var rootBlock = 0
    private var rootPartRef = 0

    init(reader: IOReader) throws {
        self.reader = reader
        try parseVolumeStructure()
    }

    // MARK: public API

    func list(path: [String]) throws -> [UDFEntry] {
        var (block, partRef) = (rootBlock, rootPartRef)
        for name in path {
            let entries = try readDirectory(block: block, partRef: partRef)
            guard let next = entries.first(where: { $0.isDir && $0.name == name }) else {
                throw DiscError.directoryNotFound(name)
            }
            (block, partRef) = (next.icbBlock, next.icbPartRef)
        }
        return try readDirectory(block: block, partRef: partRef)
    }

    func extents(of entry: UDFEntry) throws -> [(offset: Int64, length: Int64)] {
        let fe = try readFileEntry(block: entry.icbBlock, partRef: entry.icbPartRef)
        return try fe.allocationExtents.map { ext in
            let sector = try resolve(block: ext.block, partRef: extentPartRef(for: fe, ad: ext))
            return (offset: Int64(sector) * Int64(ss), length: Int64(ext.length))
        }
    }

    /// Partition ref for an allocation descriptor. long_ad carries its own ref.
    /// short_ad has none, so it is relative to the FE's own recording partition.
    /// For a metadata-partition FE that means metadata-virtual blocks (resolved via
    /// metaExtents, the same mapping the FE was read through): directory data and small
    /// files live inside the metadata partition. Large file data (m2ts) sits in the
    /// physical partition and is referenced with long_ad (explicit physical part ref).
    /// The Metadata File's own extents are physical, but those are read directly in
    /// parseVolumeStructure, not through this path.
    private func extentPartRef(for fe: FE, ad: AllocExt) -> Int {
        ad.longPartRef ?? fe.partRef
    }

    // MARK: descriptor IO

    private func readSector(_ s: Int) throws -> [UInt8] {
        guard reader.seek(offset: Int64(s) * Int64(ss), whence: SEEK_SET) >= 0 else {
            throw DiscError.malformed("seek \(s)")
        }
        var buf = [UInt8](repeating: 0, count: ss); var got = 0
        try buf.withUnsafeMutableBufferPointer { p in
            while got < ss {
                let n = reader.read(p.baseAddress!.advanced(by: got), size: Int32(ss - got))
                if n == 0 { break }; if n < 0 { throw DiscError.malformed("read \(s)") }
                got += Int(n)
            }
        }
        guard got == ss else { throw DiscError.malformed("short read at sector \(s)") }
        return buf
    }

    private func tagID(_ b: [UInt8]) -> Int { b.count >= 2 ? Int(b[0]) | (Int(b[1])<<8) : -1 }
    private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i+1])<<8) }
    private func u32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i+1])<<8) | (Int(b[i+2])<<16) | (Int(b[i+3])<<24) }

    // MARK: volume structure

    private func parseVolumeStructure() throws {
        // AVDP at sector 256
        let avdp = try readSector(256)
        guard tagID(avdp) == 2 else { throw DiscError.notUDF }
        let vdsLen = u32(avdp, 16), vdsLoc = u32(avdp, 20)
        let vdsSectors = max(1, vdsLen / ss)

        var lvd: [UInt8]? = nil
        for i in 0..<vdsSectors {
            let d = try readSector(vdsLoc + i)
            switch tagID(d) {
            case 5: physPartStart[u16(d, 22)] = u32(d, 188)  // Partition Descriptor
            case 6: lvd = d                                   // LVD
            case 8: break                                     // Terminating
            default: break
            }
        }
        guard let lvd else { throw DiscError.malformed("no LVD") }

        fsdBlock = u32(lvd, 252); fsdPartRef = u16(lvd, 256)  // FSD long_ad
        let nMaps = u32(lvd, 268)  // partition maps
        let capMaps = min(nMaps, 64)
        var off = 440
        for _ in 0..<capMaps {
            guard off + 2 <= lvd.count else { break }
            let type = Int(lvd[off]); let len = Int(lvd[off+1])
            guard len > 0, off + len <= lvd.count else { break }
            if type == 1 {
                let pn = u16(lvd, off+4)
                partMaps.append(PartMap(isMetadata: false, physicalPartNumber: pn, metadataFileBlock: 0))
            } else if type == 2 {
                let pn = u16(lvd, off+38)
                let metaFileBlock = u32(lvd, off+40)
                partMaps.append(PartMap(isMetadata: true, physicalPartNumber: pn, metadataFileBlock: metaFileBlock))
            } else {
                partMaps.append(PartMap(isMetadata: false, physicalPartNumber: 0, metadataFileBlock: 0))
            }
            off += len
        }
        // Metadata partition physical extents from its Metadata File (short_ad, physStart-relative).
        for pm in partMaps where pm.isMetadata {
            guard let physStart = physPartStart[pm.physicalPartNumber] else { continue }
            let metaFE = try readFileEntryRaw(sector: physStart + pm.metadataFileBlock)
            metaExtents = metaFE.allocationExtents.map { (start: physStart + $0.block, blocks: $0.length / ss) }
        }
        dbg("vds loc=\(vdsLoc) len=\(vdsLen) sectors=\(vdsSectors)")
        dbg("physPartStart=\(physPartStart)")
        dbg("partMaps=\(partMaps.map { $0.isMetadata ? "meta(phys=\($0.physicalPartNumber),fileBlk=\($0.metadataFileBlock))" : "phys(\($0.physicalPartNumber))" })")
        dbg("metaExtents=\(metaExtents)")
        dbg("fsd block=\(fsdBlock) partRef=\(fsdPartRef)")
        let fsdSector = try resolve(block: fsdBlock, partRef: fsdPartRef)  // root dir from FSD
        let fsd = try readSector(fsdSector)
        dbg("fsd resolved sector=\(fsdSector) tag=\(tagID(fsd))")
        guard tagID(fsd) == 256 else { throw DiscError.malformed("no FSD") }
        rootBlock = u32(fsd, 404); rootPartRef = u16(fsd, 408)
        dbg("root block=\(rootBlock) partRef=\(rootPartRef)")
    }

    // MARK: block resolution

    private func resolve(block: Int, partRef: Int) throws -> Int {
        guard partRef < partMaps.count else { throw DiscError.malformed("partRef \(partRef)") }
        let pm = partMaps[partRef]
        if !pm.isMetadata {
            guard let start = physPartStart[pm.physicalPartNumber] else { throw DiscError.malformed("phys part") }
            return start + block
        }
        // metadata partition: virtual block -> physical via metaExtents
        var remaining = block
        for ext in metaExtents {
            if remaining < ext.blocks { return ext.start + remaining }
            remaining -= ext.blocks
        }
        throw DiscError.malformed("metadata block \(block) out of range")
    }

    // MARK: file entry parsing

    private struct AllocExt { let block: Int; let length: Int; let longPartRef: Int? }
    private struct FE { let partRef: Int; let allocationExtents: [AllocExt] }

    private func readFileEntry(block: Int, partRef: Int) throws -> FE {
        let sector = try resolve(block: block, partRef: partRef)
        let raw = try readFileEntryRaw(sector: sector, recordingPartRef: partRef)
        return FE(partRef: partRef, allocationExtents: raw.allocationExtents)
    }

    /// Parse (E)FE at a physical sector. Tag 261 (FE) and 266 (EFE);
    /// short_ad (adType 0) and long_ad (adType 1) allocation descriptors.
    /// `recordingPartRef` is the partition the FE is recorded in; it resolves a
    /// short_ad allocation-extent continuation (extent type 3) to its sector. nil
    /// for the bootstrap Metadata File read, where the partition map is not yet
    /// resolvable and a continuation is not expected.
    private func readFileEntryRaw(sector: Int, recordingPartRef: Int? = nil) throws -> FE {
        let d = try readSector(sector)
        let tid = tagID(d)
        guard tid == 261 || tid == 266 else { throw DiscError.malformed("not a file entry @\(sector): tag \(tid)") }
        let adType = u16(d, 34) & 0x07
        let (lEAOff, lADOff, adBase): (Int, Int, Int) = tid == 266 ? (208, 212, 216) : (168, 172, 176)
        let lEA = u32(d, lEAOff)
        let lAD = u32(d, lADOff)
        var exts: [AllocExt] = []
        try parseAllocDescriptors(d, start: adBase + lEA, length: lAD, adType: adType,
                                  recordingPartRef: recordingPartRef, into: &exts)
        dbg("FE @\(sector): tag=\(tid) adType=\(adType) lEA=\(lEA) lAD=\(lAD) exts=\(exts.map { "(blk:\($0.block),len:\($0.length),ref:\($0.longPartRef.map(String.init) ?? "-"))" })")
        return FE(partRef: 0, allocationExtents: exts)
    }

    /// Parse one run of allocation descriptors. Extent type (top 2 bits of the
    /// length field) 0-2 are data extents; type 3 is a continuation pointer to an
    /// Allocation Extent Descriptor (tag 258) holding the next run -- used when a
    /// file's descriptors overflow the (E)FE. Follows the chain, bounded by depth.
    private func parseAllocDescriptors(_ buf: [UInt8], start: Int, length: Int, adType: Int,
                                       recordingPartRef: Int?, into exts: inout [AllocExt], depth: Int = 0) throws {
        let stride = adType == 1 ? 16 : 8
        var p = start
        let end = min(start + length, buf.count)
        while p + stride <= end {
            let lenField = u32(buf, p)
            let extType = (lenField >> 30) & 0x3
            let len = lenField & 0x3fffffff
            let blk = u32(buf, p + 4)
            let longRef: Int? = adType == 1 ? u16(buf, p + 8) : nil
            if extType == 3 {
                // Continuation: blk points to an AED with more descriptors. Bounded to
                // avoid a crafted self-referential chain; one sector holds the AED.
                guard depth < 16, len > 0, let pref = longRef ?? recordingPartRef,
                      let contSector = try? resolve(block: blk, partRef: pref) else { break }
                let aed = try readSector(contSector)
                guard tagID(aed) == 258 else { break }              // Allocation Extent Descriptor
                let aedLAD = u32(aed, 20)                            // LengthOfAllocationDescriptors @20 (16 tag + 4 prevLoc)
                try parseAllocDescriptors(aed, start: 24, length: aedLAD, adType: adType,
                                          recordingPartRef: recordingPartRef, into: &exts, depth: depth + 1)
                break  // type 3 is always the final descriptor of the current run
            }
            if len == 0 { break }
            exts.append(AllocExt(block: blk, length: len, longPartRef: longRef))
            p += stride
        }
    }

    // MARK: directory parsing

    private func readDirectory(block: Int, partRef: Int) throws -> [UDFEntry] {
        let fe = try readFileEntry(block: block, partRef: partRef)
        let maxDirBytes = 8 * 1024 * 1024
        var data = [UInt8]()
        for ext in fe.allocationExtents {
            let sector = try resolve(block: ext.block, partRef: extentPartRef(for: fe, ad: ext))
            var remaining = ext.length
            var s = sector
            while remaining > 0 {
                guard data.count < maxDirBytes else { throw DiscError.malformed("directory too large") }
                let chunk = try readSector(s)
                data += chunk.prefix(min(remaining, ss))
                remaining -= min(remaining, ss)
                s += 1
            }
        }
        dbg("readDirectory block=\(block) partRef=\(partRef): \(data.count) bytes, first16=\(data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
        var out: [UDFEntry] = []
        var p = 0
        while p + 38 <= data.count {
            guard tagID(Array(data[p..<min(p+16, data.count)])) == 257 else {
                dbg("  FID parse stop at off=\(p): tag=\(tagID(Array(data[p..<min(p+16, data.count)]))) (expected 257)")
                break
            }
            let chars = Int(data[p+18])
            let lfi = Int(data[p+19])
            let icbBlock = u32(data, p+20+4)     // long_ad block @ ICB+4
            let icbPartRef = u16(data, p+20+8)   // long_ad partRef @ ICB+8
            let liu = u16(data, p+36)
            let nameOff = p + 38 + liu
            let isParent = (chars & 0x08) != 0
            let isDir = (chars & 0x02) != 0
            var name = ""
            if lfi > 0, nameOff + lfi <= data.count {
                let comp = data[nameOff]  // dstring: first byte = compression id (8 or 16)
                let bytes = Array(data[(nameOff+1)..<(nameOff+lfi)])
                name = comp == 16 ? String(decoding: utf16be(bytes), as: UTF16.self) : String(decoding: bytes, as: UTF8.self)
            }
            if !isParent, lfi > 0 {
                out.append(UDFEntry(name: name, isDir: isDir, icbBlock: icbBlock, icbPartRef: icbPartRef))
            }
            var fidLen = 38 + liu + lfi
            if fidLen % 4 != 0 { fidLen += 4 - (fidLen % 4) }
            if fidLen <= 0 { break }
            p += fidLen
        }
        return out
    }

    private func utf16be(_ b: [UInt8]) -> [UInt16] {
        stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0+1]) }
    }
}
