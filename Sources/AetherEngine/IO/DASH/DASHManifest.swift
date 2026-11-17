import Foundation

/// AE#859: the part of an MPEG-DASH MPD the engine plays: one static Period whose representations
/// each live in a single file addressed by `SegmentBase` (the on-demand profile). Everything else a
/// manifest can say is either carried through (language, label) or refused with a reason
/// (`DASHSourceError`), never guessed at.
struct DASHManifest: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case video, audio, text, other
    }

    /// The bytes of one representation's file the engine needs before it can lay the file out.
    struct SegmentBase: Equatable, Sendable {
        /// Inclusive byte range of the initialization segment (ftyp + moov).
        var initialization: ClosedRange<Int64>
        /// Inclusive byte range of the segment index (the top-level `sidx`).
        var index: ClosedRange<Int64>
    }

    /// Why a representation cannot be played, kept so the error names the real reason.
    enum Unplayable: Equatable, Sendable, CustomStringConvertible {
        case encrypted
        case segmentTemplate
        case segmentList
        case noSegmentIndex
        case separateInitializationFile

        var description: String {
            switch self {
            case .encrypted: return "it is encrypted (ContentProtection)"
            case .segmentTemplate: return "it is addressed by SegmentTemplate"
            case .segmentList: return "it is addressed by SegmentList"
            case .noSegmentIndex: return "its SegmentBase names no indexRange"
            case .separateInitializationFile: return "its initialization segment is a separate file"
            }
        }
    }

    struct Representation: Equatable, Sendable {
        var id: String
        var kind: Kind
        var mimeType: String?
        var codecs: String?
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var language: String?
        var label: String?
        var url: URL
        /// nil exactly when `unplayable` is set.
        var segmentBase: SegmentBase?
        var unplayable: Unplayable?
    }

    struct AdaptationSet: Equatable, Sendable {
        var kind: Kind
        var representations: [Representation]
    }

    var isDynamic: Bool
    var periodCount: Int
    var durationSeconds: Double?
    var adaptationSets: [AdaptationSet]

    /// Audio tracks carried at most. Each one is its own file, reader, URLSession and block cache (up to
    /// 8 MiB), and an 8 MB MPD can declare tens of thousands of sets (audit NET-204). Real
    /// presentations carry a handful of languages; 16 leaves room and bounds the cost near 128 MiB.
    static let maxAudioRepresentations = 16

    /// The representations the engine muxes into one virtual file: the highest-bandwidth playable
    /// video representation, then the highest-bandwidth playable representation of every audio
    /// adaptation set in manifest order. Representations inside one adaptation set are bitrate
    /// alternatives of the same content by definition, so taking one per set keeps every language
    /// and drops only duplicates. Text and image sets are not carried.
    func selectRepresentations() throws -> [Representation] {
        if isDynamic { throw DASHSourceError.liveManifest }
        if periodCount != 1 { throw DASHSourceError.periodCount(periodCount) }
        func best(_ set: AdaptationSet) -> Representation? {
            set.representations.filter { $0.unplayable == nil }.max { $0.bandwidth < $1.bandwidth }
        }
        let videoSets = adaptationSets.filter { $0.kind == .video }
        let audioSets = adaptationSets.filter { $0.kind == .audio }
        let video = videoSets.compactMap(best).max { $0.bandwidth < $1.bandwidth }
        let audio = Array(audioSets.compactMap(best).prefix(Self.maxAudioRepresentations))
        if !videoSets.isEmpty, video == nil {
            throw DASHSourceError.noPlayableRepresentation(Self.refusal(videoSets, kind: "video"))
        }
        if video == nil, audio.isEmpty {
            throw DASHSourceError.noPlayableRepresentation(
                audioSets.isEmpty ? "the manifest has no video or audio adaptation set"
                    : Self.refusal(audioSets, kind: "audio"))
        }
        return (video.map { [$0] } ?? []) + audio
    }

    private static func refusal(_ sets: [AdaptationSet], kind: String) -> String {
        let reasons = Set(sets.flatMap(\.representations).compactMap { $0.unplayable?.description })
        return "no \(kind) representation is playable: " + reasons.sorted().joined(separator: ", ")
    }
}

