import AudioToolbox
import Foundation

/// The speaker bed object audio is rendered into before it is handed to tvOS.
///
/// A bitstreaming player lets the AVR render Atmos objects against the room it knows. Apple TV
/// never bitstreams: it decodes everything and sends Atmos to the receiver as Dolby MAT, so the
/// only way TrueHD Atmos objects reach the receiver as height information is for the engine to
/// render them into a channel bed itself and hand that bed to the system as spatial audio (APAC).
/// The bed is the one fact about the room the engine has to be told, which is why this is a host
/// option and not something the engine derives.
///
/// Channel order is CoreAudio's for the matching `kAudioChannelLayoutTag_Atmos_*` tag, because
/// that tag is what the APAC encoder is opened with and the encoder reads planes in that order.
public enum SpatialSpeakerLayout: String, Sendable, CaseIterable, Codable {
    case l512 = "5.1.2"
    case l514 = "5.1.4"
    case l712 = "7.1.2"
    case l714 = "7.1.4"
    case l916 = "9.1.6"

    /// Speakers in CoreAudio channel order for `channelLayoutTag`.
    public var speakers: [SpatialSpeaker] {
        switch self {
        case .l512: return [.left, .right, .center, .lfe, .surroundLeft, .surroundRight, .topMiddleLeft, .topMiddleRight]
        case .l514: return [.left, .right, .center, .lfe, .surroundLeft, .surroundRight,
                            .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight]
        case .l712: return [.left, .right, .center, .lfe, .sideLeft, .sideRight, .rearLeft, .rearRight,
                            .topMiddleLeft, .topMiddleRight]
        case .l714: return [.left, .right, .center, .lfe, .sideLeft, .sideRight, .rearLeft, .rearRight,
                            .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight]
        case .l916: return [.left, .right, .center, .lfe, .sideLeft, .sideRight, .rearLeft, .rearRight,
                            .wideLeft, .wideRight, .topFrontLeft, .topFrontRight,
                            .topMiddleLeft, .topMiddleRight, .topRearLeft, .topRearRight]
        }
    }

    public var channelCount: Int { speakers.count }

    /// Whether every channel of DTS:X's standard presentation, the 7.1 bed and the four heights, has
    /// a speaker of its own here, so each plays where it was authored and nothing is re-panned or
    /// folded: 7.1.4 and 9.1.6.
    var carriesDTSXOneToOne: Bool {
        let standard: [SpatialSpeaker] = [.left, .right, .center, .lfe, .sideLeft, .sideRight,
                                          .rearLeft, .rearRight, .topFrontLeft, .topFrontRight,
                                          .topRearLeft, .topRearRight]
        return standard.allSatisfy(speakers.contains)
    }

    /// The bed DTS:X is rendered into when the host asks for this layout: the layout itself when it
    /// carries the standard channels one to one, otherwise 7.1.4, the smallest bed that does. The
    /// receiver maps 7.1.4 onto its own speakers, so a 5.1.2 room still gets the heights instead of
    /// the 7.1 channel bridge, and no DTS:X channel is ever panned.
    var dtsxBed: SpatialSpeakerLayout {
        carriesDTSXOneToOne ? self : .l714
    }

    /// CoreAudio's tag for this bed. The comments in CoreAudioBaseTypes.h spell the order
    /// `speakers` mirrors.
    public var channelLayoutTag: AudioChannelLayoutTag {
        switch self {
        case .l512: return kAudioChannelLayoutTag_Atmos_5_1_2
        case .l514: return kAudioChannelLayoutTag_Atmos_5_1_4
        case .l712: return kAudioChannelLayoutTag_Atmos_7_1_2
        case .l714: return kAudioChannelLayoutTag_Atmos_7_1_4
        case .l916: return kAudioChannelLayoutTag_Atmos_9_1_6
        }
    }

    /// Index of the LFE channel. Every layout here has exactly one, in slot 3.
    public var lfeIndex: Int { speakers.firstIndex(of: .lfe)! }
}

