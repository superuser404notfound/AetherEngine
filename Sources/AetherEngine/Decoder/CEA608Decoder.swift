import Foundation

/// Minimal CEA-608 (line-21) caption decoder. Issue #77, first cut: **field 1 / channel CC1 only**.
/// Field 2 and CEA-708 (DTVCC) are intentionally out of scope and dropped by the caller.
///
/// Consumes the `(cc_data_1, cc_data_2)` byte pairs from field-1 triplets (see `CCDataParser`) in
/// display order and produces high-level `Action`s (show a snapshot of the displayed caption, or clear
/// it). The tap turns those into `SubtitleCue`s on the host-overlay path, so 608 renders through the
/// same `subtitleCues` array as every other subtitle codec.
///
/// Supports pop-on (RCL/EOC/EDM/ENM), roll-up (RU2/3/4 + CR), and paint-on (RDC); PAC row addressing;
/// mid-row codes; and the basic / special / extended character sets. Behaviour validated against
/// FFmpeg's `ccaption_dec.c` (the decoder mpv/VLC mirror): odd-parity validation, doubled-control
/// suppression, the character-set overrides, and PAC bounds all follow it. Not thread-safe.
final class CEA608Decoder {

    enum Action: Equatable {
        /// The full displayed caption changed to this text (rows joined with "\n"); show it from `pts`.
        case display(String)
        /// The displayed caption was erased.
        case clear
    }

    private enum Mode { case popOn, rollUp(Int), paintOn }

    private static let rowCount = 15
    private static let colCount = 32

    /// Two screen buffers; pop-on builds in the hidden one and EOC flips them.
    private var displayed: [[Character]] = CEA608Decoder.blankScreen()
    private var hidden: [[Character]] = CEA608Decoder.blankScreen()

    private var mode: Mode = .popOn
    private var cursorRow = CEA608Decoder.rowCount - 1
    private var cursorCol = 0
    /// Bottom (base) row of the roll-up window.
    private var rollBaseRow = CEA608Decoder.rowCount - 1

    /// Which service the characters on field 1 currently belong to. Every control code names its data
    /// channel (0x10-0x17 CC1, 0x18-0x1F CC2) and an XDS code (0x01-0x0F) starts an XDS packet, so the
    /// characters that follow belong to that service until the next control code; CC1's TR and RTD hand
    /// them to the text service T1 until RCL, RU2-4 or RDC. Only CC1 caption characters reach the screen.
    private var dataChannelIsCC1 = true
    private var inTextService = false

    /// Last control pair processed, for doubled-control-code suppression. Mirrors FFmpeg's `prev_cmd`:
    /// set on every processed control pair, cleared only after a standard character pair, so a control
    /// transmitted twice is processed once, and even a 3× burst stays suppressed until a different pair
    /// arrives (NOT re-applied as the old self-clearing logic did).
    private var lastControlPair: (UInt8, UInt8)?
    /// Last emitted rendering of the displayed screen, to suppress duplicate `.display` actions.
    private var lastRendered = ""

    private static func blankScreen() -> [[Character]] {
        Array(repeating: [Character](repeating: " ", count: colCount), count: rowCount)
    }

    /// Clear all state. Called on a seek discontinuity so stale roll-up / pop-on memory from the old
    /// position can't bleed into the new one.
    func reset() {
        displayed = CEA608Decoder.blankScreen()
        hidden = CEA608Decoder.blankScreen()
        mode = .popOn
        cursorRow = CEA608Decoder.rowCount - 1
        cursorCol = 0
        rollBaseRow = CEA608Decoder.rowCount - 1
        lastControlPair = nil
        lastRendered = ""
        dataChannelIsCC1 = true
        inTextService = false
    }

    /// True when `b` carries correct odd parity (line-21 sets bit 7 so each byte has an odd number of 1s).
    private static func hasOddParity(_ b: UInt8) -> Bool { b.nonzeroBitCount % 2 == 1 }

    /// Feed one field-1 byte pair (still parity-bearing). Returns 0+ actions to apply.
    func feed(_ b0raw: UInt8, _ b1raw: UInt8) -> [Action] {
        // Parity validation (FFmpeg `validate_cc_data_pair`): a bad high byte invalidates the whole pair;
        // a bad low byte is replaced with 0x7F (the solid-block error glyph) rather than trusted.
        guard Self.hasOddParity(b0raw) else { return [] }
        let b0 = b0raw & 0x7F
        let b1 = Self.hasOddParity(b1raw) ? (b1raw & 0x7F) : 0x7F

        // Null padding.
        if b0 == 0 && b1 == 0 { return [] }

        if b0 >= 0x01 && b0 <= 0x0F {
            dataChannelIsCC1 = false
            lastControlPair = nil
            return []
        }

        let isControl = (b0 >= 0x10 && b0 <= 0x1F)
        if isControl {
            dataChannelIsCC1 = b0 <= 0x17
            // Doubled control: suppress an identical immediately-repeated pair, but DON'T clear
            // `lastControlPair` (FFmpeg keeps prev_cmd set; only a standard char clears it).
            if let last = lastControlPair, last == (b0, b1) { return [] }
            lastControlPair = (b0, b1)
            return handleControl(b0, b1)
        }

        // Standard character pair of the current data channel. Clears the doubled-control guard.
        lastControlPair = nil
        guard dataChannelIsCC1, !inTextService else { return [] }
        if b0 >= 0x20 {
            writeChar(Self.basicChar(b0))
            if b1 >= 0x20 { writeChar(Self.basicChar(b1)) }
        }
        // Character writes only change the *displayed* screen in roll-up / paint-on (pop-on builds into
        // the hidden buffer). Emitting per character would spam a cue per keystroke in roll-up, which is
        // wrong, FFmpeg emits per completed line. So display snapshots are produced only by the control
        // codes that actually flip/roll/erase the screen (see handleMiscControl), never here.
        return []
    }

