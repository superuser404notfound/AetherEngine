import Foundation

/// #316: declare host-supplied sidecar subtitles as legible renditions on the `nativeRemoteHLS` bypass.
///
/// Media selection on an HLS asset comes from the playlist and from nowhere else. There is no API that
/// adds an `AVMediaSelectionOption` to a remote `AVURLAsset`, so `addExternalSubtitleTrack` can only ever
/// drive the host overlay, which is not drawn once the picture leaves the host's view hierarchy (PiP,
/// AirPlay, a wired external display). The only route to a real rendition is a master the engine writes.
///
/// Rewriting the origin master rather than re-serving the media keeps the property the bypass exists for:
/// every variant, audio rendition and key URI is made absolute against the origin, so AVPlayer still
/// fetches all A/V bytes straight from the origin and E-AC-3/Atmos passthrough is untouched. Only the
/// master itself and the WebVTT renditions come from the loopback server.
///
/// Rendition URIs stay RELATIVE on purpose: they resolve against whatever host the master was served
/// from, so the #86/#227 AirPlay swap to the device's LAN IP carries them along without a second rewrite.
enum RemoteHLSMasterRewrite {

    /// Group id for renditions the engine adds when the origin declares no subtitles group of its own.
    static let injectedGroupID = "subs"

    /// One sidecar, as it is served by `HLSLocalServer` (`/subs_{ordinal}.m3u8`).
    struct Rendition: Equatable, Sendable {
        var ordinal: Int
        var name: String
        var language: String?
        var isForced: Bool
        var isSDH: Bool

        init(ordinal: Int, name: String, language: String? = nil,
             isForced: Bool = false, isSDH: Bool = false) {
            self.ordinal = ordinal
            self.name = name
            self.language = language
            self.isForced = isForced
            self.isSDH = isSDH
        }
    }

    /// Why a playlist cannot carry injected renditions. Every case leaves the caller on the origin URL
    /// with overlay-only subtitles, which is the pre-#316 behaviour, so none of them fails a load.
    enum Refusal: Error, Equatable, Sendable {
        /// No `#EXTM3U`: not a playlist at all (an origin error page, an HTML redirect).
        case notAPlaylist
        /// A master whose `EXT-X-STREAM-INF` tags have no URI line after them.
        case masterWithoutVariants
        /// Nothing to inject.
        case noRenditions
    }

    /// Rewrite `originPlaylist` into a master that can be served from the loopback origin.
    ///
    /// `originURL` must be the FINAL URL the body was fetched from (after redirects); every relative URI
    /// in the playlist is resolved against it. A media playlist (no `EXT-X-STREAM-INF`) is wrapped in a
    /// synthetic single-variant master pointing back at it, since renditions can only be declared in a
    /// master. `mediaPlaylistBandwidth` is the placeholder BANDWIDTH for that wrap; with one variant
    /// nothing selects on it, but the attribute is required by RFC 8216.
    static func rewrite(originPlaylist: String,
                        originURL: URL,
                        renditions: [Rendition],
                        mediaPlaylistBandwidth: Int = 5_000_000) throws -> String {
        try rewriteDeclaringNames(originPlaylist: originPlaylist, originURL: originURL,
                                  renditions: renditions,
                                  mediaPlaylistBandwidth: mediaPlaylistBandwidth).master
    }

    /// The rewritten master, and the NAME it declares for each rendition, in `renditions` order.
    struct Rewritten: Equatable, Sendable {
        var master: String
        var renditionNames: [String]
    }

