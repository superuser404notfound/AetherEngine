import Foundation

/// Reassembles a complete ASS script from the raw event lines the
/// engine emits with `LoadOptions.preserveASSMarkup` (AetherEngine#30).
///
/// libavcodec normalizes every ASS/SSA event to
/// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
/// WITHOUT timestamps; timing travels on the cue (`startTime` /
/// `endTime`, absolute source-PTS seconds). Whole-file renderers
/// (e.g. swift-ass-renderer's `loadTrack(content:)`) want a full
/// script with `Dialogue:` lines instead. This builder accumulates
/// events as they stream in from the paced side demuxer, dedupes
/// re-emits by ReadOrder (unique per event, stable across producer
/// restarts and seeks), and renders `header + Dialogue lines` on
/// demand.
///
/// Pure string assembly, no rendering, no UI: the engine stays
/// backend-only; hosts hand the script to whatever renderer they ship.
/// Not thread-safe; confine to one actor (hosts typically call it
/// from their MainActor cue sink).
public final class ASSScriptBuilder {

    private let header: String
    /// ReadOrder -> synthesized Dialogue line. Sorted by key when
    /// rendering so out-of-order arrival (backward seek re-emits)
    /// still produces a monotonic script.
    private var events: [Int: String] = [:]

    public var eventCount: Int { events.count }

    /// `header` is the track's script header, i.e.
    /// `TrackInfo.assHeader` (`[Script Info]` + `[V4+ Styles]` +
    /// the `[Events]` Format line).
    public init(header: String) {
        self.header = header
    }

    /// Add one cue body. `rawEventText` is `SubtitleCue.body`'s text
    /// under `preserveASSMarkup`; it may contain SEVERAL raw event
    /// lines joined by newlines (one per packet rect). `start` / `end`
    /// are the cue's times in seconds. Returns true when at least one
    /// NEW event (unseen ReadOrder) was added.
    @discardableResult
    public func add(rawEventText: String, start: Double, end: Double) -> Bool {
        var addedAny = false
        for line in rawEventText.split(separator: "\n", omittingEmptySubsequences: true) {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, let readOrder = Int(fields[0]) else { continue }
            guard events[readOrder] == nil else { continue }
            let layer = fields[1]
            let tail = fields[2...].joined(separator: ",")
            events[readOrder] = "Dialogue: \(layer),\(Self.timestamp(start)),\(Self.timestamp(end)),\(tail)"
            addedAny = true
        }
        return addedAny
    }

    /// The full script: header, then all known events ordered by
    /// ReadOrder.
    public func script() -> String {
        var lines = [header]
        for key in events.keys.sorted() {
            lines.append(events[key]!)
        }
        return lines.joined(separator: "\n")
    }

    /// Drop all accumulated events (track switch; the header stays).
    public func reset() {
        events.removeAll(keepingCapacity: true)
    }

    /// ASS timestamp `H:MM:SS.cc` (centiseconds). Negative input
    /// clamps to zero.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        var centis = Int((total * 100).rounded())
        let h = centis / 360_000
        centis %= 360_000
        let m = centis / 6_000
        centis %= 6_000
        let s = centis / 100
        centis %= 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, centis)
    }
}
