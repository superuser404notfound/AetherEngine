import Foundation
import Testing
@testable import AetherEngine

/// #112 full umbau (ijuniorfu): the fixed reconstruct lead-in was a dead-end. The engine already retains ~300 s
/// of decoded cues in `subtitleCues`; a seek whose target is served by that retained store shows the active line
/// instantly with zero I/O, so it must NOT clear the store nor pay for a reconstruct back-scan. Coverage is
/// derived from the store itself: the target must lie at/below the store frontier (highest retained image cue
/// start - beyond it is unseen forward territory the open-ended tail must not be trusted to cover) AND the newest
/// image cue starting at/before the target must still cover it (a cue trimmed to end before the target means a
/// newer composition was held/dropped/pruned, i.e. a gap the store cannot answer). `retainedStoreCoversSeek` is
/// that predicate.
struct Issue112PGSRetainedIndexTests {

    @Test("a backward seek onto a retained line that still covers the target is covered")
    func backwardSeekOntoCoveringLineIsCovered() {
        // Newest image cue at/before 105 s is [100,110); it covers 105 s and 105 <= frontier(130). Instant, no I/O.
        #expect(AetherEngine.retainedStoreCoversSeek(
            activeCueEnd: 110, storeFrontier: 130, target: 105) == true)
    }

    @Test("a forward seek within the read-ahead region is covered")
    func forwardSeekWithinReadAheadIsCovered() {
        // The reader parks ~90 s ahead, so the store holds cues past the playhead; a small forward seek lands on a
        // decoded, covering cue.
        #expect(AetherEngine.retainedStoreCoversSeek(
            activeCueEnd: 4_296_178, storeFrontier: 180, target: 150) == true)
    }

    @Test("a forward seek beyond the store frontier is not covered")
    func forwardSeekBeyondFrontierIsNotCovered() {
        // 600 s was never decoded. The open-ended tail cue's window would nominally cover it, but past the frontier
        // that is a placeholder, not evidence: reconstruction is required.
        #expect(AetherEngine.retainedStoreCoversSeek(
            activeCueEnd: 4_296_178, storeFrontier: 500, target: 600) == false)
    }

    @Test("a backward seek into a held/dropped gap is not covered")
    func backwardSeekIntoGapIsNotCovered() {
        // The newest retained image cue at/before 115 s ends at 110 s (a newer composition was held by #100 and
        // dropped, or pruned): the store has a hole at 115 s, so it must reconstruct rather than show nothing.
        #expect(AetherEngine.retainedStoreCoversSeek(
            activeCueEnd: 110, storeFrontier: 130, target: 115) == false)
    }

    @Test("a target before any retained composition is not covered")
    func targetBeforeOldestIsNotCovered() {
        // No image cue starts at/before the target (its composition was pruned out of the 300 s window).
        #expect(AetherEngine.retainedStoreCoversSeek(
            activeCueEnd: nil, storeFrontier: 500, target: 50) == false)
    }

    @Test("an empty store covers nothing")
    func emptyStoreCoversNothing() {
        // No retained image cue at all (fresh track / just cleared): every seek needs a reconstruction pass.
        #expect(AetherEngine.retainedStoreCoversSeek(
            activeCueEnd: nil, storeFrontier: nil, target: 42) == false)
    }
}
