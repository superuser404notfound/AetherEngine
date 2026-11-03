// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import os

/// A `CVPixelBuffer` (or the display metadata riding with it) on its way across a
/// queue boundary.
///
/// `CVPixelBuffer` is a CoreFoundation class and not `Sendable`, but the handoff
/// is a baton pass: whichever thread produced the buffer (a VideoToolbox output
/// thread, or Metal's completion queue) stops touching it the moment it is handed
/// to ``OrderedDelivery``, and `emit` is the only reader after that. The box
/// states that rather than making the surrounding types unchecked.
struct SendableBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

/// One frame ready to reach the display layer, composed or bypassed alike
/// (dolby-vision-fel.md §5.7).
///
/// Everything `OrderedDelivery.emit` needs is resolved and carried here
/// *before* the frame reaches the delivery queue: `dmNAL` and `hdr10Data` are
/// looked up once, under the decoder's lock, at the same point pairing decides
/// what happens to the frame (mirroring how `hdr10Data` already arrives as a
/// parameter rather than a cache lookup). That is what lets `emit` attach
/// metadata and call `onFrame` without reaching into the decoder's frame state.
/// (`emit` itself may briefly take the decoder's lock through `onFrame`, as the
/// decoder's own `reportDecodedFormat` does on this queue; what is guaranteed is the
/// other direction, below.)
struct DeliveredFrame: Sendable {
    let buffer: SendableBuffer
    let pts: CMTime
    let hdr10Data: Data?
    /// The Profile 8.1 `unspec62` NAL (with its 2-byte header) for this frame,
    /// or nil if none was cached for its PTS. See `DoviDisplayMetadata.attach`.
    let dmNAL: [UInt8]?
}

/// Ordered, single-owner delivery of decoded and composed frames to the host
/// (dolby-vision-fel.md §5.7).
///
/// Every outgoing frame — composed on the GPU or bypassed straight from
/// pairing — reaches the display layer through ``fulfil(ticket:epoch:_:)``.
/// One serial queue, `qos: .userInteractive`, orders both kinds the same way
/// once they reach it, and `emit` — the Dolby Vision attachment plus
/// `onFrame` — runs there with **no lock held by this type**, and the invariant
/// the decoder keeps in return is that nothing ever holds its lock while waiting on this
/// queue (`fulfil` is non-blocking, `barrier()` is called only after unlocking), so a
/// delivery that takes the decoder's lock briefly can never deadlock against it.
/// Delivering under the decoder's `NSRecursiveLock` would call
/// `emit` (and with it the renderer's `enqueue`, which takes its own lock)
/// from inside that lock, one frame away from nesting it inside whatever lock
/// the host's `onFrame` takes. `OrderedDelivery` shares no state with the
/// decoder's lock: every field below is confined to `queue`.
///
/// `DoviFelComposer` keeps a small relay queue of its own
/// (`deliveryQueue`), which every composed frame's completion still hops
/// through before it ever calls `fulfil`. That queue is a §4.3 firewall
/// against Metal's completion handler ever blocking, not a second ordering
/// mechanism — `fulfil` reorders by ticket no matter which thread or queue
/// calls it, so a bypass calling in directly from a VideoToolbox thread and
/// a composition arriving via that relay hop are indistinguishable once
/// they reach `queue`. See `DualLayerVideoDecoder.swift`'s `orderedDelivery`
/// doc and dolby-vision-fel.md §5.7, §5.9 for the full justification.
///
/// **Epochs instead of moving the line under a lock.** A ticket carries the
/// epoch it was issued in. ``reset(epoch:nextTicket:)`` bumps `epoch` and
/// fast-forwards `nextToEmit` with `queue.sync`, which waits for anything
/// already running or queued ahead of it to finish first. A composition
/// already committed to the GPU when `flush()`/`close()` runs still calls
/// `fulfil` later, from Metal's completion handler, tagged with the *old*
/// epoch; by then `self.epoch` has moved on, so it is dropped instead of
/// reaching `onFrame`. That is invariant I3 (dolby-vision-fel.md §5.12), and it holds
/// without the decoder ever blocking on the GPU or the delivery queue while
/// holding its own lock.
///
/// **`resetAsync`/`barrier`: the same guarantee, callable under a lock.**
/// `reset` cannot be called while `DualLayerVideoDecoder.lock` is held — it
/// would block a `queue.sync` under a lock, the exact shape I8 forbids — but
/// `flush()`/`close()` still need the epoch bump ordered *with* the ticket
/// issuance it retires (a ticket for the new epoch, issued the instant the lock that raised it is
/// released, must never be able to reach `fulfil` before the matching reset
/// has even been enqueued). ``resetAsync(epoch:nextTicket:)`` is the
/// non-blocking half — a plain `queue.async`, safe to call from inside a
/// lock — and ``barrier()`` is the wait, called after the lock is released.
/// Because both the reset and the racing ticket's eventual `fulfil` can only
/// reach `queue` in an order `lock` already fixed (nothing can issue a
/// ticket for the new epoch until the critical section that called
/// `resetAsync` has unlocked), FIFO ordering on `queue` does the rest: the
/// reset is always ahead of it. `reset` itself is just
/// `resetAsync` + an immediate `barrier()`, kept for callers (tests, mainly)
/// that have no lock to hold and want the old synchronous call.
///
/// **Stall guard.** A ticket that never arrives (a bug, or a completion that
/// silently failed) would otherwise stall every later frame forever, since
/// `nextToEmit` never finds it. Once more than `maxFramesInFlight + K + 2`
/// frames are backed up behind the head of the line — more than could ever be
/// legitimately in flight at once — the missing ticket is skipped and logged.
/// A lost ticket costs one frame, not the session.
final class OrderedDelivery: @unchecked Sendable {

