// Only with the DualLayerDolbyVision trait: the dual-layer route is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
@testable import AetherEngine

/// `OrderedDelivery` is one serial `.userInteractive` queue,
/// owned by the decoder, that both composed and bypassed frames go through on
/// their way to `onFrame`. These tests drive it directly — no decoder, no
/// GPU — to pin its three load-bearing guarantees: ticket order survives any
/// arrival order, an epoch bump (`reset`) is what makes flush/close's "nothing
/// from before this returns after" invariant (I3) hold, and a ticket that
/// never arrives costs exactly the one frame at the stall-guard threshold,
/// not the rest of the session.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OrderedDeliveryTests {

    private static func makeBuffer() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [:] as CFDictionary, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    /// Encodes an identifying number into a frame's PTS so a test can tell
    /// which ticket a delivery corresponds to without `DeliveredFrame`
    /// carrying the ticket itself (it deliberately does not — `emit` has no
    /// use for it).
    private static func frame(_ buffer: CVPixelBuffer, tag: Int64) -> DeliveredFrame {
        DeliveredFrame(buffer: SendableBuffer(value: buffer), pts: CMTime(value: tag, timescale: 1), hdr10Data: nil, dmNAL: nil)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var tags: [Int64] = []
        func record(_ pts: CMTime) { lock.lock(); tags.append(pts.value); lock.unlock() }
        var snapshot: [Int64] { lock.lock(); defer { lock.unlock() }; return tags }
        var count: Int { lock.lock(); defer { lock.unlock() }; return tags.count }
    }

    @Test("frames reach onFrame in ticket order no matter what order fulfil is called in")
    func deliversInTicketOrder() async throws {
        let buffer = try #require(Self.makeBuffer())
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.order")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }

        // Deliberately out of arrival order — this is what a composition that
        // finishes on the GPU out of order, or a bypass that races ahead of a
        // slower composition, looks like from `fulfil`'s point of view.
        for ticket in [3, 1, 0, 4, 2] {
            delivery.fulfil(ticket: UInt64(ticket), epoch: 0, Self.frame(buffer, tag: Int64(ticket)))
        }

        try await waitFor { recorder.count == 5 }
        #expect(recorder.snapshot == [0, 1, 2, 3, 4])
    }

    @Test("bypass-shaped and compose-shaped fulfil calls interleave through the same order, indistinguishably")
    func bypassAndComposeShareOneOrder() async throws {
        let buffer = try #require(Self.makeBuffer())
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.mixed")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }

        // A "bypass" is just a `fulfil` called synchronously on the pairing
        // thread; a "compose" is the same call from Metal's completion queue,
        // later. `OrderedDelivery` has no notion of which is which, so there is
        // one ordering mechanism, not two.
        delivery.fulfil(ticket: 0, epoch: 0, Self.frame(buffer, tag: 0)) // bypass, ticket 0
        delivery.fulfil(ticket: 2, epoch: 0, Self.frame(buffer, tag: 2)) // bypass, ticket 2, arrives immediately
        // Both have been handled before the "compose" for ticket 1 finishes: ticket 2 is pending.
        delivery.barrier()
        let lateFrame = Self.frame(buffer, tag: 1) // built outside the closure: `DeliveredFrame` is Sendable, `CVPixelBuffer` is not
        // A dedicated thread, not the global pool: blocking tests elsewhere in a full run can
        // starve GCD's workers for seconds, which made this test time out rather than reorder.
        Thread.detachNewThread {
            // "Compose" for ticket 1 finishes late, off a different thread.
            delivery.fulfil(ticket: 1, epoch: 0, lateFrame)
        }

        try await waitFor { recorder.count == 3 }
        #expect(recorder.snapshot == [0, 1, 2], "ticket 2 must wait behind the late ticket 1, whichever path produced it")
    }

    @Test("a ticket that is never fulfilled costs exactly one frame (the stall guard)")
    func stallGuardCostsExactlyOneFrame() async throws {
        let buffer = try #require(Self.makeBuffer())
        // Threshold = maxFramesInFlight + maxLayerSkew + 2 = 3 + 3 + 2 = 8,
        // matching production (`DoviFelComposer.maxFramesInFlight`,
        // `DualLayerVideoDecoder.maxLayerSkewFrames`).
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.stall")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }

        // Ticket 0 is never fulfilled — the composition it belonged to failed
        // to call back at all, the one failure mode a ticket, rather than a
        // bypass, cannot self-report. Tickets 1...12 arrive normally.
        for ticket in 1...12 {
            delivery.fulfil(ticket: UInt64(ticket), epoch: 0, Self.frame(buffer, tag: Int64(ticket)))
        }

        try await waitFor { recorder.count == 12 }
        #expect(recorder.count == 12, "every ticket but the missing one must still be delivered")
        #expect(recorder.snapshot == Array(1...12), "delivery order is unaffected beyond the one skipped ticket")
    }

    @Test("reset drops a stale-epoch delivery that is already pending when reset runs")
    func resetDropsStaleEpoch() async throws {
        let buffer = try #require(Self.makeBuffer())
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.epoch")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }

        // Ticket 0 never arrives (as if its base layer were still waiting for
        // a partner when a seek lands), so tickets 1 and 2 — tagged with the
        // pre-seek epoch — sit pending behind it.
        delivery.fulfil(ticket: 1, epoch: 0, Self.frame(buffer, tag: 1))
        delivery.fulfil(ticket: 2, epoch: 0, Self.frame(buffer, tag: 2))
        delivery.barrier() // both are now in `pending`

        // The seek: bump the epoch and fast-forward past every ticket issued
        // so far. `reset` is `queue.sync`, so this line does not return until
        // both `fulfil` calls above have already run to completion (they
        // deliver nothing, since ticket 0 is still missing and below the new
        // stall threshold) — this is invariant I3's mechanism, exercised
        // directly rather than through `DualLayerVideoDecoder.flush()`.
        delivery.reset(epoch: 1, nextTicket: 10)

        // A composition for the OLD epoch retiring late — e.g. a GPU command
        // buffer that was already committed before the seek — must never
        // reach `onFrame`, even though its ticket number (11) is not below
        // the new base ticket: only the epoch tells it from a live one.
        delivery.fulfil(ticket: 11, epoch: 0, Self.frame(buffer, tag: 11))
        // A fresh, post-seek ticket at `nextTicket` with the NEW epoch must
        // deliver normally. Ticket 11 would follow it if the epoch were ignored.
        delivery.fulfil(ticket: 10, epoch: 1, Self.frame(buffer, tag: 10))

        delivery.barrier()
        #expect(recorder.snapshot == [10], "only the post-reset ticket may reach onFrame; tickets 1 and 2 predate the reset and ticket 11 carries the old epoch")
    }

    @Test("a new-epoch ticket fulfilled before reset is (visibly) delivered is not lost")
    func newEpochTicketFulfilledBeforeResetIsDeliveredIsNotLost() async throws {
        // The sequence `fulfil(0...4, e0)`, `fulfil(5, e1)`, `reset(e1, 5)`,
        // `fulfil(6...13, e1)` loses ticket 5 and stalls 6...13 until the
        // stall guard skips it if `flush()` calls `reset` (synchronously,
        // `queue.sync`) only after a concurrent caller could already have
        // reached `fulfil` for the new epoch.
        //
        // `DualLayerVideoDecoder.flush()`/`close()` (see the comment atop
        // `flush()`) therefore call `resetAsync` — the non-blocking
        // half of `reset` — from INSIDE the same lock that makes issuing a
        // new-epoch ticket possible in the first place, so the reset is
        // always enqueued before any ticket that could race it. This test
        // drives that exact ordering directly against `OrderedDelivery`,
        // with no decoder involved: `resetAsync` is called first, and
        // `fulfil(5, epoch: 1, ...)` is called immediately after — before
        // anything has waited for `resetAsync`'s block to actually run, i.e.
        // "fulfilled before reset is delivered" — and ticket 5 must still
        // arrive, with nothing behind it held back either.
        //
        // Tickets 0...4 (epoch 0) are expected to drain and reach `onFrame`
        // normally before any of this runs — they were enqueued strictly
        // before `resetAsync`, so FIFO order alone (with no epoch mismatch
        // to drop them) delivers them first. The property under
        // test is only about ticket 5 onward.
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.post-flush-ticket")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }
        let buffer = try #require(Self.makeBuffer())

        for ticket in 0...4 {
            delivery.fulfil(ticket: UInt64(ticket), epoch: 0, Self.frame(buffer, tag: Int64(ticket)))
        }
        delivery.resetAsync(epoch: 1, nextTicket: 5)
        delivery.fulfil(ticket: 5, epoch: 1, Self.frame(buffer, tag: 5))
        for ticket in 6...13 {
            delivery.fulfil(ticket: UInt64(ticket), epoch: 1, Self.frame(buffer, tag: Int64(ticket)))
        }

        try await waitFor { recorder.count == 14 }
        #expect(recorder.snapshot == Array(0...13), "ticket 5 must not be lost, and 6...13 must not be held back waiting for it")
    }

    @Test("exactly the stall threshold's worth of pending frames does not trigger the stall guard")
    func stallGuardBoundaryDoesNotSkipAtExactlyTheThreshold() async throws {
        let buffer = try #require(Self.makeBuffer())
        // Threshold = maxFramesInFlight + maxLayerSkew + 2 = 3 + 3 + 2 = 8.
        // `drainReady`'s guard is `pending.count > stallThreshold` (strictly
        // greater), so exactly 8 pending behind the missing head-of-line
        // ticket must not be enough to skip it.
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.stall-boundary-no-skip")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }

        for ticket in 1...8 {
            delivery.fulfil(ticket: UInt64(ticket), epoch: 0, Self.frame(buffer, tag: Int64(ticket)))
        }
        // Every arrival has been handled, so ticket 0 would already have been (wrongly) skipped
        // while draining 1...8; there is no ninth arrival to trigger it.
        delivery.barrier()
        #expect(recorder.count == 0, "nothing may deliver while ticket 0, the head of the line, is still missing")

        delivery.fulfil(ticket: 0, epoch: 0, Self.frame(buffer, tag: 0))
        try await waitFor { recorder.count == 9 }
        #expect(recorder.snapshot == Array(0...8), "ticket 0 must not have been skipped at exactly 8 pending behind it")
    }

    @Test("a ticket that arrives late, but before the stall threshold is exceeded, still delivers in order")
    func lateTicketWithinThresholdDeliversInOrder() async throws {
        let buffer = try #require(Self.makeBuffer())
        let delivery = OrderedDelivery(maxFramesInFlight: 3, maxLayerSkew: 3, label: "test.ordered-delivery.late-ticket-in-order")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }

        // 7 pending behind the missing ticket 0 — one short of the 8-pending
        // stall-guard threshold — then ticket 0 arrives late, well inside
        // the window the guard tolerates.
        for ticket in 1...7 {
            delivery.fulfil(ticket: UInt64(ticket), epoch: 0, Self.frame(buffer, tag: Int64(ticket)))
        }
        delivery.barrier()
        delivery.fulfil(ticket: 0, epoch: 0, Self.frame(buffer, tag: 0))

        try await waitFor { recorder.count == 8 }
        #expect(recorder.snapshot == Array(0...7), "a late ticket within the stall threshold must still deliver, in order")
    }

    @Test("DEBUG: emit only ever runs on OrderedDelivery's own queue")
    func emitRunsOnItsOwnQueue() async throws {
        // `emit`'s `dispatchPrecondition(.onQueue(queue))` (DEBUG-only) traps
        // if this is ever violated. Driving a normal delivery through to
        // completion without crashing, from a suite that runs this alongside
        // every other `fulfil` call above, is the running proof that it never
        // fires — there is no path to `emit` except through `queue.async`/
        // `queue.sync` inside this class.
        let buffer = try #require(Self.makeBuffer())
        let delivery = OrderedDelivery(maxFramesInFlight: 1, maxLayerSkew: 0, label: "test.ordered-delivery.onqueue")
        let recorder = Recorder()
        delivery.setOnFrame { _, pts, _ in recorder.record(pts) }
        delivery.fulfil(ticket: 0, epoch: 0, Self.frame(buffer, tag: 0))
        try await waitFor { recorder.count == 1 }
        #expect(recorder.snapshot == [0])
    }
}
#endif
