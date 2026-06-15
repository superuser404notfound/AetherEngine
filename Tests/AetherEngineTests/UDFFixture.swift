import Foundation
@testable import AetherEngine

/// Minimal UDF 2.50 image builder for tests. Sector size 2048. Exercises a
/// metadata partition and a fragmented file. Builder offsets mirror UDFReader.
enum UDFFixture {
    static let ss = 2048

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v>>8)&0xff)] }
    static func le32(_ v: Int) -> [UInt8] { [UInt8(v&0xff),UInt8((v>>8)&0xff),UInt8((v>>16)&0xff),UInt8((v>>24)&0xff)] }
    static func le64(_ v: Int) -> [UInt8] { le32(v & 0xffffffff) + le32(v >> 32) }

    /// Write a 16-byte descriptor tag at the front of `body` (which already has
    /// 16 zero bytes reserved at [0..16]); fills id, version, location, checksum.
    static func tag(_ id: Int, location: Int, into body: inout [UInt8]) {
        body[0..<2]  = ArraySlice(le16(id))
        body[2..<4]  = ArraySlice(le16(0x0200))     // descriptor version 2
        body[12..<16] = ArraySlice(le32(location))  // TagLocation
        // CRC length 0 (reader ignores CRC); checksum over bytes 0-3 and 5-15.
        var sum = 0
        for i in 0..<16 where i != 4 { sum = (sum + Int(body[i])) & 0xff }
        body[4] = UInt8(sum)
    }

    /// extent_ad: length(bytes), location(sector).
    static func extentAD(lenBytes: Int, location: Int) -> [UInt8] { le32(lenBytes) + le32(location) }
    /// long_ad: lenBytes, block, partitionRef.
    static func longAD(lenBytes: Int, block: Int, partRef: Int) -> [UInt8] {
        le32(lenBytes) + le32(block) + le16(partRef) + [UInt8](repeating:0,count:6)
    }
    /// short_ad: lenBytes, block.
    static func shortAD(lenBytes: Int, block: Int) -> [UInt8] { le32(lenBytes) + le32(block) }

    /// An Extended File Entry (tag 266). `fileType` 4=dir 5=file. `adType` 0=short_ad.
    /// `ads` is the concatenated allocation-descriptor bytes. `infoLen` is the file's
    /// data length in bytes.
    static func efe(location: Int, fileType: Int, partRefOfSelf: Int, adType: Int, infoLen: Int, ads: [UInt8]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 216 + ads.count)
        tag(266, location: location, into: &b)
        // ICBTag @16: FileType @ 16+11=27, Flags @ 16+18=34
        b[27] = UInt8(fileType)
        b[34..<36] = ArraySlice(le16(adType))
        b[56..<64] = ArraySlice(le64(infoLen))         // InformationLength
        b[208..<212] = ArraySlice(le32(0))             // L_EA
        b[212..<216] = ArraySlice(le32(ads.count))     // L_AD
        for (i, v) in ads.enumerated() { b[216 + i] = v }
        return b
    }

    /// A File Identifier Descriptor (tag 257). Returns padded-to-4 bytes.
    static func fid(location: Int, name: String, isDir: Bool, childBlock: Int, childPartRef: Int) -> [UInt8] {
        let nameBytes: [UInt8] = name.isEmpty ? [] : ([0x08] + Array(name.utf8)) // 8-bit dstring
        let lfi = nameBytes.count
        var b = [UInt8](repeating: 0, count: 38 + lfi)
        tag(257, location: location, into: &b)
        b[18] = isDir ? 0x02 : 0x00                    // FileCharacteristics
        b[19] = UInt8(lfi)                             // L_FI
        b[20..<36] = ArraySlice(longAD(lenBytes: ss, block: childBlock, partRef: childPartRef)) // ICB
        b[36..<38] = ArraySlice(le16(0))               // L_IU
        for (i, v) in nameBytes.enumerated() { b[38 + i] = v }
        while b.count % 4 != 0 { b.append(0) }         // pad to 4
        return b
    }

    /// Build the complete BD image. Returns (bytes). Files placed:
    /// metadata vblock layout: 1=FSD, 2=rootDirEFE, 3=rootDirData,
    /// 4=BDMV EFE, 5=BDMV data, 6=PLAYLIST EFE, 7=PLAYLIST data,
    /// 8=STREAM EFE, 9=STREAM data, 10=mpls EFE, 11=mpls data,
    /// 12=m2ts EFE. m2ts data is two physical extents (fragmented), placed in
    /// the physical partition AFTER the metadata region.
    static func make(mplsBytes: [UInt8], m2tsBytes: [UInt8]) -> Data {
        let partStart = 270
        // metadata partition extent = physical blocks 2.. of partition 0.
        // virtual block V -> physical sector partStart + 2 + V.
        func phys(_ vblock: Int) -> Int { partStart + 2 + vblock }

        // --- helpers to place a sector ---
        var image = [UInt8](repeating: 0, count: (partStart + 64) * ss)
        func put(_ bytes: [UInt8], atSector s: Int) {
            precondition((s+1)*ss <= image.count || bytes.count <= ss)
            for (i, v) in bytes.enumerated() where i < ss { image[s*ss + i] = v }
        }
        // metadata-partition descriptors are addressed by VIRTUAL block but the
        // tag's TagLocation must be the virtual block number (UDF: tags inside
        // the metadata partition record their metadata-partition block).
        func putV(_ bytes: [UInt8], vblock: Int) { put(bytes, atSector: phys(vblock)) }

        // m2ts fragmented data: two extents in the physical partition, after the
        // metadata region. Pick physical blocks well past the metadata vblocks.
        let frag1Block = 40, frag2Block = 50   // partition-relative blocks
        let half = m2tsBytes.count / 2
        let m2tsExt1 = Array(m2tsBytes[0..<half])
        let m2tsExt2 = Array(m2tsBytes[half...])
        put(padTo(m2tsExt1, ss * 4), atSector: partStart + frag1Block)
        put(padTo(m2tsExt2, ss * 4), atSector: partStart + frag2Block)

        // mpls data (virtual block 11)
        putV(padTo(mplsBytes, ss), vblock: 11)

        // --- EFEs (all in the metadata partition, adType short_ad=0) ---
        // m2ts EFE (vblock 12): two short_ad extents (fragmented), partition-relative blocks
        let m2tsADs = shortAD(lenBytes: m2tsExt1.count, block: frag1Block)
                    + shortAD(lenBytes: m2tsExt2.count, block: frag2Block)
        putV(efe(location: 12, fileType: 5, partRefOfSelf: 0, adType: 0, infoLen: m2tsBytes.count, ads: m2tsADs), vblock: 12)
        // mpls EFE (vblock 10): one extent -> the mpls is in the METADATA partition,
        // so use a long_ad into partition ref 1 (metadata), block 11. adType long_ad=1.
        putV(efe(location: 10, fileType: 5, partRefOfSelf: 1, adType: 1, infoLen: mplsBytes.count,
                 ads: longAD(lenBytes: mplsBytes.count, block: 11, partRef: 1)), vblock: 10)

        // STREAM dir data (vblock 9): FID "00001.m2ts" -> m2ts EFE (vblock 12, partRef 1) + parent
        let streamData = fid(location: 9, name: "", isDir: true, childBlock: 4, childPartRef: 1) // parent placeholder
                       + fid(location: 9, name: "00001.m2ts", isDir: false, childBlock: 12, childPartRef: 1)
        putV(padTo(streamData, ss), vblock: 9)
        putV(efe(location: 8, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: streamData.count,
                 ads: longAD(lenBytes: ss, block: 9, partRef: 1)), vblock: 8)

        // PLAYLIST dir data (vblock 7): FID "00000.mpls" -> mpls EFE (vblock 10)
        let plData = fid(location: 7, name: "", isDir: true, childBlock: 4, childPartRef: 1)
                   + fid(location: 7, name: "00000.mpls", isDir: false, childBlock: 10, childPartRef: 1)
        putV(padTo(plData, ss), vblock: 7)
        putV(efe(location: 6, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: plData.count,
                 ads: longAD(lenBytes: ss, block: 7, partRef: 1)), vblock: 6)

        // BDMV dir data (vblock 5): FIDs PLAYLIST (vblock 6) and STREAM (vblock 8)
        let bdmvData = fid(location: 5, name: "", isDir: true, childBlock: 2, childPartRef: 1)
                     + fid(location: 5, name: "PLAYLIST", isDir: true, childBlock: 6, childPartRef: 1)
                     + fid(location: 5, name: "STREAM", isDir: true, childBlock: 8, childPartRef: 1)
        putV(padTo(bdmvData, ss), vblock: 5)
        putV(efe(location: 4, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: bdmvData.count,
                 ads: longAD(lenBytes: ss, block: 5, partRef: 1)), vblock: 4)

        // root dir data (vblock 3): FID BDMV (vblock 4)
        let rootData = fid(location: 3, name: "", isDir: true, childBlock: 2, childPartRef: 1)
                     + fid(location: 3, name: "BDMV", isDir: true, childBlock: 4, childPartRef: 1)
        putV(padTo(rootData, ss), vblock: 3)
        putV(efe(location: 2, fileType: 4, partRefOfSelf: 1, adType: 1, infoLen: rootData.count,
                 ads: longAD(lenBytes: ss, block: 3, partRef: 1)), vblock: 2)

        // FSD (vblock 1): RootDirectoryICB -> root dir EFE (vblock 2, partRef 1)
        var fsd = [UInt8](repeating: 0, count: ss)
        tag(256, location: 1, into: &fsd)
        fsd[400..<416] = ArraySlice(longAD(lenBytes: ss, block: 2, partRef: 1))
        putV(fsd, vblock: 1)

        // --- Metadata File (E)FE at physical block 0 of partition 0 (sector partStart) ---
        // one extent: metadata partition = physical blocks 2.. (short_ad, partition-relative)
        let metaExtentBlocks = 32
        let metaFile = efe(location: 0, fileType: 5, partRefOfSelf: 0, adType: 0,
                           infoLen: metaExtentBlocks * ss,
                           ads: shortAD(lenBytes: metaExtentBlocks * ss, block: 2))
        put(metaFile, atSector: partStart + 0)

        // --- LVD (sector 258) ---
        var lvd = [UInt8](repeating: 0, count: ss)
        tag(6, location: 258, into: &lvd)
        lvd[212..<216] = ArraySlice(le32(ss))                 // LogicalBlockSize
        lvd[248..<264] = ArraySlice(longAD(lenBytes: ss, block: 1, partRef: 1)) // FSD long_ad (metadata part)
        // partition maps
        var maps = [UInt8]()
        // index 0: Type 1 -> partition number 0
        maps += [1, 6] + le16(0) + le16(0)
        // index 1: Type 2 metadata, 64 bytes
        var t2 = [UInt8](repeating: 0, count: 64)
        t2[0] = 2; t2[1] = 64
        // PartitionTypeIdentifier regid (offset 4) "*UDF Metadata Partition"
        let mid = Array("*UDF Metadata Partition".utf8)
        for (i,v) in mid.enumerated() where i < 23 { t2[5 + i] = v } // [4]=flags,[5..] id
        t2[36..<38] = ArraySlice(le16(0))                     // VolumeSequenceNumber
        t2[38..<40] = ArraySlice(le16(0))                     // PartitionNumber (physical part 0)
        t2[40..<44] = ArraySlice(le32(0))                     // MetadataFileLocation = block 0 of part 0
        maps += t2
        lvd[264..<268] = ArraySlice(le32(maps.count))         // MapTableLength
        lvd[268..<272] = ArraySlice(le32(2))                  // NumberofPartitionMaps
        for (i,v) in maps.enumerated() { lvd[440 + i] = v }
        put(lvd, atSector: 258)

        // --- Partition Descriptor (sector 257) ---
        var pd = [UInt8](repeating: 0, count: ss)
        tag(5, location: 257, into: &pd)
        pd[22..<24] = ArraySlice(le16(0))                     // PartitionNumber 0
        pd[188..<192] = ArraySlice(le32(partStart))           // PartitionStartingLocation
        pd[192..<196] = ArraySlice(le32(128))                 // PartitionLength (sectors, ample)
        put(pd, atSector: 257)

        // --- AVDP (sector 256) -> VDS at sector 257, length 2 sectors ---
        var avdp = [UInt8](repeating: 0, count: ss)
        tag(2, location: 256, into: &avdp)
        avdp[16..<24] = ArraySlice(extentAD(lenBytes: 2*ss, location: 257)) // MainVDS extent
        put(avdp, atSector: 256)

        return Data(image)
    }

    static func padTo(_ b: [UInt8], _ n: Int) -> [UInt8] {
        b.count >= n ? b : b + [UInt8](repeating: 0, count: n - b.count)
    }
}