    private static let signpostLog = OSLog(subsystem: EngineLog.subsystem, category: "dovi.delivery")

    private let queue: DispatchQueue

    // Confined to `queue`: no lock. Nothing outside this class ever reads or
    // writes these, including the decoder that owns this instance.
    private var epoch: UInt64 = 0
    private var nextToEmit: UInt64 = 0
    private var pending: [UInt64: PendingEntry] = [:]
    private var onFrame: DecodedFrameHandler?
    /// One-shot-per-stall latch so a run of consecutive missing tickets logs
    /// once for the event rather than once per skipped ticket.
    private var stallLogPending = false

    private let pendingCountLock = NSLock()
    private var pendingCount: Int = 0
    private var peakPendingCount: Int = 0

    private struct PendingEntry {
        /// Nil for a ticket that is given up on: it takes its place in line and emits nothing.
        let frame: DeliveredFrame?
        let signpostID: OSSignpostID
    }

    /// A ticket that has waited this many frames behind the head of the line
    /// with no sign of arriving is presumed lost (dolby-vision-fel.md §5.7): sized off the
    /// most frames that can legitimately be outstanding at once — GPU slots
    /// plus pairing skew — with two more of margin.
    private let stallThreshold: Int

    init(maxFramesInFlight: Int, maxLayerSkew: Int, label: String = "de.superuser404.dovi.delivery") {
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
        self.stallThreshold = maxFramesInFlight + maxLayerSkew + 2
    }

    /// Installs (or, at `close()`, clears) the host callback. Runs on `queue`
    /// so it is ordered against in-flight `fulfil` calls exactly like every
    /// other piece of state here — a handler installed before any frame is
    /// paired is guaranteed to be in place before the first `emit`, and one
    /// cleared by `close()` cannot race a frame still draining out of the
    /// queue.
    ///
    /// This is `queue.async`, not `queue.sync`: `close()` (and
    /// `DualLayerVideoDecoder.onFrame`'s setter) can return before `onFrame`
    /// is actually cleared here. That is harmless: nothing can reach `emit` after `close()`'s own
    /// `reset`/`barrier` pair has returned, old-epoch or new, so there is no
    /// window in which a stale handler could still fire; this call clearing
    /// a beat later just means the closure is retained a beat longer.
    func setOnFrame(_ handler: DecodedFrameHandler?) {
        queue.async { [self] in
            onFrame = handler
        }
    }

