import Foundation
import Testing
@testable import AetherEngine

/// #112 round 8 (ijuniorfu, 0.9.17, flat MPEG-TS): "The subtitles aren't showing up" after a fast-forward and
/// never again for the session. Two coupled defects:
///
/// 1. The side reader's positioning seek on an index-less remote MPEG-TS binary-searches via read_timestamp,
///    dozens of remote range reads riding a starved connection; one reader sat in that single seek for minutes
///    and never reached its read loop.
/// 2. `startEmbeddedSubtitleTask`'s predecessor drain was an unbounded `await prior.value`; the wedged reader
///    never observes its cancel (it is inside a native call), so the producer-restart re-anchor fired, logged,
///    and no reader ever started again (device log: subCues=0 for the rest of the session).
///
/// These tests lock the two pure pieces: the bounded drain race and the byte-estimate seek target.
struct Issue112SideReaderWedgeTests {

    @Test("a wedged predecessor times the drain out instead of blocking the successor forever")
    func wedgedPredecessorTimesOut() async {
        // Simulates a reader stuck in a blocking native call: never completes, ignores cancellation.
        let wedged = Task<Void, Never> {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        let drained = await AetherEngine.awaitDrain(wedged, timeoutNanos: 100_000_000)
        #expect(drained == false)
        wedged.cancel()
    }

    @Test("a completed predecessor drains immediately")
    func completedPredecessorDrains() async {
        let done = Task<Void, Never> {}
        let drained = await AetherEngine.awaitDrain(done, timeoutNanos: 5_000_000_000)
        #expect(drained == true)
    }

    @Test("a predecessor finishing within the budget drains true")
    func finishingPredecessorDrains() async {
        let brief = Task<Void, Never> { try? await Task.sleep(nanoseconds: 20_000_000) }
        let drained = await AetherEngine.awaitDrain(brief, timeoutNanos: 2_000_000_000)
        #expect(drained == true)
    }

    @Test("byte-estimate target is proportional with the early bias applied")
    func byteEstimateProportionalWithBias() {
        // 1000 bytes over 100 s, target 50 s, 5% early bias: fraction 0.45.
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: 50) == 450)
        // Bias-free check of the raw proportion.
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: 50, earlyBias: 0) == 500)
    }

    @Test("byte-estimate target clamps at the file edges")
    func byteEstimateClamps() {
        // Near the head the bias cannot push the target negative.
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: 1) == 0)
        // Past the duration it caps at the file size.
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: 500) == 1000)
    }

    @Test("byte-estimate target is nil when size or duration is unknown")
    func byteEstimateNilWhenUnknown() {
        #expect(Demuxer.byteEstimateTarget(fileSize: -1, duration: 100, target: 50) == nil)
        #expect(Demuxer.byteEstimateTarget(fileSize: 0, duration: 100, target: 50) == nil)
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 0, target: 50) == nil)
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: -1) == nil)
    }
}
