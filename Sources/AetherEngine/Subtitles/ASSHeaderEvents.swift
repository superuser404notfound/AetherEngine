import Foundation

/// AE#1127: one ASS event a muxer wrote into the track's CodecPrivate instead of into a block.
struct ASSHeaderEvent: Sendable, Equatable {
    let startSeconds: Double
    let durationSeconds: Double
    /// The event in Matroska block form (ReadOrder, then the `Format:` fields without Start and
    /// End), the payload libavcodec's ASS decoder expects from a demuxed packet.
    let payload: Data
}

/// AE#1127: some Matroska muxers put every event of an ASS track into its CodecPrivate (the
/// `[Events]` section with all its `Dialogue:` lines) and write no subtitle blocks at all. libass
/// reads events from the header, so mpv shows them; libavformat only turns blocks into packets, so
/// the engine saw a track with nothing in it. These events are lifted out of the header once at
/// open and fed to the session as if the muxer had written them as blocks.
///
/// This splits lines and reads two timestamps; the events themselves still go through libavcodec.
enum ASSHeaderEvents {
    /// Ceiling on lifted payload per track. A full feature film is around 150 KB of events, and a
    /// header is attacker-sized, so anything past this stays out of the session.
    static let maxPayloadBytesPerTrack = 512 * 1024

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
        var lifted = 0
        var strippedAny = false
        // A CRLF pair is one Character in Swift, so this splits it as one line break.
        for line in header.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased().hasPrefix("[events]")
            } else if inEvents, trimmed.hasPrefix("Format:") {
                format = trimmed.dropFirst("Format:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else if inEvents, trimmed.hasPrefix("Dialogue:") {
                // Removed from the header whether or not it parses: a host that renders the header
                // with libass would otherwise draw every lifted line twice.
                strippedAny = true
                if let event = event(trimmed.dropFirst("Dialogue:".count), format: format, readOrder: lifted),
                   payloadBytes + event.payload.count <= maxPayloadBytesPerTrack {
                    payloadBytes += event.payload.count
                    events.append(event)
                    lifted += 1
                }
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
        guard format.count >= 3,
              let startIndex = format.firstIndex(where: { $0.caseInsensitiveCompare("Start") == .orderedSame }),
              let endIndex = format.firstIndex(where: { $0.caseInsensitiveCompare("End") == .orderedSame })
        else { return nil }
        // Text is the last field and may itself contain commas.
        let fields = body.drop { $0 == " " }
            .split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
        guard fields.count == format.count,
              let start = timestamp(fields[startIndex]),
              let end = timestamp(fields[endIndex]),
              end > start else { return nil }
        var block = [String(readOrder)]
        for (i, field) in fields.enumerated() where i != startIndex && i != endIndex {
            block.append(String(field))
        }
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