    /// Hands one frame's place in line to the queue. Callable from any thread
    /// — a VideoToolbox output thread for a bypass, Metal's completion queue
    /// for a composition — with no lock held on either side of the call.
    ///
    /// `epoch` is read by the caller under the decoder's lock at the moment
    /// the ticket was issued (dolby-vision-fel.md §5.7: "a ticket carries the epoch it was
    /// issued in"). It is compared here, on `queue`, against the epoch
    /// `reset` last installed; a mismatch means a flush or close happened in
    /// between and this frame predates it.
    func fulfil(ticket: UInt64, epoch callerEpoch: UInt64, _ frame: DeliveredFrame) {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Delivery", signpostID: signpostID,
                    "ticket=%{public}llu", ticket)
        queue.async { [self] in
            guard callerEpoch == epoch, ticket >= nextToEmit else {
                os_signpost(.end, log: Self.signpostLog, name: "Delivery", signpostID: signpostID, "dropped")
                return
            }
            pending[ticket] = PendingEntry(frame: frame, signpostID: signpostID)
            updatePendingCounts()
            drainReady()
        }
    }

    /// Gives up the frame holding `ticket`: it keeps its place in line, so the frames behind it are not held
    /// up, but nothing is emitted for it. Used when a composition failed after it had started writing into
    /// the buffer it would have delivered, which leaves nothing that is safe to show. Same epoch rules as
    /// ``fulfil(ticket:epoch:_:)``.
    func skip(ticket: UInt64, epoch callerEpoch: UInt64) {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Delivery", signpostID: signpostID,
                    "ticket=%{public}llu skipped", ticket)
        queue.async { [self] in
            guard callerEpoch == epoch, ticket >= nextToEmit else {
                os_signpost(.end, log: Self.signpostLog, name: "Delivery", signpostID: signpostID, "dropped")
                return
            }
            pending[ticket] = PendingEntry(frame: nil, signpostID: signpostID)
            updatePendingCounts()
            drainReady()
        }
    }

    /// Bumps the epoch and fast-forwards the head of the line to `nextTicket`,
    /// dropping anything still pending behind it. Enqueues the work
    /// (`queue.async`) rather than waiting for it, so this is safe to call
    /// while holding a lock — see the type doc's "resetAsync/barrier"
    /// section and ``barrier()``.
    ///
    /// The caller is responsible for the ordering guarantee this depends on:
    /// nothing that could produce a ticket for `newEpoch` may be able to run
    /// until *after* the call to this method has returned (in
    /// `DualLayerVideoDecoder`, that is what holding `lock` across this call
    /// provides — pairing cannot issue a new-epoch ticket until the same
    /// critical section that calls this has unlocked). Given that, FIFO
    /// ordering on `queue` guarantees this reset always runs before any
    /// `fulfil` for the epoch it installs, however soon that `fulfil` is
    /// called after this method returns.
    func resetAsync(epoch newEpoch: UInt64, nextTicket: UInt64) {
        queue.async { [self] in
            for entry in pending.values {
                os_signpost(.end, log: Self.signpostLog, name: "Delivery", signpostID: entry.signpostID, "reset")
            }
            epoch = newEpoch
            nextToEmit = nextTicket
            pending.removeAll()
            stallLogPending = false
            pendingCountLock.lock()
            pendingCount = 0
            peakPendingCount = 0
            pendingCountLock.unlock()
        }
    }

    /// Blocks until everything enqueued on `queue` ahead of this call —
    /// every `fulfil` and `resetAsync` already running or waiting, in
    /// particular the one a caller just enqueued — has finished running.
    ///
    /// This is `reset`'s wait, split out so `resetAsync` can be enqueued
    /// under a lock and this can be called after releasing it: waiting here
    /// while still holding `DualLayerVideoDecoder.lock` would be exactly the
    /// blocking-wait-under-a-lock shape I8 forbids. The precondition catches
    /// the one way to defeat the wait itself: calling this from inside
    /// `onFrame`, which would deadlock the queue against its own
    /// synchronous wait.
    func barrier() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
    }

    /// `resetAsync` followed immediately by `barrier()`: bumps the epoch and
    /// fast-forwards the head of the line to `nextTicket`, and does not
    /// return until that has actually happened — nothing after this call
    /// returns can reach `onFrame` under the old epoch (invariant I3,
    /// dolby-vision-fel.md §5.8). For callers with no lock to hold across the two halves (tests,
    /// mainly); `DualLayerVideoDecoder.flush()`/`close()` call `resetAsync`
    /// and `barrier()` separately so the wait happens outside `lock`.
    func reset(epoch newEpoch: UInt64, nextTicket: UInt64) {
        resetAsync(epoch: newEpoch, nextTicket: nextTicket)
        barrier()
    }

    /// Emits every ticket that has become the head of the line, in order,
    /// applying the stall guard when the head is missing and a bound number
    /// of frames have backed up behind it. Runs on `queue`.
    private func drainReady() {
        defer { updatePendingCounts() }
        while true {
            if let entry = pending.removeValue(forKey: nextToEmit) {
                nextToEmit &+= 1
                stallLogPending = false
                if let frame = entry.frame { emit(frame) }
                os_signpost(.end, log: Self.signpostLog, name: "Delivery", signpostID: entry.signpostID)
                continue
            }
            guard pending.count > stallThreshold else { break }
            // The ticket at the head is not coming: skip it so the frames
            // already backed up behind it are not stalled forever
            // (dolby-vision-fel.md §5.7). This costs exactly the one frame at `nextToEmit`.
            if !stallLogPending {
                EngineLog.emit(
                    "[OrderedDelivery] stall guard: ticket \(nextToEmit) never arrived with \(pending.count) frames pending; skipping",
                    category: .swPlayback)
                stallLogPending = true
            }
            // Straight to the oldest frame that did arrive: stepping one missing ticket per turn
            // spins the queue once per number when the backlog sits far ahead of the head.
            guard let oldest = pending.keys.min(), oldest > nextToEmit else {
                nextToEmit &+= 1
                continue
            }
            nextToEmit = oldest
        }
    }

    /// Attaches the Dolby Vision display metadata and hands the frame to the
    /// host (see `dolby-vision-fel.md §4.1`). Runs on `queue`, holding no lock of this
    /// type's. `onFrame` may take the decoder's lock for a moment; that cannot deadlock because
    /// no caller of `fulfil`/`resetAsync` holds a lock while waiting on `queue` (only `barrier()`
    /// and `reset()` wait, and they are called with no decoder lock held).
    private func emit(_ frame: DeliveredFrame) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
        DoviDisplayMetadata.attach(rpuNAL: frame.dmNAL, to: frame.buffer.value)
        onFrame?(frame.buffer.value, frame.pts, frame.hdr10Data)
    }

    private func updatePendingCounts() {
        pendingCountLock.lock()
        let count = pending.count
        pendingCount = count
        if count > peakPendingCount {
            peakPendingCount = count
        }
        pendingCountLock.unlock()
    }

    /// Peak count of pending frames waiting in the delivery queue since the last read.
    /// Resets the peak to the current pending count for the next interval (dolby-vision-fel.md §5.11).
    func takePeakPendingCount() -> Int {
        pendingCountLock.lock()
        defer { pendingCountLock.unlock() }
        let peak = peakPendingCount
        peakPendingCount = pendingCount
        return peak
    }

    /// Current count of pending frames waiting in the delivery queue without blocking `queue`.
    var currentPendingCount: Int {
        pendingCountLock.lock()
        defer { pendingCountLock.unlock() }
        return pendingCount
    }

    // MARK: - Test seams

    /// `queue.sync` reads for `DualLayerVideoDecoder.stateSnapshotForTesting`
    /// and its `onFrame` getter (never on a hot path — nothing in production
    /// reads the handler back, only assigns it).
    ///
    /// Every accessor below is
    /// `queue.sync`, same as `reset`/`barrier`. Reading any of them — in
    /// particular `currentOnFrame`, which backs `DualLayerVideoDecoder.
    /// onFrame`'s getter — from inside a closure already running on `queue`
    /// (i.e. from inside `emit`, or a host `onFrame` implementation that
    /// reads the decoder's own `onFrame` back) deadlocks, the same
    /// `dispatchPrecondition(.notOnQueue)` violation `reset`/`barrier` guard
    /// against explicitly. Nothing in this codebase does that today — the
    /// getter exists for the host to read what it itself assigned, not for
    /// `onFrame`'s body to call back into — so there is no precondition
    /// here, only this note.
    var pendingCountForTesting: Int { queue.sync { pending.count } }
    var nextToEmitForTesting: UInt64 { queue.sync { nextToEmit } }
    var hasOnFrameForTesting: Bool { queue.sync { onFrame != nil } }
    var currentOnFrame: DecodedFrameHandler? { queue.sync { onFrame } }
}
#endif
