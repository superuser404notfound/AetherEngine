import Foundation

/// An entry discovered in a UDF directory.
struct UDFEntry: Equatable {
    let name: String
    let isDir: Bool
    let icbBlock: Int     // child (E)FE logical block
    let icbPartRef: Int   // child (E)FE partition reference
}

/// Read-only UDF 2.50 reader for Blu-ray BDMV discs. Resolves the metadata
/// partition (UDF 2.50) and fragmented-file allocation descriptors. Sector size
/// 2048. Validates descriptor tag identifiers (not CRC). No external libs.
final class UDFReader {
    private let reader: IOReader
    private let ss = 2048

    // Physical partition: ref-index -> (physicalStartSector). For a metadata
    // partition ref, we instead resolve through `metaMap`.
    private var physPartStart: [Int: Int] = [:]        // physical partition number -> start sector
    private struct PartMap { let isMetadata: Bool; let physicalPartNumber: Int; let metadataFileBlock: Int }
    private var partMaps: [PartMap] = []               // index = partition reference number
    private var metaExtents: [(start: Int, blocks: Int)] = []  // metadata partition -> physical blocks (per phys partition start)
    private var fsdBlock = 0
    private var fsdPartRef = 0
    private var rootBlock = 0
    private var rootPartRef = 0

    init(reader: IOReader) throws {
        self.reader = reader
        try parseVolumeStructure()
    }

    // MARK: public API

    /// List the entries of a directory given by path (e.g. ["BDMV","PLAYLIST"]).
    /// Empty path = root directory.
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

    /// Resolve a file entry's data extents to absolute byte offsets in the ISO.
    func extents(of entry: UDFEntry) throws -> [(offset: Int64, length: Int64)] {
        let fe = try readFileEntry(block: entry.icbBlock, partRef: entry.icbPartRef)
        return try fe.allocationExtents.map { ext in
            let sector = try resolve(block: ext.block, partRef: extentPartRef(for: fe, ad: ext))
            return (offset: Int64(sector) * Int64(ss), length: Int64(ext.length))
        }
    }

    /// Partition reference used to resolve a single allocation descriptor.
    /// long_ad carries its own partition reference. short_ad blocks are relative
    /// to the FE's own partition, EXCEPT for metadata-resident FEs whose short_ad
    /// blocks are physical-partition relative (mirrors the Metadata File's own
    /// extents). For those, resolve against the underlying physical partition ref.
    private func extentPartRef(for fe: FE, ad: AllocExt) -> Int {
        if let ref = ad.longPartRef { return ref }
        // short_ad: FE's own partition, unless that partition is metadata.
        if fe.partRef < partMaps.count, partMaps[fe.partRef].isMetadata {
            return physicalPartRef(forMetadataRef: fe.partRef)
        }
        return fe.partRef
    }

