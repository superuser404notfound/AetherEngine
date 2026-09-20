import Testing
import Foundation
@testable import AetherEngine

/// That both live routes carry the recording tap, and that the software route carries it at BOTH
/// of its packet read sites (AE#560).
///
/// The source-level assertion below is deliberate. Neither software loop can be driven from a unit
/// test without a live origin, and a tap missing from one of them is exactly the defect that would
/// ship silently: `runDemuxLoop` serves a live session loaded WITHOUT `dvrWindowSeconds`, so a tap
/// only in `runLiveReaderLoop` would record nothing for those sessions while every other test
/// stayed green.
@Suite("Live recording taps")
struct LiveRecordingTapTests {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)            // Tests/AetherEngineTests/<this file>
            .deletingLastPathComponent()           // Tests/AetherEngineTests
            .deletingLastPathComponent()           // Tests
            .deletingLastPathComponent()           // repo root
            .appendingPathComponent("Sources/AetherEngine")
    }

    @Test("both live routes conform to LiveRecordingHost")
    func bothRoutesConform() {
        #expect((HLSSegmentProducer.self as Any) is LiveRecordingHost.Type)
        #expect((SoftwarePlaybackHost.self as Any) is LiveRecordingHost.Type)
    }

    @Test("the software host taps at both of its packet read sites")
    func softwareTapsBothReadSites() throws {
        let path = Self.sourcesRoot.appendingPathComponent("Native/SoftwarePlaybackHost.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        // The two read loops are `nonisolated static` and reach the host through @Sendable
        // closures, so the tap arrives as `recordingTap`, mirroring the existing subtitleTapSink.
        let taps = source.components(separatedBy: "recordingTap(packet)").count - 1
        #expect(taps == 2,
                "expected the tap in both readerIteration and demuxIteration, found \(taps)")
    }

    @Test("the loopback tap sits on the merged read, not on the bare demuxer")
    func loopbackTapsTheMergedRead() throws {
        let path = Self.sourcesRoot.appendingPathComponent("Video/HLSSegmentProducer.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        // The merged read is what carries side-audio packets. Tapping anywhere else would record a
        // packed-AAC live channel without audio.
        #expect(source.contains("readNextSourcePacketMergedTapped"))
        let taps = source.components(separatedBy: "tapForRecording(read.packet)").count - 1
        #expect(taps == 1, "expected exactly one loopback tap, found \(taps)")
    }
}
