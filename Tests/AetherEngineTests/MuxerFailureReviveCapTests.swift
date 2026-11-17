import Testing
import Foundation
@testable import AetherEngine

/// AE#366: the muxerFailed twin of the #169 arm. Once its gate was exhausted,
/// `handleVODMuxerFailure` logged "giving up (source not muxable in this session)" and returned
/// with a bare `return`: no producer, no restart, no error. The provider then answered
/// `404 init.mp4 empty` forever while AVPlayer sat in waitingToPlay, which reaches the viewer as a
/// permanent black screen. Its sibling `handleVODReadErrorExit`, 150 lines up the same file, has
/// surfaced its own exhaustion since #169.
@Suite("VOD muxerFailed revive-cap exhaustion")
struct MuxerFailureReviveCapTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _code: Int32?
        private var _reason: String?
        var code: Int32? {
            lock.lock(); defer { lock.unlock() }
            return _code
        }
        var reason: String? {
            lock.lock(); defer { lock.unlock() }
            return _reason
        }
        func set(_ code: Int32, _ reason: String) {
            lock.lock(); _code = code; _reason = reason; lock.unlock()
        }
    }

    private func makeEngine() -> HLSVideoEngine {
        HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/witness.mkv"), dvModeAvailable: false)
    }

    @Test("an exhausted muxer-failure gate surfaces onVODSourceFailed instead of dying silently")
    func exhaustedGateSurfacesFailure() {
        let engine = makeEngine()
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 0)
        let failed = Flag()
        engine.onVODSourceFailed = { code, reason, _ in failed.set(code, reason) }

        engine.handleVODMuxerFailure()

        #expect(failed.code == FFmpegErr.einval,
                "the cap-reached arm must surface the terminal failure to the host")
        // The reason travels with it: nothing was misread here, the moov could not be written, and a
        // host that reports "read failed" sends the viewer after the wrong thing.
        #expect(failed.reason == "Source audio cannot be muxed")
    }

    @Test("a failure inside the cap rebuilds instead of surfacing a terminal error")
    func admittedFailureDoesNotSurface() {
        let engine = makeEngine()
        engine.muxerFailureReviveGate = ReviveBudget(maxAttempts: 2)
        let failed = Flag()
        engine.onVODSourceFailed = { code, reason, _ in failed.set(code, reason) }

        engine.handleVODMuxerFailure()

        #expect(failed.code == nil,
                "a revive attempt is not a terminal failure; surfacing here would kill recoverable sessions")
    }
}

/// AE#366: where the seek-based moov prime looks when the forward scan comes back empty.
@Suite("Audio moov prime hunt positions")
struct MoovPrimeHuntPositionTests {

    @Test("positions stay inside the source and start at the midpoint")
    func positionsAreOrderedAndInBounds() {
        let duration = 8889.8   // the reported UHD remux
        let positions = HLSSegmentProducer.moovPrimeHuntPositions(durationSeconds: duration)
        #expect(positions.count == 4)
        #expect(positions.allSatisfy { $0 > 0 && $0 < duration })
        // Midpoint first: a track that is present throughout with wide gaps is found there in one
        // seek. The second probe is the far end, which is where a bulk-muxed legacy track sits.
        #expect(positions[0] == duration * 0.5)
        #expect(positions[1] > positions[0])
    }

    @Test("a source with no usable duration has nowhere to look")
    func degenerateDurationYieldsNoPositions() {
        #expect(HLSSegmentProducer.moovPrimeHuntPositions(durationSeconds: 0).isEmpty)
        #expect(HLSSegmentProducer.moovPrimeHuntPositions(durationSeconds: -1).isEmpty)
        #expect(HLSSegmentProducer.moovPrimeHuntPositions(durationSeconds: .infinity).isEmpty)
        #expect(HLSSegmentProducer.moovPrimeHuntPositions(durationSeconds: .nan).isEmpty)
    }
}
