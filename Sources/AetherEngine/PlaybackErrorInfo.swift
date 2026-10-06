import Foundation

/// Stable classification token for a published `PlaybackState.error` (#376).
///
/// A string-backed struct rather than an enum on purpose: the set grows whenever the engine learns a
/// new way to fail, and a host switching exhaustively over an enum would stop compiling on a minor
/// release. Raw values are API and do not change, so one can be shipped into an analytics bucket as
/// it stands. They also carry no origin, which is what a host whose telemetry contract forbids raw
/// error strings can send in place of the message.
public struct PlaybackErrorKind: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    // MARK: Load

    /// The source could not be opened, probed or routed. `underlyingDomain` / `underlyingCode` name the
    /// failure the open ran into.
    public static let sourceOpenFailed = PlaybackErrorKind(rawValue: "sourceOpenFailed")
    /// The origin answered the source request with an HTTP status instead of media: a 401/403 refusal,
    /// a 404, a 5xx. `underlyingCode` is that status; `underlyingDomain` is nil, the sentence is the
    /// engine's. Before this kind existed both this and a corrupt file arrived as `sourceOpenFailed`
    /// carrying FFmpeg's "Invalid data found when processing input". A 429/503/509 arrives as
    /// `sourceRateLimited` instead: same shape, different recovery.
    public static let sourceRefused = PlaybackErrorKind(rawValue: "sourceRefused")
    /// The transport was refused over certificate trust before any media arrived: a self-signed or
    /// private-CA origin, an expired certificate, a client certificate the process cannot present.
    /// `underlyingCode` is the `NSURLErrorDomain` code (-1200 to -1206). Distinct from
    /// `sourceOpenFailed`, which this used to arrive as: on the FFmpeg path a refused handshake reaches
    /// the demuxer as an empty stream and surfaces as "Invalid data found when processing input", which
    /// reads as a corrupt file, and on the native path the URL error sits under AVFoundation's own where
    /// nothing looked. Nothing about the media is wrong and no retry will help; the trust decision is
    /// the host's to make (AE#495).
    public static let sourceCertificateRejected = PlaybackErrorKind(rawValue: "sourceCertificateRejected")
    /// A custom `IOReader`'s initial probe failed. The host built that reader, so only the host can
    /// re-point it.
    public static let customSourceProbeFailed = PlaybackErrorKind(rawValue: "customSourceProbeFailed")
    /// A live probe that burned its full reconnect budget without opening.
    public static let liveSourceUnavailable = PlaybackErrorKind(rawValue: "liveSourceUnavailable")
    /// An HLS playlist handed to the raw live path by a custom reader, which the engine cannot re-point
    /// for the host. A plain `url:` source of the same shape is routed onto the ingest instead (AE#363).
    public static let hlsPlaylistOnRawLivePath = PlaybackErrorKind(rawValue: "hlsPlaylistOnRawLivePath")
    /// Dolby Vision with no compatible base layer on the software path.
    public static let dolbyVisionRequiresHardware = PlaybackErrorKind(rawValue: "dolbyVisionRequiresHardware")
    /// A demuxed-audio live source on a codec path that cannot carry one.
    public static let demuxedAudioLiveUnsupported = PlaybackErrorKind(rawValue: "demuxedAudioLiveUnsupported")

    // MARK: Session, after the load returned

    /// `AVPlayerItem` reached `.failed`. The message is AVFoundation's `localizedDescription`, so it is
    /// in the device's language; `underlyingDomain` / `underlyingCode` are the part that classifies.
    public static let nativeItemFailed = PlaybackErrorKind(rawValue: "nativeItemFailed")
    /// The remote-HLS bypass reached its readiness ceiling: AVFoundation built no track within the
    /// budget and the source's carriage could not be identified (#334).
    public static let noPlayableTrackWithinBudget = PlaybackErrorKind(rawValue: "noPlayableTrackWithinBudget")
    /// AVPlayer rejected the served master playlist and the media-playlist fallback was unavailable or
    /// already spent (#98/#130).
    public static let masterPlaylistRejected = PlaybackErrorKind(rawValue: "masterPlaylistRejected")
    /// A VOD source died without producing (or after the revive cap), reported by the reader
    /// (#126/#169). `underlyingCode` is the reader's code.
    public static let vodSourceFailed = PlaybackErrorKind(rawValue: "vodSourceFailed")
    /// The origin is metering us: it answered 429/503/509 and kept doing so across the session's
    /// bounded retries (#377), or answered one to the open itself, where `underlyingCode` is that
    /// status (#378). Distinct from `vodSourceFailed` because the source is not gone and
    /// the recovery is different in kind: the same request will succeed later, and a host that
    /// reacts to a dead source by handing off to a second engine will simply have that engine
    /// refused by the same origin. Wait, or tell the user, but do not re-ask immediately.
    public static let sourceRateLimited = PlaybackErrorKind(rawValue: "sourceRateLimited")
    /// The software decode pipeline failed.
    public static let softwarePipelineFailed = PlaybackErrorKind(rawValue: "softwarePipelineFailed")
    /// An audio-only session failed.
    public static let audioSessionFailed = PlaybackErrorKind(rawValue: "audioSessionFailed")
    /// A background reload of the same source failed.
    public static let reloadFailed = PlaybackErrorKind(rawValue: "reloadFailed")
    /// A live reload was served but the player never became ready on it.
    public static let liveReloadNeverReady = PlaybackErrorKind(rawValue: "liveReloadNeverReady")
    /// An audio-track switch failed; the session it replaced is gone with it.
    public static let audioTrackSwitchFailed = PlaybackErrorKind(rawValue: "audioTrackSwitchFailed")
    /// A source whose audio has to be transcoded (MP3, MP2, DTS, TrueHD, Vorbis, PCM: anything not
    /// legal for stream-copy into fMP4) produced no encoded audio at all, so the mp4 muxer could not
    /// build the sample entry it can only derive from a written packet and the first segment cut
    /// failed (AE#396). Distinct from `vodSourceFailed`, which this used to arrive as: the source is
    /// neither gone nor unreadable, and a second player that decodes the track itself will play it.
    /// A host with a fallback ladder should DEMOTE on this one, not end the ladder.
    public static let audioBridgeProducedNoOutput = PlaybackErrorKind(rawValue: "audioBridgeProducedNoOutput")
    /// [MovieClaw P25] 临时目录所在的卷写满了，切好的分片写不进去。片源没坏、网络也没断：
    /// 宿主该收小缓冲窗口原位重开（或提示清理存储），不该当成「解不了」换播放器
    public static let storageExhausted = PlaybackErrorKind(rawValue: "storageExhausted")
}

