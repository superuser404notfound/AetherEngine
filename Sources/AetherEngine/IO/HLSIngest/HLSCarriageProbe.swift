import Foundation

/// AE#293: reads a live HLS source's video carriage from its playlist and the first segment's PMT, so the
/// #168 verdict is available while the native mount is still inside its watchdog grace instead of 4 s
/// after it. Same evidence chain #268 uses for finite VOD, minus the VOD-only requirements (no
/// EXT-X-ENDLIST, no duration axis), so a rolling live window can be judged as well.
///
/// AE#296: two stages, because they cost different things. The playlist stage is free of a per-token
/// connection cap and settles every source whose playlists already carry the answer; only what is left
/// reaches a segment, and the caller spends that read once a lost connection can no longer cost the mount.
///
/// Never throws: a caller acts on positive evidence only, so every failure collapses to `inconclusive`
/// and leaves the source on the route it is already taking.
enum HLSCarriageProbe {
    /// Bounded like the VOD ingest's playlist fetch: a playlist larger than this is not one the ingest
    /// would serve either.
    static let maximumPlaylistBytes = 2 * 1024 * 1024
    /// Segment head the PMT must appear in; a conforming segment carries PAT and PMT in its first packets.
    static let maximumSegmentHeadBytes = 128 * 1024
    /// Probe verdict granularity: re-inspect after this much fresh payload, packet-aligned.
    static let segmentHeadChunkBytes = 188 * 32

    /// One process-wide session rather than one per probe: an uninvalidated `URLSession` outlives its
    /// caller. The request timeout is short because a verdict that arrives after the watchdog grace has
    /// already been overtaken by the grace it was meant to replace.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        // The request timeout is an idle timeout; without a resource ceiling an origin trickling a
        // byte every few seconds kept a probe open for the 7-day default (audit NET-10).
        configuration.timeoutIntervalForResource = 30
        return URLSession(
            configuration: configuration, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }()

    /// AE#296: what the playlist chain established, and whether a media byte is still needed to settle it.
    /// The two stages are separated because they have different costs: playlists are free of a per-token
    /// connection cap, a segment fetch is not.
    enum PlaylistEvidence: Equatable {
        /// Answered from the playlists alone; no segment was fetched.
        case settled(MPEGTransportStreamCodecProbe.Verdict)
        /// Only this segment's PMT separates the carriages here.
        case needsSegmentHead(URL)
    }

    /// AE#296: the playlist stage. Costs one playlist fetch for a media playlist, two for a master, and
    /// never a media byte, so it can run against the native mount on a connection-capped origin.
    ///
    /// It settles the case outright when the playlists already carry the answer: an `EXT-X-MAP` is fMP4
    /// carriage, and an fMP4-only advertised codec (`advertisesFragmentedMP4OnlyVideo`, from the master
    /// `CODECS` AVFoundation has already parsed) *without* an `EXT-X-MAP` is that codec in MPEG-TS, since
    /// an fMP4 media segment requires an EXT-X-MAP (RFC 8216 4.3.2.5). Everything else hands back the
    /// segment whose PMT decides it, for the caller to spend when a lost connection can no longer cost
    /// the mount.
    static func classifyFromPlaylists(
        playlistURL: URL,
        httpHeaders: [String: String],
        advertisesFragmentedMP4OnlyVideo: Bool,
        session: URLSession? = nil
    ) async -> PlaylistEvidence {
        do {
            return try await resolveFirstSegment(
                playlistURL: playlistURL,
                httpHeaders: httpHeaders,
                advertisesFragmentedMP4OnlyVideo: advertisesFragmentedMP4OnlyVideo,
                session: session ?? sharedSession
            )
        } catch {
            EngineLog.emit(
                "[HLSCarriageProbe] carriage probe inconclusive: \(EngineLog.summary(of: error))",
                category: .engine)
            return .settled(.inconclusive)
        }
    }

    /// AE#296: the segment stage, run apart from the playlist stage so the one media byte the probe ever
    /// spends is spent where losing it costs the verdict rather than the mount. Never throws: an origin
    /// that refuses this read leaves the source on the route it is already taking.
    ///
    /// `credentialOrigin` is the playlist the host gave `httpHeaders` for; the segment is a URI that
    /// playlist named, so credentials only follow it to the same origin (audit NET-7).
    static func classifyDeferredSegmentHead(
        url: URL,
        httpHeaders: [String: String],
        credentialOrigin: URL,
        session: URLSession? = nil
    ) async -> MPEGTransportStreamCodecProbe.Verdict {
        do {
            return try await classifySegmentHead(
                url: url,
                httpHeaders: RedirectHeaderPolicy.scoped(httpHeaders, grantedFor: credentialOrigin, sentTo: url),
                session: session ?? sharedSession
            )
        } catch {
            EngineLog.emit(
                "[HLSCarriageProbe] carriage probe inconclusive: \(EngineLog.summary(of: error))",
                category: .engine)
            return .inconclusive
        }
    }

    /// Both stages back to back. The host runs them at different times (AE#296); this is the composed
    /// chain for harnesses and tests that want one verdict.
    static func classifyLiveCarriage(
        playlistURL: URL,
        httpHeaders: [String: String],
        advertisesFragmentedMP4OnlyVideo: Bool = false,
        session: URLSession? = nil
    ) async -> MPEGTransportStreamCodecProbe.Verdict {
        switch await classifyFromPlaylists(
            playlistURL: playlistURL,
            httpHeaders: httpHeaders,
            advertisesFragmentedMP4OnlyVideo: advertisesFragmentedMP4OnlyVideo,
            session: session
        ) {
        case .settled(let verdict):
            return verdict
        case .needsSegmentHead(let segmentURL):
            return await classifyDeferredSegmentHead(
                url: segmentURL, httpHeaders: httpHeaders, credentialOrigin: playlistURL, session: session
            )
        }
    }

