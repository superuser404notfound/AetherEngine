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

/// An mfra that stops short of the file: the demuxer read the last fragment for the durations and
/// found a keyframe the last tfra entry's fragment cannot hold, so the two are not trusted.
@Test func anMfraThatStopsShortOfTheLastFragmentIsRejected() {
    #expect(FragmentedMP4RandomAccess.shiftOntoIndex(times: [0, 1000], indexedKeyframes: [0, 500, 5000]) == nil)
}

@Test func startsAreSecondsFromTheFirstEntry() {
    let access = FragmentedMP4RandomAccess(trackID: 1, timescale: 12288, times: [512, 12800, 25088], moofOffsets: [1, 2, 3])
    #expect(access.startsSeconds == [0, 1, 2])
}

// MARK: - The probe through AVIO

/// A byte source that remembers where it was asked to seek.
private final class SeekRecordingReader: IOReader, @unchecked Sendable {
    private let inner: DataIOReader
    private let lock = NSLock()
    private var recorded: [Int64] = []
    init(_ data: Data) { inner = DataIOReader(data: data) }
    var seeks: [Int64] { lock.lock(); defer { lock.unlock() }; return recorded }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { inner.read(buffer, size: size) }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == SEEK_SET { lock.lock(); recorded.append(offset); lock.unlock() }
        return inner.seek(offset: offset, whence: whence)
    }
    func close() { inner.close() }
    func cancel() {}
    func makeIndependentReader() -> IOReader? { nil }
    var discImageProbeEnabled: Bool { false }
}

private func probe(_ file: Data) throws -> (FragmentedMP4RandomAccess.Probe, [Int64]) {
    let reader = SeekRecordingReader(file)
    let bridge = CustomIOReaderBridge(reader: reader)
    try bridge.open()
    defer { bridge.close() }
    let pb = try #require(bridge.context)
    return (FragmentedMP4RandomAccess.probe(pb), reader.seeks)
}

private let ftyp = box("ftyp", Data("isom0000isom".utf8))
private func fragmentedMoov() -> Data {
    box("moov", fullBox("mvhd", version: 0, Data(count: 96)) + trak(id: 1, handler: "vide", timescale: 12288)
        + box("mvex", fullBox("trex", version: 0, Data(count: 20))))
}

/// Two fragments whose tfra entries point at their moofs; `secondStarts` is the flags of the
/// second fragment's first sample.
private func fragmentedFile(secondStarts: UInt32) -> Data {
    let first = moof(track: 1, perSample: [sync, nonSync]) + box("mdat", Data(count: 4_000))
    let second = moof(track: 1, perSample: [secondStarts, nonSync]) + box("mdat", Data(count: 4_000))
    let head = ftyp + fragmentedMoov()
    let index = tfra(track: 1, version: 1, entries: [(512, Int64(head.count)), (12_800, Int64(head.count + first.count))])
    let mfraBody = index + fullBox("mfro", version: 0, be32(index.count + 8 + 16))
    return head + first + second + box("mfra", mfraBody)
}

@Test func theProbeReadsAFragmentedFilesMfra() throws {
    let (result, _) = try probe(fragmentedFile(secondStarts: sync))
    guard case .usable(let access) = result else { Issue.record("expected usable, got \(result)"); return }
    #expect(access.trackID == 1 && access.timescale == 12288 && access.times == [512, 12_800])
}

/// ffmpeg's mfra for -frag_duration without frag_keyframe: an entry per fragment start, sync or not.
@Test func anMfraThatNamesAPredictedFrameIsNotUsedForThePlan() throws {
    let (result, _) = try probe(fragmentedFile(secondStarts: nonSync))
    guard case .unusable(let reason) = result else { Issue.record("expected unusable, got \(result)"); return }
    #expect(reason.contains("not a sync sample"), "\(reason)")
}

@Test func aFragmentedFileWithoutMfraIsIndexedInFull() throws {
    let file = ftyp + fragmentedMoov() + box("moof", Data(count: 64)) + box("mdat", Data(count: 4_000))
    let (result, _) = try probe(file)
    #expect(result == .unusable("no mfra at the end of the file"))
}

/// A classic MP4 whose moov comes after its media: the probe stops at the mdat and reads nothing
/// near the end, so the open's own trailing-index pass is the only one.
@Test func mediaBeforeTheMoovStopsTheProbeAtTheMdat() throws {
    let mdat = box("mdat", Data(count: 200_000))
    let file = ftyp + mdat + box("moov", fullBox("mvhd", version: 0, Data(count: 96)) + trak(id: 1, handler: "vide", timescale: 24000))
    let (result, seeks) = try probe(file)
    #expect(result == .notFragmented)
    #expect(seeks.allSatisfy { $0 <= Int64(ftyp.count) }, "seeks: \(seeks)")
}

// MARK: tfra entries against their moof

