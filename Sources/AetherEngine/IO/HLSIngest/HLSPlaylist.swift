import Foundation

struct HLSVariant: Equatable {
    let bandwidth: Int
    let uri: String
    /// nil when the variant declares no alternate-audio group.
    let audioGroupID: String?
    /// nil when the variant declares no subtitle group (AE#359).
    let subtitleGroupID: String?
}

/// EXT-X-MEDIA:TYPE=AUDIO with a URI. Companion reader ingests chosen rendition for demuxed-audio variants (ARD-style).
struct HLSAudioRendition: Equatable {
    let groupID: String
    let uri: String
    let isDefault: Bool
}

/// EXT-X-MEDIA:TYPE=SUBTITLES with a URI (AE#359). Unlike audio these are never companion-demuxed:
/// the rendition is a WebVTT playlist of its own, fetched only once the host selects the track.
/// A line without a URI describes something muxed into the variant and is not a fetchable rendition.
struct HLSSubtitleRendition: Equatable {
    let groupID: String
    let uri: String
    let name: String
    let language: String?
    let isDefault: Bool
    let isForced: Bool
}

/// `demuxedAudioGroupIDs` is kept as a stable Set for O(1) membership checks even though it is derivable from `audioRenditions`. EXT-X-MEDIA without a URI means audio is muxed into the variant stream.
struct HLSMasterPlaylist: Equatable {
    let variants: [HLSVariant]
    let demuxedAudioGroupIDs: Set<String>
    let audioRenditions: [HLSAudioRendition]
    let subtitleRenditions: [HLSSubtitleRendition]
}

/// AES-128 clear-key context (Pluto/Samsung-TV+ style). `iv`: explicit EXT-X-KEY IV attribute or big-endian media-sequence number per RFC 8216 §5.2.
struct HLSSegmentCrypt: Equatable {
    let keyURI: String
    let iv: Data
}

/// EXT-X-BYTERANGE (RFC 8216 4.3.2.2): the segment is `length` bytes of its URI's resource starting
/// at `offset`, not the whole resource. A packager that writes one file per stream lists every
/// segment against that file.
struct HLSByteRange: Equatable {
    let offset: Int
    let length: Int

    /// The `Range` request header value for this sub-range.
    var requestHeaderValue: String { "bytes=\(offset)-\(offset + length - 1)" }

    /// The segment's bytes out of a 2xx answer to a request that carried `requestHeaderValue`. A 206 is
    /// the sub-range itself and must start where it was asked to and hold all of it. An origin that
    /// ignores `Range` answers 200 with the whole resource, and the sub-range is cut from it here. An
    /// answer that cannot hold the sub-range fails, since playing the wrong bytes is worse than failing
    /// the segment.
    func segmentBytes(from body: Data, status: Int, contentRange: String?) throws -> Data {
        if status == 206 {
            if let contentRange, Self.contentRangeStart(contentRange) != offset {
                throw HLSIngestError.playlistInvalid(reason: "byte range answered elsewhere")
            }
            guard body.count >= length else {
                throw HLSIngestError.playlistInvalid(reason: "byte range answered short")
            }
            return body.prefix(length)
        }
        guard body.count >= offset + length else {
            throw HLSIngestError.playlistInvalid(reason: "byte range beyond the resource")
        }
        let start = body.startIndex + offset
        return body.subdata(in: start..<(start + length))
    }

    /// The first byte position of a `Content-Range: bytes <first>-<last>/<total>` value.
    static func contentRangeStart(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes "),
              let dash = text.firstIndex(of: "-") else { return nil }
        return Int(text[text.index(text.startIndex, offsetBy: 6)..<dash].trimmingCharacters(in: .whitespaces))
    }
}

struct HLSMediaSegment: Equatable {
    let uri: String
    let duration: Double
    let discontinuityBefore: Bool
    let crypt: HLSSegmentCrypt?
    /// Wall time this segment starts at, from EXT-X-PROGRAM-DATE-TIME plus the durations since the last
    /// tag. Nil when the playlist carries none. This is the only reference two renditions of a program
    /// reliably share (AE#359): their PTS bases can differ, their PDT and media sequence do not.
    let programDateTime: Date?
    /// Nil when the segment is its whole resource.
    let byteRange: HLSByteRange?

    init(uri: String, duration: Double, discontinuityBefore: Bool, crypt: HLSSegmentCrypt? = nil,
         programDateTime: Date? = nil, byteRange: HLSByteRange? = nil) {
        self.uri = uri
        self.duration = duration
        self.discontinuityBefore = discontinuityBefore
        self.crypt = crypt
        self.programDateTime = programDateTime
        self.byteRange = byteRange
    }
}