/// Machine-readable companion to the text inside `PlaybackState.error` (#376).
///
/// The message alone cannot classify a failure: roughly half of them are the engine's own sentence,
/// the rest are forwarded from the failure underneath, and on the native paths that is
/// `AVPlayerItem.error.localizedDescription` verbatim, which AVFoundation renders in the device's
/// language. Both halves arrive through one publisher, so a substring rule over the string buckets
/// every non-English device as unknown. `kind` is the key; the message stays what a human reads.
///
/// Published as `AetherEngine.errorInfo`, **assigned before `state`**, so a `$state` sink may read it
/// synchronously, and cleared by the state's own move away from `.error`, so the two cannot drift.
public struct PlaybackErrorInfo: Sendable, Equatable {
    /// What failed, in a form that survives a locale and a release.
    public let kind: PlaybackErrorKind
    /// `NSError.domain` of the failure underneath, nil where the engine authored the failure itself.
    /// Non-nil also means `message` embeds text localized by the OS.
    public let underlyingDomain: String?
    /// `NSError.code` of the failure underneath, or a reader's own code where one exists.
    public let underlyingCode: Int?
    /// The same text `state` carries.
    public let message: String

    public init(kind: PlaybackErrorKind,
                message: String,
                underlyingDomain: String? = nil,
                underlyingCode: Int? = nil) {
        self.kind = kind
        self.message = message
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
    }

    /// Captures domain and code off a Foundation / AVFoundation error, which is the half of the
    /// message that `localizedDescription` has already flattened past recognition.
    init(kind: PlaybackErrorKind, message: String, underlying: Error?) {
        let nsError = underlying as NSError?
        self.init(kind: kind,
                  message: message,
                  underlyingDomain: nsError?.domain,
                  underlyingCode: nsError?.code)
    }
}

extension AetherEngine {

    /// The single point where a failure becomes `state` (#376). Everything that fails goes through
    /// here, so a published `.error` can never arrive without its classification: the info is assigned
    /// first, the state second, and `PlaybackErrorInfoSourceTests` fails the build if a new
    /// `state = .error(...)` appears anywhere else.
    @MainActor
    func publishError(_ info: PlaybackErrorInfo) {
        errorInfo = info
        state = .error(info.message)
    }

    /// Engine-authored failure: the sentence names the cause and stays in English.
    @MainActor
    func publishError(_ kind: PlaybackErrorKind, _ message: String) {
        publishError(PlaybackErrorInfo(kind: kind, message: message))
    }

    /// Failure carrying a Foundation / AVFoundation error underneath, whose domain and code are the
    /// only part of it that classifies once `localizedDescription` has been folded into the message.
    @MainActor
    func publishError(_ kind: PlaybackErrorKind, _ message: String, underlying: Error?) {
        publishError(PlaybackErrorInfo(kind: kind, message: message, underlying: underlying))
    }

    /// A failed open the reader typed with the origin's answer (`AVIOReaderError.httpStatus`): the
    /// status becomes the kind, and stays in `underlyingCode` either way. A 429/503/509 is
    /// `sourceRateLimited`, not `sourceRefused` (#377): the source is not gone, the same request is
    /// expected to work later, and a host that reacts to a refusal by handing off to a second player
    /// would have that player metered by the same origin. Anything the reader did not type keeps the
    /// historical `sourceOpenFailed` with whatever was underneath.
    @MainActor
    func publishLoadFailure(_ error: Error) {
        // AE#495: trust first. A refused handshake is not a verdict on the resource, it is the absence
        // of a connection, and it can arrive either typed by the reader or as a URL error nested under
        // whatever gave up on top of it.
        if let readerError = error as? AVIOReaderError,
           case .transportSecurityFailed(let code) = readerError {
            publishError(PlaybackErrorInfo(kind: .sourceCertificateRejected,
                                           message: TransportSecurityFailure.sentence(for: code),
                                           underlyingDomain: NSURLErrorDomain,
                                           underlyingCode: code))
            return
        }
        if let code = TransportSecurityFailure.code(in: error) {
            publishError(PlaybackErrorInfo(kind: .sourceCertificateRejected,
                                           message: TransportSecurityFailure.sentence(for: code),
                                           underlyingDomain: NSURLErrorDomain,
                                           underlyingCode: code))
            return
        }
        if let readerError = error as? AVIOReaderError, case .httpStatus(let status) = readerError {
            let kind: PlaybackErrorKind = AVIOReader.isRateLimitStatus(status) ? .sourceRateLimited : .sourceRefused
            publishError(PlaybackErrorInfo(kind: kind,
                                           message: "Failed to load: \(error.localizedDescription)",
                                           underlyingCode: status))
            return
        }
        publishError(.sourceOpenFailed, "Failed to load: \(error.localizedDescription)", underlying: error)
    }
}
