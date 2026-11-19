import Foundation
import Testing
@testable import AetherEngine

/// The fragment header fetch's view of a fragmented MP4: whether the head is one, which `moof`
/// offsets its `mfra` lists, and how much of a fetched range a `moof` still needs.
private func be32(_ v: Int) -> Data { var x = UInt32(truncatingIfNeeded: v).bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
private func be64(_ v: Int64) -> Data { var x = UInt64(bitPattern: v).bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
private func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + Data(type.utf8) + payload }

/// An mfra (with its mfro) listing `moofs` for track 1 (version 1 entries, 1-byte numbers).
private func mfra(_ moofs: [Int64], track2: [Int64] = []) -> Data {
    func tfra(_ track: Int, _ offsets: [Int64]) -> Data {
        var body = Data([1, 0, 0, 0]) + be32(track) + be32(0) + be32(offsets.count)
        for (i, offset) in offsets.enumerated() { body += be64(Int64(i) * 1000) + be64(offset) + Data([1, 1, 1]) }
        return box("tfra", body)
    }
    let inner = tfra(1, moofs) + (track2.isEmpty ? Data() : tfra(2, track2))
    let total = inner.count + 8 + 16
    return be32(total) + Data("mfra".utf8) + inner + be32(16) + Data("mfro".utf8) + be32(0) + be32(total)
}

@Test func aFragmentedHeadIsAnFtypWithAnMvex() {
    let head = box("ftyp", Data("isom0000".utf8)) + box("moov", box("mvex", Data(count: 8)))
    #expect(AVIOReader.headIsFragmentedMP4(head))
    #expect(!AVIOReader.headIsFragmentedMP4(box("ftyp", Data("isom0000".utf8)) + box("moov", Data(count: 64))))
    #expect(!AVIOReader.headIsFragmentedMP4(Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(count: 60)))   // Matroska
}

@Test func theMfraListsEveryTracksMoofsInOrder() {
    let index = mfra([5_000, 1_000, 9_000], track2: [1_000, 7_000])
    let fileSize: Int64 = 20_000
    let tail = ResidentSpan(start: fileSize - Int64(index.count), data: index)
    #expect(AVIOReader.fragmentOffsets(tail: tail, prefix: Data(), fileSize: fileSize)
        == .offsets([1_000, 5_000, 7_000, 9_000], end: fileSize - Int64(index.count)))
}

@Test func anMfraLargerThanTheTailAsksForTheBytesInFront() {
    let index = mfra([1_000, 2_000, 3_000])
    let fileSize: Int64 = 50_000
    let tail = ResidentSpan(start: fileSize - 20, data: index.suffix(20))
    let start = fileSize - Int64(index.count)
    #expect(AVIOReader.fragmentOffsets(tail: tail, prefix: Data(), fileSize: fileSize) == .missing(start..<(fileSize - 20)))
    #expect(AVIOReader.fragmentOffsets(tail: tail, prefix: Data(index.prefix(index.count - 20)), fileSize: fileSize)
        == .offsets([1_000, 2_000, 3_000], end: start))
}

@Test func aTailWithoutAnMfroListsNothing() {
    let tail = ResidentSpan(start: 900, data: Data(count: 100))
    #expect(AVIOReader.fragmentOffsets(tail: tail, prefix: Data(), fileSize: 1_000) == .none)
}

/// A fetched range must hold its whole moof and the bytes the walk reads behind it: 16 for the
/// mdat header, or 8 KB more for the lazy walk's probe read.
@Test func aMoofLongerThanItsRangeAsksForTheRest() {
    let moof = box("moof", Data(count: 3_000))                    // 3,008 bytes
    let block = Data(count: 256) + moof.prefix(2_000)              // lead, then part of the moof
    #expect(AVIOReader.fragmentHeaderShortfall(block, ceiling: 1 << 20) == 256 + 3_008 + 16 - block.count)
    #expect(AVIOReader.fragmentHeaderShortfall(block, ceiling: 1 << 20, trailing: 8_192 + 16)
        == 256 + 3_008 + 8_208 - block.count)
    let whole = Data(count: 256) + moof + Data(count: 16)
    #expect(AVIOReader.fragmentHeaderShortfall(whole, ceiling: 1 << 20) == nil)
    #expect(AVIOReader.fragmentHeaderShortfall(block, ceiling: 2_500) == 2_500 - block.count)   // capped at the next range
}

/// What the share keeps of a fetched range: the moof and the 16 bytes behind it, nothing of the
/// lead in front or the estimate past it.
@Test func theShareKeepsOnlyTheMoofAndTheHeaderBehindIt() {
    let moof = box("moof", Data(count: 1_000))
    let block = Data(count: 256) + moof + Data(count: 4_000)
    #expect(AVIOReader.fragmentHeaderCore(block) == 256..<(256 + moof.count + 16))
    #expect(AVIOReader.fragmentHeaderCore(Data(count: 256) + moof.prefix(500)) == nil)   // cut short
    #expect(AVIOReader.fragmentHeaderCore(Data(count: 4_096)) == nil)
}

/// The share holds one source, and a retention timer only ever releases the source it was set for.
@Test func theShareIsReleasedByItsOwnRetentionTimerOnly() {
    let share = FragmentHeaderShare()
    share.publish(key: "a", start: 100, block: Data(count: 64))
    let first = share.currentGeneration
    #expect(share.heldBytes == 64)
    share.publish(key: "b", start: 100, block: Data(count: 32))
    #expect(share.heldBytes == 32)
    share.drop(generation: first)            // the first source's timer fires late
    #expect(share.heldBytes == 32)
    share.drop(generation: share.currentGeneration)
    #expect(share.heldBytes == 0)
}