    /// Flush after EOF: emit any pending displayed snapshot.
    func flush() -> [Action] { emitIfChanged() }

    // MARK: - Control handling

    private func handleControl(_ b0: UInt8, _ b1: UInt8) -> [Action] {
        // CC1 (channel 1) uses b0 0x10–0x17; CC2 uses 0x18–0x1F. First cut: CC1 only.
        guard b0 <= 0x17 else { return [] }
        if b0 == 0x14, let entersText = Self.serviceSwitch(b1) { inTextService = entersText }
        guard !inTextService else { return [] }

        // Misc control: 0x14 + 0x20…0x2F.
        if b0 == 0x14, b1 >= 0x20, b1 <= 0x2F {
            return handleMiscControl(b1)
        }
        // Mid-row style code: 0x11 + 0x20…0x2F, or 0x17 + 0x2E…0x2F (italics/underline). Each occupies one
        // space cell (FFmpeg `handle_textattr` → write_char(' ')). Styling itself is not rendered.
        if (b0 == 0x11 && b1 >= 0x20 && b1 <= 0x2F) || (b0 == 0x17 && b1 >= 0x2E && b1 <= 0x2F) {
            writeChar(" ")
            return []
        }
        // Special characters: 0x11 + 0x30…0x3F.
        if b0 == 0x11, b1 >= 0x30, b1 <= 0x3F {
            writeChar(Self.specialChars[Int(b1 - 0x30)])
            return []
        }
        // Extended West-European: 0x12 (Spanish/French) or 0x13 (Portuguese/German/Danish), + 0x20…0x3F.
        // These replace the preceding standard character.
        if (b0 == 0x12 || b0 == 0x13), b1 >= 0x20, b1 <= 0x3F {
            backspace()
            let table = (b0 == 0x12) ? Self.extendedFrSp : Self.extendedPtDeDa
            writeChar(table[Int(b1 - 0x20)])
            return []
        }
        // Tab offset: 0x17 + 0x21…0x23.
        if b0 == 0x17, b1 >= 0x21, b1 <= 0x23 {
            for _ in 0..<Int(b1 - 0x20) { advanceColumn() }
            return []
        }
        // Preamble Address Code. Valid b1 range is 0x40…0x7F for b0 0x11–0x17, but only 0x40…0x5F for
        // b0 0x10 (FFmpeg `process_cc608`); 0x10 + 0x60…0x7F is not a PAC.
        if b1 >= 0x40, b1 <= 0x7F {
            if b0 == 0x10 && b1 > 0x5F { return [] }
            applyPAC(b0, b1)
            return []
        }
        return []
    }

    /// RCL, RU2-4 and RDC enter the caption service; TR and RTD enter the text service. Nil for the rest.
    private static func serviceSwitch(_ b1: UInt8) -> Bool? {
        switch b1 {
        case 0x20, 0x25, 0x26, 0x27, 0x29: return false
        case 0x2A, 0x2B: return true
        default: return nil
        }
    }

    private func handleMiscControl(_ b1: UInt8) -> [Action] {
        switch b1 {
        case 0x20:  // RCL: Resume Caption Loading (pop-on)
            mode = .popOn
            return []
        case 0x21:  // BS: Backspace
            backspace()
            return emitIfChanged()
        case 0x24:  // DER: Delete to End of Row
            clearRow(cursorRow, from: cursorCol)
            return emitIfChanged()
        case 0x25, 0x26, 0x27:  // RU2 / RU3 / RU4: Roll-up with 2/3/4 rows
            let rows = Int(b1 - 0x23)   // 0x25→2, 0x26→3, 0x27→4
            mode = .rollUp(rows)
            rollBaseRow = cursorRow
            return []
        case 0x29:  // RDC: Resume Direct Captioning (paint-on)
            mode = .paintOn
            return []
        case 0x2C:  // EDM: Erase Displayed Memory
            displayed = Self.blankScreen()
            return emitIfChanged()
        case 0x2D:  // CR: Carriage Return (roll-up: roll the window up one row)
            if case .rollUp(let rows) = mode { rollUp(rows: rows) }
            return emitIfChanged()
        case 0x2E:  // ENM: Erase Non-displayed Memory
            hidden = Self.blankScreen()
            return []
        case 0x2F:  // EOC: End Of Caption (flip hidden <-> displayed)
            swap(&displayed, &hidden)
            return emitIfChanged()
        default:
            return []
        }
    }

