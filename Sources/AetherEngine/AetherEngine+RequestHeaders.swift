import Foundation

/// AE#792: replacing a live session's request headers without a rebuild.
///
/// A media server that requires a bearer token on every request, with tokens that live an hour,
/// rotates the credential under any long title. Nothing about the session changes when it does:
/// the source, the routing and the byte stream are the same, and only the value of one header is
/// new. `reloadAtCurrentPosition(applying:)` (#460) can install it, but it is a teardown at the
/// playhead, a visible restart bought for a value only the NEXT request reads.
///
/// Every request an `AVIOReader` builds goes through `headers(for:)`, so the only thing that kept a
/// session on its load-time headers was that each reader froze a copy at its open. The session now
/// creates one `RequestHeaderStore` per load and hands it to every reader it opens on its source
/// (the playback demuxer, the producer's reopens and revives, the I-frame and subtitle side
/// readers); this call replaces the value in it.
extension AetherEngine {

    /// Replace the HTTP headers the session's source requests carry, from the next request on,
    /// without a rebuild (AE#792).
    ///
    /// ```swift
    /// player.updateRequestHeaders(["Authorization": "Bearer \(fresh)"])
    /// ```
    ///
    /// The set REPLACES the current one, the way `LoadOptions.httpHeaders` does at `load`; it is not
    /// merged. It is also installed into the session's options, so every rebuild that replays them
    /// (an audio switch, a background return, `reloadAtCurrentPosition()`) opens with it too.
    ///
    /// A request already in flight finishes with the headers it was sent with. A reconnect that is
    /// backing off after a refusal sends the new set on its next attempt, so a session stalled over
    /// a lapsed credential heals without a teardown once the host supplies a current one.
    /// `RedirectHeaderPolicy` scoping is unchanged: a credential still does not follow a
    /// cross-origin redirect.
    ///
    /// - Returns: whether the session's live requests will carry the new set. See
    ///   `RequestHeaderUpdateOutcome`; on `.installedForNextRebuild` call
    ///   `reloadAtCurrentPosition()` if the headers are needed now.
    @discardableResult
    public func updateRequestHeaders(_ headers: [String: String]) -> RequestHeaderUpdateOutcome {
        guard let url = loadedURL else {
            EngineLog.emit("[AetherEngine] AE#792: request headers not updated, no active session",
                           category: .engine)
            return .noActiveSession
        }
        setLoadedHTTPHeaders(headers)
        sessionRequestHeaders.replace(headers)
        let outcome = RequestHeaderUpdateOutcome.forSession(
            isCustomSource: isCustomSource
                && (customReader as? HLSLiveIngestReader)?.followsSessionHeaders != true,
            isDiscImage: !isCustomSource
                && (Demuxer.isDiscImageURL(url) || DASHSourceOpener.isKnownManifest(url)),
            route: videoRoute,
            audioRequestsOwnedByAVFoundation: audioSessionRequestsOwnedByAVFoundation)
        // Names only: the values are credentials.
        EngineLog.emit(
            "[AetherEngine] AE#792: request headers replaced (\(headers.keys.sorted().joined(separator: ", "))): "
            + (outcome == .appliedToLiveRequests
                ? "live, the next source request carries them"
                : "installed for the next rebuild, this session's requests are fixed at load"),
            category: .engine)
        return outcome
    }
}

extension AetherEngine {
    /// AE#792 part 2: the software path reports a source that stopped answering as a pipeline
    /// failure. When the reader's last answer was a credential refusal, that is what the host is
    /// told, with the status, the way an open-time 401 already arrives.
    nonisolated static func reclassifiedForCredentialRefusal(
        _ info: PlaybackErrorInfo, refusal: RequestHeaderStore.CredentialRefusal?
    ) -> PlaybackErrorInfo {
        guard info.kind == .softwarePipelineFailed, let refusal else { return info }
        return PlaybackErrorInfo(kind: .sourceRefused,
                                 message: "Source refused the session's credentials (HTTP \(refusal.status))",
                                 underlyingCode: refusal.status)
    }
}

/// What `updateRequestHeaders(_:)` did (AE#792).
public enum RequestHeaderUpdateOutcome: Sendable, Equatable {
    /// The session's source readers send the new set on their next request, a reconnect already
    /// backing off included. Nothing was torn down.
    case appliedToLiveRequests
    /// The session's requests are made by something that fixed its headers when the session was
    /// built: AVFoundation on a `.remoteBypass` route or an AVPlayer-hosted audio item, a custom
    /// `IOReader` the host built (the engine's own live ingest reads the store, so it is not one), a remote disc image, or a DASH manifest (AE#859). The set is
    /// installed for the next rebuild; call `reloadAtCurrentPosition()` if it is needed now.
    case installedForNextRebuild
    /// Nothing is loaded. Nothing was installed.
    case noActiveSession

    /// Which session shapes have every source request built by an `AVIOReader` that reads the
    /// session's store. `.none` is a load still opening, whose probe reader already reads it.
    static func forSession(isCustomSource: Bool, isDiscImage: Bool, route: VideoRoute,
                           audioRequestsOwnedByAVFoundation: Bool) -> RequestHeaderUpdateOutcome {
        if isCustomSource || isDiscImage { return .installedForNextRebuild }
        switch route {
        case .remoteBypass:
            return .installedForNextRebuild
        case .audio:
            return audioRequestsOwnedByAVFoundation ? .installedForNextRebuild : .appliedToLiveRequests
        case .none, .loopback, .software:
            return .appliedToLiveRequests
        }
    }
}