/// Every way a DASH source fails before playback, phrased for `openFailed(reason:)`.
enum DASHSourceError: Error, Equatable, CustomStringConvertible {
    case notAManifest
    case malformedManifest(String)
    case manifestTooLarge(Int)
    case liveManifest
    case periodCount(Int)
    case noPlayableRepresentation(String)
    case malformedIndex(String)
    case malformedInitialization(String)
    case tooManySubsegments(Int)
    case representationUnreachable(String)
    case cancelled

    var description: String {
        switch self {
        case .notAManifest: return "DASH: the body is not an MPD"
        case .malformedManifest(let why): return "DASH: the MPD does not parse (\(why))"
        case .manifestTooLarge(let bytes): return "DASH: the MPD is larger than the \(bytes) byte bound"
        case .liveManifest: return "DASH: live (type=\"dynamic\") manifests are not supported"
        case .periodCount(let n): return "DASH: only single-Period manifests are supported (this one has \(n))"
        case .noPlayableRepresentation(let why): return "DASH: \(why)"
        case .malformedIndex(let why): return "DASH: the segment index does not parse (\(why))"
        case .malformedInitialization(let why): return "DASH: the initialization segment does not parse (\(why))"
        case .tooManySubsegments(let n): return "DASH: a representation has \(n) subsegments, more than one sidx can index"
        case .representationUnreachable(let why): return "DASH: a representation could not be read (\(why))"
        case .cancelled: return "DASH: the open was cancelled"
        }
    }
}

// MARK: - Parsing

extension DASHManifest {

    /// True when a body's leading bytes are an MPD root element, tolerating a UTF-8 BOM, whitespace,
    /// an XML declaration, comments and a namespace prefix on the root (`<mpd:MPD`). Read off the
    /// same open prefix as the HLS tag check; a media container never opens with '<'.
    static func bodyBeginsWithManifest(_ bytes: [UInt8]) -> Bool {
        var i = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
        func skip(past terminator: [UInt8]) -> Bool {
            while i + terminator.count <= bytes.count {
                if Array(bytes[i..<(i + terminator.count)]) == terminator {
                    i += terminator.count
                    return true
                }
                i += 1
            }
            return false
        }
        while true {
            skipSpace()
            guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "<") else { return false }
            if bytes[i + 1] == UInt8(ascii: "?") {
                guard skip(past: Array("?>".utf8)) else { return false }
            } else if bytes[i + 1] == UInt8(ascii: "!") {
                guard skip(past: Array("-->".utf8)) else { return false }
            } else {
                break
            }
        }
        i += 1
        var name: [UInt8] = []
        while i < bytes.count, !([0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ">"), UInt8(ascii: "/")].contains(bytes[i])) {
            name.append(bytes[i])
            i += 1
        }
        let local = name.split(separator: UInt8(ascii: ":")).last.map(Array.init) ?? name
        return local == Array("MPD".utf8)
    }

    static func parse(_ data: Data, manifestURL: URL) throws -> DASHManifest {
        let delegate = MPDParserDelegate(manifestURL: manifestURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            if let error = delegate.failure { throw error }
            throw DASHSourceError.malformedManifest(
                parser.parserError.map { "\($0.localizedDescription)" } ?? "unknown XML error")
        }
        if let error = delegate.failure { throw error }
        guard delegate.sawRoot else { throw DASHSourceError.notAManifest }
        return delegate.manifest
    }

    /// `xs:duration` as the MPD uses it (`PT1450S`, `PT0H4M0.000S`, `P1DT2H`). Years and months
    /// have no fixed length and do not occur in presentation durations; they are refused.
    static func parseDuration(_ text: String) -> Double? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        guard s.first == "P" else { return nil }
        s = s.dropFirst()
        var total = 0.0
        var inTime = false
        var number = ""
        var sawComponent = false
        for ch in s {
            switch ch {
            case "T":
                guard !inTime, number.isEmpty else { return nil }
                inTime = true
            case "0"..."9", ".":
                number.append(ch)
            default:
                guard let value = Double(number), value.isFinite else { return nil }
                number = ""
                sawComponent = true
                switch (ch, inTime) {
                case ("D", false): total += value * 86_400
                case ("H", true): total += value * 3_600
                case ("M", true): total += value * 60
                case ("S", true): total += value
                default: return nil
                }
            }
        }
        guard number.isEmpty, sawComponent, total.isFinite, total <= MediaDurationCeiling.seconds else { return nil }
        return total
    }

    /// `first-last`, both inclusive, as `indexRange` and `Initialization@range` write it.
    static func parseByteRange(_ text: String) -> ClosedRange<Int64>? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int64(parts[0]), let last = Int64(parts[1]),
              first >= 0, last >= first, last - first < DASHSourceOpener.maxHeadBytes else { return nil }
        return first...last
    }
}

