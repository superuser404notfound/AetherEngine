import Testing
@testable import AetherEngine

/// Sodalite#256: a renderer path's channel preference outlived its session and turned the next
/// stereo title into Multichannel PCM 5.1 at a Sonos Arc. The session itself does not exist off
/// device, so these pin the decisions around it: who hands the value back, which value, and the
/// 8 -> 6 step-down for a sink that answers a refused count with stereo.
@Suite("Sodalite#256: channel preference hand-back")
@MainActor
struct Sodalite256ChannelPreferenceHandBackTests {

    private final class Token {}
    private let tokenA = Token()
    private let tokenB = Token()
    private var a: ObjectIdentifier { ObjectIdentifier(tokenA) }
    private var b: ObjectIdentifier { ObjectIdentifier(tokenB) }

    @Test("a lone holder hands the preference back when it lets go", .timeLimit(.minutes(3)))
    func loneHolder() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.holdChannelPreference(a)
        #expect(c.releaseChannelPreference(a))
        // A second release (final teardown after a native load already let go) owes nothing.
        #expect(!c.releaseChannelPreference(a))
    }

    @Test("an engine that never wrote a preference hands nothing back", .timeLimit(.minutes(3)))
    func nonHolder() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        #expect(!c.releaseChannelPreference(a))
    }

    @Test("with two renderer tiles, only the last one out hands it back", .timeLimit(.minutes(3)))
    func lastHolderOut() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        c.holdChannelPreference(a)
        c.holdChannelPreference(b)
        #expect(!c.releaseChannelPreference(a))
        #expect(c.releaseChannelPreference(b))
    }

    @Test("a native tile leaving does not take the preference from a software tile", .timeLimit(.minutes(3)))
    func nativeTileLeaving() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        c.holdChannelPreference(a)
        #expect(!c.releaseChannelPreference(b))
        #expect(c.releaseChannelPreference(a))
    }

    @Test("the value from before the first write is the one handed back", .timeLimit(.minutes(3)))
    func baselineIsTheFirst() {
        let ledger = ChannelPreferenceLedger()
        #expect(ledger.takeBaseline() == nil)
        ledger.noteBeforeWrite(preferredNow: 0)
        ledger.noteBeforeWrite(preferredNow: 6)
        ledger.noteLanded(LandedChannelPreference(wanted: 8, maxOutput: 32, landed: 6))
        #expect(ledger.takeBaseline() == 0)
        // Taken once: the next renderer session records its own starting value.
        #expect(ledger.takeBaseline() == nil)
        #expect(ledger.landed == nil)
    }

    @Test("7.1 tries 5.1 next; 5.1 and stereo have no lower rung", .timeLimit(.minutes(3)))
    func ladder() {
        #expect(channelPreferenceLadder(wanted: 8) == [8, 6])
        #expect(channelPreferenceLadder(wanted: 7) == [7, 6])
        #expect(channelPreferenceLadder(wanted: 6) == [6])
        #expect(channelPreferenceLadder(wanted: 2) == [2])
    }

    @Test("a step-down happens only when the session gave fewer channels than the next rung", .timeLimit(.minutes(3)))
    func stepDown() {
        // Sonos Arc, measured: 8 gave output 2.
        #expect(channelPreferenceShouldStepDown(outputAfterWrite: 2, nextRung: 6))
        // A 7.1 receiver takes 8; a sink that gave 6 by itself needs no second write.
        #expect(!channelPreferenceShouldStepDown(outputAfterWrite: 8, nextRung: 6))
        #expect(!channelPreferenceShouldStepDown(outputAfterWrite: 6, nextRung: 6))
    }

    @Test("a route change does not climb back to the count the sink refused", .timeLimit(.minutes(3)))
    func landedStepDownHolds() {
        let landed = LandedChannelPreference(wanted: 8, maxOutput: 32, landed: 6)
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 6, sourceChannels: 8, maxOutput: 32, landed: landed) == nil)
        // A different route (other maximum) gets the full count again.
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 6, sourceChannels: 8, maxOutput: 8, landed: landed) == 8)
        // A different source on the same route is a new question too.
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 6, sourceChannels: 2, maxOutput: 32, landed: landed) == 2)
    }
}
