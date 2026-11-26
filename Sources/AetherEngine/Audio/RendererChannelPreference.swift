import AVFoundation
import Foundation
import os

// Sodalite#256: the renderer paths write the session's channel preference, and the preference is
// process-wide. Nothing handed it back, so it outlived the session that wrote it. Measured on an
// Apple TV 4K into a Sonos Arc: after a software-host 5.1 title (preference 6), the next stereo title
// on the native path arrived at the bar as Multichannel PCM 5.1, every time, until the app restarted.
// Writing the launch value back before that title brought PCM 2.0 back, twice out of twice. A fresh
// process starts at 0, which means "no preference".
//
// So the value from before the first renderer write is kept here and written back when the last
// engine that wrote one leaves the renderer paths: on a final teardown, and when an engine moves on to
// AVPlayer video (which leaves the preference to AVKit) without stopping first.

/// Pure: the counts to ask for, best first. tvOS does not fall back to the next smaller layout when the
/// HDMI sink cannot take a count as LPCM, it stays in stereo: on a Sonos Arc a preference of 8 threw
/// -50 and left 2 output channels, while 6 gave 6. A 7.1 source therefore tries 5.1 next.
nonisolated func channelPreferenceLadder(wanted: Int) -> [Int] {
    wanted > 6 ? [wanted, 6] : [wanted]
}

/// Pure: whether the next rung is worth a write, given what the session made of the last one.
nonisolated func channelPreferenceShouldStepDown(outputAfterWrite: Int, nextRung: Int) -> Bool {
    outputAfterWrite < nextRung
}

/// Where a ladder ended, so a later route change does not climb back up to the count the sink refused.
struct LandedChannelPreference: Equatable, Sendable {
    let wanted: Int
    let maxOutput: Int
    let landed: Int
}

/// Process-wide record of what the renderer paths did to the session's channel preference. Read and
/// written from the session transition queue (off the main actor), hence the lock.
nonisolated final class ChannelPreferenceLedger: Sendable {
    static let shared = ChannelPreferenceLedger()

    private struct State {
        var baseline: Int?
        var landed: LandedChannelPreference?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Keeps the value the session held before the first renderer write. Later writes keep the first.
    func noteBeforeWrite(preferredNow: Int) {
        state.withLock { if $0.baseline == nil { $0.baseline = preferredNow } }
    }

    func noteLanded(_ landed: LandedChannelPreference) {
        state.withLock { $0.landed = landed }
    }

    var landed: LandedChannelPreference? { state.withLock { $0.landed } }

    /// The value to write back, nil when no renderer wrote one since the last restore. Clears both.
    func takeBaseline() -> Int? {
        state.withLock { s in
            defer { s = State() }
            return s.baseline
        }
    }
}

extension AetherEngine {

    /// The renderer activation and the route-change refresh both write through here.
    func holdRendererChannelPreference() {
        SharedOutputCoordinator.shared.holdChannelPreference(ObjectIdentifier(self))
    }

    /// Hands the channel preference back once no engine on a renderer path still holds one. Runs on
    /// the session transition queue, so it lands before a release queued after it (the session must be
    /// active for the write to count) and before the next renderer activation.
    func releaseRendererChannelPreference(reason: String) {
        guard SharedOutputCoordinator.shared.releaseChannelPreference(ObjectIdentifier(self)) else { return }
        #if os(iOS) || os(tvOS)
        _ = enqueueAudioSessionTransition {
            AetherEngine.restoreChannelPreferenceBaseline(reason: reason)
        }
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// Writes `wanted`, or the next rung of the ladder when the session answers with fewer channels
    /// than that rung. Returns the count that stayed written.
    @discardableResult
    nonisolated static func writeRendererChannelPreference(wanted: Int, maxOutput: Int, reason: String) -> Int {
        let session = AVAudioSession.sharedInstance()
        let ledger = ChannelPreferenceLedger.shared
        ledger.noteBeforeWrite(preferredNow: session.preferredOutputNumberOfChannels)
        let ladder = channelPreferenceLadder(wanted: wanted)
        var landed = session.preferredOutputNumberOfChannels
        for (index, rung) in ladder.enumerated() {
            let next = index + 1 < ladder.count ? ladder[index + 1] : nil
            do {
                try session.setPreferredOutputNumberOfChannels(rung)
            } catch {
                // The Arc answers 8 with -50 (and the property reads 8 anyway), so a throw is a
                // refusal like a short output, not the end of the ladder.
                EngineLog.emit("[AetherEngine] \(reason): channel preference \(rung) refused (\(error))\(next.map { ", trying \($0)" } ?? "")", category: .engine)
                continue
            }
            landed = rung
            let output = session.outputNumberOfChannels
            guard let next, channelPreferenceShouldStepDown(outputAfterWrite: output, nextRung: next) else { break }
            EngineLog.emit("[AetherEngine] \(reason): preference \(rung) gave output=\(output), trying \(next)", category: .engine)
        }
        ledger.noteLanded(LandedChannelPreference(wanted: wanted, maxOutput: maxOutput, landed: landed))
        return landed
    }

    nonisolated static func restoreChannelPreferenceBaseline(reason: String) {
        guard let baseline = ChannelPreferenceLedger.shared.takeBaseline() else { return }
        let session = AVAudioSession.sharedInstance()
        let before = session.preferredOutputNumberOfChannels
        guard before != baseline else { return }
        do {
            try session.setPreferredOutputNumberOfChannels(baseline)
            EngineLog.emit("[AetherEngine] \(reason): channel preference handed back \(before) -> \(baseline) (output=\(session.outputNumberOfChannels))", category: .engine)
        } catch {
            EngineLog.emit("[AetherEngine] \(reason): channel preference hand-back to \(baseline) failed: \(error)", category: .engine)
        }
    }
    #endif
}
