import Foundation
import Testing
@testable import AetherEngine

/// AE#535: a master refusal taken while the display is not eligible for HDR is not a fact about the panel.
///
/// Measured by cmcpherson274 on an Apple TV 4K (tvOS 26.6): an audio route death right after a display
/// mode switch, a session-preserving reload landing 45 ms later with the readout at
/// `matching=off hdrEligible=no`, and AVPlayer failing the master with -11868. Three of four such reloads
/// latched `panelRefusedHDRMaster`, two of them in processes that never backgrounded, so the AE#588 clear
/// never came and every later HDR title in the session played media-direct.
struct Issue535RefusalNeedsEligibilityTests {

    @Test("A display rejection while the display is ineligible for HDR does not latch")
    func ineligibleWindowDoesNotLatch() {
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: false, displaySwitchInProgress: false))
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -11848, servedMasterIsHDR: true, displayEligibleForHDRNow: false, displaySwitchInProgress: false))
    }

    @Test("A display rejection on an eligible display still latches")
    func eligibleRefusalStillLatches() {
        #expect(MasterFallbackDecision.shouldLatchPanelRefusal(code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
        #expect(MasterFallbackDecision.shouldLatchPanelRefusal(code: -11848, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
    }

    /// cmcpherson274, 2026-10-11: two SDR titles' masters refused with -11848 latched the HDR route.
    @Test("A refusal of an SDR master never latches the HDR route")
    func sdrMasterRefusalNeverLatches() {
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -11848, servedMasterIsHDR: false, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -11868, servedMasterIsHDR: false, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
    }

    /// AE#849: on iOS and macOS the routing reads the display's eligibility, not the latch, and an eligible
    /// built-in panel takes an HDR master however it is presenting, so the refusal is about the master.
    @Test("A refusal on a panel that engages HDR on demand never latches")
    func onDemandPanelRefusalNeverLatches() {
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false, panelEngagesHDROnDemand: true))
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -11848, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false, panelEngagesHDROnDemand: true))
    }

    /// -1002 is a manifest filtered at parse time (#130), a statement about the playlist, never the display.
    @Test("The parse-time rejection never latches, eligible or not")
    func parseRejectionNeverLatches() {
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -1002, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(code: -1002, servedMasterIsHDR: true, displayEligibleForHDRNow: false, displaySwitchInProgress: false))
    }

    /// The fallback itself is unaffected: the item still reloads the media playlist whatever the latch does.
    @Test("An ineligible-window refusal still earns the item its media fallback")
    func fallbackIsIndependentOfTheLatch() {
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: true, alreadyFellBack: false))
    }

    /// A policy test cannot see the call site, so this one reads it: the latch is set only behind the gate.
    @Test("The latch site asks the eligibility gate before setting the latch")
    func latchSiteUsesTheGate() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let fn = try #require(text.range(of: "func fallBackToMediaPlaylist("))
        let body = String(text[fn.lowerBound...].prefix(2500))
        let gate = try #require(body.range(of: "shouldLatchPanelRefusal("))
        let set = try #require(body.range(of: "Self.panelRefusedHDRMaster = true"))
        #expect(gate.lowerBound < set.lowerBound)
        #expect(body.contains("AVPlayer.eligibleForHDRPlayback"))
        let sdrGuard = try #require(body.range(of: "!session.servedSourceIsHDR"))
        #expect(sdrGuard.lowerBound < set.lowerBound)
    }
}