    /// `rewrite`, also answering with the exact NAME each rendition was written under. The engine
    /// selects an injected rendition by that NAME and hides it from the legible list by it, so it has
    /// to key on what the master says, not on the name it asked for (audit NAT-2): a sidecar that
    /// repeats another's name, or the origin's, is written with a disambiguator.
    static func rewriteDeclaringNames(originPlaylist: String,
                                      originURL: URL,
                                      renditions: [Rendition],
                                      mediaPlaylistBandwidth: Int = 5_000_000) throws -> Rewritten {
        guard !renditions.isEmpty else { throw Refusal.noRenditions }
        let lines = originPlaylist.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") }) else {
            throw Refusal.notAPlaylist
        }
        guard lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else {
            let names = declaredNames(for: renditions, taken: [])
            return Rewritten(
                master: wrapMediaPlaylist(originURL: originURL, renditions: renditions, names: names,
                                          bandwidth: mediaPlaylistBandwidth),
                renditionNames: names)
        }
        return try rewriteMaster(lines: lines, originURL: originURL, renditions: renditions)
    }

    // MARK: - Master

    private static func rewriteMaster(lines: [String],
                                      originURL: URL,
                                      renditions: [Rendition]) throws -> Rewritten {
        // Which groups the injected renditions have to join: every SUBTITLES group the origin declares
        // (a variant references exactly one, and different variants may reference different ones), plus
        // our own group if any variant references none.
        var originGroups: [String] = []
        var originNames: Set<String> = []
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            guard HLSPlaylistParser.attribute("TYPE", in: line) == "SUBTITLES",
                  let group = HLSPlaylistParser.attribute("GROUP-ID", in: line) else { continue }
            if !originGroups.contains(group) { originGroups.append(group) }
            if let name = HLSPlaylistParser.attribute("NAME", in: line) { originNames.insert(name) }
        }
        let names = declaredNames(for: renditions, taken: originNames)
        let variantsWithoutGroup = lines.contains {
            $0.hasPrefix("#EXT-X-STREAM-INF:") && HLSPlaylistParser.attribute("SUBTITLES", in: $0) == nil
        }
        var targetGroups = originGroups
        if variantsWithoutGroup || targetGroups.isEmpty {
            if !targetGroups.contains(injectedGroupID) { targetGroups.append(injectedGroupID) }
        }

        var out: [String] = []
        var injected = false
        var expectVariantURI = false
        var sawVariantURI = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if expectVariantURI, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                out.append(absolute(trimmed, against: originURL))
                expectVariantURI = false
                sawVariantURI = true
                continue
            }
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                // The renditions have to be declared before the first variant references their group.
                if !injected {
                    out.append(contentsOf: mediaTags(renditions: renditions,
                                                     names: names,
                                                     groups: targetGroups))
                    injected = true
                }
                out.append(withSubtitlesGroup(trimmed))
                expectVariantURI = true
                continue
            }
            out.append(rewriteURIAttribute(in: line, against: originURL))
        }
        guard sawVariantURI else { throw Refusal.masterWithoutVariants }
        return Rewritten(master: out.joined(separator: "\n") + "\n", renditionNames: names)
    }

    /// A variant that already names a SUBTITLES group keeps it (the injected renditions joined that
    /// group); one that names none is pointed at ours.
    private static func withSubtitlesGroup(_ streamInf: String) -> String {
        guard HLSPlaylistParser.attribute("SUBTITLES", in: streamInf) == nil else { return streamInf }
        return streamInf + ",SUBTITLES=\"\(injectedGroupID)\""
    }

    // MARK: - Media playlist wrap

    private static func wrapMediaPlaylist(originURL: URL,
                                          renditions: [Rendition],
                                          names: [String],
                                          bandwidth: Int) -> String {
        var lines = ["#EXTM3U", "#EXT-X-INDEPENDENT-SEGMENTS"]
        lines.append(contentsOf: mediaTags(renditions: renditions,
                                           names: names,
                                           groups: [injectedGroupID]))
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),SUBTITLES=\"\(injectedGroupID)\"")
        lines.append(originURL.absoluteString)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - EXT-X-MEDIA

    /// `DEFAULT=NO,AUTOSELECT=NO` deliberately, matching the loopback master (#15 / Sodalite#32): the
    /// host that declared the sidecar decides when it plays, and AE#154 mirrors any selection back into
    /// `activeSubtitleTrackIndex`. `FORCED=YES` is also withheld on purpose: AVKit force-displays a forced
    /// rendition whose language matches the selected audio regardless of the user's caption preference
    /// (Sodalite#38). `isForced` still rides the published `TrackInfo` so a host can label and pick it.
    private static func mediaTags(renditions: [Rendition],
                                  names: [String],
                                  groups: [String]) -> [String] {
        var tags: [String] = []
        for group in groups {
            for (rendition, name) in zip(renditions, names) {
                var attrs = ["TYPE=SUBTITLES", "GROUP-ID=\"\(group)\"", "NAME=\"\(name)\""]
                if let language = rendition.language, !language.isEmpty {
                    attrs.append("LANGUAGE=\"\(escaped(language))\"")
                }
                if rendition.isSDH {
                    attrs.append("CHARACTERISTICS=\"\(HLSLocalServer.sdhCharacteristics)\"")
                }
                attrs.append(contentsOf: ["DEFAULT=NO", "AUTOSELECT=NO"])
                attrs.append("URI=\"subs_\(rendition.ordinal).m3u8\"")
                tags.append("#EXT-X-MEDIA:\(attrs.joined(separator: ","))")
            }
        }
        return tags
    }

    /// NAMEs must be unique within a group or AVFoundation collapses the legible options into one. The
    /// origin's own names are already taken, so a sidecar that repeats one gets a numeric disambiguator
    /// rather than silently disappearing from the picker. One name per rendition across every group,
    /// taken against the origin names of all of them, so the engine can select it by that one string;
    /// uniqueness is decided on the escaped form, which is the one the master carries.
    private static func declaredNames(for renditions: [Rendition], taken: Set<String>) -> [String] {
        var used = taken
        return renditions.map { uniqueName(escaped($0.name), in: &used) }
    }

    private static func uniqueName(_ preferred: String, in used: inout Set<String>) -> String {
        let base = preferred.isEmpty ? "Subtitle" : preferred
        if !used.contains(base) {
            used.insert(base)
            return base
        }
        var suffix = 2
        while used.contains("\(base) \(suffix)") { suffix += 1 }
        let name = "\(base) \(suffix)"
        used.insert(name)
        return name
    }

    /// Quoted attribute values cannot carry a `"`; a name that contains one would truncate the tag.
    /// Nor a line break or any other control character (audit NAT-6): a sidecar name is host input,
    /// often a file name or server metadata, and a CR/LF in it would end the tag and let the rest of
    /// the name write its own master lines, a variant included. Mapped per scalar, because CRLF is a
    /// single Character and a Character-level test would let it through as one.
    private static func escaped(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                out.append(" ")
            default:
                out.append(scalar == "\"" ? "'" : scalar)
            }
        }
        return String(out)
    }

    // MARK: - URI absolutisation

    /// Master-level tags whose `URI=` must survive the move to the loopback origin. Media playlists are
    /// never rewritten (they stay at the origin and resolve their own segment URIs there), so segment
    /// tags are deliberately absent.
    private static let uriBearingTags = [
        "#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-SESSION-KEY:", "#EXT-X-SESSION-DATA:"
    ]

    private static func rewriteURIAttribute(in line: String, against base: URL) -> String {
        guard uriBearingTags.contains(where: { line.hasPrefix($0) }),
              let uri = HLSPlaylistParser.attribute("URI", in: line), !uri.isEmpty else { return line }
        let resolved = absolute(uri, against: base)
        guard resolved != uri else { return line }
        return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(resolved)\"")
    }

    private static func absolute(_ uri: String, against base: URL) -> String {
        guard URL(string: uri)?.scheme == nil else { return uri }
        return URL(string: uri, relativeTo: base)?.absoluteURL.absoluteString ?? uri
    }
}