struct HLSMediaPlaylist: Equatable {
    let targetDuration: Double
    let mediaSequence: Int
    let segments: [HLSMediaSegment]
    let hasEndList: Bool
    let isEncrypted: Bool
    /// True for SAMPLE-AES / SAMPLE-AES-CTR or AES-128 with no URI; AES-128 with a URI is supported and decrypted inline.
    let hasUnsupportedEncryption: Bool
    let hasMap: Bool
}

enum HLSPlaylist: Equatable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

/// Line-oriented RFC 8216 parser for the subset the live ingest needs. Pure (no I/O).
enum HLSPlaylistParser {

    /// Audit NET-105: the longest line any tag or URI in a real playlist comes to is a DATERANGE with
    /// a SCTE-35 payload, a few KB. A line past this is not a playlist line, and refusing it keeps every
    /// per-line helper, present and future, off a megabyte of one attribute soup.
    static let maximumLineBytes = 64 * 1024

    static func parse(_ text: String) throws -> HLSPlaylist {
        // `split(separator: "\n")` compares whole Characters, and "\r\n" is one grapheme cluster in
        // Swift, so a CRLF playlist came back as a single line (audit NET-2, NAT-3). `isNewline` is
        // true for "\r\n", "\n" and "\r" alike.
        let lines = try text
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                guard line.utf8.count <= maximumLineBytes else {
                    throw HLSIngestError.playlistInvalid(reason: "playlist line exceeds \(maximumLineBytes) bytes")
                }
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw HLSIngestError.playlistInvalid(reason: "missing #EXTM3U")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(try parseMaster(lines))
        }
        return .media(try parseMedia(lines))
    }

    static func resolve(uri: String, against base: URL) -> URL? {
        URL(string: uri, relativeTo: base)?.absoluteURL
    }

    // MARK: - Private

    private static func parseMaster(_ lines: [String]) throws -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var demuxedAudioGroups: Set<String> = []
        var audioRenditions: [HLSAudioRendition] = []
        var subtitleRenditions: [HLSSubtitleRendition] = []
        var pendingBandwidth: Int?
        var pendingAudioGroup: String?
        var pendingSubtitleGroup: String?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
                pendingAudioGroup = attribute("AUDIO", in: line)
                pendingSubtitleGroup = attribute("SUBTITLES", in: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                if attribute("TYPE", in: line) == "AUDIO",
                   let uri = attribute("URI", in: line),
                   let group = attribute("GROUP-ID", in: line) {
                    demuxedAudioGroups.insert(group)
                    audioRenditions.append(HLSAudioRendition(
                        groupID: group,
                        uri: uri,
                        isDefault: attribute("DEFAULT", in: line) == "YES"
                    ))
                } else if attribute("TYPE", in: line) == "SUBTITLES",
                          let uri = attribute("URI", in: line),
                          let group = attribute("GROUP-ID", in: line) {
                    subtitleRenditions.append(HLSSubtitleRendition(
                        groupID: group,
                        uri: uri,
                        name: attribute("NAME", in: line) ?? "",
                        language: attribute("LANGUAGE", in: line),
                        isDefault: attribute("DEFAULT", in: line) == "YES",
                        isForced: attribute("FORCED", in: line) == "YES"
                    ))
                }
            } else if !line.hasPrefix("#"), let bw = pendingBandwidth {
                variants.append(HLSVariant(bandwidth: bw, uri: line,
                                           audioGroupID: pendingAudioGroup,
                                           subtitleGroupID: pendingSubtitleGroup))
                pendingBandwidth = nil
                pendingAudioGroup = nil
                pendingSubtitleGroup = nil
            }
        }
        guard !variants.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "master playlist without variants")
        }
        return HLSMasterPlaylist(
            variants: variants,
            demuxedAudioGroupIDs: demuxedAudioGroups,
            audioRenditions: audioRenditions,
            subtitleRenditions: subtitleRenditions
        )
    }

    private static func parseMedia(_ lines: [String]) throws -> HLSMediaPlaylist {
        var targetDuration: Double?
        var mediaSequence = 0
        var segments: [HLSMediaSegment] = []
        var hasEndList = false
        var isEncrypted = false
        var hasUnsupportedEncryption = false
        var hasMap = false
        var pendingDuration: Double?
        var pendingDiscontinuity = false
        // AES-128 keys are "sticky": one EXT-X-KEY tag governs all following segments until the next tag. Pluto/Samsung-TV+ emit one tag per segment with the same URI and an incrementing explicit IV.
        var currentKeyURI: String?
        var currentExplicitIV: Data?
        // EXT-X-PROGRAM-DATE-TIME is emitted periodically, not per segment; the segments after one
        // inherit it plus the durations in between.
        var pendingDateTime: Date?
        // EXT-X-BYTERANGE applies to the next URI only. Without an offset it continues right after the
        // previous segment, which must then be a sub-range of the same resource.
        var pendingByteRange: (length: Int, offset: Int?)?
        var previousRangeEnd: (uri: String, end: Int)?

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = try boundedDuration(line.dropFirst("#EXT-X-TARGETDURATION:".count),
                                                     tag: "TARGETDURATION")
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                // A hostile or MITM value near Int.max makes `mediaSequence + segments.count`
                // overflow and trap downstream (audit NET-3); reject it here instead. A merely
                // unparseable tag keeps the pre-existing default of 0.
                if let parsed = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) {
                    guard parsed >= 0, parsed <= Int.max / 2 else {
                        throw HLSIngestError.playlistInvalid(reason: "media sequence out of range")
                    }
                    mediaSequence = parsed
                }
            } else if line.hasPrefix("#EXTINF:") {
                // The duration is the first non-empty comma field; `split` built a Substring for every
                // field of the title to find it (audit NET-105).
                let payload = line.dropFirst("#EXTINF:".count).drop(while: { $0 == "," })
                let field = payload[..<(payload.firstIndex(of: ",") ?? payload.endIndex)]
                pendingDuration = try boundedDuration(field, tag: "EXTINF")
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                switch method {
                case "NONE":
                    currentKeyURI = nil
                    currentExplicitIV = nil
                case "AES-128":
                    isEncrypted = true
                    currentKeyURI = attribute("URI", in: line)
                    currentExplicitIV = attribute("IV", in: line).flatMap(parseHexIV)
                    // A keyless AES-128 tag is unusable; treat as unsupported.
                    if currentKeyURI == nil { hasUnsupportedEncryption = true }
                default:
                    // SAMPLE-AES / SAMPLE-AES-CTR / anything else: not decryptable here.
                    isEncrypted = true
                    hasUnsupportedEncryption = true
                    currentKeyURI = nil
                    currentExplicitIV = nil
                }
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                pendingDateTime = parseProgramDateTime(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = try parseByteRange(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                hasMap = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                let crypt: HLSSegmentCrypt?
                if let keyURI = currentKeyURI {
                    let sequence = mediaSequence + segments.count
                    crypt = HLSSegmentCrypt(
                        keyURI: keyURI,
                        iv: currentExplicitIV ?? sequenceIV(sequence)
                    )
                } else {
                    crypt = nil
                }
                let segmentDuration = pendingDuration ?? targetDuration ?? 0
                let segmentDate = pendingDateTime
                if let segmentDate { pendingDateTime = segmentDate.addingTimeInterval(segmentDuration) }
                var byteRange: HLSByteRange?
                if let pending = pendingByteRange {
                    let offset: Int
                    if let explicit = pending.offset {
                        offset = explicit
                    } else if let previous = previousRangeEnd, previous.uri == line {
                        offset = previous.end
                    } else {
                        // No previous sub-range of this URI to continue (RFC 8216: MUST fail to parse).
                        throw HLSIngestError.playlistInvalid(reason: "BYTERANGE offset undefined")
                    }
                    guard offset <= Int.max - pending.length else {
                        throw HLSIngestError.playlistInvalid(reason: "BYTERANGE out of range")
                    }
                    byteRange = HLSByteRange(offset: offset, length: pending.length)
                }
                previousRangeEnd = byteRange.map { (line, $0.offset + $0.length) }
                segments.append(HLSMediaSegment(
                    uri: line,
                    duration: segmentDuration,
                    discontinuityBefore: pendingDiscontinuity,
                    crypt: crypt,
                    programDateTime: segmentDate,
                    byteRange: byteRange
                ))
                pendingDuration = nil
                pendingDiscontinuity = false
                pendingByteRange = nil
            }
        }
        guard let target = targetDuration else {
            throw HLSIngestError.playlistInvalid(reason: "missing TARGETDURATION")
        }
        guard !segments.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "no segments")
        }
        return HLSMediaPlaylist(
            targetDuration: target,
            mediaSequence: mediaSequence,
            segments: segments,
            hasEndList: hasEndList,
            isEncrypted: isEncrypted,
            hasUnsupportedEncryption: hasUnsupportedEncryption,
            hasMap: hasMap
        )
    }

    /// A duration tag's value; nil when it does not parse, which keeps the pre-existing fallbacks.
    /// `Double(_:)` accepts `inf`, `nan` and any magnitude, and every consumer converts to an integer
    /// somewhere downstream (audit NET-101), so a non-finite value or one past the program ceiling is
    /// refused here. Negatives are left to the consumers: they trap nothing, and a sloppy live origin
    /// should not lose its channel over one.
    private static func boundedDuration(_ text: Substring, tag: String) throws -> Double? {
        guard let value = Double(text) else { return nil }
        guard value.isFinite, value <= MediaDurationCeiling.seconds else {
            throw HLSIngestError.playlistInvalid(reason: "\(tag) out of range")
        }
        return value
    }

    /// `<length>[@<offset>]`, both decimal integers. A zero length names no bytes, so it is refused
    /// with the malformed forms rather than fetched as a request no origin can answer.
    private static func parseByteRange(_ text: Substring) throws -> (length: Int, offset: Int?) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let length = Int(parts[0]), length > 0 else {
            throw HLSIngestError.playlistInvalid(reason: "malformed BYTERANGE")
        }
        guard parts.count == 2 else { return (length, nil) }
        guard let offset = Int(parts[1]), offset >= 0 else {
            throw HLSIngestError.playlistInvalid(reason: "malformed BYTERANGE")
        }
        return (length, offset)
    }

    /// Parse a `0x`-prefixed hex EXT-X-KEY IV into 16-byte big-endian Data. Returns nil on malformed length (caller falls back to sequence-number IV).
    /// ISO 8601 with fractional seconds is what every broadcaster emits; the plain form is accepted
    /// because the spec allows it.
    private static func parseProgramDateTime(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        return (try? fractionalDateStyle.parse(text)) ?? (try? plainDateStyle.parse(text))
    }

    /// Audit NET-106: two `ISO8601DateFormatter`s were built per PROGRAM-DATE-TIME line, 1.1 to 1.6 s
    /// for a 3600-segment window that carries one on every segment. Value-type styles are built once.
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainDateStyle = Date.ISO8601FormatStyle()

    private static func parseHexIV(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }

    /// RFC 8216 default IV: 16-byte big-endian segment media-sequence number.
    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var value = UInt64(bitPattern: Int64(sequence))
        for offset in 0..<8 {
            iv[15 - offset] = UInt8(value & 0xFF)
            value >>= 8
        }
        return iv
    }

    /// Extract a KEY=VALUE attribute from a tag line, tolerating quoted values. Match is anchored to `:` or `,` before the key: bare substring search matched `BANDWIDTH=` inside `AVERAGE-BANDWIDTH=` and caused wrong variant selection.
    /// Internal rather than private since #316: the master rewriter reads the same attributes off the
    /// same tag lines, and a second parser would be a second place for the anchoring trap to reappear.
    ///
    /// One left-to-right pass that carries the quote parity along. It recounted the quotes from the
    /// line start for every `KEY=` it met, so a line of unclosed quote plus thousands of `,KEY=` took
    /// time quadratic in its length, 9.6 s at 64 KiB (audit NET-105, NAT-102). Scanned as UTF-8: the
    /// delimiters are ASCII.
    static func attribute(_ key: String, in line: String) -> String? {
        let needle = Array("\(key)=".utf8)
        var line = line
        return line.withUTF8 { bytes -> String? in
            let count = bytes.count
            var insideQuotes = false
            var index = 0
            while index < count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    insideQuotes.toggle()
                    index += 1
                    continue
                }
                guard !insideQuotes, byte == needle[0], index + needle.count <= count,
                      index == 0 || bytes[index - 1] == UInt8(ascii: ":") || bytes[index - 1] == UInt8(ascii: ","),
                      needle.indices.allSatisfy({ bytes[index + $0] == needle[$0] })
                else {
                    index += 1
                    continue
                }
                let valueStart = index + needle.count
                if valueStart < count, bytes[valueStart] == UInt8(ascii: "\"") {
                    let quoted = UnsafeBufferPointer(rebasing: bytes[(valueStart + 1)...])
                    guard let end = quoted.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
                    return String(decoding: UnsafeBufferPointer(rebasing: quoted[..<end]), as: UTF8.self)
                }
                let rest = UnsafeBufferPointer(rebasing: bytes[valueStart...])
                let end = rest.firstIndex(of: UInt8(ascii: ",")) ?? rest.endIndex
                return String(decoding: UnsafeBufferPointer(rebasing: rest[..<end]), as: UTF8.self)
            }
            return nil
        }
    }
}
