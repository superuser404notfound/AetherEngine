import Foundation
import Testing
import AetherLibavformat
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

/// AE#1104 (sarathm09): on the software path, a file opened at 46.2 s and then sought to 0 never got
/// the cues from 7.25 to 25.25 s back. The store held only what the load's landing read had found,
/// from 27.5 s on, and the reset after the seek decoded that island first. The cursor then sat on
/// its far side, and the cues the readers found from 0 on were stored behind it and never decoded.
/// The ledger knew the stretch in front of the island was unread; the reset never asked it.
@MainActor
struct Issue1104BackwardSeekLeadingGroundTests {

    private static let release = AetherEngine.subtitleDrainHarvestGapReleaseLeadSeconds

    /// The ledger as the reported session leaves it right after the seek: the load's landing read
    /// ran from 27 s to the end, the pump has just been anchored at the landing.
    private func ledgerAfterSeek() -> SubtitleHarvestCoverage {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.prefetch, at: 27)
        for through in stride(from: 37.0, through: 117, by: 10) {
            coverage.noteProgress(.prefetch, through: through)
        }
        coverage.noteAnchor(.pump, at: 0)
        return coverage
    }

    private func check(_ coverage: SubtitleHarvestCoverage) -> (Double, Double) -> Bool {
        { coverage.covers(from: $0, through: $1) }
    }

    // MARK: - The rule

    @Test("a reset whose first entry lies past unread ground decodes nothing and holds at the window start")
    func resetHoldsInFrontOfTheIsland() {
        let pts: [Double] = [27.5, 29.4, 35, 38, 43.4, 48.85, 52.95]
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { UInt64($0 + 1) },
            held: nil, resumeFrom: (110, 40), resetFrom: -15,
            releaseAt: 0 + Self.release, isRead: check(ledgerAfterSeek()))
        #expect(step.decodeEnd == 0)
        #expect(step.hold == .init(at: 0, sequence: 0),
                "held at the window start clamped to 0, where every reader's read start is clamped")
    }

    @Test("the hold resumes once a reader has read up to the first entry")
    func holdResumesOnReadGround() {
        var coverage = ledgerAfterSeek()
        coverage.noteAnchor(.prefetch, at: 0)
        coverage.noteProgress(.prefetch, through: 12)
        let pts: [Double] = [7.25, 11.8, 27.5, 29.4]
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { UInt64($0 + 50) },
            held: .init(at: 0, sequence: 0), resumeFrom: (-15, 0), resetFrom: nil,
            releaseAt: 0.5 + Self.release, isRead: check(coverage))
        #expect(step.decodeEnd == 2, "7.25 and 11.8 decode, the stretch from 12 s to the island is still unread")
        #expect(step.hold?.at == 11.8)
    }

    @Test("a reset on read ground decodes its whole window, as before")
    func resetOnReadGroundDecodes() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.prefetch, at: 0)
        coverage.noteProgress(.prefetch, through: 20)
        let pts: [Double] = [7.25, 11.8, 18]
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { UInt64($0 + 1) },
            held: nil, resumeFrom: nil, resetFrom: -15,
            releaseAt: 0 + Self.release, isRead: check(coverage))
        #expect(step.decodeEnd == pts.count)
        #expect(step.hold == nil)
    }

    @Test("a first entry already due decodes, read or not")
    func dueFirstEntryDecodes() {
        let pts: [Double] = [27.5, 29.4]
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { UInt64($0 + 1) },
            held: nil, resumeFrom: nil, resetFrom: 12,
            releaseAt: 27 + Self.release, isRead: check(ledgerAfterSeek()))
        #expect(step.decodeEnd == pts.count, "the landing line is never held")
    }

    @Test("a silent ledger keeps the old reset")
    func silentLedgerDecodes() {
        let pts: [Double] = [27.5, 29.4]
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { UInt64($0 + 1) },
            held: nil, resumeFrom: nil, resetFrom: -15,
            releaseAt: 0 + Self.release, isRead: nil)
        #expect(step.decodeEnd == pts.count, "harvest order has no pair to compare at a window boundary")
    }

    // MARK: - Through the drain

    @Test("the reported session: the cues in front of the load's start come back after a seek to 0",
          .timeLimit(.minutes(3)))
    func reportedSessionThroughTheDrain() async throws {
        let format = try #require(avformat_alloc_context())
        defer { avformat_free_context(format) }
        let stream = try #require(avformat_new_stream(format, nil))
        stream.pointee.time_base = AVRational(num: 1, den: 1_000)
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_SUBRIP

        let engine = try AetherEngine()
        defer { engine.clearSubtitle() }
        engine.loadedURL = URL(string: "https://example.invalid/movie.mkv")!
        let store = SubtitlePacketStore()
        engine.softwareSubtitlePacketStore = store
        engine.subtitleDrainDecoderFactoryForTesting = { index in
            index == 0 ? EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 1920,
                                                 sourceVideoHeight: 1080) : nil
        }
        func drain() async {
            engine.requestSubtitleDrainTick()
            while let pending = engine.subtitleDrainTickInFlight { await pending.value }
        }
        func harvest(_ pts: [Double]) {
            for time in pts {
                store.append(streamIndex: 0, ptsSeconds: time, durationSeconds: 2.5,
                             payload: Data("line at \(time)".utf8))
            }
        }
        var starts: [Double] {
            engine.subtitleCues.map { ($0.startTime * 100).rounded() / 100 }.sorted()
        }

        // Load at 46.2 s: the landing read runs from 27 s on.
        store.noteHarvestAnchor(.prefetch, at: 27)
        harvest([27.5, 29.4, 35, 38, 43.4, 48.85, 52.95])
        for through in stride(from: 37.0, through: 107, by: 10) {
            store.noteHarvestProgress(.prefetch, through: through)
        }
        engine.clock.sourceTime = 46.2
        engine.selectSubtitleTrack(index: 0)
        await drain()
        #expect(starts.first == 35, "the load's reset window starts at 31.2 s")

        // Seek to 0: the pump is anchored at the landing, nothing in front of the island is read yet.
        store.noteHarvestAnchor(.pump, at: 0)
        engine.clock.sourceTime = 0
        await drain()
        #expect(engine.subtitleDrainCursors[.primary]?.lastDecodedPts == -15,
                "the cursor waits at the window start, not on the far side of the island")

        // The landing read covers 0 to 30 s and finds the cues the load never read.
        store.noteHarvestAnchor(.prefetch, at: 0)
        harvest([7.25, 11.8, 18, 21.75, 25.25])
        store.noteHarvestProgress(.prefetch, through: 15)
        store.noteHarvestProgress(.prefetch, through: 30)
        engine.clock.sourceTime = 0.5
        await drain()
        #expect(Array(starts.prefix(7)) == [7.25, 11.8, 18, 21.75, 25.25, 27.5, 29.4])
    }
}
