import Foundation
import Testing
@testable import AetherEngine

/// #250 (cmcpherson274): an external conformance harness adjudicating seek-time subtitle
/// correctness has to decide, from the log alone, whether the pipeline has DETERMINED the display
/// state at the rendered position or has merely produced nothing yet. On a PGS track with no
/// acquisition point those are indistinguishable from outside.
///
/// Every case here is one way the statement could lie, since a diagnostic that over-claims is worse
/// than no diagnostic: the harness would adjudicate on it. Pure values throughout, matching #220:
/// the live gauge is written from the prefetch task and read from the main actor, so the tests
/// exercise the value functions both sides go through.
struct Issue250SubtitleResolutionTests {

    private static let fence = SubtitleResolutionStatement.Fence(loadGeneration: 3,
                                                                 seekGeneration: 7)

    private static func statement(
        coveredFrom: Double = 1185,
        windowThrough: Double = 1260,
        decodedThrough: Double = 1204,
        prefetchFrontier: Double? = nil,
        prefetchAtEndOfFile: Bool = false,
        retainedFrom: Double? = 1185,
        reason: SubtitleResolutionStatement.Reason = .reconstruction
    ) -> SubtitleResolutionStatement.Statement {
        SubtitleResolutionStatement.make(
            fence: fence, streamIndex: 4,
            coveredFrom: coveredFrom, windowThrough: windowThrough,
            decodedThrough: decodedThrough,
            prefetchFrontier: prefetchFrontier, prefetchAtEndOfFile: prefetchAtEndOfFile,
            retainedFrom: retainedFrom,
            reason: reason)
    }

    // MARK: - What resolvedThrough may claim

    /// The defect the whole line exists to avoid. The drain window runs to playhead + 60 s whether
    /// or not anybody has read that far, so taking its edge as the answer claims determination over
    /// bytes nobody fetched, which is exactly the ambiguity the harness is trying to remove.
    @Test("an unread window is not claimed as determined")
    func frontierBoundsTheWindow() {
        let s = Self.statement(prefetchFrontier: 1218)
        #expect(s.via == .prefetch)
        #expect(s.resolvedThrough == 1218)
    }

    /// The mirror image: a reader that has run past the lead edge does not extend the claim beyond
    /// the window the drainer actually decoded.
    @Test("a frontier beyond the lead edge is clamped to the window")
    func windowBoundsTheFrontier() {
        #expect(Self.statement(prefetchFrontier: 1900).resolvedThrough == 1260)
    }

    /// The other tempting answer, and why the drain cursor cannot be it on the prefetch path: on a
    /// sparse or forced track the last decoded cue stands still for minutes, so a cursor-based
    /// statement would report every dialogue pause as unresolved. Since #230 the reader's banked
    /// position moves between cues (it parks on the pacing stream's read position), so it keeps
    /// stating determination through silence.
    @Test("a sparse stretch is resolved past the last decoded cue")
    func sparseTrackResolvesPastTheCursor() {
        let s = Self.statement(decodedThrough: 1190, prefetchFrontier: 1249)
        #expect(s.resolvedThrough == 1249)
        #expect(s.decodedThrough == 1190, "the cursor is still reported, just not as the answer")
    }

    /// The side reader read to end of stream, so an empty position inside the window means "no cue
    /// here" rather than "not yet". This is the strongest state the line can report and the one the
    /// harness can adjudicate on outright.
    @Test("end of file determines the whole window")
    func endOfFileDeterminesTheWindow() {
        let s = Self.statement(prefetchFrontier: 1249, prefetchAtEndOfFile: true)
        #expect(s.via == .eof)
        #expect(s.resolvedThrough == 1260)
    }

    /// Without a usable side-reader frontier there is no read position anywhere in the engine: the
    /// producer tap harvests as a side effect of the video path and states nothing. The claim
    /// collapses to what was actually decoded, and says so through `via`.
    @Test("no side reader collapses the claim onto the drain cursor")
    func pumpFallbackIsTheCursor() {
        let s = Self.statement(prefetchFrontier: nil)
        #expect(s.via == .pump)
        #expect(s.resolvedThrough == 1204)
    }

    /// A fresh window with nothing decoded and no reader is the honest "nothing determined", and it
    /// has to be distinguishable from "determined, and empty".
    @Test("nothing decoded and no reader resolves to nothing")
    func nothingDeterminedReportsNone() {
        let s = Self.statement(decodedThrough: .nan, prefetchFrontier: nil)
        #expect(s.via == .pump)
        #expect(s.resolvedThrough == nil)
        #expect(SubtitleResolutionStatement.format(s).contains("resolvedThrough=none"))
    }

    /// A backward seek leaves the reader's banked position ahead of the new window. It says nothing
    /// about the region now being decoded, so it is not a claim over it.
    @Test("a frontier behind the window start resolves to nothing")
    func frontierBehindCoverageResolvesToNone() {
        #expect(Self.statement(coveredFrom: 1185, prefetchFrontier: 900).resolvedThrough == nil)
    }

    // MARK: - Generation fencing

