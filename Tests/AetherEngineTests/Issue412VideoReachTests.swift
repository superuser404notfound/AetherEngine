import Foundation
import Testing
@testable import AetherEngine

/// AE#412: what a stored segment is worth to a COLD arrival.
///
/// Audio routes packets by plan boundary while video routes them keyframe-gated, so inside a
/// keyframe drought audio opens boundaries the cutter folded, and those segments carry no
/// random-access point. AVPlayer reaches back a fixed few seconds on a cold seek and does not search
/// for one, so a target below the next sync sample lands late and silently skips content.
///
/// Measured on a 12 s drought (`Scripts/timecode-fixture.sh` + `Scripts/mkv-cue-fixture.py`, seek from
/// 88 s back): a seek to 50.0 s landed at 55.0 s and a seek to 54.0 s at 54.96 s, while the same
/// source cut on its real sync samples landed exactly on all three targets tested.
@Suite("AE#412 segment video reach")
struct Issue412VideoReachTests {

    private func makeData(_ n: Int) -> Data { Data(repeating: 0xAA, count: n) }

    private func adopt(_ cache: SegmentCache, index: Int,
                       reach: SegmentCache.VideoReach?) throws {
        let staging = cache.sessionDir.appendingPathComponent("staging-\(index).tmp")
        try makeData(64).write(to: staging)
        cache.adopt(index: index, stagingPath: staging, byteCount: 64, videoReach: reach)
    }

    @Test("A segment opening on a sync sample serves every position inside it")
    func opensOnSyncServesEverything() {
        let reach = SegmentCache.VideoReach.syncAt(offsetSeconds: 0)
        #expect(reach.serves(offsetSeconds: 0))
        #expect(reach.serves(offsetSeconds: 3.9))
    }

    @Test("A sync sample partway in serves only from there on")
    func syncPartwayIn() {
        // seg10 of the measured fixture: advertised 40.0, first sync at 43.0.
        let reach = SegmentCache.VideoReach.syncAt(offsetSeconds: 3.0)
        #expect(!reach.serves(offsetSeconds: 0))
        #expect(!reach.serves(offsetSeconds: 2.999))
        #expect(reach.serves(offsetSeconds: 3.0))
        #expect(reach.serves(offsetSeconds: 3.5))
    }

    @Test("A segment with no random-access point serves nothing")
    func noSyncServesNothing() {
        // seg11 and seg12 of the measured fixture: audio cut them on boundaries the cutter folded.
        let reach = SegmentCache.VideoReach.none
        #expect(!reach.serves(offsetSeconds: 0))
        #expect(!reach.serves(offsetSeconds: 3.9))
    }

    @Test("A gate that opened BELOW its boundary serves its whole segment")
    func negativeOffsetServesEverything() {
        // What a re-cut produces: the covering random-access point sits below the advertised start.
        let reach = SegmentCache.VideoReach.syncAt(offsetSeconds: -5.0)
        #expect(reach.serves(offsetSeconds: 0))
        #expect(reach.serves(offsetSeconds: 2.0))
    }

    @Test("The cache hands back what was adopted, per index")
    func cacheRoundTrip() throws {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        try adopt(cache, index: 10, reach: .syncAt(offsetSeconds: 3.0))
        try adopt(cache, index: 11, reach: SegmentCache.VideoReach.none)
        #expect(cache.videoReach(10) == .syncAt(offsetSeconds: 3.0))
        #expect(cache.videoReach(11) == SegmentCache.VideoReach.none)
    }

    @Test("An index nobody stored has no claim, and neither has one adopted without one")
    func absentIsNoClaim() throws {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        #expect(cache.videoReach(7) == nil)
        try adopt(cache, index: 7, reach: nil)
        #expect(cache.videoReach(7) == nil)
    }

    /// The claim describes the BYTES, so an epoch that rewrites an index must not inherit the
    /// previous epoch's answer: a re-cut turns exactly this `.none` into a servable segment, and a
    /// stale claim would make the repair look like it never happened.
    @Test("Re-adopting an index replaces its claim")
    func readoptReplacesClaim() throws {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        try adopt(cache, index: 11, reach: SegmentCache.VideoReach.none)
        #expect(cache.videoReach(11) == SegmentCache.VideoReach.none)
        try adopt(cache, index: 11, reach: .syncAt(offsetSeconds: -1.0))
        #expect(cache.videoReach(11) == .syncAt(offsetSeconds: -1.0))
    }

    /// A claim outliving its bytes would answer for a segment that is no longer there.
    @Test("Pruning an entry drops its claim with it")
    func pruneDropsClaim() throws {
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1)
        defer { cache.close() }
        cache.declareTarget(10)
        try adopt(cache, index: 10, reach: SegmentCache.VideoReach.none)
        #expect(cache.videoReach(10) == SegmentCache.VideoReach.none)
        cache.declareTarget(50)
        #expect(cache.peekURL(index: 10) == nil)
        #expect(cache.videoReach(10) == nil)
    }
}

