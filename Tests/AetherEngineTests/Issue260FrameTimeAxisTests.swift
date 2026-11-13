import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

// MARK: - Fixtures

/// Fixtures/ is local-only by design (gitignored; Scripts/fetch-fixtures.sh regenerates the
/// synthetic clips). The tests skip via `.enabled(if:)` when a clip is absent, e.g. on CI.
private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// The observer fires on the pump thread; the test reads from its own.
private final class FrameTimeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [NativeVideoFrameTime] = []

    func record(_ frame: NativeVideoFrameTime) {
        lock.lock(); frames.append(frame); lock.unlock()
    }

    func snapshot() -> [NativeVideoFrameTime] {
        lock.lock(); defer { lock.unlock() }; return frames
    }
}

// MARK: - Tests

/// AE#260: per-frame presentation times on both axes. The witness clip is H.264 with `-bf 3`, so its
/// first muxed frame sits two frames off the item axis (`playlistShiftSeconds` = -0.083333 s at 24 fps),
/// which is exactly what makes the two axes distinguishable here.
@Suite("Issue 260 native frame time axes", .serialized)
struct Issue260FrameTimeAxisTests {

    @Test("Every frame reports source and item, separated by the producer shift",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func framesCarryBothAxes() throws {
        let collector = FrameTimeCollector()
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        engine.setNativeVideoFrameTimeObserver { collector.record($0) }
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)

        #expect(prov.mediaSegment(at: 0) != nil)
        #expect(prov.mediaSegment(at: 1) != nil)

        let frames = collector.snapshot()
        try #require(!frames.isEmpty, "no frame times emitted")

        // Vacuum guard: with a zero separation the two axes coincide and the witness proves nothing.
        // AE#418 round 5: read it off the PAIR, not off `playlistShiftSeconds`. Since 6.56.6 the
        // published axis states where AVPlayer PLACES the segment (the presented offset), while the
        // pair here is what the muxer wrote; on a pinned gate those were one number and this guard
        // read the wrong one the moment they parted.
        let deltas = frames.map { CMTimeGetSeconds($0.source) - CMTimeGetSeconds($0.item) }
        let shift = try #require(deltas.first)
        try #require(abs(shift) > 0.001,
                     "source and item coincide on this clip; the axis witness would be vacuous")

        for frame in frames {
            let delta = CMTimeGetSeconds(frame.source) - CMTimeGetSeconds(frame.item)
            #expect(abs(delta - shift) < 0.001,
                    "frame at source \(CMTimeGetSeconds(frame.source))s: source - item = \(delta)s, expected the producer shift \(shift)s")
        }

        // The first muxed frame is the gating keyframe, and it does NOT sit at item time 0: the shift
        // anchors the segment's tfdt on its DTS, while the reported time is the PTS, which under B-frame
        // reorder leads the DTS by the reorder distance. That distance IS the shift on this clip, so the
        // first frame lands at exactly -shift. Assuming item 0 here is the mistake this API prevents.
        #expect(frames[0].isKeyframe, "the first muxed frame is the gating keyframe")
        let firstItem = CMTimeGetSeconds(frames[0].item)
        #expect(abs(firstItem - (-shift)) < 0.001,
                "first muxed frame should sit at item time \(-shift)s (the reorder distance), got \(firstItem)s")
        #expect(frames.allSatisfy { CMTimeGetSeconds($0.item) >= 0 },
                "no muxed frame may carry a negative item timestamp")
    }

    /// Documented contract: delivery is decode order, so `source` is not monotonic under B-frames and a
    /// consumer that wants a frame-boundary list has to sort. A fixture without reorder would let a
    /// consumer assume monotonicity and be right by accident.
    @Test("Delivery is decode order, not presentation order",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func deliveryIsDecodeOrder() throws {
        let collector = FrameTimeCollector()
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        engine.setNativeVideoFrameTimeObserver { collector.record($0) }
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)
        #expect(prov.mediaSegment(at: 0) != nil)

        let sources = collector.snapshot().map { CMTimeGetSeconds($0.source) }
        try #require(sources.count > 4, "not enough frames to judge ordering")
        let hasReorder = zip(sources, sources.dropFirst()).contains { $0 > $1 }
        #expect(hasReorder,
                "expected B-frame reorder in the delivered sequence; got \(sources.prefix(8))")
    }

    /// A restart re-muxes segments from its start index forward under a fresh shift. The epoch is how a
    /// consumer tells the rewritten frames from the ones it recorded before.
    @Test("A restart opens a new epoch and reports the seam it starts at",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func restartOpensNewEpoch() async throws {
        let collector = FrameTimeCollector()
        let seams = SeamCollector()
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        engine.setNativeVideoFrameTimeObserver { collector.record($0) }
        engine.onPlaylistShiftChanged = { shift, seamItemSeconds in
            seams.record(shift: shift, at: seamItemSeconds)
        }
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)

        #expect(prov.mediaSegment(at: 0) != nil)
        #expect(prov.mediaSegment(at: 1) != nil)
        let firstEpoch = try #require(collector.snapshot().last?.epoch)

        engine.requestRestart(at: 1)

        try await waitFor { collector.snapshot().contains { $0.epoch > firstEpoch } }
        let restarted = collector.snapshot().filter { $0.epoch > firstEpoch }

        // The restart producer starts at segment 1, so its seam sits at that segment's item-axis start,
        // not at 0: a seam of 0 would collapse the history exactly like the pre-#260 behaviour.
        let recorded = seams.snapshot()
        try #require(recorded.count >= 2, "expected an initial shift plus a restart shift, got \(recorded)")
        #expect(abs(recorded[0].at) < 0.001, "the first producer anchors at item 0, got \(recorded[0].at)s")
        #expect(recorded[1].at > 1.0,
                "restart at segment 1 must report its own item-axis start, got \(recorded[1].at)s")

        // And the restarted frames land at or after that seam on the item axis.
        let seamAt = recorded[1].at
        for frame in restarted {
            #expect(CMTimeGetSeconds(frame.item) >= seamAt - 0.001,
                    "restarted frame at item \(CMTimeGetSeconds(frame.item))s precedes its seam \(seamAt)s")
        }
    }
}

private final class SeamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(shift: Double, at: Double)] = []

    func record(shift: Double, at: Double) {
        lock.lock(); entries.append((shift, at)); lock.unlock()
    }

    func snapshot() -> [(shift: Double, at: Double)] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}
