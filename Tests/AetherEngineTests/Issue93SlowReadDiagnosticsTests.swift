import Testing
import Foundation
@testable import AetherEngine

/// #93 restart latency: rrgomes' LAN trace shows a producer's first post-restart read waiting
/// 19-46 s while a side reader's read issued 19 s later completes in 300 ms, against a source
/// answering range requests in milliseconds. The wait is client-side; the diagnostics accumulate
/// where a single AVIOReader.read() call spends its time and render ONE summary line when the
/// read exceeds the reporting threshold, so a device trace localizes the wait without guesswork.
struct Issue93SlowReadDiagnosticsTests {

    @Test("a fast read emits nothing")
    func fastReadSilent() {
        var diag = SlowReadDiagnostics()
        diag.recordDetourServe(ms: 12, fetched: true)
        let line = diag.line(elapsedMs: 350, offset: 1_234_567, generationSpan: (4, 4))
        #expect(line == nil)
    }

    @Test("a slow read renders every counter it accumulated")
    func slowReadRendersCounters() {
        var diag = SlowReadDiagnostics()
        diag.recordDetourServe(ms: 220, fetched: true)
        diag.recordDetourServe(ms: 1, fetched: false)
        diag.recordStallWait(ms: 19_800, signaled: false)
        diag.recordReconnect()
        diag.recordBackoff(ms: 500)
        diag.recordStaleGenerationDrop(bytes: 4_194_304)
        let line = diag.line(elapsedMs: 21_000, offset: 352 * 4_194_304, generationSpan: (7, 9))
        let rendered = try! #require(line)
        #expect(rendered.contains("slow read"))
        #expect(rendered.contains("21000ms"))
        #expect(rendered.contains("detour=2(221ms,1fetch)"))
        #expect(rendered.contains("stallWaits=1(19800ms,0signaled)"))
        #expect(rendered.contains("reconnects=1"))
        #expect(rendered.contains("backoff=500ms"))
        #expect(rendered.contains("staleGenDropped=4194304b"))
        #expect(rendered.contains("gen=7->9"))
    }

    @Test("a slow read reports loop iterations and the time unaccounted by any counter")
    func slowReadReportsIterationsAndUnaccounted() {
        // #93/#96 residual: the pathological reads show near-zero recorded counters but a
        // multi-second total, i.e. the wait is upstream of every instrumented branch. The
        // unaccounted figure (elapsed minus stall/detour/backoff) makes that gap quantitative,
        // and the iteration count separates a single blocked call from a spin.
        var diag = SlowReadDiagnostics()
        diag.recordIteration()
        diag.recordIteration()
        diag.recordStallWait(ms: 70, signaled: true)
        diag.recordReconnect()
        let line = diag.line(elapsedMs: 18_938, offset: 2_661_629_352, generationSpan: (24, 25))
        let rendered = try! #require(line)
        #expect(rendered.contains("iters=2"))
        // 18938 - 70 stall - 0 detour - 0 backoff = 18868 upstream of the loop.
        #expect(rendered.contains("unaccounted=18868ms"))
    }

    @Test("unaccounted equals the whole elapsed when nothing was counted")
    func unaccountedIsWholeElapsedWithoutCounters() {
        let diag = SlowReadDiagnostics()
        let line = diag.line(elapsedMs: 15_795, offset: 1_217_464_230, generationSpan: (10, 11))
        let rendered = try! #require(line)
        #expect(rendered.contains("iters=0"))
        #expect(rendered.contains("unaccounted=15795ms"))
    }

    @Test("threshold is configurable and inclusive above, exclusive below")
    func thresholdBoundary() {
        var diag = SlowReadDiagnostics(thresholdMs: 1000)
        diag.recordReconnect()
        let below = diag.line(elapsedMs: 999, offset: 0, generationSpan: (1, 1))
        let above = diag.line(elapsedMs: 1001, offset: 0, generationSpan: (1, 1))
        #expect(below == nil)
        #expect(above != nil)
    }

    @Test("a slow read with no accumulated counters still reports (the wait was elsewhere)")
    func slowReadWithoutCountersStillReports() {
        // If nothing was counted the time went somewhere the counters do not
        // cover (e.g. inside the seek, or upstream of the read loop); the line
        // must still fire so the gap itself is visible.
        let diag = SlowReadDiagnostics()
        let line = diag.line(elapsedMs: 8_000, offset: 42, generationSpan: (2, 2))
        let rendered = try! #require(line)
        #expect(rendered.contains("detour=0"))
        #expect(rendered.contains("stallWaits=0"))
    }

    @Test("restart phase summary renders all four phases")
    func restartPhaseSummary() {
        let s = HLSVideoEngine.restartPhaseSummary(
            stopWaitMs: 5_002, reopenMs: 19_480, seekMs: 210, buildMs: 45)
        #expect(s == "stopWait=5002ms reopen=19480ms seek=210ms build=45ms")
    }

    @Test("restart phase summary omits the reopen phase when no reopen ran")
    func restartPhaseSummaryNoReopen() {
        let s = HLSVideoEngine.restartPhaseSummary(
            stopWaitMs: 3, reopenMs: nil, seekMs: 12, buildMs: 6)
        #expect(s == "stopWait=3ms seek=12ms build=6ms")
    }

    @Test("a missed detour fetch accounts its time so it does not land in unaccounted")
    func missedDetourFetchIsAccounted() {
        // #93/#96 root cause hid HERE: a backward-scrub detour fetch that starved and MISSED
        // burned 15-35s, but detour time was only recorded on a successful serve, so the failed
        // fetch's time fell into `unaccounted` and read as an unlocalized wait. A miss (or a
        // rate-limited attempt) must account its fetch time: it renders as a fetch with zero
        // serves, and it is subtracted from unaccounted.
        var diag = SlowReadDiagnostics()
        diag.recordIteration()
        diag.recordDetourFetchAttempt(ms: 15_000)
        diag.recordReconnect()
        let line = try! #require(diag.line(elapsedMs: 15_040, offset: 822_867_215, generationSpan: (10, 11)))
        #expect(line.contains("detour=0(15000ms,1fetch)"))
        // 15040 - 15000 detour = 40 left, not the whole 15040 as unaccounted.
        #expect(line.contains("unaccounted=40ms"))
    }

    @Test("the interactive detour fetch budget caps a starved fetch well below the chunk budget")
    func detourFetchBudgetIsTight() {
        // A 4 MB detour block over a healthy remote 4K source lands in ~1s; the full chunk budget
        // (idle 15s / total 35s) let a per-connection-starved backward-scrub fetch ride 15-35s
        // before the rescue reconnect (which serves in ~30-190ms). The detour path uses a tight
        // interactive budget instead, and never exceeds a caller that already asked for less.
        #expect(AVIOReader.effectiveDetourBudget(chunkRequestTimeout: 35) == 4)
        #expect(AVIOReader.effectiveDetourBudget(chunkRequestTimeout: 2) == 2)
    }
}
