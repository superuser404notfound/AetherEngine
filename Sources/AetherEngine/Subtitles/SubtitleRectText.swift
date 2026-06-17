import Foundation
import Libavcodec

/// Plain-text extraction from FFmpeg subtitle rects, shared by
/// `SubtitleDecoder` (sidecar files) and `EmbeddedSubtitleDecoder`
/// (in-container tracks). One source of truth so ASS parsing fixes
/// don't have to be patched twice.
enum SubtitleRectText {

    /// Plain text for a rect: prefers the decoder's `text` field, falls
    /// back to parsing the raw ASS `Dialogue:` line (strip the 8 header
    /// fields, clean override tags + escapes).
    static func plainText(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            var line = String(cString: assPtr)
            if line.hasPrefix("Dialogue: ") {
                line.removeFirst("Dialogue: ".count)
            }
            // ASS dialogue layout: 9 comma-separated fields; the body
            // is the 9th and may contain commas.
            let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            let raw = parts.count == 9 ? String(parts[8]) : line
            return cleanASSBody(raw)
        }
        return nil
    }

    /// Raw ASS event line for the rect, exactly as libavcodec hands
    /// it over (the `ReadOrder,Layer,Style,...,Text` payload with all
    /// override tags and escapes intact). Used by the
    /// `preserveASSMarkup` opt-in path on both the embedded
    /// (`EmbeddedSubtitleDecoder`) and sidecar (`SubtitleDecoder`)
    /// readers; nil when the rect carries no ASS payload (bitmap
    /// rects, plain-text-only rects).
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
