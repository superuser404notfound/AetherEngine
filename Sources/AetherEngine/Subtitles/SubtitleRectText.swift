import CoreGraphics
import Foundation
import AetherLibavcodec

extension SubtitleTextRun {
    /// Same styling, different text. Keeps the trim and fold passes from restating every attribute.
    func withText(_ newText: String) -> SubtitleTextRun {
        SubtitleTextRun(text: newText, color: color, isBold: isBold, isItalic: isItalic,
                        isUnderlined: isUnderlined, isStruckThrough: isStruckThrough,
                        fontName: fontName, fontSize: fontSize)
    }
}

/// Plain-text extraction from FFmpeg subtitle rects, shared by `SubtitleDecoder` (sidecar) and `EmbeddedSubtitleDecoder` (in-container) so ASS parsing fixes live in one place.
enum SubtitleRectText {

    /// Audit SUB-101: the most text of one cue any pass below looks at. A real cue is a few hundred
    /// bytes; a hostile track can hand over megabytes, and every per-cue pass here runs on the demux
    /// pump thread under the subtitle tap lock.
    static let maxCueBytes = 64 * 1024

    /// `text` cut to `maxCueBytes` at a scalar boundary; the same string, untouched, when it fits.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maxCueBytes else { return text }
        var end = text.unicodeScalars.startIndex
        var used = 0
        for scalar in text.unicodeScalars {
            let next = used + UTF8.width(scalar)
            if next > maxCueBytes { break }
            used = next
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }

    /// Plain text for a rect: prefers `text` field, falls back to parsing the raw ASS `Dialogue:` line (strip 8 header fields, clean tags + escapes).
    static func plainText(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = boundedString(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            return plainText(fromASSEventLine: boundedString(cString: assPtr))
        }
        return nil
    }