/// AE#412: when a cold seek's landing segment has to be re-cut.
///
/// The offsets in these cases are the ones measured on the 12 s-drought fixture: seg11 and seg12
/// carry no random-access point at all (audio cut them on boundaries the keyframe-gated cutter
/// folded), seg10 opens 3.0 s below its first one, seg13 opens 3.0 s below its own at 55.0 s.
@Suite("AE#412 re-cut decision")
struct Issue412RecutDecisionTests {

    @Test("A segment that opens a run at the target is left alone")
    func servesItself() {
        // seg10: advertised 40.0, sync at 43.0, target 46.0.
        #expect(!HLSVideoEngine.needsRecut(
            landingReach: .syncAt(offsetSeconds: 3.0),
            offsetIntoSegment: 6.0,
            coveringSyncDistance: 3.0))
    }

    /// The measured shape of the target that already landed exactly: seg11 carries nothing, but the
    /// random-access point at 43.0 is 3.0 s below the target and AVPlayer reaches further than that.
    /// Re-cutting here would spend a restart on a landing that works.
    @Test("A random-access point within reach below the target is enough")
    func coveredByReachBack() {
        #expect(!HLSVideoEngine.needsRecut(
            landingReach: SegmentCache.VideoReach.none,
            offsetIntoSegment: 2.0,
            coveringSyncDistance: 3.0))
    }

    /// Target 50.0 of the measured run: nothing below it inside the drought, and the covering point
    /// at 43.0 is 7.0 s down, past the reach. This is the seek that landed at 55.0 s.
    @Test("Nothing in reach below the target means a re-cut")
    func outOfReachNeedsRecut() {
        #expect(HLSVideoEngine.needsRecut(
            landingReach: SegmentCache.VideoReach.none,
            offsetIntoSegment: 2.0,
            coveringSyncDistance: 7.0))
    }

    @Test("No known random-access point below the target at all means a re-cut")
    func noCoveringPointNeedsRecut() {
        #expect(HLSVideoEngine.needsRecut(
            landingReach: SegmentCache.VideoReach.none,
            offsetIntoSegment: 2.0,
            coveringSyncDistance: nil))
    }

    /// Target 54.0: seg13 does carry a sync sample, at 55.0 s, which is ABOVE the target. A reach
    /// answered per segment rather than against the target would call this servable and land late.
    @Test("A sync sample above the target does not serve it")
    func syncAboveTargetDoesNotServe() {
        #expect(HLSVideoEngine.needsRecut(
            landingReach: .syncAt(offsetSeconds: 3.0),
            offsetIntoSegment: 2.0,
            coveringSyncDistance: 11.0))
    }

    @Test("The reach boundary is inclusive")
    func reachBoundaryInclusive() {
        #expect(!HLSVideoEngine.needsRecut(
            landingReach: SegmentCache.VideoReach.none,
            offsetIntoSegment: 1.0,
            coveringSyncDistance: HLSVideoEngine.coldSeekLookbackSeconds))
        #expect(HLSVideoEngine.needsRecut(
            landingReach: SegmentCache.VideoReach.none,
            offsetIntoSegment: 1.0,
            coveringSyncDistance: HLSVideoEngine.coldSeekLookbackSeconds + 0.001))
    }
}

/// AE#1117: a re-cut is a restart, and two landings must never pay for one. The reported shape: a
/// stashed seek to 0.00 on an IPTV catch-up whose first keyframe came 2.104 s after its first
/// timestamp, read by a host reader with `sequentialOrigin`. The seek reached seg0 at item -2.104 s,
/// the re-cut asked for a restart at idx 0, and the sequential origin failed the session with -5.
@Suite("AE#1117 re-cut skips")
struct Issue1117RecutSkipTests {

    @Test("A sequential origin never re-cuts, wherever the landing is", .timeLimit(.minutes(3)))
    func sequentialOriginSkips() {
        #expect(HLSVideoEngine.recutSkip(sequentialOrigin: true, landingIndex: 0,
                                         offsetIntoSegment: -2.104) == .sequentialOrigin)
        #expect(HLSVideoEngine.recutSkip(sequentialOrigin: true, landingIndex: 12,
                                         offsetIntoSegment: 2.0) == .sequentialOrigin)
    }

    @Test("A target before seg0 is not re-cut", .timeLimit(.minutes(3)))
    func beforeFirstSegmentSkips() {
        #expect(HLSVideoEngine.recutSkip(sequentialOrigin: false, landingIndex: 0,
                                         offsetIntoSegment: -2.104) == .beforeFirstSegment)
    }

    @Test("Inside seg0 and past it the re-cut still runs", .timeLimit(.minutes(3)))
    func ordinaryLandingsStillRecut() {
        #expect(HLSVideoEngine.recutSkip(sequentialOrigin: false, landingIndex: 0,
                                         offsetIntoSegment: 0) == nil)
        #expect(HLSVideoEngine.recutSkip(sequentialOrigin: false, landingIndex: 11,
                                         offsetIntoSegment: -0.5) == nil)
    }
}
