import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

/// AE#1023: a software host that has already played, is paused, and is then moved presents the frame
/// at the landing while its transport stays stopped, the way the native route does. The flush keeps the
/// pre-seek frame on screen (#90) and the loops are parked under the pause, so before this nothing
/// decoded at the landing until `play()`.
@Suite("AE#1023 paused seek presents the landed frame", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue1023PausedSeekFrameTests {

    @Test("a seek on a paused host that has shown frames decodes the frame at the landing and stays paused")
    func pausedSeekPresentsTheLandedFrame() async throws {
        let host = SoftwarePlaybackHost()
        defer { host.stop() }
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        try await host.load(demuxer: dem, startPosition: nil, audioSourceStreamIndex: nil)

        host.play()
        try await waitFor { host.framesEnqueued > 0 }
        host.pause()

        let outcome = await host.seek(to: 0)
        #expect(outcome == .landed)
        let atLanding = host.framesEnqueued

        try await waitFor { host.framesEnqueued > atLanding }
        #expect(!host.isPlaying)
        #expect(host.rate == 0)
    }

    /// The hold ends at the first frame the renderer hands over. A decoder that answers in coding order
    /// delivers the P-frame past the target before the B-frames at it, so the first DECODED frame is the
    /// wrong one to present and to move the stopped clock onto.
    @Test("the first frame handed over from a coding-order run is the earliest one, not the first decoded")
    @MainActor
    func handoverHookSeesTheEarliestFrame() throws {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: true))
        let handed = HandedSeconds()
        renderer.setHandoverHook { handed.append($0) }
        let pixels = try Issue407CadenceTests.makePixelBuffer()
        // 24 fps, coding order I P B B P B B: the 27.125 P-frame arrives before the 27.042 and 27.083 B-frames.
        let codingOrder: [Int64] = [27_000, 27_125, 27_042, 27_083, 27_250, 27_167, 27_208]
        for ms in codingOrder {
            renderer.enqueue(pixelBuffer: pixels, pts: CMTimeMake(value: ms, timescale: 1000))
        }
        renderer.drainReorderBuffer()
        #expect(handed.values == [27.0, 27.042, 27.083, 27.125, 27.167, 27.208, 27.25])
    }

    @Test("only a host whose loops run and that has a picture to wait for holds a paused landing open")
    func holdsOnlyWithLoopsAndVideo() {
        #expect(PausedFirstFrame.holdsAfterPausedLanding(loopsStarted: true, hasVideo: true))
        #expect(!PausedFirstFrame.holdsAfterPausedLanding(loopsStarted: false, hasVideo: true))
        #expect(!PausedFirstFrame.holdsAfterPausedLanding(loopsStarted: true, hasVideo: false))
    }
}

private final class HandedSeconds: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ value: Double) { lock.lock(); _values.append(value); lock.unlock() }
}
