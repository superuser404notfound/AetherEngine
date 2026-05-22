import Foundation

/// Parses captured init.mp4 (`ftyp` + `moov`) bytes and emits a
/// human-readable summary of the audio sample entry and any associated
/// codec-specific extension box (`dec3` for EAC3, `dac3` for AC3,
/// `dfLa` for FLAC). Used to diagnose differences between bridge-
/// encoded output and stream-copy output that affect AVPlayer's
/// bitstream-passthrough routing decision.
///
/// Why: on Sonos Arc the bridge-encoded EAC3 5.1 plays as stereo while
/// stream-copy AC3 5.1 from the same player path plays as surround.
/// Both produce a sample entry with channelcount=6, but tvOS chooses
/// different output routes for them. The `dec3` box's data_rate /
/// bsid / bsmod / acmod / lfeon fields are the only EAC3-specific
/// signals AVPlayer reads, so this inspector dumps them on first init
/// segment so we can compare what each path actually writes.
///
/// Not a full ISOBMFF parser. Only walks the path
/// `ftyp` ... `moov` -> `trak` -> `mdia` -> `minf` -> `stbl` -> `stsd`
/// -> audio entry -> extension box. Skips unknown boxes.
enum InitSegmentInspector {
    /// Box tag as a 4-byte ASCII identifier.
    private struct BoxTag: Equatable {
        let bytes: (UInt8, UInt8, UInt8, UInt8)
        init(_ s: String) {
            let chars = Array(s.utf8)
            bytes = (chars[0], chars[1], chars[2], chars[3])
        }
        static func == (l: BoxTag, r: BoxTag) -> Bool {
            l.bytes == r.bytes
        }
    }

    /// Walks the init bytes, finds the first audio sample entry under
    /// `moov/trak/mdia/minf/stbl/stsd`, and logs:
    ///   - the sample-entry header (channelcount, samplesize, samplerate)
    ///   - the codec-specific extension box, parsed where understood
    ///     (`dec3`, `dac3`, `dfLa`) or dumped as hex otherwise.
    static func dumpAudioSampleEntry(initBytes: Data, sessionLabel: String) {
        guard let stsdBody = findBoxBody(in: initBytes, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            EngineLog.emit(
                "[InitSegmentInspector] \(sessionLabel): stsd not found in init.mp4 (\(initBytes.count) B)",
                category: .session
            )
            return
        }

        // The first stsd in audio's trak is the audio sample entry. But
        // an init.mp4 may carry multiple trak boxes (video + audio).
        // findBoxBody returned the first one we hit, which is video.
        // Walk all traks instead.
        guard let moov = findBoxBody(in: initBytes, path: ["moov"]) else { return }
        for trakBody in iterateBoxes(in: moov, tag: "trak") {
            guard let stsd = walkPath(in: trakBody, path: ["mdia", "minf", "stbl", "stsd"]) else { continue }
            // Skip stsd 8-byte fullbox header (version + flags) and
            // 4-byte entry_count, then read one sample entry.
            guard stsd.count >= 8 else { continue }
            let entries = stsd.subdata(in: 8..<stsd.count)
            guard entries.count >= 8 else { continue }
            // Each entry: size(4) + type(4) + ...
            let entrySize = readU32BE(entries, offset: 0)
            guard entrySize >= 8, Int(entrySize) <= entries.count else { continue }
            let entryType = entries.subdata(in: 4..<8)
            let typeString = asciiString(entryType)
            guard isAudioSampleEntryType(typeString) else {
                // This trak is probably video. Try the next trak.
                _ = stsdBody  // silence warning
                continue
            }
            let entryBody = entries.subdata(in: 0..<Int(entrySize))
            dumpAudioEntry(entryBody, typeString: typeString, sessionLabel: sessionLabel)
            return
        }
        EngineLog.emit(
            "[InitSegmentInspector] \(sessionLabel): no audio sample entry found in init.mp4",
            category: .session
        )
    }

    private static func isAudioSampleEntryType(_ s: String) -> Bool {
        switch s {
        case "ec-3", "ac-3", "fLaC", "alac", "mp4a", "Opus", "twos", "sowt":
            return true
        default:
            return false
        }
    }

