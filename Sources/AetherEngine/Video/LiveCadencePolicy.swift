import Foundation

/// Turns the OBSERVED arrival cadence of a live ingest source (`LiveArrivalCadenceMeter`, surfaced by the
/// reader as `LiveIngestSourceInfo.observedLiveCadenceSeconds`) into two LL-HLS decisions, re-evaluated on
/// every manifest render. Replaces trusting the upstream's self-reported `#EXT-X-TARGETDURATION`, which a
/// bursty relay/IPTV origin under-reports, leaving blocking-reload wrongly enabled until the held
/// `?_HLS_msn=` reload trips `-15410` (AetherEngine#167).
///
/// Gate (blocking-reload eligibility): starts OFF; latches ON only after `disciplineObservationSeconds` of
/// uninterrupted disciplined cadence; latches permanently OFF (terminal `.bursty`) the moment a burst is
/// observed. The monotonic OFF -> ON -> OFF(terminal) path is deliberate: ON<->OFF flapping would itself
/// trip `-15410` as AVPlayer's in-flight blocking reload straddles the advert change, and a source that was
/// disciplined long enough to earn the ON is very unlikely to burst afterwards.
///
/// Floor (`#EXT-X-TARGETDURATION`): the monotonic max of observed cadence, seeded by the self-reported TD
/// (a valid *lower* bound on segment duration, just not on delivery cadence), so AVPlayer's 1.5x-TD
/// unchanged-playlist patience always covers the real inter-batch gap (anti `-12888`).
///
/// Thread-safe: read from the server's socket-handling threads on each render.
final class LiveCadencePolicy: @unchecked Sendable {
    enum GateState { case observing, disciplined, bursty }

    private let observe: @Sendable () -> Double?
    private let clock: @Sendable () -> Double
    private let burstThresholdSeconds: Double
    private let disciplineObservationSeconds: Double

    private let lock = NSLock()
    private var state: GateState = .observing
    private var firstObservationTime: Double?
    private var maxObservedCadence: Double

    /// - Parameters:
    ///   - observe: reader's current `observedLiveCadenceSeconds`; nil until the first upstream arrival.
    ///   - cutTargetSeconds: local segment cut target; the burst threshold is 1.5x it (matching the prior
    ///     self-reported gate so disciplined sources behave identically once proven).
    ///   - disciplineObservationSeconds: sustained clean-cadence window required before enabling
    ///     blocking-reload.
    ///   - initialFloorSeconds: self-reported upstream TARGETDURATION, used only as a lower bound on the
    ///     floor (never as evidence of discipline).
    ///   - clock: monotonic seconds; injectable for tests.
    init(
        observe: @escaping @Sendable () -> Double?,
        cutTargetSeconds: Double,
        disciplineObservationSeconds: Double = 12,
        initialFloorSeconds: Double? = nil,
        clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    ) {
        self.observe = observe
        self.clock = clock
        self.burstThresholdSeconds = cutTargetSeconds * 1.5
        self.disciplineObservationSeconds = disciplineObservationSeconds
        self.maxObservedCadence = max(0, initialFloorSeconds ?? 0)
    }

    /// Advance the latch and the running floor from a fresh observation. Idempotent for a given
    /// (cadence, now): the max only grows and the state only advances, so the two per-render reads
    /// (gate + floor) cannot disagree or double-count.
    private func advanceLocked() {
        let now = clock()
        guard let cadence = observe() else { return }
        if firstObservationTime == nil { firstObservationTime = now }
        maxObservedCadence = max(maxObservedCadence, cadence)
        switch state {
        case .bursty:
            break
        case .observing:
            if cadence > burstThresholdSeconds {
                state = .bursty
            } else if let t0 = firstObservationTime, now - t0 >= disciplineObservationSeconds {
                state = .disciplined
            }
        case .disciplined:
            if cadence > burstThresholdSeconds { state = .bursty }
        }
    }

    var blockingReloadEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return state == .disciplined
    }

    var targetDurationFloorSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        advanceLocked()
        return maxObservedCadence > 0 ? maxObservedCadence : nil
    }
}
