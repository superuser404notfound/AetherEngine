import Foundation
import AVFAudio

/// #95: lifecycle owner for one audio tap. Owns the AsyncStream continuation and (on the native
/// path) the LoopbackAudioReader. One per engine; re-install replaces it. MainActor like the
/// engine itself; the yield closure it vends is Sendable and safe from any thread.
@MainActor
final class AudioTapController {

    /// Registration hook the caller uses to hand back a stop closure for whatever it started.
    typealias StartReader = (_ onStop: (@escaping () -> Void) -> Void) -> Void

    /// The readers release at most tolerance + lead (12 s) ahead of the playhead, about 120
    /// buffers at the 100 ms chunk floor (#864). Twice that, so a consumer that keeps pace never
    /// loses one. A consumer that falls behind keeps what is queued and loses what arrives while
    /// the queue is full, and the first buffer after that gap carries `discontinuity`: shedding
    /// the oldest instead would drop a buffer the next one cannot be flagged against, since it is
    /// already queued.
    nonisolated static let streamCapacity = 256

    private var continuation: AsyncStream<AudioTapBuffer>.Continuation?
    private var filter: AudioTapMonotonicFilter?
    private var stopReader: (() -> Void)?
    private var torndown = false

    /// Build the stream and let the caller start its delivery source. `startReader` runs
    /// synchronously; it registers a stop closure via its callback.
    func makeStream(startReader: StartReader) -> AsyncStream<AudioTapBuffer> {
        let (stream, cont) = AsyncStream.makeStream(of: AudioTapBuffer.self,
                                                    bufferingPolicy: .bufferingOldest(Self.streamCapacity))
        continuation = cont
        filter = AudioTapMonotonicFilter(downstream: { buf in
            if case .dropped = cont.yield(buf) { return false }
            return true
        })
        startReader { [weak self] stop in self?.stopReader = stop }
        // The weak capture belongs on the outer closure. Written on the inner Task it was
        // decorative: `self` was still strongly captured here, so the continuation this
        // controller owns retained the controller back. Every path releases the controller
        // through `teardown()` (removeAudioTap, load, stop), so the strong reference bought
        // nothing, and a future path that drops it without tearing down would have kept the
        // reader running instead of stopping it.
        cont.onTermination = { [weak self] _ in
            // Consumer cancelled (broke the for-await loop): tear down from the MainActor.
            Task { @MainActor in self?.teardown() }
        }
        return stream
    }

    /// Thread-safe delivery closure for the reader / SW sink. Nil once torn down.
    func makeYield() -> (@Sendable (AudioTapBuffer) -> Void)? {
        guard !torndown, let filter else { return nil }
        return { buf in filter.accept(buf) }
    }

    /// True when startReader registered a running delivery source. False means nothing will
    /// ever yield (no session, no audio track): the caller finishes the stream immediately.
    var hasDeliverySource: Bool { stopReader != nil }

    func teardown() {
        guard !torndown else { return }
        torndown = true
        stopReader?()
        stopReader = nil
        continuation?.finish()
        continuation = nil
        filter = nil
    }
}
