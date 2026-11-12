import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil

@testable import AetherEngine

@Suite("Truncated HEVC header at a transport-stream tail")
struct ShortHEVCHeaderTests {
    private func unit(_ bytes: [UInt8], width: Int = 4) -> [UInt8] {
        (0..<width).reversed().map { UInt8((bytes.count >> ($0 * 8)) & 0xff) } + bytes
    }
    private func ranges(_ bytes: [UInt8], width: Int = 4, confirmed: Bool = true) -> [Range<Int>] {
        bytes.withUnsafeBytes {
            NALUnitChain.shortHEVCHeaderRanges($0, lengthPrefixSize: width, framingConfirmed: confirmed)
        }
    }

    @Test("(#960) A complete length chain can still contain a truncated EOS header")
    func damagedEOSIsRemovedWithoutLosingThePictureOrFollowingRPU() {
        let picture = unit([0x26, 0x01, 0x80])
        let eos = unit([0x48])
        let rpu = unit([0x7c, 0x01, 0x80])
        let sample = picture + eos + rpu
        #expect(
            sample.withUnsafeBytes { NALUnitChain.completeRunLength($0, lengthPrefixSize: 4, framingConfirmed: true) }
                == nil)
        #expect(ranges(sample) == [picture.count..<(picture.count + eos.count)])
        let removed = ranges(sample)
        let cleaned = sample.enumerated().filter { entry in
            !removed.contains { $0.contains(entry.offset) }
        }.map(\.element)
        #expect(cleaned == picture + rpu)
    }

    @Test("(#960) Valid HEVC delimiters and pictures remain byte-for-byte unchanged")
    func validUnitsSurvive() {
        #expect(ranges(unit([0x26, 0x01, 0x80]) + unit([0x48, 0x01, 0x80])) == [])
    }

    @Test("(#960) Framing and bounds fail closed, and all prefix widths are supported")
    func framingBoundsAndWidths() {
        #expect(ranges([0, 0, 0, 1, 0x48], confirmed: false) == [])
        #expect(ranges(unit([0x48]) + [0, 0, 2]) == [])
        for width in 1...4 { #expect(ranges(unit([0x48], width: width), width: width) == [0..<(width + 1)]) }
    }
    private final class InitBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func set(_ data: Data) { lock.withLock { bytes = data } }
        func get() -> Data { lock.withLock { bytes } }
    }

    @Test("(#960) The muxer compacts a shared packet and writes the correct picture/RPU size")
    func muxerCompactsWithoutChangingTheSharedOriginal() throws {
        try muxerRoundTrip(dropsFirstSample: false)
    }

    @Test("(#960) A packet containing only short headers is dropped before the next valid sample")
    func muxerDropsAnAllShortSample() throws {
        try muxerRoundTrip(dropsFirstSample: true)
    }

    private func muxerRoundTrip(dropsFirstSample: Bool) throws {
        let fixture = try #require(Data(base64Encoded: Self.hevcFixture, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: fixture), formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC)
        var sourcePacket: UnsafeMutablePointer<AVPacket>? = try #require(try demuxer.readPacket())
        defer { trackedPacketFree(&sourcePacket) }
        let picture = Data(bytes: sourcePacket!.pointee.data!, count: Int(sourcePacket!.pointee.size))
        let rpu = Data(unit([0x7c, 0x01, 0x80]))
        let expected = picture + rpu
        let damaged = dropsFirstSample ? Data(unit([0x48]) + unit([0x4a])) : picture + Data(unit([0x48])) + rpu
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("short-hevc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = InitBytes()
        let muxer = try MP4SegmentMuxer(initialSegmentIndex: 0, sessionDir: directory,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base,
                         codecTagOverride: nil, nalFramingLatch: NALFramingLatch(confirmed: true)),
            audio: nil, onInitCaptured: { initial.set($0) })

        var packet: UnsafeMutablePointer<AVPacket>? = try #require(trackedPacketAlloc())
        var shared: UnsafeMutablePointer<AVPacket>? = try #require(trackedPacketAlloc())
        defer { trackedPacketFree(&packet); trackedPacketFree(&shared) }
        #expect(av_new_packet(packet!, Int32(damaged.count)) >= 0)
        damaged.withUnsafeBytes { _ = memcpy(packet!.pointee.data!, $0.baseAddress!, $0.count) }
        packet!.pointee.pts = 0; packet!.pointee.dts = 0; packet!.pointee.duration = 512
        packet!.pointee.flags = AV_PKT_FLAG_KEY
        packet!.pointee.stream_index = muxer.videoOutputStreamIndex
        #expect(av_packet_ref(shared!, packet!) >= 0)
        let outcome = muxer.writePacket(packet!)
        #expect(outcome.rc >= 0)
        #expect(Data(bytes: shared!.pointee.data!, count: Int(shared!.pointee.size)) == damaged)
        if dropsFirstSample {
            #expect(outcome.written.pts == Int64.min && packet!.pointee.size == 0)
            #expect(muxer.writtenVideoEndPts == Int64.min)
            #expect(av_new_packet(packet!, Int32(expected.count)) >= 0)
            expected.withUnsafeBytes { _ = memcpy(packet!.pointee.data!, $0.baseAddress!, $0.count) }
            packet!.pointee.pts = 512; packet!.pointee.dts = 512; packet!.pointee.duration = 512
            packet!.pointee.flags = AV_PKT_FLAG_KEY
            packet!.pointee.stream_index = muxer.videoOutputStreamIndex
            #expect(muxer.writePacket(packet!).rc >= 0)
        } else {
            #expect(outcome.written.pts == 0 && outcome.written.dts == 0)
        }
        guard case .completed(let path, let count) = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("The valid sample did not produce a complete fragment")
            return
        }
        let fragment = try Data(contentsOf: path)
        #expect(fragment.count == count)
        let result = Demuxer()
        defer { result.close() }
        try result.open(reader: DataIOReader(data: initial.get() + fragment), formatHint: "mp4")
        var clean: UnsafeMutablePointer<AVPacket>? = try #require(try result.readPacket())
        defer { trackedPacketFree(&clean) }
        #expect(clean!.pointee.size == expected.count)
        #expect(Data(bytes: clean!.pointee.data!, count: Int(clean!.pointee.size)) == expected)
        if let unexpected = try result.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = unexpected
            trackedPacketFree(&owned)
            Issue.record("The dropped header-only sample survived in the fragment")
        }
    }

    // Own synthetic two-frame 64x64 black HEVC MP4; x265 info=0, no private sample.
    private static let hevcFixture = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAA3ttb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAVAABAAABAAAAAAAA
    AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACpnRy
    YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAVAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
    AAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAFQAAAAAAAEAAAAAAh5tZGlhAAAAIG1kaGQAAAAA
    AAAAAAAAAAAAADAAAAAEAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAHJbWluZgAA
    ABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABiXN0YmwAAAEJc3RzZAAAAAAA
    AAABAAAA+Wh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEUTGF2YzYzLjEuMTAyIGxpYngyNjUA
    AAAAAAAAAAAAAAAY//8AAAB1aHZjQwEBYAAAAJAAAAAAAB7wAPz9+PgAAA8DoAABABhAAQwB//8BYAAAAwCQAAADAAADAB6VmAmh
    AAEAKEIBAQFgAAADAJAAAAMAAAMAHqAggQWWVmkkyvAWgIAAAAMAgAAADASiAAEAB0QBwXK0IkAAAAAKZmllbAEAAAAAEHBhc3AA
    AAABAAAAAQAAABRidHJ0AAAAAAAADAAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAIAAAIAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAc
    c3RzYwAAAAAAAAABAAAAAQAAAAIAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAIAAAASAAAADgAAABRzdGNvAAAAAAAAAAEAAAOnAAAA
    YXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEA
    AAABAAAAAExhdmY2My4xLjEwMgAAAAhmcmVlAAAAKG1kYXQAAAAOKAGvHYD3AbL//SMvszwAAAAKAgHQCX4Qxjv6hA==
    """

}
