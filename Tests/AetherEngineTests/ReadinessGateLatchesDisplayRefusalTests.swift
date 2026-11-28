import Foundation
import Testing
@testable import AetherEngine

/// AE#1143: the #35 startup readiness gate held a display refusal, spent a data-wait round, a master
/// reload and the reduced master on it, then fell back to the media playlist without latching
/// `panelRefusedHDRMaster`. Measured on an Apple TV 4K behind a cable that could not carry the HDR link:
/// about 14 s to the first frame, and 26 s on the next HDR title, because nothing had been learned.
///
/// A refusal now skips the data-wait and the reload, and the gate's media fallback latches through the
/// same helper the reactive path uses. A plain cold failure (-11819, the silent park) keeps its reload
/// and latches nothing, which is what lets the next title keep its DV master once the link is warm.
@Suite("AE#1143: the readiness gate learns a display refusal", .timeLimit(.minutes(3)))
struct ReadinessGateLatchesDisplayRefusalTests {

    private func engineSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// From the declaration to the method's closing brace at member indentation.
    private func functionBody(_ text: String, from start: String) throws -> String {
        let range = try #require(text.range(of: start))
        let rest = text[range.lowerBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.upperBound])
    }

    @Test("a refusal on the first attempt goes straight to the media fallback, whatever the outcome")
    func refusalSkipsReloadAndDataWait() {
        for outcome in [StartupReadiness.dead, .timedOut, .awaitingData] {
            #expect(StartupReadinessGate.nextAction(
                outcome: outcome, attempt: 1,
                masterAlreadyFellBack: false, hasMediaFallbackURL: true,
                refusedByDisplay: true) == .fallBackToMedia)
        }
    }

    @Test("a refusal with nothing left to fall back to gives up instead of reloading")
    func refusalWithoutMediaGivesUp() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead, attempt: 1,
            masterAlreadyFellBack: false, hasMediaFallbackURL: false,
            refusedByDisplay: true) == .giveUp)
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead, attempt: 1,
            masterAlreadyFellBack: true, hasMediaFallbackURL: true,
            refusedByDisplay: true) == .giveUp)
    }

    @Test("a ready item still proceeds even if an earlier item of the run was refused")
    func readyWinsOverAnEarlierRefusal() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .ready, attempt: 1,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true,
            refusedByDisplay: true) == .proceed)
    }

    @Test("a cold failure without a refusal keeps the #35 reload")
    func coldFailureStillReloads() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead, attempt: 1,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .reloadMaster)
    }

    @Test("the withheld I-frame 404 counts as a display refusal, a plain 404 does not")
    func withheldIFrameReadsAsRefusal() {
        let notFound = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
        #expect(MasterFallbackDecision.isDisplayRejectionCode(
            MasterFallbackDecision.rejectionCode(for: notFound, iFramePlaylistWithheld: true)))
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(
            MasterFallbackDecision.rejectionCode(for: notFound, iFramePlaylistWithheld: false)))
    }

    @Test("the process latch is set in exactly one place, the shared helper")
    func oneLatchSite() throws {
        let names = try FileManager.default.subpathsOfDirectory(
            atPath: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/AetherEngine").path)
            .filter { $0.hasSuffix(".swift") }
        var sites = 0
        for name in names {
            sites += try engineSource(name).components(separatedBy: "panelRefusedHDRMaster = true").count - 1
        }
        #expect(sites == 1)
        let helper = try functionBody(try engineSource("AetherEngine.swift"),
                                      from: "func latchPanelRefusalIfDue(")
        #expect(helper.contains("Self.panelRefusedHDRMaster = true"))
    }

    @Test("both fallbacks route through the helper")
    func bothFallbacksLatch() throws {
        let text = try engineSource("AetherEngine.swift")
        let reactive = try functionBody(text, from: "func fallBackToMediaPlaylist(")
        #expect(reactive.contains("latchPanelRefusalIfDue(code: rejection.code"))
        let gate = try functionBody(text, from: "private func runStartupReadinessGate(")
        #expect(gate.contains("latchPanelRefusalIfDue(code: refusal.code"))
        #expect(gate.contains("refusedByDisplay: refusal != nil"))
    }

    /// The AE#535 / AE#667 guards judge the display at the refusal. The gate falls back up to 3 s
    /// later, by when a panel that read ineligible mid-handshake may read eligible.
    @Test("the gate hands the helper the display state it read at the refusal")
    func gateLatchesOnTheRefusalsDisplayState() throws {
        let gate = try functionBody(try engineSource("AetherEngine.swift"),
                                    from: "private func runStartupReadinessGate(")
        #expect(gate.contains("eligibleAtRefusal: refusal.eligible, switchingAtRefusal: refusal.switching"))
    }

    /// The status KVO reaches the main actor through a Task, so a code stashed by `handleItemFailed`
    /// can still be missing when the gate's poll sees `.failed`. The host reads it off the item.
    @Test("the refusal is read off the failed item, not from a field the failure handler fills")
    func refusalIsReadOffTheItem() throws {
        let host = try engineSource("Native/NativeAVPlayerHost.swift")
        let getter = try functionBody(host, from: "var startupDisplayRejectionCode: Int? {")
        #expect(getter.contains("item.status == .failed"))
    }

    /// After a cold master failure, a refused reduced master may be the link still warming (#35), and
    /// the stated rule is that a cold start latches nothing. Only master attempts are judged.
    @Test("the reduced master's outcome is never recorded as a refusal")
    func reducedAttemptRecordsNoRefusal() throws {
        let gate = try functionBody(try engineSource("AetherEngine.swift"),
                                    from: "private func runStartupReadinessGate(")
        let reduced = try #require(gate.range(of: "if let reducedURL = session.reducedHDRMasterPlaylistURL"))
        let fallback = try #require(gate.range(of: "masterFallbackUsed = true"))
        #expect(!gate[reduced.lowerBound..<fallback.lowerBound].contains("noteRefusal()"))
        #expect(gate.contains("refusal == nil || session.masterCarriesSupplementalCodecs"))
    }

    @Test("the gate reloads onto the LAN address only for a receiver")
    func gateReloadsStayOnLoopbackLocally() throws {
        let gate = try functionBody(try engineSource("AetherEngine.swift"),
                                    from: "private func runStartupReadinessGate(")
        #expect(!gate.contains("airPlayHostSwapped("))
        #expect(gate.contains("gateItemURL("))
    }
}
