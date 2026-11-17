import Foundation
import Testing
@testable import AetherEngine

/// AE#588: the master-refusal latch had no way to expire.
///
/// `panelRefusedHDRMaster` records that AVFoundation refused an HDR master, which is a fact about an
/// output CONFIGURATION rather than about the panel. The user changes that configuration in Settings,
/// the platform reports nothing when they do, and an Apple TV can hold the same app process for days,
/// so a latch taken in a mode that genuinely refused kept routing every HDR title media-direct long
/// after the mode was changed back. Measured by classicjazz on #459: two boxes with identical panel
/// readouts, one serving the master and one not, and a force-quit curing the second one.
///
/// Reaching the output format means leaving the app, so a real return from the background is the one
/// event guaranteed to follow the change. The latch is forgotten there and re-earned, at the price of
/// one in-place media fallback, by the next HDR load that is still refused.
@Suite(.serialized)
struct Issue588RefusalLatchLifetimeTests {

    /// Restore the process-wide latch, so a failing expectation cannot leak into another test.
    private func withLatch(_ latched: Bool, _ body: () throws -> Void) rethrows {
        let previous = AetherEngine.panelRefusedHDRMaster
        defer { AetherEngine.panelRefusedHDRMaster = previous }
        AetherEngine.panelRefusedHDRMaster = latched
        try body()
    }

    @Test("A refusal taken under an output format that no longer exists does not survive the return")
    func theLatchDoesNotSurviveAForegroundReturn() {
        withLatch(true) {
            AetherEngine.clearPanelRefusalOnForegroundReturn()
            #expect(AetherEngine.panelRefusedHDRMaster == false)
        }
    }

    /// The reporter's cure, without the force-quit. Same panel, same three other terms, and the route
    /// comes back the moment the latch does not answer for a configuration that is gone.
    @Test("After the clear, an unproven but eligible panel is offered the master again")
    func theRouteRecoversWithoutARestart() {
        withLatch(true) {
            #expect(AetherEngine.sessionRoutesAsHDRPanel(
                panelPresentsHDR: false,
                attemptWhenUnproven: true,
                displayEligibleForHDR: true,
                panelRefusedHDRMaster: AetherEngine.panelRefusedHDRMaster) == false)

            AetherEngine.clearPanelRefusalOnForegroundReturn()

            #expect(AetherEngine.sessionRoutesAsHDRPanel(
                panelPresentsHDR: false,
                attemptWhenUnproven: true,
                displayEligibleForHDR: true,
                panelRefusedHDRMaster: AetherEngine.panelRefusedHDRMaster))
        }
    }

    @Test("Clearing a latch nobody set changes nothing")
    func clearingAnUnsetLatchIsANoOp() {
        withLatch(false) {
            AetherEngine.clearPanelRefusalOnForegroundReturn()
            #expect(AetherEngine.panelRefusedHDRMaster == false)
        }
    }

    /// `didBecomeActive` also fires after a resign that never backgrounded the app (a system alert, a
    /// volume HUD), and the user cannot have reached Settings in that gap. Clearing there would spend
    /// the fallback for nothing, so the observer reads the background flag it is about to clear and
    /// acts only on a real return. A policy test cannot see a notification, so this one reads the site.
    @Test("Only a real return from the background clears it, not every activation")
    func onlyARealBackgroundReturnClearsIt() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine+Background.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let observer = try #require(text.range(of: "UIApplication.didBecomeActiveNotification"))
        let site = String(text[observer.lowerBound...].prefix(900))
        #expect(site.contains("returnedFromBackground"))
        #expect(site.contains("clearPanelRefusalOnForegroundReturn"))
    }
    /// AE#887: the playback probe read headroom 1.20 a tenth of a second after a live PQ master was
    /// refused, so that refusal was about the stream, and the latch must not outlive the reading.
    @Test("An HDR reading during playback withdraws a latched refusal")
    func anHDRReadingWithdrawsTheLatch() {
        withLatch(true) {
            AetherEngine.withdrawPanelRefusalOnHDRReading()
            #expect(AetherEngine.panelRefusedHDRMaster == false)
        }
    }

    @Test("The withdrawal sits on the playback probe's HDR answer")
    func theWithdrawalSitsOnTheProbeAnswer() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let probe = try #require(text.range(of: "await self.displayCriteria.probePanelDuringPlayback()"))
        let site = String(text[probe.lowerBound...].prefix(400))
        #expect(site.contains("withdrawPanelRefusalOnHDRReading()"))
    }
}
