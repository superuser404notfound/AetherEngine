import Foundation

/// Where a native subtitle selection stands (AE#1141), published by
/// `AetherEngine.nativeSubtitleSelectionState`.
///
/// A select does not land at once. The engine fills the rendition before it hands it to AVKit,
/// and it deselects and reselects to make AVKit attach its renderer, so the item's legible
/// selection reads empty for most of that time. A host that follows AVKit's subtitle menu
/// through `mediaSelectionDidChangeNotification` cannot tell that empty selection from the viewer
/// choosing Off. This value tells it which one it is.
public enum NativeSubtitleSelectionState: Equatable, Sendable {
    /// No rendition is selected or asked for. Also the state while no session item exists.
    case idle
    /// A select of `ordinal` is on its way: from the call until AVKit holds the selection. The
    /// engine's own replays (recovery, audio-switch and AirPlay reloads, the PiP re-anchor) pass
    /// through here as well, and a reload that carries a pick reads `preparing` throughout.
    case preparing(ordinal: Int)
    /// AVKit holds the selection of `ordinal`. A menu marker (`markerOnly: true`) reads this too.
    case selected(ordinal: Int)
    /// The engine left `ordinal` deselected: its rendition was empty at the playhead (AVKit keeps
    /// whatever it is handed, so an empty select would show nothing for the rest of the session),
    /// no option in the legible group matches it, or there is no item to select it on. A later
    /// replay can still select it, and the state then moves on through `preparing`.
    case refused(ordinal: Int)

    /// The rendition this state is about, nil for `idle`.
    public var ordinal: Int? {
        switch self {
        case .idle: nil
        case .preparing(let ordinal), .selected(let ordinal), .refused(let ordinal): ordinal
        }
    }

    /// Whether an empty legible selection means the viewer turned subtitles off. True while idle
    /// or selected. While preparing the engine empties the selection itself, and after a refusal
    /// it was never filled.
    public var emptySelectionMeansOff: Bool {
        switch self {
        case .idle, .selected: true
        case .preparing, .refused: false
        }
    }
}
