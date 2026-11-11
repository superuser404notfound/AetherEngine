import Foundation

/// Decision core for the live feeder's audio look-ahead pump (#107 audio chopping).
///
/// The combined feeder loop paces on the VIDEO renderer's queue, so interleaved audio can
/// never build more lead over the synchronizer clock than the video queue allows (<1 s
/// measured). On devices where software 1080i decode + deinterlace runs near or below
/// real time, that lead is zero and every feeder stall is an audible dropout. The pump
/// feeds audio packets from the DVR ring ahead of the combined cursor, bounded by
/// `targetLeadSeconds`, so audio delivery is independent of video decode pace.
enum AudioLookaheadPolicy {
    /// Decoded-audio lead the pump maintains over the synchronizer clock. Bounds renderer
    /// memory (~1.5 MB PCM at 4 s stereo Float32 48 kHz) while surviving multi-second
    /// feeder stalls.
    static let targetLeadSeconds = 4.0

    /// Pre-arm packet budget per pump pass: enough to coax first buffers out of a
    /// delay-heavy decoder so the clock can arm, without racing through the whole ring
    /// when a track never produces output.
    static let preArmPacketBudget = 64

    enum Verdict: Equatable {
        case feed
        case stop
    }

    /// Live-edge underrun handling: when the source itself delivers below real time and the
    /// pump drains the ring at the edge, the free-running synchronizer clock would outrun the
    /// stream permanently (every later sample arrives in the clock's past = continuous
    /// chopping that never recovers). Pause the clock and rebuffer instead, exactly like the
    /// native path's AVPlayer stall handling.
    static let underrunPauseLeadSeconds = 0.15
    static let rebufferResumeLeadSeconds = 2.0

    /// AE#1025: a lead this far below zero means the clock has run a full second past the last
    /// audio fed, which an exactly-realtime origin (whose lead sits at its start offset) never
    /// reaches. It opens the on-demand pause arm for a source that is slower than real time from
    /// the first byte and therefore never builds `rebufferResumeLeadSeconds` to latch it.
    static let starvedLeadSeconds = -1.0

    /// Whether the software host's on-demand pause arm is open. It stays open once opened, until
    /// a seek resets it: either the source proved it can deliver a real lead, or it proved it
    /// cannot keep up at all.
    static func pauseArmOpens(wasOpen: Bool, lead: Double) -> Bool {
        wasOpen || lead >= rebufferResumeLeadSeconds || lead <= starvedLeadSeconds
    }

    enum ClockAction: Equatable {
        case none
        case pauseForRebuffer
        case resume
    }

    /// `bufferedAheadSeconds` is the media the source has delivered ahead of the clock, and
    /// `resumeCushionSeconds` how much of it a resume waits for (AE#813: a source that delivers a
    /// whole segment at a time would otherwise resume the moment a late segment lands, with nothing
    /// to cover the next one). nil waits for the audio lead alone.
    static func clockAction(
        rebuffering: Bool,
        lastFedAudioPTS: Double,
        clockSeconds: Double,
        atRingEnd: Bool,
        sourceEnded: Bool,
        bufferedAheadSeconds: Double = .infinity,
        resumeCushionSeconds: Double? = nil
    ) -> ClockAction {
        let lead = lastFedAudioPTS.isFinite ? lastFedAudioPTS - clockSeconds : 0
        if rebuffering {
            // sourceEnded: nothing more will arrive; resume and drain what is queued.
            if sourceEnded { return .resume }
            guard lead >= rebufferResumeLeadSeconds else { return .none }
            if let cushion = resumeCushionSeconds, !(bufferedAheadSeconds >= cushion) { return .none }
            return .resume
        }
        // Only a DRY ring at the edge is a source underrun. A low lead with packets still
        // in the ring is decode lag; the next pump pass refills it without touching the clock.
        return (atRingEnd && !sourceEnded && lead < underrunPauseLeadSeconds) ? .pauseForRebuffer : .none
    }

    static func decide(
        clockArmed: Bool,
        preArmPacketsFed: Int,
        lastFedAudioPTS: Double,
        clockSeconds: Double
    ) -> Verdict {
        guard clockArmed else {
            // Before arming the clock reads garbage, so lead is meaningless; feed a bounded
            // burst until the first decoded buffers arm it.
            return preArmPacketsFed < preArmPacketBudget ? .feed : .stop
        }
        // Deliberately not gated on renderer.isReadyForMoreMediaData: the audio renderer
        // flips it at ~1.5 s queued, but keeps buffering enqueues fine (AudioOutput.enqueue
        // is unconditional by design). The lead target is the actual bound.
        let lead = lastFedAudioPTS.isFinite ? lastFedAudioPTS - clockSeconds : 0
        return lead < targetLeadSeconds ? .feed : .stop
    }
}

/// Cursor + fed-PTS state for the audio look-ahead pump, shared between the feeder thread
/// (advances) and seek paths (reset alongside the combined feed cursor). Lock-guarded, safe
/// to capture in @Sendable closures.
final class AudioLookaheadState: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = 0
    private var lastFedPTS = Double.nan

    /// Reposition after a DVR seek (mirrors `setFeedCursor`). Clears the fed PTS so the
    /// next pump pass treats lead as zero instead of comparing against a pre-seek PTS.
    func reset(to seq: Int) {
        lock.lock()
        cursor = seq
        lastFedPTS = .nan
        lock.unlock()
    }

    /// Raise the cursor to at least `seq` (pump entry alignment with the combined cursor,
    /// self-heals after ring eviction clamps). Raising means the pump lost track of what
    /// was fed, so the stale fed PTS is cleared. Returns the aligned cursor.
    func align(to seq: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if cursor < seq {
            cursor = seq
            lastFedPTS = .nan
        }
        return cursor
    }

    /// Compare-and-advance from `old`; a concurrent seek reset wins and the fed PTS is not
    /// committed. `fedPTS` is nil for skipped (video / unreadable) entries.
    func advance(from old: Int, fedPTS: Double?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard cursor == old else { return false }
        cursor = old + 1
        if let fedPTS { lastFedPTS = fedPTS }
        return true
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return cursor
    }

    var lastFedAudioPTS: Double {
        lock.lock()
        defer { lock.unlock() }
        return lastFedPTS
    }
}