/// One loudspeaker position in the engine's room model.
///
/// Positions are ALLOCENTRIC: coordinates in a unit cube describing the room, not angles around a
/// listener. That is the model Atmos object metadata is authored in, so an object on the left wall
/// halfway back lands between the left-side speakers whatever the physical angles are.
/// `x` runs left (0) to right (1), `y` front (0) to back (1), `z` floor/ear level (0) to ceiling (1).
///
/// Ceiling speakers sit at the panner targets ETSI TS 103 448 gives them (table A.5): a quarter of
/// the room in from each wall, not in its corners. An object on the ceiling between them is panned
/// between them, and one beyond them, out at a wall or a corner, plays from the nearest. With the
/// tops in the corners, an object a third of the way back put 25% of its power in the rear tops
/// instead of 7%, so overhead content measured up to 4 points of energy higher and 3° higher
/// against Apple's own Atmos render.
public enum SpatialSpeaker: String, Sendable, CaseIterable {
    case left, right, center, lfe
    /// 5.1-style surrounds. TS 103 448 table A.3 puts them halfway down the side walls, where a
    /// 7.1 bed has its sides, not in the rear corners: an object on the side wall plays from them
    /// alone, and one at the back wall stays on them rather than reaching past them.
    case surroundLeft, surroundRight
    case sideLeft, sideRight
    case rearLeft, rearRight
    case wideLeft, wideRight
    case topFrontLeft, topFrontRight
    case topMiddleLeft, topMiddleRight
    case topRearLeft, topRearRight

    /// Allocentric position (x, y, z). LFE has no position; it is routed, never panned.
    var position: SIMD3<Float> {
        switch self {
        case .left:           return SIMD3(0, 0, 0)
        case .right:          return SIMD3(1, 0, 0)
        case .center:         return SIMD3(0.5, 0, 0)
        case .lfe:            return SIMD3(0.5, 0, 0)
        case .surroundLeft:   return SIMD3(0, 0.5, 0)
        case .surroundRight:  return SIMD3(1, 0.5, 0)
        case .sideLeft:       return SIMD3(0, 0.5, 0)
        case .sideRight:      return SIMD3(1, 0.5, 0)
        case .rearLeft:       return SIMD3(0, 1, 0)
        case .rearRight:      return SIMD3(1, 1, 0)
        case .wideLeft:       return SIMD3(0, 0.25, 0)
        case .wideRight:      return SIMD3(1, 0.25, 0)
        case .topFrontLeft:   return SIMD3(0.25, 0.25, 1)
        case .topFrontRight:  return SIMD3(0.75, 0.25, 1)
        case .topMiddleLeft:  return SIMD3(0.25, 0.5, 1)
        case .topMiddleRight: return SIMD3(0.75, 0.5, 1)
        case .topRearLeft:    return SIMD3(0.25, 0.75, 1)
        case .topRearRight:   return SIMD3(0.75, 0.75, 1)
        }
    }

    var isLFE: Bool { self == .lfe }
    var isHeight: Bool { position.z > 0 }

    /// The CoreAudio label for this position, so the bed's log line names channels the way the
    /// route line and CoreAudioBaseTypes.h do. 5.1-style surrounds and 7.1 sides share
    /// `LeftSurround`/`RightSurround`, as CoreAudio's own Atmos tags do; no layout has both.
    var channelLabel: AudioChannelLabel {
        switch self {
        case .left: return kAudioChannelLabel_Left
        case .right: return kAudioChannelLabel_Right
        case .center: return kAudioChannelLabel_Center
        case .lfe: return kAudioChannelLabel_LFEScreen
        case .surroundLeft, .sideLeft: return kAudioChannelLabel_LeftSurround
        case .surroundRight, .sideRight: return kAudioChannelLabel_RightSurround
        case .rearLeft: return kAudioChannelLabel_RearSurroundLeft
        case .rearRight: return kAudioChannelLabel_RearSurroundRight
        case .wideLeft: return kAudioChannelLabel_LeftWide
        case .wideRight: return kAudioChannelLabel_RightWide
        case .topFrontLeft: return kAudioChannelLabel_VerticalHeightLeft
        case .topFrontRight: return kAudioChannelLabel_VerticalHeightRight
        case .topMiddleLeft: return kAudioChannelLabel_LeftTopMiddle
        case .topMiddleRight: return kAudioChannelLabel_RightTopMiddle
        case .topRearLeft: return kAudioChannelLabel_LeftTopRear
        case .topRearRight: return kAudioChannelLabel_RightTopRear
        }
    }
}
