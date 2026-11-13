import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

/// Fixtures/ is local-only by design (gitignored; Scripts/fetch-fixtures.sh regenerates the
/// synthetic clips). The fixture-backed test skips via `.enabled(if:)` when a clip is absent, e.g. on CI.
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

private final class EpochCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [NativeVideoFrameTime] = []

    func record(_ frame: NativeVideoFrameTime) {
        lock.lock(); frames.append(frame); lock.unlock()
    }

    func snapshot() -> [NativeVideoFrameTime] {
        lock.lock(); defer { lock.unlock() }; return frames
    }
}

private final class GenerationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SoftwareVideoFrameTime] = []

    var values: [SoftwareVideoFrameTime] {
        lock.lock(); defer { lock.unlock() }; return storage
    }

    func append(_ value: SoftwareVideoFrameTime) {
        lock.lock(); storage.append(value); lock.unlock()
    }
}

/// AE#314: the frame-time discriminators are ordered process-wide, not per session.
///
/// Both public frame-time types document the same rule: a higher value retires everything recorded
/// under a lower one. A `load()` builds a new session and a new renderer, so per-instance counters made
/// that rule invert at exactly the seam it is needed at, and a host that ordered by it dropped the new
/// item's frames for as long as the item played.
///
/// Every assertion here is an inequality on purpose. The sequences are process-wide, so a test running
/// in parallel legitimately consumes values in between; consecutive values are not part of the contract.
@Suite("Frame-time sequences across loads (#314)")
struct Issue314FrameTimeSequenceTests {

    // MARK: - The allocator

    @Test("the sequence is strictly increasing and never zero")
    func sequenceIsStrictlyIncreasing() {
        let sequence = FrameTimeSequence()
        let values = (0..<8).map { _ in sequence.next() }

        #expect(values.first == 1, "the first value must outrank an unset UInt64")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// Two sessions overlap while the outgoing one unwinds, so the allocator is read from two threads
    /// that no engine-side lock covers together. A dropped increment would hand two producers the same
    /// epoch, which is the one value ordering cannot separate.
    @Test("concurrent draws never collide")
    func concurrentDrawsAreUnique() {
        let sequence = FrameTimeSequence()
        let sink = ValueSink()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<500 { sink.append(sequence.next()) }
        }

        let drawn = sink.values
        #expect(drawn.count == 4000)
        #expect(Set(drawn).count == 4000, "two callers were handed the same value")
    }

    // MARK: - Software path

    /// The load seam, without media: a load builds a new `SampleBufferRenderer`, and the outgoing one
    /// has usually flushed at least once (any seek during the previous item). A renderer counting from
    /// zero therefore came up *below* the one it replaces, and a host applying the documented rule
    /// discarded every frame of the new item.
    @Test("a new renderer reports above the one it replaces")
    @MainActor
    func newRendererOutranksTheOutgoingOne() throws {
        let outgoing = SampleBufferRenderer()
        let outgoingFrames = GenerationCollector()
        outgoing.setFrameEnqueuedObserver { outgoingFrames.append($0) }

        outgoing.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 5.0, preferredTimescale: 600))
        outgoing.drainReorderBuffer()
        outgoing.flush(removingDisplayedImage: false)   // a seek in the outgoing item
        outgoing.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 60.0, preferredTimescale: 600))
        outgoing.drainReorderBuffer()
        let outgoingGeneration = try #require(outgoingFrames.values.last?.generation)

        let incoming = SampleBufferRenderer()           // the load
        let incomingFrames = GenerationCollector()
        incoming.setFrameEnqueuedObserver { incomingFrames.append($0) }
        incoming.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 0.0, preferredTimescale: 600))
        incoming.drainReorderBuffer()
        let incomingGeneration = try #require(incomingFrames.values.first?.generation)

        #expect(incomingGeneration > outgoingGeneration,
                "new item reported generation \(incomingGeneration), outgoing item was at \(outgoingGeneration)")

        // And a frame the outgoing renderer still hands over ranks below the new item, so it is retired
        // by the new item's first report rather than retiring it.
        outgoing.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 61.0, preferredTimescale: 600))
        outgoing.drainReorderBuffer()
        let straggler = try #require(outgoingFrames.values.last?.generation)
        #expect(straggler < incomingGeneration,
                "straggler reported \(straggler), which outranks the new item's \(incomingGeneration)")
    }

    // MARK: - Native path

    /// Same seam on the native path, where the sessions are real: two `HLSVideoEngine` instances stand
    /// in for the two sides of a `load()`, which is exactly how the engine builds them.
    @Test("a new native session reports above the one it replaces",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func newNativeSessionOutranksTheOutgoingOne() async throws {
        let outgoingFrames = EpochCollector()
        let outgoing = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        outgoing.setNativeVideoFrameTimeObserver { outgoingFrames.record($0) }
        _ = try outgoing.start()
        defer { outgoing.stop() }
        let outgoingProvider = try #require(outgoing.provider)
        #expect(outgoingProvider.mediaSegment(at: 0) != nil)
        let outgoingEpoch = try #require(outgoingFrames.snapshot().last?.epoch)

        // The next item. The outgoing session is deliberately still alive here: that is the state the
        // host sees while its pump unwinds, and the state the per-instance counter got wrong.
        let incomingFrames = EpochCollector()
        let incoming = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        incoming.setNativeVideoFrameTimeObserver { incomingFrames.record($0) }
        _ = try incoming.start()
        defer { incoming.stop() }
        let incomingProvider = try #require(incoming.provider)
        #expect(incomingProvider.mediaSegment(at: 0) != nil)
        let incomingEpoch = try #require(incomingFrames.snapshot().first?.epoch)

        #expect(incomingEpoch > outgoingEpoch,
                "new session opened at epoch \(incomingEpoch), the outgoing one was at \(outgoingEpoch)")

        // A restart in the new session still outranks its own first epoch, so the within-session rule
        // (#260) is untouched by the process-wide draw.
        incoming.requestRestart(at: 1)
        try await waitFor { incomingFrames.snapshot().contains { $0.epoch > incomingEpoch } }
    }

    // MARK: - Helpers

    private final class ValueSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []
        var values: [UInt64] {
            lock.lock(); defer { lock.unlock() }; return storage
        }
        func append(_ value: UInt64) {
            lock.lock(); storage.append(value); lock.unlock()
        }
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
}
