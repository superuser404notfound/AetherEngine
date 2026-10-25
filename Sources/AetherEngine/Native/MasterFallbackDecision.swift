import Foundation

/// AVPlayer rejecting the served HLS master playlist: the `AVPlayerItem` failed at startup with a
/// master-incompatibility error. `-11868` (AVErrorNoCompatibleAlternatesForExternalDisplay) is the
/// iOS external-SDR-monitor case; `-11848` is an HDR master shipped to an SDR-parked panel; `-1002`
/// (NSURLErrorUnsupportedURL) is every variant filtered at master parse time (#130).
struct DisplayRejection: Sendable, Equatable {
    let code: Int
    let message: String
    /// `NSError.domain` of the item error behind the rejection: the message is AVFoundation's
    /// localized text, so the domain is what still classifies once it is published (#376).
    let domain: String?
}

/// Pure master to media fallback decision (#98). Kept separate and pure so the gate is testable
/// offline, matching the style of `ItemDeathReviveGate`. On an actual master rejection, reload the
/// bare media playlist (SDR-tone-mappable) instead of hard-failing.
///
/// An SDR-signalled master was tried (Stage 1.5) and reverted: forcing VIDEO-RANGE=SDR on HDR/DV
/// content does not fool the external-display compatibility gate (it checks the real colr/codec, not
/// the manifest string), so HDR/DV on an SDR external display stays media-playlist-driven, which drops
/// the subtitle renditions. Subtitles there are a separate host effort (overlay on the external
/// UIScreen). The #35 gate still reloads an HDR-preserving reduced master (source range kept, DV
/// dropped) because that variant is truthful and only serves an HDR panel.
enum MasterFallbackDecision {

    /// The two AVFoundationErrorDomain codes that mean "this display cannot present the master".
    static func isDisplayRejectionCode(_ code: Int) -> Bool {
        code == -11868 || code == -11848
    }

    /// AE#535: whether a refusal teaches the process something about the panel.
    ///
    /// A display rejection answers "does this output configuration accept an HDR master" only while
    /// the display is eligible for HDR at all. Measured on an Apple TV 4K on tvOS 26.6: an audio route
    /// death right after a display mode switch opens a window in which the criteria readout reads
    /// `matching=off hdrEligible=no`, a session-preserving reload lands in it, and AVPlayer fails the
    /// master with -11868 because nothing HDR is compatible WITH AN INELIGIBLE DISPLAY. That refusal is
    /// fully explained by the window, so it earns this item its media fallback and nothing more.
    /// Latching it cost the rest of the viewing session its master, and in a process that never
    /// backgrounds the AE#588 clear never came.
    ///
    /// AE#667: nor while a display mode switch is in progress. AVPlayer answers for the mode the panel is
    /// in at that moment, which mid-switch is the one it is leaving, so the refusal is about the moment.
    ///
    /// AE#535 (2026-10-11): nor when the refused master advertised `VIDEO-RANGE=SDR`. A refusal of an SDR
    /// master says nothing about HDR presentation, yet it latched the HDR route for every later title
    /// (cmcpherson274, two SDR titles' -11848 refusals at 7.15.1 and 7.17.1).
    ///
    /// AE#849: nor on a panel that engages HDR on demand (iOS, macOS). The latch only ever moves the
    /// panel answer, and the routing there reads the display's eligibility instead, so it changed nothing
    /// but a log line claiming every later HDR title went media-direct. Nor is the refusal a fact about
    /// such a panel: an eligible built-in panel takes the master however it is presenting (measured on a
    /// MacBook Air M1 SDR panel: a P8.1 master with and without SUPPLEMENTAL-CODECS, a High-tier 3832x1600
    /// PQ master and an audio switch to AC-3 on both, none refused), so a refusal there is about the
    /// master, and latching it would take the master from later titles it would have served.
    static func shouldLatchPanelRefusal(code: Int, servedMasterIsHDR: Bool, displayEligibleForHDRNow: Bool,
                                        displaySwitchInProgress: Bool,
                                        panelEngagesHDROnDemand: Bool = false) -> Bool {
        isDisplayRejectionCode(code) && servedMasterIsHDR && displayEligibleForHDRNow && !displaySwitchInProgress
            && !panelEngagesHDROnDemand
    }

    /// Any code that means "AVPlayer rejected the served master itself": the display-rejection pair
    /// plus NSURLErrorDomain -1002 "unsupported URL", which AVPlayer surfaces when it filters EVERY
    /// EXT-X-STREAM-INF out of the master at parse time and is left with no variant URL to load
    /// (#130: a VIDEO-RANGE=PQ/HLG variant without a FRAME-RATE attribute; master fetched twice,
    /// media.m3u8 never requested). -1002 is only classified here, behind the startup path's
    /// `servingMasterPlaylist` gate: the failed URL is then the engine's own loopback master, whose
    /// GETs the server demonstrably answered, so the code cannot mean a genuinely bad host URL.
    static func isMasterRejectionCode(_ code: Int) -> Bool {
        isDisplayRejectionCode(code) || code == -1002
    }

    /// A malformed media playlist can be wrapped in the same -11848 as a display refusal.
    /// It says nothing about HDR support and must not poison the process's display decision.
    ///
    /// AE#682: an HDR master with an SDR motion JPEG I-frame rendition has one variant left when AVPlayer
    /// refuses the HDR one, and AVPlayer would play the stills as the video. The server therefore
    /// withholds the I-frame playlist until a media segment is asked for, and the refused item fails
    /// with the 404's NSURLErrorDomain -1100. With `iFramePlaylistWithheld` that is the -11848 refusal
    /// it stands in for.
    static func isMasterRejection(_ error: NSError, mediaErrorCodes: [Int] = [],
                                  iFramePlaylistWithheld: Bool = false) -> Bool {
        if iFramePlaylistWithheld, isWithheldIFramePlaylistFailure(error) { return true }
        guard !mediaErrorCodes.contains(-12642) else { return false }
        var current: NSError? = error
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == "CoreMediaErrorDomain", value.code == -12642 { return false }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return isMasterRejectionCode(error.code)
    }

    static func isWithheldIFramePlaylistFailure(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == NSURLErrorFileDoesNotExist
    }

    /// The code the fallback acts on: the item's own, or for a withheld I-frame playlist the display
    /// refusal the 404 stands in for.
    static func rejectionCode(for error: NSError, iFramePlaylistWithheld: Bool) -> Int {
        iFramePlaylistWithheld && isWithheldIFramePlaylistFailure(error) ? -11848 : error.code
    }

    /// Fall back to the media playlist only when a master-rejection failed the item, the engine was
    /// serving the master, and this session has not already fallen back (single-shot, no loop).
    static func shouldFallBackToMediaPlaylist(
        errorCode: Int, servingMasterPlaylist: Bool, alreadyFellBack: Bool
    ) -> Bool {
        isMasterRejectionCode(errorCode) && servingMasterPlaylist && !alreadyFellBack
    }

    /// AE#849: whether an audio switch rebuilds onto the media playlist its session already fell back to.
    ///
    /// The switch changes the audio and nothing the display was asked about, so a display that refused
    /// this session's HDR master refuses the rebuilt one too and the rebuild pays the same rejection and
    /// fallback again. Only a display refusal of an HDR master carries: a `-1002` parse failure is about
    /// the playlist, which the switch rewrites, and an SDR refusal is about the window (#535).
    static func audioSwitchKeepsMediaRoute(
        outgoingServingMaster: Bool, outgoingMasterRefusedByDisplay: Bool
    ) -> Bool {
        !outgoingServingMaster && outgoingMasterRefusedByDisplay
    }
}
