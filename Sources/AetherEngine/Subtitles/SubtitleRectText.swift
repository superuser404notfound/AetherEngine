import Foundation
import Libavcodec

/// Plain-text extraction from FFmpeg subtitle rects, shared by `SubtitleDecoder` (sidecar) and `EmbeddedSubtitleDecoder` (in-container) so ASS parsing fixes live in one place.
enum SubtitleRectText {

    /// Plain text for a rect: prefers `text` field, falls back to parsing the raw ASS `Dialogue:` line (strip 8 header fields, clean tags + escapes).
    static func plainText(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            return plainText(fromASSEventLine: String(cString: assPtr))
        }
        return nil
    }

    /// Plain text from a raw ASS event line (`ReadOrder,Layer,Style,...,Text`), for surfaces that need
    /// plain text out of markup-preserving cues (the WebVTT rendition over tap-harvested stores,
    /// Sodalite#32). Guarded on the first field being the integer ReadOrder so a plain, comma-heavy
    /// line is never misparsed as an event; non-event lines just get tag/escape cleaning.
    static func plainText(fromASSEventLine line: String) -> String? {
        var l = line
        if l.hasPrefix("Dialogue: ") {
            l.removeFirst("Dialogue: ".count)
        }
        // ASS dialogue: 9 comma-separated fields; body is the 9th and may contain commas.
        let parts = l.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        if parts.count == 9, Int(parts[0]) != nil {
            return cleanASSBody(String(parts[8]))
        }
        return cleanASSBody(l)
    }

    /// Raw ASS event line exactly as libavcodec hands it over (`ReadOrder,Layer,Style,...,Text`, tags + escapes intact), for the `preserveASSMarkup` path; nil when the rect carries no ASS payload (bitmap or plain-text-only rects).
    static func rawASSLine(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        guard let assPtr = rect.pointee.ass else { return nil }
        let line = String(cString: assPtr)
        return line.isEmpty ? nil : line
    }

    /// Strip ASS escapes (`\\N` newline, `\\h` hard space) and
    /// `{...}` override tags; nil when nothing displayable remains.
    static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = s.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
