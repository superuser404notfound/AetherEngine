import Foundation
import Testing
@testable import AetherEngine

struct MasterFallbackDecisionTests {
    @Test("a malformed media playlist is not evidence of display incompatibility")
    func malformedMedia() {
        let parser = NSError(domain: "CoreMediaErrorDomain", code: -12642)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11848,
            userInfo: [NSUnderlyingErrorKey: parser])
        #expect(!MasterFallbackDecision.isMasterRejection(wrapped))
        let generic = NSError(domain: "AVFoundationErrorDomain", code: -11848)
        #expect(!MasterFallbackDecision.isMasterRejection(generic, mediaErrorCodes: [-12642]))
        #expect(MasterFallbackDecision.isMasterRejection(generic))
    }

    @Test("AE#682: a 404 is the HDR variant's refusal only when the server withheld the I-frame playlist")
    func withheldIFramePlaylist() {
        let notFound = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
        #expect(!MasterFallbackDecision.isMasterRejection(notFound))
        #expect(MasterFallbackDecision.isMasterRejection(notFound, iFramePlaylistWithheld: true))
        #expect(MasterFallbackDecision.rejectionCode(for: notFound, iFramePlaylistWithheld: true) == -11848)
        #expect(MasterFallbackDecision.rejectionCode(for: notFound, iFramePlaylistWithheld: false) == -1100)
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(!MasterFallbackDecision.isMasterRejection(timeout, iFramePlaylistWithheld: true))
        let display = NSError(domain: "AVFoundationErrorDomain", code: -11868)
        #expect(MasterFallbackDecision.rejectionCode(for: display, iFramePlaylistWithheld: true) == -11868)
    }

    @Test("Display-rejection codes are the two AVFoundation display-reject codes")
    func recognisesRejectionCodes() {
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11868))
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11848))
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-12889)) // media timeout
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-11800)) // generic unknown
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(0))
    }

    @Test("#130: -1002 (all variants filtered at master parse) is a master rejection, not a display rejection")
    func recognisesVariantFilterRejection() {
        #expect(MasterFallbackDecision.isMasterRejectionCode(-1002))
        #expect(MasterFallbackDecision.isMasterRejectionCode(-11868))
        #expect(MasterFallbackDecision.isMasterRejectionCode(-11848))
        #expect(!MasterFallbackDecision.isMasterRejectionCode(-12889))
        #expect(!MasterFallbackDecision.isMasterRejectionCode(0))
        // The display-rejection set stays exactly the two AVFoundation codes.
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-1002))
    }

    @Test("#130: -1002 while serving the master falls back to media, single-shot")
    func variantFilterFallsBack() {
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -1002, servingMasterPlaylist: true, alreadyFellBack: false))
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -1002, servingMasterPlaylist: false, alreadyFellBack: false))
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -1002, servingMasterPlaylist: true, alreadyFellBack: true))
    }

    @Test("Fall back only for a rejection code while serving the master and not yet fallen back")
    func fallbackGate() {
        // Eligible: rejection code, serving master, first time.
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: true, alreadyFellBack: false))
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11848, servingMasterPlaylist: true, alreadyFellBack: false))
        // Not a rejection code.
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -12889, servingMasterPlaylist: true, alreadyFellBack: false))
        // Already serving media (not the master).
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: false, alreadyFellBack: false))
        // Already fell back once this session (no loop).
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: true, alreadyFellBack: true))
    }
}

/// #98: the media fallback reloads where the REJECTED item was placed. A recovery swaps a fresh item in
/// under a session that stays whole, so that is not always where the session first started.
///
/// Field log, Apple TV 4K 3rd gen, tvOS 27.0, HDR10+ HEVC Matroska opened with a resume at 1844 s:
/// paused at 2099.69 s, the item died behind the screensaver, the #93 stage-2 recovery swapped a
/// fresh item in at 2099.69 s, that item was refused at startup with -11868, and the fallback
/// reloaded at the first mount's 1844 s (landing on the keyframe at 1834.79 s). The viewer pressed
/// play four minutes behind the pause; a session started from the beginning of a title is put back
/// to its first frame.
@Suite("#98: the media fallback comes back where the rejected item was placed")
@MainActor
struct MasterFallbackPositionTests {

    private let url = URL(fileURLWithPath: "/nonexistent-master-fallback-position-test.m3u8")

    @Test("An in-place recovery swap moves the placement the fallback reads")
    func recoverySwapMovesThePlacement() {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }

        host.load(url: url, startPosition: 1844, contract: .init())
        #expect(host.mountedStartPosition == 1844)

        // The #93/#65 stage-2 recovery: same session, fresh item, placed where playback stood.
        host.swapItem(url: url, startPosition: 2099.69)
        #expect(host.mountedStartPosition == 2099.69)
    }

    @Test("A mount with no start position is placed at the head, as its seek is")
    func nilStartIsTheHead() {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }

        host.load(url: url, startPosition: nil, contract: .init())
        #expect(host.mountedStartPosition == 0)
    }

    @Test("A live rejoin makes no start seek, so it records no placement")
    func liveRejoinRecordsNoPlacement() {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }

        host.load(url: url, startPosition: 30, contract: .init(isLive: true))
        host.swapItem(url: url, startPosition: nil, skipInitialSeek: true)
        #expect(host.mountedStartPosition == nil)
    }

    /// A host-level test cannot see the call site, so this one reads it, as the #535 latch test does.
    @Test("The fallback reads the placement of the item it replaces")
    func fallbackReadsThePlacement() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let fn = try #require(text.range(of: "func fallBackToMediaPlaylist("))
        // The whole function, up to the next declaration: a fixed-length window dropped the call
        // out of view the moment the function grew (AE#849).
        let rest = text[fn.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        let body = String(text[fn.lowerBound..<end])
        #expect(body.contains("host.mountedStartPosition"))
    }
}
