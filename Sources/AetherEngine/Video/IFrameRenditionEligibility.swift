// Sources/AetherEngine/Video/IFrameRenditionEligibility.swift
import Foundation

/// AE#682: whether a session serves the I-frame rendition. Pure, so the rule is testable without a
/// session. The rendition is all or nothing: AVKit shows a stale picture for a keyframe it cannot
/// fetch, so a session that cannot answer every listed entry lists none.
enum IFrameRenditionEligibility {
    enum AbsentReason: String, Equatable {
        case notRequested, live, planNotKeyframeAligned, sequentialOrigin, heldSourceConnection
        case serialOrigin, discSource, noSecondReader, mediaPlaylistRouting
        /// A Dolby Vision Profile 5 / 10.0 source in a build without the `DolbyVisionStillReshaping`
        /// trait: no entry could be answered with a correct picture.
        case dolbyVisionStillsNotBuiltIn
    }

    enum Verdict: Equatable {
        case served
        case absent(AbsentReason)
    }

    struct Inputs {
        var requested: Bool
        var isLive: Bool
        var planBoundariesClaimRandomAccess: Bool
        var sequentialOrigin: Bool
        var heldSourceConnection: Bool
        var originIsSerial: Bool
        var isDiscSource: Bool
        var secondReaderAvailable: Bool
        /// The source's frames cannot become a still in this build (`FrameDecodeContext.yieldsStill`).
        var stillsUnavailable = false
    }

    /// Everything except the master decision, which needs this verdict as one of its inputs.
    static func candidate(_ i: Inputs) -> Verdict {
        guard i.requested else { return .absent(.notRequested) }
        if i.isLive { return .absent(.live) }
        guard i.planBoundariesClaimRandomAccess else { return .absent(.planNotKeyframeAligned) }
        if i.sequentialOrigin { return .absent(.sequentialOrigin) }
        if i.heldSourceConnection { return .absent(.heldSourceConnection) }
        if i.originIsSerial { return .absent(.serialOrigin) }
        if i.isDiscSource { return .absent(.discSource) }
        guard i.secondReaderAvailable else { return .absent(.noSecondReader) }
        if i.stillsUnavailable { return .absent(.dolbyVisionStillsNotBuiltIn) }
        return .served
    }

    static func resolve(candidate: Verdict, servingMaster: Bool) -> Verdict {
        guard candidate == .served else { return candidate }
        return servingMaster ? .served : .absent(.mediaPlaylistRouting)
    }
}
