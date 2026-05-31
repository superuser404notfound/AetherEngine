import Foundation

/// Which extraction mode produced (or is requested for) a frame.
///
/// - `thumbnail`: nearest keyframe, no forward decode, downscaled to a
///   small width. Cheap; used for scrub previews and Recents lists.
/// - `snapshot`: frame-accurate (decode forward to the exact PTS),
///   full or requested resolution. Used for user snapshots / stills.
public enum FrameMode: Sendable, Hashable {
    case thumbnail
    case snapshot
}