/// One XML pass. Attributes that DASH lets a child inherit (mimeType, codecs, SegmentBase, BaseURL)
/// are kept per level and resolved when a Representation closes, which is after every ancestor has
/// stated its own.
private final class MPDParserDelegate: NSObject, XMLParserDelegate {

    private struct SegmentInfo {
        var indexRange: ClosedRange<Int64>?
        var initialization: ClosedRange<Int64>?
        var initializationHasSourceURL = false
    }

    /// What one level (MPD, Period, AdaptationSet, Representation) declares for its children.
    private struct Level {
        var baseURL: String?
        var mimeType: String?
        var codecs: String?
        var contentType: String?
        var language: String?
        var label: String?
        var segment: SegmentInfo?
        var hasTemplate = false
        var hasList = false
        var isProtected = false
    }

    let manifestURL: URL
    var manifest = DASHManifest(isDynamic: false, periodCount: 0, durationSeconds: nil, adaptationSets: [])
    var failure: DASHSourceError?
    var sawRoot = false

    private var mpd = Level()
    private var period = Level()
    private var adaptation = Level()
    private var adaptationAttributes: [String: String] = [:]
    private var adaptationComponents: [String] = []
    private var representations: [DASHManifest.Representation] = []
    private var representation = Level()
    private var representationAttributes: [String: String] = [:]
    private var inRepresentation = false
    private var inAdaptation = false
    private var inPeriod = false
    private var stack: [String] = []
    private var text = ""

