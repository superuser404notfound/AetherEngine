import Foundation
import AVFAudio

/// #95 follow-up: network-sourced, playhead-following twin of LoopbackAudioReader for the
/// loadRemoteHLS path (which has no loopback producer/cache to read). VOD follows the playhead by
/// cumulative-EXTINF index; live edge-follows via HLSPlaylistTracker. Best-effort, lossy, never
/// stalls playback. sourceTime rides the reader's own cumulative clock (not container PTS), so it
/// aligns with nativeHost.currentTime on VOD and is rate-correct on live.
final class AudioTapHLSReader: @unchecked Sendable {

    struct Dependencies: @unchecked Sendable {
        let playhead: @Sendable () -> Double?
        let mediaURL: URL
        let fetchPlaylist: @Sendable (URL) async throws -> HLSMediaPlaylist
        let fetchSegment: @Sendable (_ uri: String, _ crypt: HLSSegmentCrypt?) async throws -> Data
        let decodeSegment: @Sendable (Data) -> [AudioTapChunk]
        let emit: @Sendable (AudioTapBuffer) -> Void
    }

    enum StepResult: Equatable { case decoded, slept, reanchored, finished }

    private let deps: Dependencies
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false

    // Stepping state (single ingest task).
    private var isVOD = false
    private var durations: [Double] = []
    private var cumulativeStart: [Double] = []     // playlist-axis start time per segment index
    private var playlist: HLSMediaPlaylist?
    private var tracker = HLSPlaylistTracker()
    private var nextIndex: Int?
    private var lastDecodedEndPTS: Double?          // end of the reader's cumulative clock
    private var lastEmittedEndPTS: Double?          // VOD pacing input: what the consumer has
    private var previousPlayhead: Double?
    private var held = AudioTapHeldBuffers()
    private var pendingDiscontinuity = true

    init(deps: Dependencies) { self.deps = deps }

    func start() {
        task = BlockingWork.detached(priority: .utility) { [self] in await run() }
    }

    func stop() {
        lock.lock(); stopped = true; let t = task; task = nil; lock.unlock()
        t?.cancel()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func run() async {
        guard let media = try? await deps.fetchPlaylist(deps.mediaURL) else { return }
        prime(playlist: media)
        while !isStopped {
            let step = isVOD ? await stepVOD() : await stepLive()
            if step == .finished { return }
            if step != .decoded {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Test seam: set VOD mode + durations without hitting the network.
    func primeForTest(playlist: HLSMediaPlaylist) { prime(playlist: playlist) }

    private func prime(playlist media: HLSMediaPlaylist) {
        playlist = media
        isVOD = media.hasEndList
        durations = media.segments.map { $0.duration }
        cumulativeStart = []
        var acc = 0.0
        for d in durations { cumulativeStart.append(acc); acc += d }
    }

    // MARK: - VOD (internal for await-driven tests)

    func stepVOD() async -> StepResult {
        guard let media = playlist else { return .finished }
        let playhead = deps.playhead() ?? 0
        let decision = AudioTapPacing.decide(lastDecodedEndPTS: lastEmittedEndPTS, playhead: playhead,
                                             previousPlayhead: previousPlayhead,
                                             leadSeconds: AudioTapDefaults.leadSeconds,
                                             toleranceSeconds: AudioTapDefaults.toleranceSeconds)
        previousPlayhead = playhead
        switch decision {
        case .reanchor:
            nextIndex = VideoSegmentProvider.segmentIndex(forPlaylistTime: playhead, durations: durations)
            lastDecodedEndPTS = nil
            lastEmittedEndPTS = nil
            held.clear()
            pendingDiscontinuity = true
            return .reanchored
        case _ where !held.isEmpty:
            return releaseHeld(playhead: playhead) ? .decoded : .slept
        case .sleep:
            return .slept
        case .decodeNext:
            break
        }
        let idx = nextIndex ?? VideoSegmentProvider.segmentIndex(forPlaylistTime: playhead, durations: durations)
        nextIndex = idx
        guard idx < media.segments.count else { return .slept }   // VOD end
        let segment = media.segments[idx]
        guard let bytes = try? await deps.fetchSegment(segment.uri, segment.crypt), !bytes.isEmpty else {
            nextIndex = idx + 1
            pendingDiscontinuity = true
            return .slept
        }
        let chunks = deps.decodeSegment(bytes)
        guard !chunks.isEmpty else { nextIndex = idx + 1; pendingDiscontinuity = true; return .slept }
        stamp(chunks: chunks, segmentStart: cumulativeStart[idx]) { start, buffer in
            held.append(start: start, buffer: buffer)
        }
        nextIndex = idx + 1
        _ = releaseHeld(playhead: playhead)
        return .decoded
    }

    private func releaseHeld(playhead: Double) -> Bool {
        guard let end = held.release(before: playhead + AudioTapDefaults.leadSeconds,
                                     droppingEndsBefore: playhead - AudioTapDefaults.toleranceSeconds,
                                     emit: deps.emit) else { return false }
        lastEmittedEndPTS = end
        return true
    }

    // MARK: - Live (internal for await-driven tests)

    func stepLive() async -> StepResult {
        guard let media = try? await deps.fetchPlaylist(deps.mediaURL) else { return .slept }
        prime(playlist: media)                // refresh window for the tracker
        let fresh = tracker.newSegments(in: media)
        guard !fresh.isEmpty else { return .slept }
        for segment in fresh {
            if isStopped { return .slept }
            if segment.discontinuityBefore { pendingDiscontinuity = true }
            guard let bytes = try? await deps.fetchSegment(segment.uri, segment.crypt), !bytes.isEmpty else {
                pendingDiscontinuity = true; continue
            }
            let chunks = deps.decodeSegment(bytes)
            if chunks.isEmpty { pendingDiscontinuity = true; continue }
            stamp(chunks: chunks, segmentStart: lastDecodedEndPTS ?? (deps.playhead() ?? 0)) { _, buffer in
                deps.emit(buffer)
            }
        }
        return .decoded
    }

    // MARK: - Stamp

    /// Stamp a segment's chunks on the reader's cumulative clock and hand each to `deliver` with
    /// its start. The first chunk after an anchor lands at `segmentStart` and carries the pending
    /// discontinuity; subsequent chunks continue from lastDecodedEndPTS so seams abut (the
    /// monotonic filter trims priming overlaps).
    private func stamp(chunks: [AudioTapChunk], segmentStart: Double,
                       deliver: (Double, AudioTapBuffer) -> Void) {
        var cursor = pendingDiscontinuity ? segmentStart : (lastDecodedEndPTS ?? segmentStart)
        for chunk in chunks {
            deliver(cursor, AudioTapBuffer(buffer: chunk.buffer, sourceTime: cursor,
                                           discontinuity: pendingDiscontinuity,
                                           channels: chunk.channels))
            pendingDiscontinuity = false
            cursor += Double(chunk.buffer.frameLength) / AudioTapDefaults.sampleRate
        }
        lastDecodedEndPTS = cursor
    }
}
