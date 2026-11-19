import Foundation
import Testing
@testable import AetherEngine

/// Fragmented MP4, lazy index: the mfra parsing and the check that puts its times on
/// the demuxer's index axis.
private func be32(_ v: Int) -> Data { var x = UInt32(truncatingIfNeeded: v).bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
private func be64(_ v: Int64) -> Data { var x = UInt64(bitPattern: v).bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
private func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + Data(type.utf8) + payload }
private func fullBox(_ type: String, version: UInt8, _ payload: Data) -> Data { box(type, Data([version, 0, 0, 0]) + payload) }

private func trak(id: Int, handler: String, timescale: Int, version: UInt8 = 0) -> Data {
    let tkhd = version == 1
        ? fullBox("tkhd", version: 1, be64(0) + be64(0) + be32(id) + Data(count: 80))
        : fullBox("tkhd", version: 0, be32(0) + be32(0) + be32(id) + Data(count: 72))
    let mdhd = version == 1
        ? fullBox("mdhd", version: 1, be64(0) + be64(0) + be32(timescale) + be64(0) + Data(count: 4))
        : fullBox("mdhd", version: 0, be32(0) + be32(0) + be32(timescale) + be32(0) + Data(count: 4))
    let hdlr = fullBox("hdlr", version: 0, be32(0) + Data(handler.utf8) + Data(count: 13))
    return box("trak", tkhd + box("mdia", mdhd + hdlr))
}

/// A tfra with 1-byte traf/trun/sample numbers.
private func tfra(track: Int, version: UInt8, entries: [(Int64, Int64)]) -> Data {
    var body = be32(track) + be32(0) + be32(entries.count)
    for (time, moof) in entries {
        body += version == 1 ? be64(time) + be64(moof) : be32(Int(time)) + be32(Int(moof))
        body += Data([1, 1, 1])
    }
    return fullBox("tfra", version: version, body)
}

@Test func videoTrackIsFoundByHandlerWithItsTimeScale() {
    let moov = box("moov", fullBox("mvhd", version: 0, Data(count: 96))
        + trak(id: 2, handler: "soun", timescale: 44100)
        + trak(id: 1, handler: "vide", timescale: 12288, version: 1)
        + box("mvex", fullBox("trex", version: 0, Data(count: 20))))
    let tracks = FragmentedMP4RandomAccess.videoTracks(moov: moov)
    #expect(tracks.count == 1)
    #expect(tracks.first?.trackID == 1 && tracks.first?.timescale == 12288)
}

@Test func tfraEntriesParseBothVersionsPerTrack() {
    let mfra = box("mfra", tfra(track: 2, version: 0, entries: [(0, 100), (44100, 900)])
        + tfra(track: 1, version: 1, entries: [(512, 3232), (35328, 640_000), (70144, 1_300_000)])
        + fullBox("mfro", version: 0, be32(0)))
    let video = FragmentedMP4RandomAccess.tfraEntries(mfra: mfra, trackID: 1)
    #expect(video?.map(\.time) == [512, 35328, 70144])
    #expect(video?.map(\.moofOffset) == [3232, 640_000, 1_300_000])
    #expect(FragmentedMP4RandomAccess.tfraEntries(mfra: mfra, trackID: 2)?.map(\.time) == [0, 44100])
    #expect(FragmentedMP4RandomAccess.tfraEntries(mfra: mfra, trackID: 3) == nil)
}

@Test func tfraTimesGoingBackwardsAreNotTrusted() {
    let mfra = box("mfra", tfra(track: 1, version: 0, entries: [(0, 10), (300, 20), (200, 30)]))
    #expect(FragmentedMP4RandomAccess.tfraEntries(mfra: mfra, trackID: 1) == nil)
}

@Test func mfroNamesTheMfraSize() {
    #expect(FragmentedMP4RandomAccess.mfraSize(mfro: be32(16) + Data("mfro".utf8) + be32(0) + be32(3720)) == 3720)
    #expect(FragmentedMP4RandomAccess.mfraSize(mfro: be32(16) + Data("free".utf8) + be32(0) + be32(3720)) == nil)
}

/// tfra times are presentation times, the mov index decode times: the reorder delay of a B-frame
/// file (512 ticks here) is the shift, and every fragment the demuxer read must agree after it.
@Test func presentationTimesShiftOntoTheDecodeIndex() {
    let tfra: [Int64] = [512, 35328, 70144, 87552, 6_018_258]
    // The lazy open indexed the first fragment (two keyframes in it) and the last one.
    let indexed: [Int64] = [0, 17408, 6_017_746]
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: tfra, indexedKeyframes: indexed) == -512)
}

@Test func aShiftThatChangesAlongTheFileIsRejected() {
    let tfra: [Int64] = [512, 35328, 70144, 6_018_258]
    // The last fragment's keyframe is 1024 ticks off where the first fragment's delay puts it.
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: tfra, indexedKeyframes: [0, 6_018_770]) == nil)
}

/// A tfra may list only the first sync sample of each fragment: extra indexed keyframes inside a
/// fragment are fine, a listed one the demuxer did not find in a fragment it read is not.
@Test func extraKeyframesInsideAFragmentAreFineMissingOnesAreNot() {
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: [0, 1000, 2000], indexedKeyframes: [0, 500, 1000]) == 0)
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: [0, 1000, 2000], indexedKeyframes: [0, 1500]) == nil)
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: [], indexedKeyframes: [0]) == nil)
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: [0, 10], indexedKeyframes: []) == nil)
}

@Test func startsAreSecondsFromTheFirstEntry() {
    let access = FragmentedMP4RandomAccess(trackID: 1, timescale: 12288, times: [512, 12800, 25088], moofOffsets: [1, 2, 3])
    #expect(access.startsSeconds == [0, 1, 2])
}