    init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    private func withCurrentLevel(_ body: (inout Level) -> Void) {
        if inRepresentation { body(&representation) }
        else if inAdaptation { body(&adaptation) }
        else if inPeriod { body(&period) }
        else { body(&mpd) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        defer { stack.append(name); text = "" }
        if stack.isEmpty {
            guard name == "MPD" else {
                failure = .notAManifest
                parser.abortParsing()
                return
            }
            sawRoot = true
            manifest.isDynamic = attributes["type"] == "dynamic"
            manifest.durationSeconds = attributes["mediaPresentationDuration"].flatMap(DASHManifest.parseDuration)
            return
        }
        switch name {
        case "Period":
            inPeriod = true
            period = Level()
            manifest.periodCount += 1
            if manifest.durationSeconds == nil {
                manifest.durationSeconds = attributes["duration"].flatMap(DASHManifest.parseDuration)
            }
        case "AdaptationSet" where inPeriod:
            inAdaptation = true
            adaptation = Level()
            adaptation.mimeType = attributes["mimeType"]
            adaptation.codecs = attributes["codecs"]
            adaptation.contentType = attributes["contentType"]
            adaptation.language = attributes["lang"]
            adaptationAttributes = attributes
            adaptationComponents = []
            representations = []
        case "ContentComponent" where inAdaptation && !inRepresentation:
            if let type = attributes["contentType"] { adaptationComponents.append(type) }
        case "Representation" where inAdaptation:
            inRepresentation = true
            representation = Level()
            representation.mimeType = attributes["mimeType"]
            representation.codecs = attributes["codecs"]
            representation.language = attributes["lang"]
            representationAttributes = attributes
        case "SegmentBase":
            var info = SegmentInfo()
            info.indexRange = attributes["indexRange"].flatMap(DASHManifest.parseByteRange)
            withCurrentLevel { $0.segment = info }
        case "Initialization" where stack.last == "SegmentBase":
            withCurrentLevel {
                $0.segment?.initialization = attributes["range"].flatMap(DASHManifest.parseByteRange)
                if attributes["sourceURL"] != nil { $0.segment?.initializationHasSourceURL = true }
            }
        case "SegmentTemplate":
            withCurrentLevel { $0.hasTemplate = true }
        case "SegmentList":
            withCurrentLevel { $0.hasList = true }
        case "ContentProtection":
            withCurrentLevel { $0.isProtected = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = stack.popLast() ?? elementName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch name {
        case "BaseURL":
            // The first BaseURL of a level wins; the others are alternative locations of the same bytes.
            withCurrentLevel { if $0.baseURL == nil, !value.isEmpty { $0.baseURL = value } }
        case "Label" where inAdaptation && !inRepresentation:
            if adaptation.label == nil, !value.isEmpty { adaptation.label = value }
        case "Representation" where inRepresentation:
            inRepresentation = false
            if let built = buildRepresentation() { representations.append(built) }
        case "AdaptationSet" where inAdaptation:
            inAdaptation = false
            let kinds = Set(representations.map(\.kind))
            let kind = kinds.count == 1 ? kinds.first! : setKind()
            manifest.adaptationSets.append(.init(kind: kind, representations: representations))
        case "Period":
            inPeriod = false
        default:
            break
        }
    }

    private func setKind() -> DASHManifest.Kind {
        Self.kind(contentType: adaptation.contentType ?? (adaptationComponents.count == 1 ? adaptationComponents[0] : nil),
                  mimeType: adaptation.mimeType, codecs: adaptation.codecs)
    }

    static func kind(contentType: String?, mimeType: String?, codecs: String?) -> DASHManifest.Kind {
        switch contentType?.lowercased() {
        case "video": return .video
        case "audio": return .audio
        case "text": return .text
        case .some: return .other
        case nil: break
        }
        if let mime = mimeType?.lowercased() {
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("text/") || mime.hasPrefix("image/") { return mime.hasPrefix("text/") ? .text : .other }
        }
        let codec = codecs?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let family = codec.split(separator: ".").first.map(String.init) ?? codec
        if ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09", "vp08"].contains(family) { return .video }
        if ["mp4a", "ac-3", "ec-3", "ac-4", "opus", "flac", "alac", "dtsc", "dtsh", "dtsl", "dtse", "mha1", "mhm1"].contains(family) { return .audio }
        if ["stpp", "wvtt", "tx3g"].contains(family) { return .text }
        return .other
    }

    private func buildRepresentation() -> DASHManifest.Representation? {
        let attrs = representationAttributes
        let levels = [representation, adaptation, period, mpd]
        let mimeType = representation.mimeType ?? adaptation.mimeType
        let codecs = representation.codecs ?? adaptation.codecs
        let components = adaptationComponents.count == 1 ? adaptationComponents[0] : nil
        let kind = Self.kind(contentType: adaptation.contentType ?? components, mimeType: mimeType, codecs: codecs)

        var base: URL? = manifestURL
        for level in levels.reversed() {
            guard let relative = level.baseURL else { continue }
            base = URL(string: relative, relativeTo: base)?.absoluteURL
        }
        guard let url = base, url != manifestURL else {
            // A representation without any BaseURL of its own would be the manifest itself.
            return nil
        }

        var unplayable: DASHManifest.Unplayable? = .noSegmentIndex
        var segmentBase: DASHManifest.SegmentBase?
        // The innermost level that addresses segments at all decides how this one is addressed.
        for level in levels {
            if let segment = level.segment {
                if segment.initializationHasSourceURL {
                    unplayable = .separateInitializationFile
                } else if let index = segment.indexRange,
                          let initialization = segment.initialization
                            ?? (index.lowerBound > 0 ? 0...(index.lowerBound - 1) : nil) {
                    segmentBase = .init(initialization: initialization, index: index)
                    unplayable = nil
                }
                break
            }
            if level.hasTemplate { unplayable = .segmentTemplate; break }
            if level.hasList { unplayable = .segmentList; break }
        }
        if levels.contains(where: \.isProtected) {
            unplayable = .encrypted
            segmentBase = nil
        }

        func integer(_ key: String) -> Int? {
            if let value = attrs[key] { return Int(value) }
            return adaptationAttributes[key].flatMap { Int($0) }
        }
        let bandwidth: Int = attrs["bandwidth"].flatMap { Int($0) } ?? 0
        let language: String? = representation.language ?? adaptation.language
        return DASHManifest.Representation(
            id: attrs["id"] ?? "",
            kind: kind,
            mimeType: mimeType,
            codecs: codecs,
            bandwidth: bandwidth,
            width: integer("width"),
            height: integer("height"),
            language: language,
            label: adaptation.label,
            url: url,
            segmentBase: segmentBase,
            unplayable: unplayable)
    }
}
