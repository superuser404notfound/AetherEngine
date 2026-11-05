import Foundation

/// Stands a loopback origin in front of a remote HLS master, for either of two reasons.
///
/// #316: host-declared sidecars can only be declared as legible renditions through a playlist, so the
/// engine writes a master of its own, without moving a single media byte off the origin.
///
/// AE#495: a host has answered `EngineTLS.serverTrustEvaluator`, and AVPlayer asks no delegate about a
/// certificate inside its own networking, so the media has to move onto a session the engine owns. An
/// `HLSOriginRelay` mounted on the same server does that.
///
/// They compose. With both, the master carries the injected renditions AND its variants come back
/// through the relay, so a self-signed origin with sidecars gets both rather than choosing. With only
/// the relay there are no tracks and no provider, and the player is pointed straight at the relay.
///
/// The #316 sequence is deliberately cheap and entirely optional. Two playlist GETs (the master, then
/// one variant for the program duration and the VOD verdict), a rewrite, a socket. Anything that does
/// not line up, and the sidecars stay overlay-only exactly as before. A load is never failed over a
/// subtitle feature. A refusal with a relay wanted still stands the relay up on its own, because the
/// media has nowhere else to go.
enum RemoteHLSSubtitleProxy {

    /// A standing stand-in: the caller plays `masterURL` and owns the teardown.
    struct Prepared {
        let server: HLSLocalServer
        let provider: RemoteHLSSubtitleProvider?
        let masterURL: URL
        /// The NAME the served master declares for each injected track, in track order (audit NAT-2).
        var renditionNames: [String] = []

        /// False when the relay stands alone and nothing was injected.
        var servesSubtitleRenditions: Bool { provider != nil }

        func tearDown() {
            provider?.cancelFill()
            server.stop()
            server.relay?.stop()
        }
    }

    enum Refusal: Error, Equatable {
        case fetchFailed(String)
        /// No EXT-X-ENDLIST: a live or still-growing playlist. The whole-program WebVTT shape the
        /// renditions use describes a finished program, so live keeps the overlay.
        case notVOD
        case unusablePlaylist(String)
        case serverUnavailable(String)
    }

    /// Whole-operation budget. A slow origin must not add itself to time-to-first-frame; the fetches
    /// here are playlist-sized and run against the same origin AVPlayer is about to open anyway.
    static let budgetSeconds: TimeInterval = 5

    static func prepare(originURL: URL,
                        tracks: [RemoteHLSSubtitleProvider.Track],
                        httpHeaders: [String: String],
                        needsRelay: Bool) async -> Prepared? {
        guard !tracks.isEmpty || needsRelay else { return nil }
        if !tracks.isEmpty {
            do {
                let prepared = try await build(
                    originURL: originURL, tracks: tracks, httpHeaders: httpHeaders,
                    needsRelay: needsRelay)
                EngineLog.emit(
                    "[AetherEngine] #316: serving \(tracks.count) external subtitle rendition(s) over a "
                    + "rewritten master at \(prepared.masterURL.absoluteString), media "
                    + (needsRelay ? "comes back through the AE#495 relay" : "stays at the origin"),
                    category: .engine)
                return prepared
            } catch {
                EngineLog.emit(
                    "[AetherEngine] #316: no subtitle renditions on this remote-HLS source (\(reason(error))), "
                    + "the declared sidecars stay host-overlay only",
                    category: .engine)
            }
        }
        guard needsRelay else { return nil }
        return relayOnly(originURL: originURL, httpHeaders: httpHeaders)
    }

