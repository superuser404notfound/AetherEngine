import Foundation

/// AE#1127: one ASS event a muxer wrote into the track's CodecPrivate instead of into a block.
struct ASSHeaderEvent: Sendable, Equatable {
    let startSeconds: Double
    let durationSeconds: Double
    /// The event as a Matroska ASS block: `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`,
    /// the payload libavcodec's ASS decoder expects from a demuxed packet.
    let payload: Data
}

/// AE#1127: some Matroska muxers put every event of an ASS track into its CodecPrivate (the
/// `[Events]` section with all its `Dialogue:` lines) and write no subtitle blocks at all. libass
/// reads events from the header, so mpv shows them; libavformat only turns blocks into packets, so
/// the engine saw a track with nothing in it. These events are lifted out of the header once at
/// open and fed to the session as if the muxer had written them as blocks.
///
/// This only cuts lines into packets, the job libavformat's ASS demuxer does for a `.ass` file; the
/// events themselves still decode through libavcodec.
enum ASSHeaderEvents {
    /// Ceiling on lifted payload per track. A full film is around 150 KB of events and a heavily
    /// typeset episode a few MB; a header is attacker-sized, so lines past this stay in the header.
    static let maxPayloadBytesPerTrack = 4 * 1024 * 1024

    private static let defaultFormat = ["Layer", "Start", "End", "Style", "Name",
                                        "MarginL", "MarginR", "MarginV", "Effect", "Text"]

    /// `header` without the `Dialogue:` lines of its `[Events]` section, and those lines as events
    /// in start order. A header without any comes back unchanged with no events.
    static func split(_ header: String) -> (header: String, events: [ASSHeaderEvent]) {
        guard header.contains("Dialogue:") else { return (header, []) }
        var kept: [Substring] = []
        var events: [ASSHeaderEvent] = []
        var inEvents = false
        var format = defaultFormat
        var payloadBytes = 0
        var dialogueLines = 0
        var strippedAny = false
        // CR and LF only, as libass and libavformat split. A CRLF pair is one Character in Swift.
        let lines = header.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }
        for line in lines {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased().hasPrefix("[events]")
            } else if inEvents, trimmed.hasPrefix("Format:") {
                format = trimmed.dropFirst("Format:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else if inEvents, trimmed.hasPrefix("Dialogue:") {
                // ReadOrder counts every Dialogue line, as mkvmerge numbers its blocks, so a track that
                // also carries the same events as blocks stores byte-identical packets that collapse.
                let readOrder = dialogueLines
                dialogueLines += 1
                guard let event = event(trimmed.dropFirst("Dialogue:".count), format: format, readOrder: readOrder)
                else {
                    // Unreadable: no libass would draw it either, so it goes with the others.
                    strippedAny = true
                    continue
                }
                guard payloadBytes + event.payload.count <= maxPayloadBytesPerTrack else {
                    // Past the ceiling the line stays where it was, so a libass host still draws it.
                    kept.append(line)
                    continue
                }
                payloadBytes += event.payload.count
                events.append(event)
                strippedAny = true
                continue
            }
            kept.append(line)
        }
        guard strippedAny else { return (header, []) }
        // Stable: same-start events keep their file order, which is their layering order.
        let ordered = events.enumerated()
            .sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }
            .map(\.element)
        return (kept.joined(separator: "\n"), ordered)
    }

    private static func event(_ body: Substring, format: [String], readOrder: Int) -> ASSHeaderEvent? {
        func index(_ names: String...) -> Int? {
            format.firstIndex { field in names.contains { field.caseInsensitiveCompare($0) == .orderedSame } }
        }
        // Text is the last field and may itself contain commas.
        guard let startIndex = index("Start"), let endIndex = index("End"),
              let textIndex = index("Text"), textIndex == format.count - 1 else { return nil }
        let fields = body.drop { $0 == " " }
            .split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
        guard fields.count == format.count,
              let start = timestamp(fields[startIndex]),
              let end = timestamp(fields[endIndex]),
              end > start else { return nil }
        func field(_ i: Int?, default value: String) -> String {
            i.map { String(fields[$0]) } ?? value
        }
        // The block layout is fixed whatever order the script's Format line uses. SSA v4 has
        // `Marked=0` where v4+ has Layer, and some scripts say Actor for Name.
        var layer = field(index("Layer", "Marked"), default: "0")
        if layer.hasPrefix("Marked=") { layer.removeFirst("Marked=".count) }
        let block = [
            String(readOrder),
            layer,
            field(index("Style"), default: ""),
            field(index("Name", "Actor"), default: ""),
            field(index("MarginL"), default: "0"),
            field(index("MarginR"), default: "0"),
            field(index("MarginV"), default: "0"),
            field(index("Effect"), default: ""),
            String(fields[textIndex]),
        ]
        return ASSHeaderEvent(startSeconds: start, durationSeconds: end - start,
                              payload: Data(block.joined(separator: ",").utf8))
    }

    /// `H:MM:SS.CC`. The fraction is read as centiseconds whatever its length, as libass and
    /// libavformat's ASS demuxer read it, so a line times the same here as in mpv. Bounded like a
    /// demuxed timestamp (audit FEA-101), since the store and the decoders do arithmetic on it.
    static func timestamp(_ field: Substring) -> Double? {
        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let secondParts = parts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let s = Int(secondParts[0]) else { return nil }
        var centiseconds = 0
        if secondParts.count == 2 {
            guard let cs = Int(secondParts[1]) else { return nil }
            centiseconds = cs
        }
        guard h >= 0, m >= 0, s >= 0, centiseconds >= 0 else { return nil }
        let seconds = Double(h) * 3600 + Double(m) * 60 + Double(s) + Double(centiseconds) / 100
        return seconds < SourceTimestampBounds.maxPlausibleSeconds ? seconds : nil
    }
}
