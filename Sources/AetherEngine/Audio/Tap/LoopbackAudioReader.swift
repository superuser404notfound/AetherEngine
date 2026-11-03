import Foundation
import AVFAudio

/// #95: the native-path tap worker. Pulls the engine's own fMP4 segments from `SegmentCache`,
/// decodes their audio track near the playhead, and emits tap buffers. Runs on a dedicated
/// thread at utility QoS; touches only SegmentCache read APIs, so it cannot stall playback.
final class LoopbackAudioReader: @unchecked Sendable {

    struct Dependencies: @unchecked Sendable {
        /// Playlist-axis rendered position (renderedPositionMirror); nil before first render.
        let playhead: @Sendable () -> Double?
        /// Playlist-to-source shift at this moment (session.playlistShiftSeconds).
        let shiftSeconds: @Sendable () -> Double
        /// Segment index for a playlist time (provider.segmentIndex(forPlaylistTime:)).
        let anchorIndex: @Sendable (Double) -> Int
        /// Init blob for a segment index.
        let initData: @Sendable (Int) -> Data?
        /// Non-blocking segment bytes (cache.peek(index:)).
        let segmentData: @Sendable (Int) -> Data?
        /// Highest index the producer has ever stored (cache.highestStoredIndex).
        let highestStoredIndex: @Sendable () -> Int
        /// Decode one composed segment to playlist-axis chunks (AudioTapSegmentDecoder.decode).
        let decodeSegment: @Sendable (Data, Data) -> [AudioTapChunk]
        /// Deliver one tap buffer to the consumer stream.
        let emit: @Sendable (AudioTapBuffer) -> Void
    }

    enum StepResult: Equatable {
        case decoded      // decoded a segment or released held buffers
        case slept        // nothing to do right now
        case reanchored   // jumped to the playhead's segment; next step decodes there
    }

    /// Misses on a produced-but-unavailable segment before skipping it (eviction race).
    static let maxMissStreak = 3

    private let deps: Dependencies
    private let condition = NSCondition()
    private var stopped = false

    // Worker-thread state (only touched from the loop / runOnce).
    private var nextIndex: Int?
    private var lastDecodedEndPTS: Double?
    private var previousPlayhead: Double?
    private var held = AudioTapHeldBuffers()
    private var pendingDiscontinuity = true
    private var missStreak = 0

    init(deps: Dependencies) {
        self.deps = deps
    }

    func start() {
        let thread = Thread { [weak self] in
            while let self, !self.isStopped {
                if self.runOnce() != .decoded {
                    self.condition.lock()
                    if !self.stopped { self.condition.wait(until: Date().addingTimeInterval(0.25)) }
                    self.condition.unlock()
                }
            }
        }
        thread.name = "com.aetherengine.audiotap"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    /// One loop iteration. Internal (not private) so tests drive it directly.
    func runOnce() -> StepResult {
        let playhead = deps.playhead() ?? 0
        let decision = AudioTapPacing.decide(lastDecodedEndPTS: lastDecodedEndPTS, playhead: playhead,
                                             previousPlayhead: previousPlayhead,
                                             leadSeconds: AudioTapDefaults.leadSeconds,
                                             toleranceSeconds: AudioTapDefaults.toleranceSeconds)
        previousPlayhead = playhead

        switch decision {
        case .reanchor:
            nextIndex = deps.anchorIndex(playhead)
            lastDecodedEndPTS = nil
            held.clear()
            pendingDiscontinuity = true
            missStreak = 0
            return .reanchored
        case _ where !held.isEmpty:
            return releaseHeld(playhead: playhead) ? .decoded : .slept
        case .sleep:
            return .slept
        case .decodeNext:
            break
        }

        let idx = nextIndex ?? deps.anchorIndex(playhead)
        nextIndex = idx

        guard let segment = deps.segmentData(idx) else {
            if idx > deps.highestStoredIndex() {
                // Not produced yet: wait, the producer is behind us.
                missStreak = 0
                return .slept
            }
            // Produced but gone (eviction race). Tolerate a few polls, then skip it.
            missStreak += 1
            if missStreak >= Self.maxMissStreak {
                EngineLog.emit("[AudioTap] seg\(idx) evicted, skipping", category: .engine)
                nextIndex = idx + 1
                pendingDiscontinuity = true
                missStreak = 0
            }
            return .slept
        }
        missStreak = 0

        guard let initBlob = deps.initData(idx) else { return .slept }
        let chunks = deps.decodeSegment(initBlob, segment)
        guard !chunks.isEmpty else {
            // Undecodable segment (codec change mid-restart, corrupt fragment): skip it.
            EngineLog.emit("[AudioTap] seg\(idx) yielded no audio, skipping", category: .engine)
            nextIndex = idx + 1
            pendingDiscontinuity = true
            return .slept
        }

        let shift = deps.shiftSeconds()
        for chunk in chunks {
            held.append(start: chunk.ptsSeconds,
                        buffer: AudioTapBuffer(buffer: chunk.buffer,
                                               sourceTime: chunk.ptsSeconds + shift,
                                               discontinuity: pendingDiscontinuity,
                                               channels: chunk.channels))
            pendingDiscontinuity = false
        }
        nextIndex = idx + 1
        _ = releaseHeld(playhead: playhead)
        return .decoded
    }

    /// Releases the held buffers that fall inside the lead. `lastDecodedEndPTS` tracks what was
    /// emitted, so pacing measures the lead the consumer actually has.
    private func releaseHeld(playhead: Double) -> Bool {
        guard let end = held.release(before: playhead + AudioTapDefaults.leadSeconds,
                                     droppingEndsBefore: playhead - AudioTapDefaults.toleranceSeconds,
                                     emit: deps.emit) else { return false }
        lastDecodedEndPTS = end
        return true
    }
}
