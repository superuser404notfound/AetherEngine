import Foundation

/// #357: one line stating what a subtitle drain tick did with the packets it found, so that
/// "nothing appeared on screen" can be attributed from outside instead of guessed at.
///
/// The report this exists for read the absence of `[applySubtitleEvent #N]` lines as proof that
/// cue delivery had died. That line could not carry the claim, for three reasons that are worth
/// keeping written down, because each of them is a way a diagnostic can lie by omission:
///
/// - It was capped at 20 emissions per `load()`. A session went blind after the twentieth event
///   and every seek after that landed unobserved, which reads exactly like permanent starvation.
/// - It is emitted BEFORE `applyEventMutations`, so it sits ahead of the stale-arrival gate, the
///   reconstruction hold, the PGS trim and the sorted insert. It witnesses that an event carrying
///   cues was decoded, never that a cue reached the overlay.
/// - It skips events without cues, and a zero-object PGS clear is exactly that: the composition
///   that RETIRES the visible line. The one event class that changes the screen to empty was the
///   one class the log could not show.
///
/// `SubtitleResolutionStatement` (#250) does not answer this either, and deliberately so: it states
/// how far determination reaches, not what was delivered. Its `decodedThrough` rides the drain
/// cursor, which advances over every packet handed to the decoder whether or not the decoder built
/// anything from it. A window of packets that all fail to decode therefore advances the resolution
/// line at full pace while the screen stays as it was. That combination is unremarkable in the log
/// and is the shape every "resolution keeps up but nothing renders" report has had.
///
/// So the counts here are per tick and pre-interpretation: packets found, events decoded, cues
/// carried, cues the gate admitted, cues the store actually took. The outcome label is a reading
/// aid over those numbers, never a substitute for them.
enum SubtitleDeliveryStatement {

    /// What a tick did. Each case is a different diagnosis and they are mutually exclusive by
    /// construction, so a line names exactly one.
    enum Outcome: String, Sendable {
        /// The channel has a drain target and no decoder could be built for it. Nothing this
        /// channel ever does can reach the overlay, and until this line existed that state was
        /// completely silent: the tick simply skipped the channel.
        case noDecoder
        /// No packets in the drain window. The store has not been fed here yet (or never will be:
        /// a genuine gap in the authored track looks identical and only `#250 via=` can tell them
        /// apart).
        case empty
        /// Packets were handed to the decoder and none produced an event. A drain decoder is
        /// rebuilt at the backscan start of every reset, so on a bitmap track this is the signature
        /// of entering an epoch mid-way: sets whose palette or objects were established before the
        /// window cannot be composed. The cursor advances anyway, which is why nothing else reports
        /// this state.
        case undecodable
        /// Events decoded and carried cues, and the gate published none of them. Either the
        /// reconstruction pass is still holding its candidate active line, or the #100 stale hold
        /// is waiting for a successor to close an open-ended window. Both are designed states with
        /// designed exits; a tick STUCK here across a whole seek sequence is not.
        case held
        /// The gate passed the cues and the retained store already had them. The normal outcome of
        /// re-decoding a region a backward seek landed in, and not a failure of anything.
        case duplicate
        /// Events decoded and carried no cues at all. On PGS that is a clear composition, whose
        /// whole job is to take the line off screen.
        case trimOnly
        /// Cues reached the retained array.
        case published
        /// #362: the tick stopped at a hole in the harvest and decoded nothing past it. A designed
        /// wait until the far side is due, not a failure, but it has to name itself: without this line a
        /// held tick reads as `empty`, which says the store was never fed here when in fact it was
        /// fed on both sides and the middle is on its way.
        case harvestHole
    }

    /// The per-tick counts, in the order the tick produces them. Kept as plain numbers rather than
    /// a verdict: every interpretation this file makes is reversible from the line, which is the
    /// property the diagnostic it replaces did not have.
    struct Tally: Equatable, Sendable {
        /// Stored packets inside the drain window that this tick handed to the decoder. Bounded by
        /// the #271 batch cap, so it is what the tick attempted, not what the window holds.
        var packets = 0
        /// Packets that decoded into an event (a composition, or a clear carrying only a trim).
        var events = 0
        /// Cues those events carried.
        var cues = 0
        /// Cues the stale-arrival gate passed through, including a finalized reconstruction
        /// candidate and any held cue its successor resolved.
        var admitted = 0
        /// Cues the sorted insert actually took. Lower than `admitted` means the store already held
        /// them, which is information rather than loss.
        var published = 0
        /// Whether the gate is still mid-reconstruction when the tick ends. A pass that never ends
        /// holds every composition behind the playhead, so this is the one piece of gate state the
        /// counts cannot imply.
        var reconstructing = false
        /// Set when the tick could not build a decoder for the channel at all.
        var decoderMissing = false
        /// #362: where the tick stopped because the harvest has a hole there, nil when it read its
        /// whole window. The position is the point of the line: it says which stretch of the source
        /// is waiting, so a report can be matched against the producer's own log.
        var harvestGapAt: Double? = nil
        /// #362 round 2: bitmap cues this tick left open because the only packet the store held
        /// after them lay past the harvest's designed reach, so it is not evidence of a successor.
        /// The reason this is a line of its own: `harvestGapAt` reports where DELIVERY stopped, and
        /// a report about a cue that ends too late is about the END, which is derived from the same
        /// store on a different horizon. A window carrying a wrong end with `gapAt` absent said
        /// nothing at all until this count existed (the reporter's observation, exactly).
        var endsWithheld = 0
        /// #416: bitmap events this tick refused to let claim the landing, because the source
        /// between the set and the playhead was never read and an empty store there is not
        /// evidence of anything. Its own field for the same reason `endsWithheld` has one: a
        /// refusal that only shows up as a missing cue is indistinguishable from a delivery that
        /// never arrived, and those two have opposite next steps.
        var landingWithheld = 0

