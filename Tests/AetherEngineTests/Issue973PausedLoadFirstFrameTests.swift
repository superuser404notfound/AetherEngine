import Foundation
import Testing
@testable import AetherEngine

/// AE#973: a software host that is loaded and then paused without ever having played (a session
/// rebuilt at the playhead while paused, a paused mount) still decodes and presents the frame at
/// the playhead, and keeps its transport stopped.
@Suite("AE#973 paused load presents its first frame", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct Issue973PausedLoadFirstFrameTests {

    @Test("a loaded host whose first transport call is pause() still presents the first frame")
    func pausePresentsTheFirstFrame() async throws {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        try await host.load(demuxer: dem, startPosition: nil, audioSourceStreamIndex: nil)

        host.pause()

        try await waitFor { host.framesEnqueued > 0 }
        #expect(!host.isPlaying)
        #expect(host.rate == 0)
    }

    @Test("only a loaded host starts its loops on a pause; one still loading leaves them to play()")
    func startsLoopsOnlyOnceLoaded() {
        #expect(PausedFirstFrame.startsLoopsForFirstFrame(loaded: true, loopsStarted: false))
        #expect(!PausedFirstFrame.startsLoopsForFirstFrame(loaded: false, loopsStarted: false))
        #expect(!PausedFirstFrame.startsLoopsForFirstFrame(loaded: true, loopsStarted: true))
    }
}