    private static func boundedString(cString pointer: UnsafePointer<CChar>) -> String {
        let length = strnlen(pointer, maxCueBytes)
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    /// Plain text from a raw ASS event line (`ReadOrder,Layer,Style,...,Text`), for surfaces that need
    /// plain text out of markup-preserving cues (the WebVTT rendition over tap-harvested stores,
    /// Sodalite#32). Guarded on the first field being the integer ReadOrder so a plain, comma-heavy
    /// line is never misparsed as an event; non-event lines just get tag/escape cleaning.
    static func plainText(fromASSEventLine line: String) -> String? {
        var l = capped(line)
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
        var s = capped(raw)
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = strippingOverrideBlocks(s)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drop every `{...}` span: from a `{` to the first `}` after it, so `{a{b}c}` leaves `c}`. A `{`
    /// with no `}` behind it keeps itself and the rest verbatim, except in drawing mode, where the
    /// rest goes too.
    ///
    /// Text drawn in ASS drawing mode goes: it is vector commands (`m 10 20 l 30 40`), not words.
    /// Anime typesetting uses drawings for boxes and masks, and these came out as rows of numbers.
    /// Drawing starts at `\p1` or higher and ends at `\p0` or a bare `\p`, for the rest of the event
    /// (`drawingScale(inBlock:)` reads the tags).
    ///
    /// Audit SUB-101: this was `\\{[^}]*\\}` through `NSRegularExpression`, which rescans to the end
    /// of the text at every unclosed `{` (20k braces took 2.6 s, doubling cost 4x). One forward pass
    /// instead: once a `{` finds no `}`, no later one can either. Scanned as UTF-8, so the braces
    /// match exactly where the regex's UTF-16 units did.
    static func strippingOverrideBlocks(_ text: String) -> String {
        guard text.utf8.contains(0x7B) else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        var drawing = false
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x7B else {
                if !drawing { out.append(byte) }
                index += 1
                continue
            }
            guard let close = bytes[(index + 1)...].firstIndex(of: 0x7D) else {
                if !drawing { out.append(contentsOf: bytes[index...]) }
                break
            }
            if let scale = drawingScale(inBlock: bytes[(index + 1)..<close]) { drawing = scale > 0 }
            index = close + 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The drawing scale an override block leaves in force, or nil when it changes nothing. Read the
    /// way libass's `ass_parse_tags` reads it, and the last tag that sets it wins:
    ///
    /// - `\p<n>` sets it to `n`, parsed like `strtoll`: leading spaces and a sign are fine, so `\p 1`
    ///   draws, and a bare `\p` or a negative value is 0 and ends drawing.
    /// - Tags inside `\t(...)` count, because libass parses them like any other tag and `\p` has no
    ///   animation guard. Inside the parentheses of any other tag they are only an argument.
    /// - `\pos(...)` and `\pbo<n>` are other tags. `\r` does not end drawing: libass resets the
    ///   scale only at the start of an event (`init_render_context`), not in `ass_reset_render_context`.
    static func drawingScale<Bytes: Collection>(inBlock block: Bytes) -> Int? where Bytes.Element == UInt8 {
        var scale: Int?
        var tag: [UInt8] = []
        var inTag = false
        var depth = 0
        func finish() {
            defer { tag.removeAll(keepingCapacity: true) }
            guard tag.first == 0x70, !tag.starts(with: "pos".utf8), !tag.starts(with: "pbo".utf8) else { return }
            var digits = tag.dropFirst().drop(while: { $0 == 0x20 || $0 == 0x09 })
            var negative = false
            if let sign = digits.first, sign == 0x2B || sign == 0x2D {
                negative = sign == 0x2D
                digits = digits.dropFirst()
            }
            var value = 0
            for byte in digits {
                guard (0x30...0x39).contains(byte) else { break }
                value = min(value * 10 + Int(byte - 0x30), 1_000)
            }
            scale = negative ? 0 : value
        }
        for byte in block {
            if byte == 0x5C, depth == 0 { // a backslash outside an argument list starts a new tag
                finish()
                inTag = true
                continue
            }
            // libass skips spaces between the backslash and the tag name.
            if inTag, tag.isEmpty, byte == 0x20 || byte == 0x09 { continue }
            if byte == 0x28 {
                // `\t(` holds tags that libass parses again, so its parentheses do not hide them.
                if !(inTag && tag.first == 0x74) { depth += 1 }
            }
            if byte == 0x29 { depth = max(0, depth - 1) }
            if inTag { tag.append(byte) }
        }
        finish()
        return scale
    }

    /// Default ASS play resolution (`ASS_DEFAULT_PLAYRESX/Y`, libavcodec/ass.h). Every event line
    /// libavcodec synthesises for SRT, WebVTT and teletext positions against this space, so it is
    /// the right frame of reference unless a real ASS header declares its own.
    static let defaultASSPlayRes = CGSize(width: 384, height: 288)

    /// Play resolution declared by an ASS `[Script Info]` header, or nil when it declares none.
    ///
    /// The header arrives as codec extradata byte for byte as the muxer stored it, and muxed ASS
    /// is conventionally CRLF, so the line endings are not ours to assume (#261). Splitting on
    /// `isNewline` covers CRLF, LF and lone CR, and the trims are newline-inclusive so a stray CR
    /// cannot reach `Double(_:)`, which returns nil for `"718\r"` and silently costs the whole
    /// declaration.
    static func playRes(fromASSHeader header: String) -> CGSize? {
        func value(_ key: String) -> Double? {
            for line in header.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard l.lowercased().hasPrefix(key.lowercased() + ":") else { continue }
                return Double(l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        // `Double(_:)` accepts `inf` and `nan` (audit SUB-112).
        guard let x = value("PlayResX"), let y = value("PlayResY"), x > 0, y > 0,
              x.isFinite, y.isFinite else { return nil }
        return CGSize(width: x, height: y)
    }

    /// Accumulated inline ASS override state while walking an event line.
    private struct RunStyle: Equatable {
        var color: SubtitleColor?
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
        var fontName: String?
        var fontSize: Int?

        func run(_ text: String) -> SubtitleTextRun {
            SubtitleTextRun(text: text, color: color, isBold: isBold, isItalic: isItalic,
                            isUnderlined: isUnderlined, isStruckThrough: isStruckThrough,
                            fontName: fontName, fontSize: fontSize)
        }
    }

    /// Parse an ASS event line's Text body into styled runs plus the cue-level placement it asks
    /// for (#233). Every text subtitle format reaches the engine through libavcodec as one of these
    /// lines, so this single parser serves SRT (`ff_htmlmarkup_to_ass`), WebVTT, dvb_teletext
    /// (`txt_format=ass`) and ASS itself.
    ///
    /// Inline state comes from `\c`/`\1c` (BGR; a bare tag or unparseable value resets to the page
    /// default), `\b`, `\i`, `\u`, `\s`, `\fn`, `\fs` and `\r`. Cue-level `\an` and `\pos` are
    /// lifted out into the placement, with `\pos` normalized against `playRes`. Applies `\N`/`\n`
    /// -> newline and `\h` -> space. Text in drawing mode (`\p1` and up, see `drawingScale`) is
    /// vector commands and is left out. Tags that merely look like these (`\be`, `\bord`, `\iclip`,
    /// `\shad`, `\fscx`, `\fsp`) are left alone. Adjacent runs of equal styling are collapsed.
    /// nil when nothing displayable remains.
    ///
    /// `firstTextRow` is the 0-based index of the newline-delimited row the first displayable
    /// character sits on, measured BEFORE the edge trim removes it. libzvbi carries teletext
    /// row positioning in exactly that ordinal on pages it does not flag as subtitle pages
    /// (see `teletextBody`); every other format ignores it.
    static func styledRuns(fromASSEventLine line: String,
                           playRes: CGSize = SubtitleRectText.defaultASSPlayRes)
        -> (runs: [SubtitleTextRun], placement: SubtitleTextPlacement?, firstTextRow: Int)? {
        var body = capped(line)
        if body.hasPrefix("Dialogue: ") { body.removeFirst("Dialogue: ".count) }
        let parts = body.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let text: String = (parts.count == 9 && Int(parts[0]) != nil) ? String(parts[8]) : body

        var pieces: [(style: RunStyle, text: String)] = []
        var current = ""
        var style = RunStyle()
        var alignment: Int?
        var position: CGPoint?
        // In ASS drawing mode (`\p1` and up) the text is vector commands, never shown as words.
        var drawing = false

        func flush() {
            guard !current.isEmpty else { return }
            if let last = pieces.indices.last, pieces[last].style == style {
                pieces[last].text += current
            } else {
                pieces.append((style, current))
            }
            current = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "N" || n == "n" { if !drawing { current += "\n" }; i += 2; continue }
                if n == "h" { if !drawing { current += " " }; i += 2; continue }
            }
            if c == "{" {
                var j = i + 1
                var block = ""
                while j < chars.count, chars[j] != "}" { block.append(chars[j]); j += 1 }
                var next = style
                applyOverrides(block, to: &next, alignment: &alignment,
                               position: &position, playRes: playRes)
                if let scale = drawingScale(inBlock: block.utf8) { drawing = scale > 0 }
                // The text collected so far belongs to the style in force before this block.
                if next != style { flush(); style = next }
                i = (j < chars.count) ? j + 1 : j
                continue
            }
            if !drawing { current.append(c) }
            i += 1
        }
        flush()

        var runs = pieces.map { $0.style.run($0.text) }
        let placement = (alignment == nil && position == nil)
            ? nil : SubtitleTextPlacement(alignment: alignment, position: position)
        let firstTextRow = Self.firstTextRow(in: runs)
        guard let trimmed = edgeTrimmed(runs) else { return nil }
        runs = trimmed
        return (runs, placement, firstTextRow)
    }

    /// Index of the row the first displayable character sits on, counting the newline-delimited
    /// rows of the untrimmed run sequence from 0.
    private static func firstTextRow(in runs: [SubtitleTextRun]) -> Int {
        var row = 0
        for run in runs {
            for ch in run.text {
                if ch.isNewline { row += 1; continue }
                if ch.isWhitespace { continue }
                return row
            }
        }
        return row
    }

    /// Apply one override block's tags. Inline attributes mutate `style`; `\an` and `\pos` are
    /// cue-level and are lifted out instead, so they never split a run.
    private static func applyOverrides(_ block: String, to style: inout RunStyle,
                                       alignment: inout Int?, position: inout CGPoint?,
                                       playRes: CGSize) {
        for tag in block.split(separator: "\\").map(String.init) {
            if tag == "r" || (tag.hasPrefix("r") && !tag.hasPrefix("rnd")) {
                style = RunStyle()
            } else if let color = parseColorTag("\\" + tag) {
                style.color = color   // nil means reset
            } else if let v = intValue(tag, after: "b") {
                style.isBold = v != 0
            } else if let v = intValue(tag, after: "i") {
                style.isItalic = v != 0
            } else if let v = intValue(tag, after: "u") {
                style.isUnderlined = v != 0
            } else if let v = intValue(tag, after: "s") {
                style.isStruckThrough = v != 0
            } else if let v = intValue(tag, after: "an"), (1...9).contains(v) {
                alignment = v
            } else if tag.hasPrefix("fn") {
                let name = String(tag.dropFirst(2))
                style.fontName = name.isEmpty ? nil : name
            } else if tag.hasPrefix("fs"), tag.dropFirst(2).allSatisfy(\.isNumber) {
                style.fontSize = Int(tag.dropFirst(2))
            } else if let p = parsePositionTag(tag, playRes: playRes) {
                position = p
            }
        }
    }

    /// `tag` as `prefix` followed by digits and nothing else, so `\b1` parses while `\bord2`,
    /// `\be1`, `\iclip(...)` and `\shad2` do not.
    private static func intValue(_ tag: String, after prefix: String) -> Int? {
        guard tag.hasPrefix(prefix) else { return nil }
        let rest = tag.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// `pos(x,y)` normalized against the play resolution, the same [0, 1] convention
    /// `SubtitleImage.position` uses.
    private static func parsePositionTag(_ tag: String, playRes: CGSize) -> CGPoint? {
        guard tag.hasPrefix("pos("), tag.hasSuffix(")"),
              playRes.width > 0, playRes.height > 0 else { return nil }
        let inner = tag.dropFirst(4).dropLast()
        let parts = inner.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        // Audit SUB-112: a NaN or infinite tag (`Double(_:)` accepts both) breaks the [0, 1]
        // contract, and a host laying out with it raises; the cue falls back to its alignment.
        let normalized = CGPoint(x: x / playRes.width, y: y / playRes.height)
        guard normalized.x.isFinite, normalized.y.isFinite else { return nil }
        return normalized
    }

    /// Trim whitespace and newlines across the edges of a run sequence, so a styled cue matches
    /// what the plain path produces. libzvbi teletext ass can prefix a row-positioning newline that
    /// would otherwise render as a blank line ONLY on styled cues (#107). Interior blank lines are
    /// NOT folded here: that is teletext-specific and lives in `teletextBody`.
    static func edgeTrimmed(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun]? {
        var cleaned = runs.filter { !$0.text.isEmpty }
        // Edge-trim leading/trailing whitespace and newlines across the run sequence so a coloured
        // cue matches the plain path (teletextBody flattens + trims the .text case). libzvbi
        // teletext ass can prefix a row-positioning newline that would otherwise render as a blank
        // line ONLY on coloured cues (#107). Interior blank lines are folded separately below;
        // single line breaks and colours are preserved.
        // Predicate matches the plain path's `.whitespacesAndNewlines` (Unicode Zs plus tab plus
        // the newline characters). A literal-space/tab/newline test let U+00A0 survive on a styled
        // cue that an unstyled one trimmed, so the two paths disagreed on the same payload.
        // Audit SUB-110: one `removeFirst(k)`, not one shift of the whole array per blank run.
        let leadingBlank = cleaned.firstIndex { !$0.text.allSatisfy(\.isWhitespace) } ?? cleaned.count
        cleaned.removeFirst(leadingBlank)
        if let first = cleaned.first {
            cleaned[0] = first.withText(String(first.text.drop(while: \.isWhitespace)))
        }
        while let last = cleaned.last {
            var s = last.text
            while let c = s.last, c.isWhitespace { s.removeLast() }
            if s.isEmpty { cleaned.removeLast(); continue }
            cleaned[cleaned.count - 1] = last.withText(s)
            break
        }
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// Collapse interior blank lines across a run sequence (#107). libzvbi joins teletext rows with
    /// `\N`, so a caption whose lines sit on non-adjacent rows (an empty row between them, used only
    /// for vertical placement) arrives as `line1\n\nline2` and would render a blank line the
    /// broadcaster never intended. Consecutive newlines separated by nothing but horizontal
    /// whitespace fold to one; single line breaks, colours and the indentation of a real row are
    /// preserved.
    ///
    /// Folds the FLATTENED sequence and re-splits it along the original run boundaries. A per-run
    /// regex plus an adjacent-pair check missed the case the source produces most easily: the
    /// padding of an empty row carries the spacing attribute that changes colour, so the blank row
    /// can land in a whitespace-only run of its own and break the chain (`line` / whitespace run /
    /// `line`).
    private static func collapseInteriorBlankLines(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        rewritingFlattened(runs) { chars, keep in
            var i = 0
            while i < chars.count {
                guard chars[i].isNewline else { i += 1; continue }
                // Scan past horizontal whitespace and further newlines; everything up to and
                // including the last newline found is one blank-row gap and collapses onto the
                // first newline.
                var probe = i + 1
                var lastNewline = i
                while probe < chars.count {
                    let c = chars[probe]
                    if c.isNewline { lastNewline = probe }
                    else if !c.isWhitespace { break }
                    probe += 1
                }
                if lastNewline > i {
                    for k in (i + 1)...lastNewline { keep[k] = false }
                }
                i = lastNewline + 1
            }
        }
    }

    /// Trim the column padding off both ends of every row of a raw teletext grid dump (#233).
    ///
    /// On a page libzvbi does not flag as a subtitle page, `gen_sub_ass` writes each row at full
    /// column width (`decode_string(row, 0, columns)`, with `\h` for every grid space) and appends
    /// `" \N"` after it. `edgeTrimmed` only reaches the outer edges of the whole sequence, so the
    /// padding on the inside of every line break survives: a two-row caption arrives with trailing
    /// spaces on row 1 and leading spaces on row 2, which pushes a centred row off centre and makes
    /// the cue's background box wider than its text.
    ///
    /// Deliberately does NOT run on flagged pages, where the padding is the opposite of noise: there
    /// `gen_sub_ass` already trims each row and the residue it leaves is the relative indentation
    /// that carries the alignment it chose (`leading = min_leading` for left, `trailing =
    /// min_trailing` for right, both for its non-centrable centre case). See `teletextBody`.
    private static func trimGridRows(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        rewritingFlattened(runs) { chars, keep in
            // A row holds no newline by construction, so any whitespace inside one is horizontal.
            func trimRow(from start: Int, to end: Int) {
                var head = start
                while head < end, chars[head].isWhitespace { keep[head] = false; head += 1 }
                var tail = end - 1
                while tail >= head, chars[tail].isWhitespace { keep[tail] = false; tail -= 1 }
            }
            var rowStart = 0
            for (index, ch) in chars.enumerated() where ch.isNewline {
                trimRow(from: rowStart, to: index)
                rowStart = index + 1
            }
            trimRow(from: rowStart, to: chars.count)
        }
    }

    /// Let `marking` decide which characters survive on the FLATTENED sequence, then re-split the
    /// survivors along the original run boundaries.
    ///
    /// Both whitespace passes need the flattening rather than a per-run walk: the padding of a
    /// teletext row carries the spacing attribute that changes colour, so it lands in a
    /// whitespace-only run of its own and a per-run or adjacent-pair check steps right over it.
    private static func rewritingFlattened(
        _ runs: [SubtitleTextRun],
        marking: ([Character], inout [Bool]) -> Void
    ) -> [SubtitleTextRun] {
        var chars: [Character] = []
        var owner: [Int] = []
        for (index, run) in runs.enumerated() {
            for ch in run.text {
                chars.append(ch)
                owner.append(index)
            }
        }

        var keep = [Bool](repeating: true, count: chars.count)
        marking(chars, &keep)

        var texts = [String](repeating: "", count: runs.count)
        for (index, ch) in chars.enumerated() where keep[index] {
            texts[owner[index]].append(ch)
        }
        return zip(runs, texts).map { $0.withText($1) }.filter { !$0.text.isEmpty }
    }

    /// Body + placement for any text rect's ASS event line (#233): `.richText` when a run asks for
    /// styling, `.text` (flattened) when none does, nil when empty. An unstyled track therefore
    /// keeps the exact body it produced before, so a host handling only `.text` sees no change.
    static func styledBody(fromASSEventLine line: String,
                           playRes: CGSize = SubtitleRectText.defaultASSPlayRes)
        -> (body: SubtitleCue.Body, placement: SubtitleTextPlacement?)? {
        guard let parsed = styledRuns(fromASSEventLine: line, playRes: playRes) else { return nil }
        return body(for: parsed.runs).map { ($0, parsed.placement) }
    }

    /// Teletext variant (#107, #233): identical, plus the two whitespace passes libzvbi's raw grid
    /// dump requires and the grid-row placement fallback below. All three are deliberately
    /// teletext-only, since a blank line in an ASS or SRT cue can be intentional, interior
    /// indentation there can be deliberate, and a leading blank line is never a row ordinal.
    ///
    /// The passes run only on a page libzvbi did NOT flag as a subtitle page, which is exactly the
    /// page that arrives without an `\an`. `gen_sub_ass` writes such a page out as the raw grid: one
    /// full-width row per grid row, empty ones included, and the row ordinal as the only carrier of
    /// the position. On a flagged page it instead curates the output, and both of the things these
    /// passes remove become decisions there: the `empty_lines / 2` fillers are its vertical
    /// fine-positioning inside the block, and the residual padding is the relative indentation that
    /// carries the horizontal alignment it picked. Folding or trimming those deletes information
    /// rather than noise, so a curated body is passed through whole, down to the one separator
    /// space `gen_sub_ass` writes ahead of every `\N`.
    ///
    /// The two gates are the same gate. `gen_sub_ass` emits `{\anN}` on the first row of a flagged
    /// page that holds any character, and a flagged page holding none produces no cue at all, so an
    /// arriving `\an` and a curated body are equivalent.
    static func teletextBody(fromASSEventLine line: String,
                             playRes: CGSize = SubtitleRectText.defaultASSPlayRes)
        -> (body: SubtitleCue.Body, placement: SubtitleTextPlacement?)? {
        guard let parsed = styledRuns(fromASSEventLine: line, playRes: playRes) else { return nil }
        let isCurated = parsed.placement?.alignment != nil
        let placement = parsed.placement ?? gridPlacement(firstTextRow: parsed.firstTextRow)
        let runs = isCurated
            ? parsed.runs
            : trimGridRows(collapseInteriorBlankLines(parsed.runs))
        return body(for: runs).map { ($0, placement) }
    }

    /// Vertical anchor for a teletext page that carried no `\an` (#233).
    ///
    /// `gen_sub_ass` derives the anchor from the grid row and emits it as `{\anN}`, but only for
    /// pages `subtitle_map` flags as subtitle pages (row-0 header: NEWSFLASH clear AND SUBTITLE set
    /// AND SUPPRESS_HEADER set). Off that path it writes the whole page instead, one `" \N"` per
    /// grid row with the empty ones included, and the row ordinal becomes the only carrier of the
    /// position. This is that same derivation applied to the ordinal, so a page keeps the placement
    /// its broadcaster chose whether or not the flags made it through:
    ///
    ///     vertical_align = 2 - av_clip(i + 1, 0, 23) / 8
    ///     an             = alignment + vertical_align * 3
    ///
    /// with `i` the grid row (emitted row + 1, since `txt_chop_top` defaults to 1) and the
    /// horizontal alignment left at ffmpeg's own default of 2, centre. Deriving that one too is
    /// measurable now that `trimGridRows` runs, since the leading and trailing pad of each row is
    /// the column count `can_align_left` / `_right` / `_center` compare, but the analysis is not
    /// self-contained: where it leaves more than one of the three viable it resolves the tie from
    /// `last_ass_alignment`, the answer given to the PREVIOUS cue. A stateless parser has to fall
    /// back to centre there, so an unambiguous left-aligned cue followed by an ambiguous one would
    /// jump. Coarse on purpose, on both axes: three bands is what the source encodes, and mapping
    /// each row to its own offset makes consecutive cues of different heights sit at different
    /// heights, which reads as a blink.
    ///
    /// Never overrides an `\an` that arrived, including `{\an2}`: bottom is a real answer and it
    /// looks exactly like no answer.
    static func gridPlacement(firstTextRow row: Int) -> SubtitleTextPlacement {
        let gridRow = row + 1
        let verticalAlign = 2 - min(max(gridRow + 1, 0), 23) / 8
        return SubtitleTextPlacement(alignment: 2 + verticalAlign * 3, position: nil)
    }

    private static func body(for runs: [SubtitleTextRun]) -> SubtitleCue.Body? {
        if runs.contains(where: \.isStyled) { return .richText(runs) }
        let plain = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : .text(plain)
    }

    /// Parse a `\c`/`\1c` colour override tag body. Returns `.some(nil)` for a reset (bare tag or bad
    /// value), `.some(color)` for a parsed BGR value, and `nil` when the tag is not a colour tag.
    ///
    /// Deviates from the task brief's `-> (value: SubtitleColor?)?` signature: Swift rejects a
    /// single-element labeled tuple as a type ("cannot create a single-element tuple with an element
    /// label"), so this uses the semantically identical `SubtitleColor??` (double optional) instead.
    /// Behaviour (three-way nil / reset / color) is unchanged.
    private static func parseColorTag(_ tag: String) -> SubtitleColor?? {
        // Accept a block that contains \c or \1c (teletext libzvbi emits one tag per block).
        guard let range = tag.range(of: #"\\1?c(?![a-zA-Z])"#, options: .regularExpression) else { return nil }
        let after = tag[range.upperBound...]
        guard let hexRange = after.range(of: #"&H[0-9A-Fa-f]{1,6}&"#, options: .regularExpression) else {
            return .some(nil)   // bare \c => reset
        }
        let hex = after[hexRange].dropFirst(2).dropLast()   // strip &H .. &
        guard let bgr = UInt32(hex, radix: 16) else { return .some(nil) }
        let b = UInt8((bgr >> 16) & 0xFF)
        let g = UInt8((bgr >> 8) & 0xFF)
        let r = UInt8(bgr & 0xFF)
        return .some(SubtitleColor(r: r, g: g, b: b))
    }
}