    /// The fence's whole job. #240 made the prefetch session survive a seek (the anchor box moves
    /// its cursor in place instead of rebuilding it), so a position banked before the seek is still
    /// sitting in the gauge afterwards. Fenced to the superseded generation, it must not be usable.
    @Test("a position banked under a superseded seek is not a frontier")
    func supersededSeekVoidsTheFrontier() {
        var gauge = SubtitlePrefetchTelemetry.Snapshot()
        gauge.running = true
        gauge.fence = .init(loadGeneration: 3, seekGeneration: 6)
        gauge.lastPacketSeconds = 1249
        #expect(SubtitlePrefetchTelemetry.resolutionFrontier(gauge, matching: Self.fence) == nil)
        #expect(SubtitlePrefetchTelemetry.resolutionFrontier(
            gauge, matching: .init(loadGeneration: 3, seekGeneration: 6)) == 1249)
    }

    /// A different source entirely, same seek count.
    @Test("a position banked under a superseded load is not a frontier")
    func supersededLoadVoidsTheFrontier() {
        var gauge = SubtitlePrefetchTelemetry.Snapshot()
        gauge.running = true
        gauge.fence = .init(loadGeneration: 2, seekGeneration: 7)
        gauge.lastPacketSeconds = 1249
        #expect(SubtitlePrefetchTelemetry.resolutionFrontier(gauge, matching: Self.fence) == nil)
    }

    /// An in-place re-anchor moves the reader, so the position it banked before the move is void
    /// even though the session continues. Stamped after the reposition, which is why the gap
    /// between the request and the seek reads as unresolved rather than as the pre-seek position.
    @Test("an in-place re-anchor voids the banked position and re-stamps the fence")
    func reanchorVoidsThePosition() {
        var gauge = SubtitlePrefetchTelemetry.Snapshot()
        gauge.running = true
        gauge.fence = .init(loadGeneration: 3, seekGeneration: 6)
        gauge.lastPacketSeconds = 1249
        let moved = SubtitlePrefetchTelemetry.reanchored(gauge, seekGeneration: 7)
        #expect(moved.fence == Self.fence)
        #expect(SubtitlePrefetchTelemetry.resolutionFrontier(moved, matching: Self.fence) == nil)
    }

    /// A dead session's last position is not a frontier: #231 has the prefetcher exiting mid-file
    /// on a read error, and its final read position would otherwise keep claiming determination for
    /// the rest of the session.
    @Test("a stopped session has no frontier")
    func stoppedSessionHasNoFrontier() {
        var gauge = SubtitlePrefetchTelemetry.Snapshot()
        gauge.running = false
        gauge.exit = .readFailed
        gauge.fence = Self.fence
        gauge.lastPacketSeconds = 1249
        #expect(SubtitlePrefetchTelemetry.resolutionFrontier(gauge, matching: Self.fence) == nil)
        #expect(!SubtitlePrefetchTelemetry.reachedEndOfFile(gauge, matching: Self.fence))
    }

    /// EOF from the wrong generation is somebody else's end of file.
    @Test("end of file is fenced too")
    func endOfFileIsFenced() {
        var gauge = SubtitlePrefetchTelemetry.Snapshot()
        gauge.exit = .endOfFile
        gauge.fence = Self.fence
        #expect(SubtitlePrefetchTelemetry.reachedEndOfFile(gauge, matching: Self.fence))
        #expect(!SubtitlePrefetchTelemetry.reachedEndOfFile(
            gauge, matching: .init(loadGeneration: 4, seekGeneration: 7)))
    }

    /// A fresh session replaces the whole gauge, so it cannot inherit the previous session's read
    /// position under its own fence. Until its first packet it has no frontier to state.
    @Test("a fresh session starts without a position")
    func freshSessionHasNoPosition() {
        let fresh = SubtitlePrefetchTelemetry.Snapshot(generation: 2, fence: Self.fence,
                                                       running: true)
        #expect(SubtitlePrefetchTelemetry.resolutionFrontier(fresh, matching: Self.fence) == nil)
    }

    // MARK: - Anchor box

    /// The request carries the seek that asked for it, because the session outlives the seek: a
    /// fence captured at session start goes stale on the first in-place move.
    @Test("a re-anchor request carries its seek generation")
    func anchorCarriesItsGeneration() {
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorCandidates: [], fallbackDuration: 0, seekTimeout: 1)
        box.request(302, seekGeneration: 9)
        let taken = box.take()
        #expect(taken?.seconds == 302)
        #expect(taken?.seekGeneration == 9)
    }

    // MARK: - Line shape

    /// The harness taps EngineLog.handler and archives it, so the field set is the contract.
    @Test("the statement formats as one parseable line")
    func formatsAsOneLine() {
        let line = SubtitleResolutionStatement.format(
            Self.statement(prefetchFrontier: 1218, reason: .tick))
        #expect(line.hasPrefix("[AetherEngine] #250 subtitle-resolution "))
        #expect(line.contains("loadGen=3 seekGen=7 "))
        #expect(line.contains("stream=4 "))
        #expect(line.contains("coveredFrom=1185.00 "))
        #expect(line.contains("retainedFrom=1185.00 "))   // #276
        #expect(line.contains("resolvedThrough=1218.00 "))
        #expect(line.contains("via=prefetch "))
        #expect(line.contains("decodedThrough=1204.00 "))
        #expect(line.hasSuffix("reason=tick"))
        #expect(!line.contains("\n"))
    }
}