    // MARK: - Geometry

    /// Active write buffer: hidden for pop-on, displayed for roll-up / paint-on.
    private func writeChar(_ c: Character) {
        if case .popOn = mode {
            place(c, in: &hidden)
        } else {
            place(c, in: &displayed)
        }
    }

    private func place(_ c: Character, in screen: inout [[Character]]) {
        guard cursorRow >= 0, cursorRow < Self.rowCount,
              cursorCol >= 0, cursorCol < Self.colCount else { return }
        screen[cursorRow][cursorCol] = c
        advanceColumn()
    }

    private func advanceColumn() {
        if cursorCol < Self.colCount - 1 { cursorCol += 1 }
    }

    private func backspace() {
        if cursorCol > 0 { cursorCol -= 1 }
        let useHidden: Bool = { if case .popOn = mode { return true } else { return false } }()
        if useHidden { hidden[cursorRow][cursorCol] = " " }
        else { displayed[cursorRow][cursorCol] = " " }
    }

    private func clearRow(_ row: Int, from col: Int) {
        guard row >= 0, row < Self.rowCount else { return }
        let useHidden: Bool = { if case .popOn = mode { return true } else { return false } }()
        for c in max(0, col)..<Self.colCount {
            if useHidden { hidden[row][c] = " " } else { displayed[row][c] = " " }
        }
    }

    private func applyPAC(_ b0: UInt8, _ b1: UInt8) {
        if let (first, second) = Self.pacRows[b0] {
            cursorRow = (b1 >= 0x60) ? second : first
        }
        cursorCol = 0
        if case .rollUp = mode { rollBaseRow = cursorRow }
    }

    private func rollUp(rows: Int) {
        let bottom = rollBaseRow
        let top = max(0, bottom - rows + 1)
        guard top < bottom else {
            displayed[bottom] = [Character](repeating: " ", count: Self.colCount)
            cursorRow = bottom; cursorCol = 0
            return
        }
        for r in top..<bottom { displayed[r] = displayed[r + 1] }
        displayed[bottom] = [Character](repeating: " ", count: Self.colCount)
        cursorRow = bottom
        cursorCol = 0
    }

    // MARK: - Rendering

    private func emitIfChanged() -> [Action] {
        let rendered = render(displayed)
        guard rendered != lastRendered else { return [] }
        lastRendered = rendered
        return [rendered.isEmpty ? .clear : .display(rendered)]
    }

    private func render(_ screen: [[Character]]) -> String {
        screen
            .map { String($0).replacingOccurrences(of: "\u{00A0}", with: " ")
                             .trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Character tables (validated against FFmpeg ccaption_dec.c charset_overrides)

    /// Basic North American set: ASCII with the 608-specific substitutions.
    static func basicChar(_ b: UInt8) -> Character {
        switch b {
        case 0x27: return "\u{2019}"   // right single quotation mark ’
        case 0x2A: return "á"
        case 0x5C: return "é"
        case 0x5E: return "í"
        case 0x5F: return "ó"
        case 0x60: return "ú"
        case 0x7B: return "ç"
        case 0x7C: return "÷"
        case 0x7D: return "Ñ"
        case 0x7E: return "ñ"
        case 0x7F: return "█"
        default:
            let scalar = Unicode.Scalar(b)
            return (b >= 0x20 && b < 0x7F) ? Character(scalar) : " "
        }
    }

    /// Special characters: 0x11 + (0x30…0x3F).
    static let specialChars: [Character] = [
        "®", "°", "½", "¿", "™", "¢", "£", "♪",
        "à", "\u{00A0}", "è", "â", "ê", "î", "ô", "û",
    ]

    /// Extended Spanish / French: 0x12 + (0x20…0x3F).
    static let extendedFrSp: [Character] = [
        "Á", "É", "Ó", "Ú", "Ü", "ü", "´", "¡",
        "*", "‘", "-", "©", "℠", "·", "“", "”",
        "À", "Â", "Ç", "È", "Ê", "Ë", "ë", "Î",
        "Ï", "ï", "Ô", "Ù", "ù", "Û", "«", "»",
    ]

    /// Extended Portuguese / German / Danish: 0x13 + (0x20…0x3F).
    static let extendedPtDeDa: [Character] = [
        "Ã", "ã", "Í", "Ì", "ì", "Ò", "ò", "Õ",
        "õ", "{", "}", "\\", "^", "_", "¦", "~",
        "Ä", "ä", "Ö", "ö", "ß", "¥", "¤", "│",
        "Å", "å", "Ø", "ø", "┌", "┐", "└", "┘",
    ]

    /// PAC base row per b0 (first = b1<0x60, second = b1>=0x60), 0-based row index. `0x10` only ever maps
    /// to row 10 (its 0x60+ slot is rejected upstream in handleControl).
    static let pacRows: [UInt8: (Int, Int)] = [
        0x11: (0, 1),
        0x12: (2, 3),
        0x15: (4, 5),
        0x16: (6, 7),
        0x17: (8, 9),
        0x10: (10, 10),
        0x13: (11, 12),
        0x14: (13, 14),
    ]
}
