import Foundation

public enum ExternalSubtitlePreparationError: Error, Sendable, Equatable {
    case unsupportedFormat, empty, resourceLimit, decodeFailed, cancelled, stale
}

/// A single-use candidate. The engine retains no candidate; dropping the host's
/// handle releases its decoded data. It cannot outlive a load/stop generation.
@MainActor
public final class PreparedExternalSubtitle {
    fileprivate weak var owner: AetherEngine?
    fileprivate let generation: UInt64
    fileprivate let intent: UInt64
    fileprivate var registeredID: Int?
    fileprivate let track: ExternalSubtitleTrack
    fileprivate let policy: ExternalSubtitlePreparationPolicy
    fileprivate var result: SidecarDecodeResult?
    public let cueCount: Int

    fileprivate init(owner: AetherEngine, generation: UInt64,
                     track: ExternalSubtitleTrack, result: SidecarDecodeResult, policy: ExternalSubtitlePreparationPolicy) {
        self.owner = owner
        self.generation = generation
        intent = owner.externalSubtitleIntentGeneration
        self.track = track
        self.policy = policy
        self.result = result
        cueCount = result.cues.count
    }

    public func discard() { result = nil }
}

extension AetherEngine {
    /// A seek in flight is still the same session; `loadGeneration` already catches teardown.
    private var isPreparableSessionState: Bool {
        state == .playing || state == .paused || state == .seeking
    }

    /// Decode only an already downloaded, bounded text sidecar. No track,
    /// preference, cue, translation or playback state changes during preparation.
    public func prepareExternalSubtitle(_ track: ExternalSubtitleTrack,
                                        policy: ExternalSubtitlePreparationPolicy = .init()) async throws -> PreparedExternalSubtitle {
        let generation = loadGeneration
        let intent = externalSubtitleIntentGeneration
        guard isPreparableSessionState else { throw ExternalSubtitlePreparationError.stale }
        guard track.url.isFileURL, track.sourceStreamIndex == nil,
              ["srt", "vtt", "ass", "ssa"].contains(track.url.pathExtension.lowercased()) else {
            throw ExternalSubtitlePreparationError.unsupportedFormat
        }
        do {
            try Task.checkCancellation()
            let decoded = try await SubtitleDecoder.decodeFile(
                url: track.url, httpHeaders: [:], preserveASSMarkup: loadedOptions.preserveASSMarkup, preparationPolicy: policy)
            try Task.checkCancellation()
            guard generation == loadGeneration, intent == externalSubtitleIntentGeneration,
                  isPreparableSessionState else {
                throw ExternalSubtitlePreparationError.stale
            }
            guard !decoded.cues.isEmpty else { throw ExternalSubtitlePreparationError.empty }
            return PreparedExternalSubtitle(owner: self, generation: generation, track: track, result: decoded, policy: policy)
        } catch let error as ExternalSubtitlePreparationError { throw error }
        catch is CancellationError { throw ExternalSubtitlePreparationError.cancelled }
        catch SubtitleDecoderError.unsupportedTextCodec { throw ExternalSubtitlePreparationError.unsupportedFormat }
        catch SubtitleDecoderError.textLimitExceeded { throw ExternalSubtitlePreparationError.resourceLimit }
        catch { throw ExternalSubtitlePreparationError.decodeFailed }
    }

    /// Re-selecting an existing host sidecar obeys the same preparation contract.
    public func prepareExternalSubtitle(id: Int, policy: ExternalSubtitlePreparationPolicy? = nil) async throws -> PreparedExternalSubtitle {
        guard let track = externalSubtitleRegistry[id] else { throw ExternalSubtitlePreparationError.stale }
        let prepared = try await prepareExternalSubtitle(track, policy: policy ?? track.preparationPolicy ?? .init())
        guard externalSubtitleRegistry[id] == track else { throw ExternalSubtitlePreparationError.stale }
        prepared.registeredID = id
        return prepared
    }

    /// All rejection checks precede publication. A successful commit performs
    /// no file/network reads and does not suspend or re-decode the candidate.
    @discardableResult
    public func commitExternalSubtitle(_ prepared: PreparedExternalSubtitle,
                                       secondary: Bool = false) throws -> TrackInfo {
        guard !Task.isCancelled else { throw ExternalSubtitlePreparationError.cancelled }
        guard prepared.owner === self, prepared.generation == loadGeneration,
              prepared.intent == externalSubtitleIntentGeneration,
              isPreparableSessionState,
              let decoded = prepared.result else { throw ExternalSubtitlePreparationError.stale }
        let existingID = prepared.registeredID
        if let existingID, externalSubtitleRegistry[existingID] != prepared.track {
            throw ExternalSubtitlePreparationError.stale
        }
        // Consume before registration publishes its track list: a synchronous observer may
        // attempt to commit the same handle again while receiving that publication.
        prepared.result = nil
        hostExplicitSubtitleAction = true
        externalSubtitleIntentGeneration &+= 1
        let info: TrackInfo
        if let existingID, let existing = subtitleTracks.first(where: { $0.id == existingID }) {
            info = existing
            var admitted = prepared.track
            admitted.preparationPolicy = prepared.policy
            externalSubtitleRegistry[existingID] = admitted
        } else {
            var admitted = prepared.track
            admitted.preparationPolicy = prepared.policy
            info = registerExternalSubtitleTrack(admitted)
        }
        if secondary {
            clearSecondarySubtitleContent()
            loadedSecondarySidecarURL = prepared.track.url
            isSecondarySubtitleActive = true
            secondarySubtitleCues = decoded.cues
            secondarySidecarASSHeader = decoded.assHeader
            isLoadingSecondarySubtitles = false
            setSecondarySubtitleIdentity(external: info.id)
        } else {
            cancelSubtitleOCRWorker()
            cancelSidecarTask()
            clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
            activeEmbeddedSubtitleStreamIndex = -1
            pgsStaleArrivalGates[.primary]?.reset()
            liveSubtitleFetchTask?.cancel()
            liveSubtitleFetchTask = nil
            activeSubtitleTrackIndex = info.id
            loadedSidecarURL = prepared.track.url
            isSubtitleActive = true
            subtitleCues = decoded.cues
            sidecarASSHeader = decoded.assHeader
            isLoadingSubtitles = false
        }
        EngineLog.emit("[AetherEngine] overlay fed by prepared sidecar: id=\(info.id) "
                       + "channel=\(secondary ? "secondary" : "primary") (\(decoded.cues.count) cues)",
                       category: .engine)
        if !secondary && nativeSubtitleRenderingRequested { setNativeSubtitleRendering(true) }
        return info
    }
}