    /// The AE#495 half with nothing to inject: no provider, no playlist reads, and the player is
    /// pointed at the relay's own address for the origin.
    private static func relayOnly(originURL: URL, httpHeaders: [String: String]) -> Prepared? {
        let relay = HLSOriginRelay()
        relay.grantCredentials(to: originURL, httpHeaders: httpHeaders)
        let server = HLSLocalServer(relay: relay)
        do {
            try server.start()
        } catch {
            EngineLog.emit(
                "[AetherEngine] AE#495: relay did not start (\(error)). AVPlayer goes to the origin, "
                + "which needs a certificate the system trusts", category: .engine)
            relay.stop()
            return nil
        }
        guard let entry = server.relayURL(for: originURL) else {
            server.stop()
            relay.stop()
            return nil
        }
        EngineLog.emit(
            "[AetherEngine] AE#495: routing \(originURL.host ?? "the origin") through the relay so the "
            + "handshake runs where the evaluator is asked", category: .engine)
        return Prepared(server: server, provider: nil, masterURL: entry)
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case Refusal.fetchFailed(let detail): return "playlist fetch failed: \(detail)"
        case Refusal.notVOD: return "no EXT-X-ENDLIST, so not a finished program"
        case Refusal.unusablePlaylist(let detail): return "unusable playlist: \(detail)"
        case Refusal.serverUnavailable(let detail): return "loopback origin unavailable: \(detail)"
        case RemoteHLSMasterRewrite.Refusal.notAPlaylist: return "origin did not answer with a playlist"
        case RemoteHLSMasterRewrite.Refusal.masterWithoutVariants: return "master declares no variant URI"
        case RemoteHLSMasterRewrite.Refusal.noRenditions: return "nothing declared to inject"
        default: return "\(error)"
        }
    }

    private static func build(originURL: URL,
                              tracks: [RemoteHLSSubtitleProvider.Track],
                              httpHeaders: [String: String],
                              needsRelay: Bool) async throws -> Prepared {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        // Audit NAT-105: the variant is whatever the master names, on any host or scheme, so the
        // host's credentials go only where the host sent them.
        let credentials = CredentialScope(headers: httpHeaders, anchor: originURL)

        let (body, finalURL) = try await fetchPlaylist(originURL, session: session, headers: httpHeaders)
        let parsed = try parse(body, at: finalURL)
        let duration = try await programDuration(of: parsed, at: finalURL,
                                                 session: session, credentials: credentials)

        let rewritten = try RemoteHLSMasterRewrite.rewriteDeclaringNames(
            originPlaylist: body,
            originURL: finalURL,
            renditions: RemoteHLSSubtitleProvider.renditions(for: tracks))
        let master = rewritten.master

        let provider = RemoteHLSSubtitleProvider(tracks: tracks, masterBody: master,
                                                 programDuration: duration,
                                                 defaultHeaders: httpHeaders, mediaURL: originURL)
        let relay: HLSOriginRelay? = needsRelay ? HLSOriginRelay() : nil
        // Audit NET-109: the grant belongs to the URL the host handed over. A redirect target is
        // only allowed, or a cross-host redirect would move the token to the edge and leave the
        // host's own origin without it.
        relay?.grantCredentials(to: originURL, httpHeaders: httpHeaders)
        relay?.allow(finalURL)
        let server = HLSLocalServer(provider: provider, relay: relay)
        do {
            try server.start()
        } catch {
            relay?.stop()
            throw Refusal.serverUnavailable("\(error)")
        }
        guard let masterURL = server.playlistURL else {
            server.stop()
            relay?.stop()
            throw Refusal.serverUnavailable("no playlist URL after start")
        }
        // The variants in that master are the origin's, and with a relay mounted they have to come
        // back through it. Only now, because the address they point at is this server's own and does
        // not exist until it is listening. The injected renditions are relative and stay untouched.
        if let relay {
            provider.setMasterPlaylistBody(
                relay.rewritePlaylist(
                    master, relativeTo: finalURL, port: server.port, token: server.pathToken,
                    absoluteOnly: true))
        }
        // Decode up front: the rendition is fetched the moment the host selects it, and a whole-program
        // .vtt is fetched once and never again.
        provider.startFill()
        return Prepared(server: server, provider: provider, masterURL: masterURL,
                        renditionNames: rewritten.renditionNames)
    }

    // MARK: - Playlist reads

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = budgetSeconds / 2
        config.timeoutIntervalForResource = budgetSeconds
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    /// Matches the sibling HLS fetchers (`HLSCarriageProbe`, `HLSVODIngestReader`). This proxy fetches
    /// an origin master and one variant before AVPlayer ever opens the source, so an origin that
    /// answers with a fast, unbounded stream under the m3u8 URL could otherwise buffer until jetsam
    /// (audit NAT-5).
    private static let maximumPlaylistBytes = 2 * 1024 * 1024

    /// Returns the body and the URL it finally came from; every relative URI in the playlist resolves
    /// against the latter, so a redirecting origin (Plex's transcode handoff) still rewrites correctly.
    private static func fetchPlaylist(_ url: URL,
                                      session: URLSession,
                                      headers: [String: String]) async throws -> (String, URL) {
        var request = URLRequest(engineURL: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedPlaylistFetch.data(
                for: request, session: session, limit: maximumPlaylistBytes)
        } catch {
            throw Refusal.fetchFailed("\(error)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Refusal.fetchFailed("HTTP \(http.statusCode)")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw Refusal.fetchFailed("body is not UTF-8")
        }
        return (body, response.url ?? url)
    }

    private static func parse(_ body: String, at url: URL) throws -> HLSPlaylist {
        do {
            return try HLSPlaylistParser.parse(body)
        } catch {
            throw Refusal.unusablePlaylist("\(error)")
        }
    }

    /// Sum of the origin's own EXTINFs. A master is resolved through its first variant; the durations
    /// are identical across variants, and one small GET buys both the length and the VOD verdict.
    private static func programDuration(of playlist: HLSPlaylist,
                                        at url: URL,
                                        session: URLSession,
                                        credentials: CredentialScope) async throws -> Double {
        switch playlist {
        case .media(let media):
            guard media.hasEndList else { throw Refusal.notVOD }
            return try sumSegmentDurations(media.segments)
        case .master(let master):
            guard let variant = master.variants.first,
                  let variantURL = HLSPlaylistParser.resolve(uri: variant.uri, against: url) else {
                throw Refusal.unusablePlaylist("master declares no resolvable variant")
            }
            let (body, finalURL) = try await fetchPlaylist(
                variantURL, session: session, headers: credentials.headers(for: variantURL))
            guard case .media(let media) = try parse(body, at: finalURL) else {
                throw Refusal.unusablePlaylist("variant is not a media playlist")
            }
            guard media.hasEndList else { throw Refusal.notVOD }
            return try sumSegmentDurations(media.segments)
        }
    }

    /// Longest program this proxy will serve as a whole-program WebVTT rendition.
    static let maxProgramDurationSeconds: Double = MediaDurationCeiling.seconds

    /// A hostile or malformed EXTINF (`inf`, negative, or a huge total) reaches `Int(Double)` in
    /// `wholeSecondsCovering` downstream and traps (audit NAT-1); refuse it here instead. Internal
    /// rather than private so the parsing rule is testable without a network fixture.
    static func sumSegmentDurations(_ segments: [HLSMediaSegment]) throws -> Double {
        var total = 0.0
        for segment in segments {
            guard segment.duration.isFinite, segment.duration >= 0 else {
                throw Refusal.unusablePlaylist("EXTINF is not a finite, non-negative duration")
            }
            total += segment.duration
        }
        guard total.isFinite, total <= maxProgramDurationSeconds else {
            throw Refusal.unusablePlaylist("program duration exceeds \(maxProgramDurationSeconds)s")
        }
        return total
    }
}