    /// Reads the head of a segment and classifies its carriage. The body is streamed and abandoned at the
    /// first definitive verdict, so a conforming segment costs the two packets that carry PAT and PMT
    /// rather than the full ceiling; an origin that ignores the Range request is bounded the same way, by
    /// cancelling the task instead of buffering the segment.
    static func classifySegmentHead(
        url: URL,
        httpHeaders: [String: String],
        session: URLSession,
        diagnosticContext: SourceNetworkDiagnostics.Context? = SourceNetworkDiagnostics.context
    ) async throws -> MPEGTransportStreamCodecProbe.Verdict {
        var request = SourceNetworkDiagnostics.request(makeRequest(url, httpHeaders: httpHeaders), context: diagnosticContext)
        request.setValue("bytes=0-\(maximumSegmentHeadBytes - 1)", forHTTPHeaderField: "Range")
        let trace = SourceNetworkDiagnostics.Trace(role: .hlsSegment, context: SourceNetworkDiagnostics.context(for: request))
        var task: URLSessionTask?
        var terminalError: Error?
        defer {
            if let task { trace.completed(task: task, error: terminalError) }
            else { trace.record(.completed, originalURL: url, url: url, error: terminalError) }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            task = bytes.task
            trace.response(task: bytes.task, response: response)
            defer { bytes.task.cancel() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 || status == 206 else {
                throw HLSIngestError.playlistUnreachable(status: status)
            }
            var data = Data()
            data.reserveCapacity(segmentHeadChunkBytes)
            var nextVerdictAt = segmentHeadChunkBytes
            for try await byte in bytes {
                data.append(byte)
                guard data.count >= nextVerdictAt else { continue }
                let verdict = MPEGTransportStreamCodecProbe.classify(data)
                if verdict != .inconclusive { return verdict }
                guard data.count < maximumSegmentHeadBytes else { break }
                nextVerdictAt = min(maximumSegmentHeadBytes, data.count + segmentHeadChunkBytes)
            }
            guard !data.isEmpty else {
                throw HLSIngestError.unsupportedSegmentFormat
            }
            return MPEGTransportStreamCodecProbe.classify(data)
        } catch {
            terminalError = error
            throw error
        }
    }

    /// Resolves the playlist down to the segment whose PMT answers the question, or settles the verdict
    /// on playlist evidence alone. The highest-bandwidth variant is the one probed, matching #268: a
    /// master's variants share their carriage, so one answer covers them all.
    private static func resolveFirstSegment(
        playlistURL: URL,
        httpHeaders: [String: String],
        advertisesFragmentedMP4OnlyVideo: Bool,
        session: URLSession
    ) async throws -> PlaylistEvidence {
        let (root, rootURL) = try await fetchPlaylist(
            playlistURL, httpHeaders: httpHeaders, credentialOrigin: playlistURL, session: session)
        let media: HLSMediaPlaylist
        let mediaURL: URL
        switch root {
        case .media(let value):
            media = value
            mediaURL = rootURL
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  let variantURL = HLSPlaylistParser.resolve(uri: best.uri, against: rootURL) else {
                return .settled(.inconclusive)
            }
            let (selected, selectedURL) = try await fetchPlaylist(
                variantURL, httpHeaders: httpHeaders, credentialOrigin: playlistURL, session: session
            )
            guard case .media(let value) = selected else { return .settled(.inconclusive) }
            media = value
            mediaURL = selectedURL
        }
        // fMP4 carriage is what AVFoundation wants; the playlist says so before a segment is touched.
        guard !media.hasMap else { return .settled(.otherCarriage) }
        // AE#296: an fMP4 media segment requires an EXT-X-MAP, so an fMP4-only codec advertised over a
        // window that has none is that codec in MPEG-TS, settled without a media connection. Encryption
        // does not block this branch the way it blocks the PMT read (nothing is being decrypted here),
        // except where the ingest could not serve the carriage anyway.
        if advertisesFragmentedMP4OnlyVideo, !media.hasUnsupportedEncryption, !media.segments.isEmpty {
            return .settled(.hevcInMPEGTS)
        }
        // An encrypted segment hides its PMT, and an absence of evidence never reroutes.
        guard let first = media.segments.first,
              first.crypt == nil,
              !media.hasUnsupportedEncryption,
              let segmentURL = HLSPlaylistParser.resolve(uri: first.uri, against: mediaURL) else {
            return .settled(.inconclusive)
        }
        return .needsSegmentHead(segmentURL)
    }

    private static func fetchPlaylist(
        _ url: URL,
        httpHeaders: [String: String],
        credentialOrigin: URL,
        session: URLSession
    ) async throws -> (HLSPlaylist, URL) {
        let request = makeRequest(
            url, httpHeaders: RedirectHeaderPolicy.scoped(httpHeaders, grantedFor: credentialOrigin, sentTo: url))
        let (data, response) = try await BoundedPlaylistFetch.data(
            for: request, session: session, limit: maximumPlaylistBytes)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "playlist is not bounded UTF-8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private static func makeRequest(_ url: URL, httpHeaders: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return SourceNetworkDiagnostics.request(request, context: SourceNetworkDiagnostics.context)
    }
}