/// A moof with one traf for `track`: tfhd with optional default flags, one trun with optional
/// first-sample flags and per-sample flags.
private func moof(track: Int, tfhdDefault: UInt32? = nil, first: UInt32? = nil, perSample: [UInt32]? = nil,
                  samples: Int = 3) -> Data {
    let tfhdFlags = tfhdDefault == nil ? 0x020000 : 0x020020        // default-base-is-moof
    let tfhd = box("tfhd", be32(tfhdFlags) + be32(track) + (tfhdDefault.map { be32(Int($0)) } ?? Data()))
    var trunFlags = 0x001
    if first != nil { trunFlags |= 0x004 }
    if perSample != nil { trunFlags |= 0x400 | 0x200 }
    var body = be32(trunFlags) + be32(perSample?.count ?? samples) + be32(0)
    if let first { body += be32(Int(first)) }
    for f in perSample ?? [] { body += be32(100) + be32(Int(f)) }
    let trun = box("trun", body)
    return box("moof", fullBox("mfhd", version: 0, be32(1)) + box("traf", tfhd + trun))
}

private let sync: UInt32 = 0x0200_0000          // depends on nothing
private let nonSync: UInt32 = 0x0101_0000       // depends on others, sample_is_non_sync_sample

@Test func firstSampleFlagsDecideTheFirstSample() {
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1, tfhdDefault: nonSync, first: sync),
                                                   trackID: 1, trunNumber: 1, sampleNumber: 1, defaultFlags: nil) == true)
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1, tfhdDefault: nonSync, first: sync),
                                                   trackID: 1, trunNumber: 1, sampleNumber: 2, defaultFlags: nil) == false)
    // first_sample_flags override the run's own entry for sample 1
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1, first: sync, perSample: [nonSync, nonSync]),
                                                   trackID: 1, trunNumber: 1, sampleNumber: 1, defaultFlags: nil) == true)
}

@Test func aFragmentThatStartsOnAPredictedFrameIsNoSyncSample() {
    // ffmpeg's -frag_duration without frag_keyframe: the run starts mid-GOP, its flags say so
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1, perSample: [nonSync, sync, nonSync]),
                                                   trackID: 1, trunNumber: 1, sampleNumber: 1, defaultFlags: nil) == false)
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1, perSample: [nonSync, sync, nonSync]),
                                                   trackID: 1, trunNumber: 1, sampleNumber: 2, defaultFlags: nil) == true)
}

@Test func trexFlagsApplyWhenTheMoofSetsNone() {
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1), trackID: 1, trunNumber: 1,
                                                   sampleNumber: 1, defaultFlags: nonSync) == false)
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1), trackID: 1, trunNumber: 1,
                                                   sampleNumber: 1, defaultFlags: sync) == true)
    // no flags anywhere: unknown
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: moof(track: 1), trackID: 1, trunNumber: 1,
                                                   sampleNumber: 1, defaultFlags: nil) == nil)
}

@Test func anEntryTheMoofDoesNotHaveIsUnknown() {
    let m = moof(track: 1, tfhdDefault: sync, samples: 3)
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: m, trackID: 2, trunNumber: 1, sampleNumber: 1, defaultFlags: nil) == nil)
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: m, trackID: 1, trunNumber: 2, sampleNumber: 1, defaultFlags: nil) == nil)
    #expect(FragmentedMP4RandomAccess.sampleIsSync(moof: m, trackID: 1, trunNumber: 1, sampleNumber: 4, defaultFlags: nil) == nil)
}

@Test func trexDefaultFlagsAreReadPerTrack() {
    let trex = { (id: Int, flags: UInt32) in fullBox("trex", version: 0, be32(id) + be32(1) + be32(0) + be32(0) + be32(Int(flags))) }
    let moov = box("moov", fullBox("mvhd", version: 0, Data(count: 96)) + box("mvex", trex(2, sync) + trex(1, nonSync)))
    #expect(FragmentedMP4RandomAccess.defaultSampleFlags(moov: moov, trackID: 1) == nonSync)
    #expect(FragmentedMP4RandomAccess.defaultSampleFlags(moov: moov, trackID: 2) == sync)
    #expect(FragmentedMP4RandomAccess.defaultSampleFlags(moov: moov, trackID: 3) == nil)
}

@Test func tfraEntriesCarryTheirRunAndSampleNumbers() {
    let mfra = box("mfra", tfra(track: 1, version: 1, entries: [(512, 3232), (35328, 640_000)]))
    let entries = FragmentedMP4RandomAccess.tfraEntries(mfra: mfra, trackID: 1)
    #expect(entries?.map(\.trun) == [1, 1])
    #expect(entries?.map(\.sample) == [1, 1])
}

@Test func theCheckedEntriesAreSpreadOverTheFile() {
    #expect(FragmentedMP4RandomAccess.sampleIndices(count: 1) == [])
    #expect(FragmentedMP4RandomAccess.sampleIndices(count: 2) == [1])
    #expect(FragmentedMP4RandomAccess.sampleIndices(count: 3) == [1, 2])
    #expect(FragmentedMP4RandomAccess.sampleIndices(count: 93) == [23, 46, 69, 92])
    #expect(FragmentedMP4RandomAccess.sampleIndices(count: 2770).last == 2769)
}

