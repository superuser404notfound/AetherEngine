import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// `aetherctl dovitest` writes a source's video stream as Annex B for `dovi_tool`. It resolved the
/// framing of neither the converter calls nor its writer, so an Annex-B source (a Blu-ray remux) came
/// out as one bogus NAL per packet, with every packet counted as converted (audit BIT-106).
@Suite("dovitest probe")
struct DoviConvertProbeTests {

    private func nalTypes(of file: URL) throws -> [UInt8] {
        let bytes = try Data(contentsOf: file)
        var types: [UInt8] = []
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            A53SEIParser.forEachNAL(base, bytes.count, .annexB) { nal, _ in types.append((nal[0] >> 1) & 0x3F) }
        }
        return types
    }

    @Test("A raw Annex-B stream probes to the same NALs as the hvcC file it was written from",
          .enabled(if: fixtureExists("hdr10-hevc.mp4"), "needs Fixtures/hdr10-hevc.mp4 (Scripts/fetch-fixtures.sh)"),
          .timeLimit(.minutes(3)))
    func annexBSourceKeepsItsNALs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dovi-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = dir.appendingPathComponent("first.hevc")
        let second = dir.appendingPathComponent("second.hevc")
        let fromMP4 = try AetherEngine.doviConvertProbe(url: fixtureURL("hdr10-hevc.mp4"), outputPath: first.path)
        let fromAnnexB = try AetherEngine.doviConvertProbe(url: first, outputPath: second.path)

        #expect(fromMP4.videoStreamFound && fromMP4.packetsProcessed > 0)
        #expect(fromAnnexB.videoStreamFound && fromAnnexB.packetsProcessed > 0)
        #expect(fromAnnexB.failures == 0)

        // The raw demuxer also hands the stream's parameter sets over as extradata, so they head the
        // second output once more on top of the in-band copy. Repeated parameter sets are legal Annex B.
        let notParameterSet: (UInt8) -> Bool = { !(32...34).contains($0) }
        let expected = try nalTypes(of: first).filter(notParameterSet)
        #expect(expected.count >= fromMP4.packetsProcessed, "at least one NAL per packet")
        let actual = try nalTypes(of: second).filter(notParameterSet)
        #expect(actual == expected, "\(actual.count) NALs (\(actual.prefix(12))) against \(expected.count) (\(expected.prefix(12)))")
    }

    @Test("An output path that cannot be opened throws instead of reporting an empty run",
          .enabled(if: fixtureExists("hdr10-hevc.mp4"), "needs Fixtures/hdr10-hevc.mp4 (Scripts/fetch-fixtures.sh)"))
    func unwritableOutputThrows() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dovi-probe-missing-\(UUID().uuidString)/out.hevc").path
        #expect(throws: (any Error).self) {
            _ = try AetherEngine.doviConvertProbe(url: fixtureURL("hdr10-hevc.mp4"), outputPath: path)
        }
    }
}