    /// Find a Type-1 partition reference index that points at the physical
    /// partition backing the given metadata partition reference.
    private func physicalPartRef(forMetadataRef metaRef: Int) -> Int {
        let physNum = partMaps[metaRef].physicalPartNumber
        for (i, pm) in partMaps.enumerated() where !pm.isMetadata && pm.physicalPartNumber == physNum {
            return i
        }
        return 0
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
            case 5: // Partition Descriptor
                let pn = u16(d, 22), start = u32(d, 188)
                physPartStart[pn] = start
            case 6: // LVD
                lvd = d
            case 8: // Terminating
                break
            default: break
            }
        }
        guard let lvd else { throw DiscError.malformed("no LVD") }

        // FSD long_ad
        fsdBlock = u32(lvd, 252); fsdPartRef = u16(lvd, 256)
        // partition maps
        let nMaps = u32(lvd, 268)
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
        // Resolve the metadata partition's physical extents from its Metadata File.
        for pm in partMaps where pm.isMetadata {
            guard let physStart = physPartStart[pm.physicalPartNumber] else { continue }
            let metaFE = try readFileEntryRaw(sector: physStart + pm.metadataFileBlock)
            // metadata file extents are short_ad, partition-relative to physStart
            metaExtents = metaFE.allocationExtents.map { (start: physStart + $0.block, blocks: $0.length / ss) }
        }
        // root dir from FSD
        let fsdSector = try resolve(block: fsdBlock, partRef: fsdPartRef)
        let fsd = try readSector(fsdSector)
        guard tagID(fsd) == 256 else { throw DiscError.malformed("no FSD") }
        rootBlock = u32(fsd, 404); rootPartRef = u16(fsd, 408)
    }

    // MARK: block resolution

    /// Resolve a (block, partitionReference) to an absolute physical sector.
    private func resolve(block: Int, partRef: Int) throws -> Int {
        guard partRef < partMaps.count else { throw DiscError.malformed("partRef \(partRef)") }
        let pm = partMaps[partRef]
        if !pm.isMetadata {
            guard let start = physPartStart[pm.physicalPartNumber] else { throw DiscError.malformed("phys part") }
            return start + block
        }
        // metadata partition: map virtual block -> physical via metaExtents
        var remaining = block
        for ext in metaExtents {
            if remaining < ext.blocks { return ext.start + remaining }
            remaining -= ext.blocks
        }
        throw DiscError.malformed("metadata block \(block) out of range")
    }

    // MARK: file entry parsing

    private struct AllocExt { let block: Int; let length: Int; let longPartRef: Int? }
    private struct FE { let fileType: Int; let isDir: Bool; let partRef: Int; let allocationExtents: [AllocExt] }

    private func readFileEntry(block: Int, partRef: Int) throws -> FE {
        let sector = try resolve(block: block, partRef: partRef)
        let raw = try readFileEntryRaw(sector: sector)
        return FE(fileType: raw.fileType, isDir: raw.isDir, partRef: partRef, allocationExtents: raw.allocationExtents)
    }

    /// Parse an (E)FE at a physical sector. Supports tag 261 (FE) and 266 (EFE),
    /// short_ad (adType 0) and long_ad (adType 1) allocation descriptors.
    private func readFileEntryRaw(sector: Int) throws -> FE {
        let d = try readSector(sector)
        let tid = tagID(d)
        guard tid == 261 || tid == 266 else { throw DiscError.malformed("not a file entry @\(sector): tag \(tid)") }
        let fileType = Int(d[27])
        let isDir = fileType == 4
        let adType = u16(d, 34) & 0x07
        let (lEAOff, lADOff, adBase): (Int, Int, Int) = tid == 266 ? (208, 212, 216) : (168, 172, 176)
        let lEA = u32(d, lEAOff)
        let lAD = u32(d, lADOff)
        let start = adBase + lEA
        var exts: [AllocExt] = []
        var p = start
        let end = start + lAD
        let stride = adType == 1 ? 16 : 8
        while p + stride <= min(end, d.count) {
            let lenField = u32(d, p)
            let len = lenField & 0x3fffffff
            let blk = u32(d, p + 4)
            if len == 0 { break }
            let longRef: Int? = adType == 1 ? u16(d, p + 8) : nil
            exts.append(AllocExt(block: blk, length: len, longPartRef: longRef))
            p += stride
        }
        return FE(fileType: fileType, isDir: isDir, partRef: 0, allocationExtents: exts)
    }

    // MARK: directory parsing

    private func readDirectory(block: Int, partRef: Int) throws -> [UDFEntry] {
        let fe = try readFileEntry(block: block, partRef: partRef)
        // Read all the directory's data bytes via its extents.
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
        // Walk FIDs.
        var out: [UDFEntry] = []
        var p = 0
        while p + 38 <= data.count {
            guard tagID(Array(data[p..<min(p+16, data.count)])) == 257 else { break }
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
                // dstring: first byte compression id (8 or 16)
                let comp = data[nameOff]
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