        /// Cues an event carried that the gate did not pass. The subtraction is safe: `admitted`
        /// can exceed the tick's own `cues` when a finalized candidate seeded by an earlier tick is
        /// emitted, and that is a delivery, not a negative hold.
        var held: Int { max(0, cues - admitted) }

        var outcome: Outcome {
            if decoderMissing { return .noDecoder }
            // #362 before `empty`: a held tick decodes nothing by decision, and the two states have
            // opposite answers to "is anything coming".
            if packets == 0, harvestGapAt != nil { return .harvestHole }
            if packets == 0 { return .empty }
            if events == 0 { return .undecodable }
            if published > 0 { return .published }
            if cues == 0 { return .trimOnly }
            if admitted > 0 { return .duplicate }
            return .held
        }
    }

    /// What applying one decoded event did to a channel's retained cue array. Replaces the bare
    /// `changed` flag the apply path used to return: the flag is enough to decide whether to
    /// publish, and not enough to tell a gate hold from a store that already had the cue. Those two
    /// look identical from outside and mean opposite things.
    struct Application: Equatable, Sendable {
        /// Whether the array changed at all, including by a trim that closed an open window. Drives
        /// publication exactly as the old `Bool` did.
        var changed = false
        /// Cues the gate passed to the insert.
        var admitted = 0
        /// Cues the insert took. `admitted - published` is the re-decode the store deduped.
        var published = 0
        /// #416: events whose behind-playhead cues were refused the landing for want of read
        /// ground. Counted here so the tick can total it into the delivery line.
        var landingWithheld = 0
    }

    struct Statement: Equatable, Sendable {
        /// The same fence #250 uses. A delivery count under a superseded generation describes a
        /// position the user has already left.
        var fence: SubtitleResolutionStatement.Fence
        var streamIndex: Int32
        /// Source-time playhead the tick planned its window with. Deliberately `sourceTime` and not
        /// `currentTime`: cue timestamps are absolute source PTS, and on any session with a
        /// playlist shift the two axes differ by seconds.
        var playhead: Double
        var tally: Tally
    }

    /// Emit on a change of outcome, on a reset tick, and on a channel's first tick. Not per tick:
    /// the drainer runs at 2 Hz per channel, and a line for every tick would bury the moment the
    /// class changed under hundreds that said the same thing. A reset tick always states itself
    /// because the post-seek window is what every report of this class is actually about, and its
    /// outcome must never have to be inferred from silence.
    static func shouldEmit(outcome: Outcome, last: Outcome?, isReset: Bool) -> Bool {
        isReset || last != outcome
    }

    static func format(_ statement: Statement) -> String {
        let tally = statement.tally
        let fields: [String] = [
            "[AetherEngine] #357 subtitle-delivery",
            "loadGen=\(statement.fence.loadGeneration)",
            "seekGen=\(statement.fence.seekGeneration)",
            "stream=\(statement.streamIndex)",
            "playhead=\(String(format: "%.2f", statement.playhead))",
            "packets=\(tally.packets)",
            "events=\(tally.events)",
            "cues=\(tally.cues)",
            "admitted=\(tally.admitted)",
            "published=\(tally.published)",
            "held=\(tally.held)",
            "recon=\(tally.reconstructing ? 1 : 0)",
            "outcome=\(tally.outcome.rawValue)",
        ]
        var trailing: [String] = []
        if let gapAt = tally.harvestGapAt {
            trailing.append("gapAt=\(String(format: "%.2f", gapAt))")
        }
        if tally.endsWithheld > 0 {
            trailing.append("endsWithheld=\(tally.endsWithheld)")
        }
        if tally.landingWithheld > 0 {
            trailing.append("landingWithheld=\(tally.landingWithheld)")
        }
        return (fields + trailing).joined(separator: " ")
    }

    /// Budget for the per-cue `[applySubtitleEvent #N]` line, refilled per seek generation.
    ///
    /// The old budget was per `load()`, which made the line useless for the only question anyone
    /// asks of it: does delivery resume at a seek landing? Twenty events of ordinary playback
    /// exhaust it long before the first interesting seek, and the silence afterwards is
    /// indistinguishable from starvation. Refilling per generation bounds the log the same way
    /// while leaving every landing observable, including the twenty-third.
    struct EventBudget: Equatable, Sendable {
        let limit: Int
        private var generation: UInt64?
        private var spent = 0

        init(limit: Int = 20) {
            self.limit = limit
        }

        /// Claim one line for `generation`, refilling first if the generation moved. A generation
        /// that goes BACKWARDS also refills: the counters only move forward in a session, so an
        /// unequal value means a different one either way.
        mutating func claim(generation: UInt64) -> Bool {
            if self.generation != generation {
                self.generation = generation
                spent = 0
            }
            guard spent < limit else { return false }
            spent += 1
            return true
        }
    }
}
