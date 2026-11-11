import Testing
import Foundation
import AetherLibavformat
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

/// AE#1032: the container name, the Dolby Vision base-layer compatibility id and the disc titles reach
/// `SourceProbe` from the same demuxer a loaded session reads them from.
@Suite(.offCooperativePool)
struct SourceProbeContainerFactsTests {

    @Test("The container name comes from the bytes, not from the file extension")
    func containerNameIgnoresExtension() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-really.mkv")
        try TinyTransportStreamFixture.data.write(to: file)

        let probe = try AetherEngine.probe(url: file)
        #expect(probe.containerFormat == "mpegts")
        #expect(probe.dvBLCompatID == nil)
        #expect(probe.discTitles.isEmpty)
    }

    @Test("A controlled custom-reader probe reports the same container name")
    func controlledProbeReportsContainer() throws {
        let probe = try AetherEngine.probe(
            source: .custom(DataIOReader(data: TinyTransportStreamFixture.data), formatHint: "mpegts"),
            limits: ProbeLimits(), cancellation: ProbeCancellation())
        #expect(probe.containerFormat == "mpegts")
    }

    @Test("The base-layer compatibility id is read from the same record as the profile",
          arguments: [(8, 1), (8, 2), (8, 4), (7, 6), (5, 0)])
    func baseLayerCompatID(profile: Int, compatID: Int) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: TinyTransportStreamFixture.data), formatHint: "mpegts")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        Self.attachDolbyVisionRecord(to: stream, profile: UInt8(profile), compatID: UInt8(compatID))

        let probe = AetherEngine.makeSourceProbe(demuxer: demuxer, displayURL: URL(fileURLWithPath: "/x.ts"))
        #expect(probe.dvProfile == profile)
        #expect(probe.dvBLCompatID == compatID)
    }

    @Test("A disc folder probe lists the same titles a loaded session would, main feature first")
    func discFolderTitles() throws {
        let (folder, _) = BluRayFolderTests.tinyStreamFolder()
        let probe = try AetherEngine.probe(source: .custom(folder))
        #expect(probe.discTitles.count == 2)
        #expect(probe.discTitles.map(\.id) == [0, 1])
        let durations = probe.discTitles.map(\.durationSeconds)
        #expect(durations == durations.sorted(by: >))

        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: BluRayFolderTests.tinyStreamFolder().folder)
        #expect(probe.discTitles == demuxer.discTitleInfos())
        #expect(probe.containerFormat == demuxer.containerFormatName)
    }

    private static func attachDolbyVisionRecord(
        to stream: UnsafeMutablePointer<AVStream>, profile: UInt8, compatID: UInt8
    ) {
        let codecpar = stream.pointee.codecpar!
        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        guard let sd = av_packet_side_data_new(
            &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF, size, 0
        ) else { fatalError("could not attach a DOVI configuration record") }
        memset(sd.pointee.data, 0, size)
        sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
            rec.pointee.dv_version_major = 1
            rec.pointee.dv_profile = profile
            rec.pointee.rpu_present_flag = 1
            rec.pointee.bl_present_flag = 1
            rec.pointee.dv_bl_signal_compatibility_id = compatID
        }
    }
}
