import Testing
import Foundation
@testable import AetherEngine

/// A sequential-origin session serves its media playlist append-only with the durations actually
/// muxed (#346). These pin the provider -> playlist-builder half of that: which segments become
/// visible, when ENDLIST lands, and that the zero-duration hole a long GOP leaves in the plan is
/// omitted from the rendered playlist WITHOUT that omission leaking onto the live path, where a
/// dropped URI would shift every later segment's implicit media sequence number - the number a
/// blocking reload (?_HLS_msn=) resolves against.
@Suite("Sequential append playlist")
struct SequentialAppendPlaylistTests {

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(planCount: Int = 10) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 60, backwardWindow: 60),
            segments: segments(planCount),
            codecsString: "avc1.64002A,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 50,
            hdcpLevel: nil,
            sourceBitrate: 6_000_000,
            isLive: false,
            sequentialAppendPlaylist: true
        )
    }

    private func extinfValues(_ playlist: String) -> [String] {
        playlist.split(separator: "\n").compactMap { line in
            line.hasPrefix("#EXTINF:") ? String(line.dropFirst(8).dropLast()) : nil
        }
    }

    private func segmentURIs(_ playlist: String) -> [String] {
        playlist.split(separator: "\n").filter { $0.hasPrefix("seg") }.map(String.init)
    }

    @Test("only finalized segments are visible, each with its muxed duration")
    func onlyFinalizedSegmentsAreServed() {
        let provider = makeProvider()
        // A 1.92 s-GOP archive against a 4 s cut target: real spans, not the plan's uniform 4.000.
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.appendSequentialSegmentDuration(index: 1, durationSeconds: 5.76)

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(extinfValues(playlist) == ["3.840", "5.760"],
                "the playlist must advertise what was muxed, not the static plan")
        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg1.mp4"],
                "segments the producer has not finalized must not be listed")
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        #expect(!playlist.contains("#EXT-X-ENDLIST"),
                "a growing playlist must not claim to be complete")
    }

    @Test("true source EOF completes the playlist")
    func endOfSourceAddsEndlist() {
        let provider = makeProvider()
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.markSequentialEnded()

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(playlist.contains("#EXT-X-ENDLIST"),
                "without ENDLIST an EVENT playlist never reaches end-of-media")
    }

    @Test("a zero-duration hole is omitted from the playlist but keeps the later indices")
    func zeroDurationHoleIsOmitted() {
        let provider = makeProvider()
        // Index 1 is a plan index a long GOP skipped outright: reported as a hole, no media file.
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.appendSequentialSegmentDuration(index: 1, durationSeconds: 0)
        provider.appendSequentialSegmentDuration(index: 2, durationSeconds: 5.76)

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(!playlist.contains("#EXTINF:0.000,"),
                "a hole has no media file; advertising it would 404 the fetch")
        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg2.mp4"],
                "the surviving segments keep their own indices, the hole is simply absent")
        #expect(extinfValues(playlist) == ["3.840", "5.760"])
    }

    @Test("an out-of-order append is refused rather than silently reindexed")
    func outOfOrderAppendIgnored() {
        let provider = makeProvider()
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 3.84)
        provider.appendSequentialSegmentDuration(index: 5, durationSeconds: 4.0)

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(segmentURIs(playlist) == ["seg0.mp4"],
                "index 5 is not segment 1; accepting it would misalign every later EXTINF")
    }

    @Test("the plan bounds the visible count")
    func planBoundsVisibleCount() {
        let provider = makeProvider(planCount: 2)
        for i in 0..<4 { provider.appendSequentialSegmentDuration(index: i, durationSeconds: 4.0) }

        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg1.mp4"],
                "a source running past its declared window must not outgrow the asset")
    }

    // MARK: - Startup gate (#370)

    @Test("one finalized segment releases the startup gate")
    func startupGateReleasesOnFirstSegment() {
        // A published duration needs the NEXT segment's ledger open, so the old 2-segment demand
        // was really 3 segment opens (~12-18 s of media) through a possibly-stalling origin.
        let provider = makeProvider()
        provider.sequentialStartupComfort = 0.05
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 6.0)
        #expect(provider.waitForSequentialStartupSegments(timeout: 0.2))
    }

    @Test("a single entry shorter than the first reload interval holds for the comfort budget")
    func startupGateHoldsShortSingleEntry() {
        // AE#958: one 5.68 s entry under TARGETDURATION 6 ran dry 0.1 s before AVPlayer's reload.
        let provider = makeProvider()
        provider.sequentialStartupComfort = 0.3
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 5.68)
        let start = Date()
        #expect(provider.waitForSequentialStartupSegments(timeout: 5.0))
        let waited = Date().timeIntervalSince(start)
        #expect(waited >= 0.25, "one entry under the reload interval must not release at once")
        #expect(waited < 2.0, "the comfort budget caps the hold, not the playlist timeout")
    }

    @Test("a second entry releases the held gate at once")
    func startupGateReleasesWhenSecondEntryArrives() {
        let provider = makeProvider()
        provider.sequentialStartupComfort = 60
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 5.68)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.1)
            provider.appendSequentialSegmentDuration(index: 1, durationSeconds: 4.0)
        }
        let start = Date()
        #expect(provider.waitForSequentialStartupSegments(timeout: 120))
        #expect(Date().timeIntervalSince(start) < 30,
                "the second entry must release the wait, not the comfort budget")
    }

    @Test("advertised media must outlast the TARGETDURATION the entries imply")
    func startupCoverageAgainstTargetDuration() {
        #expect(!VideoSegmentProvider.sequentialStartupCoversFirstReload(advertisedSeconds: 5.68, longestSegment: 5.68))
        #expect(!VideoSegmentProvider.sequentialStartupCoversFirstReload(advertisedSeconds: 6.0, longestSegment: 6.0))
        #expect(VideoSegmentProvider.sequentialStartupCoversFirstReload(advertisedSeconds: 9.68, longestSegment: 5.68))
        #expect(!VideoSegmentProvider.sequentialStartupCoversFirstReload(advertisedSeconds: 5.8, longestSegment: 5.7),
                "two entries summing under the rounded-up target still run dry")
    }

    @Test("an empty session times out instead of blocking past its deadline")
    func startupGateTimesOutEmpty() {
        let provider = makeProvider()
        #expect(!provider.waitForSequentialStartupSegments(timeout: 0.05))
    }

    @Test("EOF with zero segments still releases the gate")
    func startupGateReleasesOnEnded() {
        let provider = makeProvider()
        provider.markSequentialEnded()
        #expect(provider.waitForSequentialStartupSegments(timeout: 0.2))
    }

    @Test("a dead pump releases a held startup GET immediately")
    func startupGateAborts() {
        let provider = makeProvider()
        provider.abortSequentialStartupWait()
        let start = Date()
        #expect(!provider.waitForSequentialStartupSegments(timeout: 5.0))
        #expect(Date().timeIntervalSince(start) < 1.0,
                "the abort must release the wait, not let it sit out the timeout")
    }

    @Test("a zero-duration hole does not release the startup gate")
    func startupGateIgnoresHoles() {
        // The renderer gives a zero-duration entry no URI, so releasing on the entry COUNT could
        // answer the held GET with a playlist that renders empty - the -12888 the gate exists for.
        let provider = makeProvider()
        provider.appendSequentialSegmentDuration(index: 0, durationSeconds: 0)
        #expect(!provider.waitForSequentialStartupSegments(timeout: 0.05),
                "an entry the playlist cannot advertise is not a served segment")
        provider.appendSequentialSegmentDuration(index: 1, durationSeconds: 4.0)
        #expect(provider.waitForSequentialStartupSegments(timeout: 0.2))
        #expect(segmentURIs(HLSLocalServer.buildMediaPlaylistText(provider: provider)) == ["seg1.mp4"],
                "the released playlist carries the segment the gate counted")
    }

    /// #370 follow-up: the release belongs to the failure surface, not to two call sites that
    /// happened to be on the reported trace. A sequential origin also reaches `requestRestart`
    /// (which it refuses) and the AE#366 / AE#169 exhaustion arms, each of which can fire before
    /// the first duration is published.
    @Test("a terminal source failure releases a held startup GET")
    func terminalFailureReleasesStartupGate() {
        let provider = makeProvider()
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/archive.ts"),
                                    dvModeAvailable: false)
        engine.provider = provider
        let surfaced = FailureBox()
        engine.onVODSourceFailed = { code, _, _ in surfaced.fire(code) }

        engine.surfaceVODSourceFailure(FFmpegErr.einval, "Source audio cannot be muxed")

        #expect(surfaced.count == 1)
        let start = Date()
        #expect(!provider.waitForSequentialStartupSegments(timeout: 5.0))
        #expect(Date().timeIntervalSince(start) < 1.0,
                "the surface must release the wait, not leave the server thread on its timeout")
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func fire(_ code: Int32) { lock.lock(); _count += 1; lock.unlock() }
    }

    // MARK: - Blast radius

    /// Live playlists must render exactly as before. Their segment URIs carry the media sequence
    /// implicitly (position + EXT-X-MEDIA-SEQUENCE), so dropping one renumbers the rest.
    private final class ZeroDurationLiveProvider: HLSSegmentProvider, @unchecked Sendable {
        func initSegment() -> Data? { Data([0x00]) }
        func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
        var segmentCount: Int { 3 }
        func segmentDuration(at index: Int) -> Double { index == 1 ? 0 : 4.0 }
        func segmentIsDiscontinuous(at index: Int) -> Bool { false }
        var playlistType: HLSPlaylistType { .live }
    }

    @Test("a zero duration on the live path is still rendered, not skipped")
    func liveKeepsZeroDurationEntries() {
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: ZeroDurationLiveProvider())

        #expect(segmentURIs(playlist) == ["seg0.mp4", "seg1.mp4", "seg2.mp4"],
                "omitting a live URI shifts the media sequence a blocking reload resolves against")
        #expect(extinfValues(playlist) == ["4.000", "0.000", "4.000"])
    }
}