    private static func dumpAudioEntry(_ entry: Data, typeString: String, sessionLabel: String) {
        // Sample entry layout (mp4 AudioSampleEntry):
        //   size(4) + type(4) + reserved(6) + data_reference_index(2)
        //   + reserved(8) + channelcount(2) + samplesize(2)
        //   + pre_defined(2) + reserved(2) + samplerate(4, fixed16.16)
        // Total header = 36 bytes before any codec-specific extension.
        guard entry.count >= 36 else {
            EngineLog.emit(
                "[InitSegmentInspector] \(sessionLabel): sample entry '\(typeString)' too short (\(entry.count) B)",
                category: .session
            )
            return
        }
        let channelcount = readU16BE(entry, offset: 24)
        let samplesize = readU16BE(entry, offset: 26)
        // samplerate is 16.16 fixed point; high 16 bits are the integer.
        let samplerate = readU16BE(entry, offset: 32)

        var summary = "[InitSegmentInspector] \(sessionLabel): audio sample entry '\(typeString)' "
        summary += "ch=\(channelcount) bits=\(samplesize) sr=\(samplerate)"

        // Walk the extension boxes after the sample entry header.
        let extOffset = 36
        if extOffset < entry.count {
            let extData = entry.subdata(in: extOffset..<entry.count)
            for ext in iterateAllBoxes(in: extData) {
                let extTag = asciiString(ext.tag)
                switch extTag {
                case "dec3":
                    summary += " | " + parseDec3(ext.body)
                case "dac3":
                    summary += " | " + parseDac3(ext.body)
                case "dfLa":
                    summary += " | dfLa(\(ext.body.count) B)"
                case "btrt":
                    summary += " | " + parseBtrt(ext.body)
                case "chnl":
                    summary += " | chnl(\(ext.body.count) B)"
                default:
                    summary += " | \(extTag)(\(ext.body.count) B)"
                }
            }
        }

        EngineLog.emit(summary, category: .session)
    }

    /// Parse the EAC3 specific box (ISO/IEC 14496-12 EC3SpecificBox).
    /// Layout: data_rate(13) num_ind_sub(3) + per substream
    /// [fscod(2) bsid(5) reserved(1) asvc(1) bsmod(3) acmod(3)
    ///  lfeon(1) reserved(3) num_dep_sub(4) (chan_loc(9) | reserved(1))]
    /// + optional [reserved(7) flag_ec3_ext_type_a(1) complexity(8)]
    private static func parseDec3(_ body: Data) -> String {
        guard body.count >= 2 else { return "dec3(short, \(body.count) B)" }
        let bits = BitReader(data: body)
        guard let dataRate = bits.read(13),
              let numIndSub = bits.read(3) else {
            return "dec3(parse-failed)"
        }
        var parts: [String] = []
        parts.append("dec3 dataRate=\(dataRate)kbps numIndSub=\(numIndSub + 1)")
        for i in 0...numIndSub {
            guard let fscod = bits.read(2),
                  let bsid = bits.read(5),
                  let _reserved1 = bits.read(1),
                  let asvc = bits.read(1),
                  let bsmod = bits.read(3),
                  let acmod = bits.read(3),
                  let lfeon = bits.read(1),
                  let _reserved2 = bits.read(3),
                  let numDepSub = bits.read(4) else {
                parts.append("sub\(i):parse-failed")
                break
            }
            _ = _reserved1; _ = _reserved2
            var sub = "sub\(i)[fscod=\(fscod) bsid=\(bsid) bsmod=\(bsmod) acmod=\(acmod) lfeon=\(lfeon) asvc=\(asvc) numDepSub=\(numDepSub)"
            if numDepSub == 0 {
                _ = bits.read(1)
            } else {
                if let chanLoc = bits.read(9) {
                    sub += " chanLoc=0x\(String(chanLoc, radix: 16))"
                }
            }
            sub += "]"
            parts.append(sub)
        }
        if let reservedTail = bits.read(7), let extFlag = bits.read(1) {
            _ = reservedTail
            if extFlag == 1, let complexity = bits.read(8) {
                parts.append("flagExtTypeA=1 complexity=\(complexity)")
            }
        }
        parts.append("rawHex=\(hexString(body))")
        return parts.joined(separator: " ")
    }

