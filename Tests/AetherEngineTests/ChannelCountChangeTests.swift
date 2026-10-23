import Testing
@testable import AetherEngine

/// F4: the renderer paths rewrite their channel preference when the route's maximum changes. The
/// notification exists on iOS and tvOS only; the tests drive the reaction with injected session values.
@Suite("F4: output channel count change")
@MainActor
struct ChannelCountChangeTests {

    private func engine(software: Bool = true) throws -> AetherEngine {
        let engine = try AetherEngine()
        if software { engine.softwareHost = SoftwarePlaybackHost(videoGravity: .resizeAspect) }
        return engine
    }

    @Test("the preference is the source count capped by what the route can output")
    func preferenceMath() {
        #expect(preferredOutputChannels(sourceChannels: 8, maxOutput: 8) == 8)
        #expect(preferredOutputChannels(sourceChannels: 8, maxOutput: 2) == 2)
        #expect(preferredOutputChannels(sourceChannels: 2, maxOutput: 8) == 2)
        #expect(preferredOutputChannels(sourceChannels: nil, maxOutput: 6) == 6)
    }

    @Test("a 7.1 receiver switching to 2.0 speakers lowers the preference, and back")
    func routeFlips() {
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 8, sourceChannels: 8, maxOutput: 2) == 2)
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 2, sourceChannels: 8, maxOutput: 8) == 8)
    }

    @Test("an unchanged preference is not rewritten, so a repeated notification ends at the first no-op")
    func repeatedNotificationsAreNoOps() {
        var preferred = 8
        var writes = 0
        for _ in 0..<5 {
            if let wanted = AetherEngine.channelPreferenceTarget(preferredNow: preferred, sourceChannels: 8, maxOutput: 2) {
                preferred = wanted
                writes += 1
            }
        }
        #expect(writes == 1)
    }

    @Test("a stereo source is never presented as 8 channels, even on a 7.1 route")
    func stereoSourceStaysStereo() {
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 2, sourceChannels: 2, maxOutput: 8) == nil)
    }

    @Test("an unknown source follows the route maximum, as activation does")
    func unknownSource() {
        #expect(AetherEngine.channelPreferenceTarget(preferredNow: 2, sourceChannels: nil, maxOutput: 6) == 6)
    }

    @Test("only renderer paths own the preference")
    func ownership() throws {
        let native = try AetherEngine()
        defer { native.stop() }
        #expect(!native.ownsChannelPreference)
        let sw = try engine()
        defer { sw.stop() }
        #expect(sw.ownsChannelPreference)
    }
}