    /// Parse the AC3 specific box (AC3SpecificBox).
    /// Layout: fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1) bit_rate_code(5) reserved(5)
    private static func parseDac3(_ body: Data) -> String {
        guard body.count >= 3 else { return "dac3(short)" }
        let bits = BitReader(data: body)
        guard let fscod = bits.read(2),
              let bsid = bits.read(5),
              let bsmod = bits.read(3),
              let acmod = bits.read(3),
              let lfeon = bits.read(1),
              let bitRateCode = bits.read(5) else {
            return "dac3(parse-failed)"
        }
        return "dac3 fscod=\(fscod) bsid=\(bsid) bsmod=\(bsmod) acmod=\(acmod) lfeon=\(lfeon) bitRateCode=\(bitRateCode) rawHex=\(hexString(body))"
    }

    private static func parseBtrt(_ body: Data) -> String {
        guard body.count >= 12 else { return "btrt(short)" }
        let bufferSize = readU32BE(body, offset: 0)
        let maxBitRate = readU32BE(body, offset: 4)
        let avgBitRate = readU32BE(body, offset: 8)
        return "btrt bufSize=\(bufferSize) maxRate=\(maxBitRate) avgRate=\(avgBitRate)"
    }

    // MARK: - ISOBMFF helpers

    private struct BoxEntry {
        let tag: Data
        let body: Data
    }

    /// Yields one box at a time at the current depth, starting at `data`'s
    /// beginning. Each box: size(4) + type(4) + body. Size==1 means
    /// 64-bit size follows (we don't support that for init segments).
    private static func iterateAllBoxes(in data: Data) -> [BoxEntry] {
        var entries: [BoxEntry] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(readU32BE(data, offset: offset))
            if size < 8 || offset + size > data.count {
                break
            }
            let tag = data.subdata(in: (offset + 4)..<(offset + 8))
            let body = data.subdata(in: (offset + 8)..<(offset + size))
            entries.append(BoxEntry(tag: tag, body: body))
            offset += size
        }
        return entries
    }

    private static func iterateBoxes(in data: Data, tag tagString: String) -> [Data] {
        var bodies: [Data] = []
        var offset = 0
        let want = Array(tagString.utf8)
        while offset + 8 <= data.count {
            let size = Int(readU32BE(data, offset: offset))
            if size < 8 || offset + size > data.count {
                break
            }
            let match = data[offset + 4] == want[0]
                && data[offset + 5] == want[1]
                && data[offset + 6] == want[2]
                && data[offset + 7] == want[3]
            if match {
                bodies.append(data.subdata(in: (offset + 8)..<(offset + size)))
            }
            offset += size
        }
        return bodies
    }

    /// Walk down a path of box tags, returning the innermost body or
    /// `nil` if any segment isn't found. Used for boxes that appear at
    /// most once at each level (e.g. moov, trak, mdia, minf, stbl).
    private static func walkPath(in data: Data, path: [String]) -> Data? {
        var current = data
        for tag in path {
            let candidates = iterateBoxes(in: current, tag: tag)
            guard let first = candidates.first else { return nil }
            current = first
        }
        return current
    }

    private static func findBoxBody(in data: Data, path: [String]) -> Data? {
        return walkPath(in: data, path: path)
    }

    // MARK: - Bit / byte readers

    private static func readU32BE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readU16BE(_ data: Data, offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return (b0 << 8) | b1
    }

    private static func asciiString(_ data: Data) -> String {
        let bytes = data.map { byte -> Character in
            (byte >= 0x20 && byte <= 0x7E) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(bytes)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private final class BitReader {
        private let bytes: [UInt8]
        private var bitOffset: Int = 0

        init(data: Data) {
            self.bytes = Array(data)
        }

        func read(_ n: Int) -> UInt32? {
            guard n > 0, n <= 32 else { return nil }
            let endBit = bitOffset + n
            guard endBit <= bytes.count * 8 else { return nil }
            var value: UInt32 = 0
            for i in 0..<n {
                let absBit = bitOffset + i
                let byte = bytes[absBit / 8]
                let bit = (byte >> (7 - (absBit % 8))) & 1
                value = (value << 1) | UInt32(bit)
            }
            bitOffset = endBit
            return value
        }
    }
}
