import Foundation
import AVFoundation
import AVKit
import Combine

/// `AVPlayer` + `AVPlayerLayer` wrapper owned by AetherEngine. Drives
/// the AVKit side that consumes the loopback HLS-fMP4 URL produced by
/// `HLSVideoEngine`. The reason this path exists at all: tvOS only
/// exposes the HDMI HDR-mode handshake to Dolby Vision through
/// `AVPlayer`-rooted playback, not through `AVSampleBufferDisplayLayer`.
///
/// This is the AVPlayer render path for sources that decode through
/// AVPlayer's HLS-fMP4 pipeline (HEVC, H.264, and AV1 on devices with
/// hardware AV1 decode). The dav1d software fallback for AV1 without
/// HW support and the VP9 path both live in `SoftwarePlaybackHost`.
///
/// Display-criteria handling lives in `DisplayCriteriaController`,
/// invoked from `AetherEngine.load(url:options:)` before the AVPlayer
/// item is loaded so the HDMI HDR-mode handshake is in flight by the
/// time AVPlayer's first segment fetch reaches the system.
@MainActor
final class NativeAVPlayerHost {

    // MARK: - Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    /// True after the AVPlayer item reaches the end of its stream.
    /// Engine flips state to .idle so host end-of-content flows
    /// (auto-dismiss, next-episode countdown if no marker) fire.
    @Published private(set) var didReachEnd: Bool = false

    // MARK: - Output

    /// The AVPlayerLayer the engine attaches to the bound
    /// `AetherPlayerView`. Created at init and reused for the lifetime
    /// of this host, even across `replaceCurrentItem` swaps.
    let playerLayer: AVPlayerLayer

    /// The underlying `AVPlayer`. Exposed engine-internally so the
    /// audio/subtitle track-selection layer can reach `AVMediaSelection`
    /// once that wiring lands.
    let avPlayer: AVPlayer

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    /// Latest external-metadata array the host wants on the playing
    /// item. Applied immediately to the current `AVPlayerItem` when set,
    /// and replayed onto a fresh item across internal reloads
    /// (audio-track switch, background reopen) so the system Now Playing
    /// surface keeps its title / artwork after the seam.
    private var pendingExternalMetadata: [AVMetadataItem] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var accessLogCount = 0

    /// Monotonic counter so multi-attempt sessions (DrHurt-style
    /// "play, fail, back out, retry") produce distinguishable log
    /// lines. Every load(url:) increments it; every async asset.load
    /// log line tags itself with the current value so a chain of
    /// "asset.load failed" entries can be matched back to the
    /// originating load() invocation.
    private static var nextSessionID: Int = 0
    private var sessionID: Int = 0

    // MARK: - Init

    init() {
        let player = AVPlayer()
        // Default (true) is right for VOD HLS, AVPlayer waits for
        // buffer. HLSAudioEngine sets `false` for live-audio latency
        // reasons, don't copy that pattern here: AVPlayer would try
        // to play the moment seg0 has any bytes and stall because
        // the lazy remuxer needs seconds to produce a full fragment.
        //
        // (Tried auto=false as a memory-bound experiment for the
        // long-form 4K HDR HEVC RSS growth. Result: AVPlayer's rate
        // dropped to 0 right after asset.load completed and never
        // resumed — startup permanently stalls. The risk note above
        // is real and the fix is to leave the default in place.)
        self.avPlayer = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.playerLayer.videoGravity = .resizeAspect
    }

    // No deinit cleanup: under Swift 6 strict concurrency the deinit
    // of a `@MainActor` type is nonisolated and can't reach
    // main-isolated properties. Callers must call `tearDown()`
    // before dropping this host. `AetherEngine.stopInternal()` is
    // the centralised invocation point.

    // MARK: - Lifecycle

    /// Load the URL produced by `HLSVideoEngine` (loopback HLS-fMP4).
    /// `DisplayCriteriaController.apply(...)` must have been invoked
    /// upstream so AVKit can configure the HDR pipeline against the
    /// right target mode before the first segment is fetched.
    func load(url: URL, startPosition: Double?, perFrameHDR: Bool = true) {
        unloadCurrentItem()

        Self.nextSessionID += 1
        sessionID = Self.nextSessionID
        let sid = sessionID

        EngineLog.emit("[NativeAVPlayerHost] #\(sid) load url=\(url.absoluteString) startPos=\(startPosition.map { String(format: "%.2fs", $0) } ?? "nil")", category: .engine)

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Match the audio engine's HLSAudioEngine config so any
        // "video-pattern is wrong" hypothesis can be ruled out as we
        // iterate. 4 s of forward buffer matches Apple's HLS authoring
        // recommendation for the current 4 s VOD segment cadence:
        // enough to ride out a normal segment-generation hiccup
        // without ballooning resident memory.
        item.preferredForwardBufferDuration = 4.0

        // Forward per-frame HDR metadata (HDR10+ ST 2094-40 and Dolby
        // Vision RPU) from the source bitstream into AVPlayer's
        // display-mode handshake. Without this, AVPlayer renders DV
        // sources in static HDR10 base only — the TV switches to
        // generic HDR mode instead of Dolby Vision mode, and DV
        // tone-mapping curves never engage. DrHurt's tests confirmed
        // that P8 MKVs and DV-tagged MP4s played end-to-end but the
        // Philips TV stayed in HDR mode for DV sources; he flagged
        // the missing AVPlayerItem flag specifically.
        //
        // Caller can disable when the routing decision routes through
        // the media playlist (panel locked SDR + match off path), where
        // AVPlayer can't engage HDR mode anyway and the per-frame
        // metadata pipeline is suspected of slow memory growth on long
        // DV 8.1 sessions (rss ~3 MB/sec linear, no visible bound).
        // Engine sets this to `false` for SDR-fallback paths so the
        // 4K HDR per-frame metadata path is bypassed and the leak
        // suspect is removed from those sessions.
        item.appliesPerFrameHDRDisplayMetadata = perFrameHDR
        // Apply any externalMetadata the host has pre-staged before this
        // load (e.g. system Now Playing title + artwork). Setting it
        // BEFORE AVPlayer.replaceCurrentItem-equivalent is the documented
        // safe order; doing it after the asset has started loading races
        // with AVPlayer's internal track-load. `AVPlayerItem.externalMetadata`
        // is unavailable on macOS — macOS hosts must write
        // `MPNowPlayingInfoCenter` directly.
        #if !os(macOS)
        if !pendingExternalMetadata.isEmpty {
            item.externalMetadata = pendingExternalMetadata
        }
        #endif
        playerItem = item
        accessLogCount = 0
        failureMessage = nil
        isReady = false

        // Status observer to track readyToPlay / failed transitions.
        // KVO observation runs on the same thread that mutated the
        // observed value, in this case AVPlayerItem hops to its own
        // queue, so we round-trip back to MainActor explicitly.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let statusStr: String
            switch item.status {
            case .unknown:     statusStr = "unknown"
            case .readyToPlay: statusStr = "readyToPlay"
            case .failed:      statusStr = "failed"
            @unknown default:  statusStr = "@unknown"
            }
            let nsErr = item.error as NSError?
            let errSuffix = nsErr.map { " err=\($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.status=\(statusStr)\(errSuffix)", category: .engine)

            // On .failed, dump the asset's track format descriptions
            // so we can see what codec FourCC AVPlayer actually saw.
            // Targets DrHurt's hev1 / dvhe rejection caveat: if a
            // session fails because the source's sample-entry tag is
            // hev1 instead of hvc1, that shows up here as "video
            // codec='hev1'". Also surfaces the underlying NSError
            // chain which often has the precise CoreMedia /
            // VideoToolbox cause behind the AVFoundationErrorDomain
            // wrapper.
            //
            // On .readyToPlay we also dump now (besides failures)
            // because the audio-track row carries the parsed
            // CMAudioFormatDescription: sample rate, channel count,
            // channel layout tag. Critical for diagnosing the FLAC
            // bridge surround-to-stereo downmix path — if the layout
            // tag comes back <missing> or kAudioChannelLayoutTag_Stereo
            // for an 8-channel source, the downmix is happening at
            // AVPlayer's moov parse rather than at the route / soundbar.
            if item.status == .failed {
                if let nsErr = nsErr,
                   let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.error.underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'", category: .engine)
                }
                Self.dumpAssetTracks(item.asset, sid: sid, reason: "item.failed")
                // Dump every error-log event accumulated since item
                // creation. AVPlayer's internal HLS pipeline writes
                // granular diagnostics here (variant filter rejections,
                // CODECS mismatches, init.mp4 parse failures, ATS
                // blocks, manifest errors) that the wrapped
                // AVFoundation/CoreMedia error codes hide. The
                // `newErrorLogEntryNotification` observer only catches
                // entries logged AFTER it registers, which races
                // synchronous entries logged during replaceCurrentItem;
                // polling the full log on .failed catches every entry
                // regardless of timing.
                if let log = item.errorLog() {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog dump: \(log.events.count) events", category: .engine)
                    for (idx, event) in log.events.enumerated() {
                        let comment = event.errorComment ?? "no comment"
                        let uri = event.uri ?? "-"
                        let server = event.serverAddress ?? "-"
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid)   errorLog[\(idx)] code=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(uri) server=\(server) '\(comment)'", category: .engine)
                    }
                } else {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog dump: <nil>", category: .engine)
                }
                if let log = item.accessLog() {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog dump: \(log.events.count) events", category: .engine)
                    for (idx, event) in log.events.enumerated() {
                        let uri = event.uri ?? "-"
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid)   accessLog[\(idx)] uri=\(uri) bytes=\(event.numberOfBytesTransferred) reqs=\(event.numberOfMediaRequests) downloadOverdue=\(event.numberOfStalls) dlSegments=\(event.numberOfDroppedVideoFrames)", category: .engine)
                    }
                } else {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog dump: <nil>", category: .engine)
                }
            } else if item.status == .readyToPlay {
                // For HLS sources `asset.tracks` returns empty
                // synchronously — the tracks live on AVPlayerItem
                // instead. Dump the player-item's audio tracks so we
                // can see what AVPlayer parsed from the moov for
                // diagnostic, plus the active audio route's channel
                // count after the route renegotiates against the
                // loaded asset.
                Self.dumpPlayerItemTracks(item, sid: sid)
                Self.dumpAudioRoute(sid: sid)
                Self.warnIfFLACSurroundExceedsRoute(item, sid: sid)
                Self.warnIfEAC3SurroundOnStereoRoute(item, sid: sid)
            }

            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isReady = true
                case .failed:
                    self.failureMessage = item.error?.localizedDescription ?? "AVPlayerItem failed (no description)"
                default:
                    break
                }
            }
        }

        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) rate=\(rate)", category: .engine)
            Task { @MainActor in
                self?.rate = rate
            }
        }

        // timeControlStatus + reasonForWaitingToPlay together explain
        // whether AVPlayer is paused, waiting on buffer, or actively
        // playing. Critical for diagnosing "spinner forever" symptoms
        // because reasonForWaitingToPlay surfaces the exact stall cause
        // (.evaluatingBufferingRate / .toMinimizeStalls / etc.).
        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let statusStr: String
            switch player.timeControlStatus {
            case .paused:                          statusStr = "paused"
            case .waitingToPlayAtSpecifiedRate:    statusStr = "waitingToPlay"
            case .playing:                         statusStr = "playing"
            @unknown default:                      statusStr = "@unknown"
            }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) timeControlStatus=\(statusStr) reason=\(reason)", category: .engine)
        }

        // Error log: AVPlayer surfaces transient HLS-level errors
        // (404 on a segment, parse failure on a manifest, ATS rejection,
        // codec mismatch) without flipping the item to .failed. These
        // are the gold mine for "AVPlayer just sits there" diagnostics.
        let errLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let event = self.playerItem?.errorLog()?.events.last else { return }
            let comment = event.errorComment ?? "no comment"
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog code=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(event.uri ?? "-") '\(comment)'", category: .engine)
        }
        notificationObservers.append(errLogObs)

        // Access log: log only the first few entries so we know
        // whether AVPlayer ever reached the segment-fetch stage.
        // AVPlayer can pump hundreds of these for a long stream so
        // capping at 5 keeps the overlay readable.
        let accessLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.accessLogCount < 5,
                  let event = self.playerItem?.accessLog()?.events.last else { return }
            self.accessLogCount += 1
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog uri=\(event.uri ?? "-") server=\(event.serverAddress ?? "-") bytes=\(event.numberOfBytesTransferred) reqs=\(event.numberOfMediaRequests)", category: .engine)
        }
        notificationObservers.append(accessLogObs)

        let failedToEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let suffix = err.map { " \($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) failedToPlayToEndTime\(suffix)", category: .engine)
        }
        notificationObservers.append(failedToEndObs)

        let stalledObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { _ in
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) playbackStalled", category: .engine)
        }
        notificationObservers.append(stalledObs)

        // End-of-stream: AVPlayer fires didPlayToEndTime when the
        // last sample is rendered. Flip the published flag so the
        // engine knows the session reached its natural end (engine
        // forwards that to state = .idle).
        let didEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) didPlayToEndTime", category: .engine)
            Task { @MainActor in
                self?.didReachEnd = true
            }
        }
        notificationObservers.append(didEndObs)

        // Periodic time observer at 100 ms drives the scrub bar
        // and the resume-position progress reporter. The closure is
        // already invoked on `.main`, so the `MainActor` mutation
        // is safe; cast through a Task to satisfy the Sendable check.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let value = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor in
                self?.currentTime = value
            }
        }

        avPlayer.replaceCurrentItem(with: item)

        // Explicitly kick off the async load of the asset's playable /
        // tracks / duration values. AVPlayerItem(asset:) plus KVO on
        // status SHOULD trigger this implicitly per Apple's docs, but
        // the build-123 overlay showed AVPlayer stuck in waitingToPlay
        // with the item never advancing past .unknown — consistent
        // with the asset never beginning its async load. Forcing the
        // load explicitly removes that ambiguity.
        //
        // We load each key in a separate await so DrHurt's
        // "1 success, 3 failures" log signature can be decoded down
        // to "which key is the -1008 hitting on": isPlayable, tracks,
        // or duration. With the batch load they all share one error
        // and we can't tell which probe AVFoundation gave up on.
        let urlStr = url.absoluteString
        Task { [weak self] in
            for key in ["isPlayable", "tracks", "duration"] {
                do {
                    switch key {
                    case "isPlayable": _ = try await asset.load(.isPlayable)
                    case "tracks":     _ = try await asset.load(.tracks)
                    case "duration":   _ = try await asset.load(.duration)
                    default: continue
                    }
                    let detail: String
                    switch key {
                    case "isPlayable": detail = "value=\(asset.isPlayable)"
                    case "tracks":     detail = "count=\(asset.tracks.count)"
                    case "duration":   detail = "seconds=\(asset.duration.seconds)"
                    default: detail = "-"
                    }
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) ok url=\(urlStr) \(detail)", category: .engine)
                } catch {
                    let nsErr = error as NSError
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) failed: \(nsErr.domain)/\(nsErr.code) '\(nsErr.localizedDescription)' url=\(urlStr)", category: .engine)
                    if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'", category: .engine)
                    }
                    // Dump whatever track info AVFoundation managed
                    // to populate before the load gave up. Targets
                    // DrHurt's -1008 stall: even on failure the
                    // asset's first probe often surfaces the
                    // sample-entry FourCC (hev1 vs hvc1, dvhe vs
                    // dvh1) that explains the rejection.
                    Self.dumpAssetTracks(asset, sid: sid, reason: "asset.load(\(key)).failed")
                    _ = self
                    return
                }
            }
        }

        // Always issue an explicit seek so AVPlayer doesn't fall back
        // to its EVENT-playlist live-edge default. For VOD this is a
        // no-op (default start is already time 0); for the sliding-
        // window EVENT path it's what makes replay-from-beginning land
        // at 0:00 instead of at the end of the initial visible window
        // (~2 min in for a 30-segment initialFillSegments window).
        // EXT-X-START:TIME-OFFSET=0 in the playlist is the spec-level
        // hint but isn't enough on its own — AVPlayer treats EVENT
        // playlists as "start near the live edge" unless the caller
        // explicitly seeks first.
        seek(to: startPosition ?? 0)
    }

    /// Release the AVPlayerItem so a follow-up `load(...)` starts
    /// from a clean state. Caller is responsible for resetting the
    /// display-criteria (the engine does this from
    /// `stopInternal()` after invoking `tearDown()` here).
    func tearDown() {
        unloadCurrentItem()
    }

    // MARK: - Playback control

    func play() {
        // AVPlayer with `automaticallyWaitsToMinimizeStalling=true`
        // (the default) handles "play before ready" correctly: it
        // sets rate=1, transitions to waitingToPlayAtSpecifiedRate,
        // begins loading the asset, buffers, and once it has enough
        // it transitions to playing. The earlier defer-until-ready
        // pattern was a guard against a different bug (master playlist
        // parse-rejection) and reintroduced a chicken-and-egg here:
        // item.status doesn't advance until the player is actually
        // told to play, so deferring play() on item.status kept the
        // status stuck at .unknown forever.
        avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        // Frame-accurate seek. Earlier experiment with
        // `.positiveInfinity` tolerances to skip the IDR-to-target
        // decode pre-roll caused AVPlayer to land on apparently-
        // arbitrary sync samples far from the requested time — the
        // user's TestFlight session showed the image "hanging" on
        // wrong-position content during forward scrubs. AVPlayer's
        // "most efficient seek" interpretation of unbounded tolerance
        // appears to be undefined for HLS-fMP4 served over loopback,
        // matching the long-standing openradar 44904505 bug report.
        // Keep tolerances at zero until we have a different lever
        // (predictive engine prefetch on scrub commit) that doesn't
        // depend on tolerance semantics.
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ value: Float) {
        avPlayer.rate = value
    }

    /// Stage the metadata items the host wants on the current and any
    /// future `AVPlayerItem` of this session. The system Now Playing
    /// surface reads from `AVPlayerItem.externalMetadata` when an
    /// `MPNowPlayingSession` is active with automatic publishing on.
    /// Applied immediately if an item exists; otherwise replays onto the
    /// next item created by `load(url:startPosition:)`.
    func setExternalMetadata(_ items: [AVMetadataItem]) {
        pendingExternalMetadata = items
        #if !os(macOS)
        playerItem?.externalMetadata = items
        #endif
    }

    // MARK: - Internal

    private func unloadCurrentItem() {
        if let to = timeObserver {
            avPlayer.removeTimeObserver(to)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        accessLogCount = 0
        avPlayer.replaceCurrentItem(with: nil)
        playerItem = nil
        isReady = false
        didReachEnd = false
        currentTime = 0
        duration = 0
        rate = 0
    }

    /// Log the asset's URL plus every track's media type, codec
    /// FourCC, enabled flag, and playable flag. Called from both the
    /// `item.status == .failed` path and the per-key `asset.load`
    /// failure path so DrHurt's "AVPlayer stalls in waitingToPlay
    /// instead of failing" sessions still surface the codec FourCCs
    /// (item.status never going `.failed` was the reason d9b8aa5's
    /// dump didn't fire in DrHurt's P5 MKV log).
    private static func dumpAssetTracks(_ asset: AVAsset, sid: Int, reason: String) {
        if let urlAsset = asset as? AVURLAsset {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.url=\(urlAsset.url.absoluteString) (\(reason))", category: .engine)
        }
        let tracks = asset.tracks
        if tracks.isEmpty {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.tracks empty (\(reason))", category: .engine)
            return
        }
        for track in tracks {
            let fourcc: String
            var extra = ""
            if let fmt = track.formatDescriptions.first {
                let cm = fmt as! CMFormatDescription
                fourcc = fourccString(CMFormatDescriptionGetMediaSubType(cm))
                if track.mediaType == .audio {
                    extra = " " + audioFormatDescription(cm)
                }
            } else {
                fourcc = "?"
            }
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.track type=\(track.mediaType.rawValue) codec='\(fourcc)' enabled=\(track.isEnabled) playable=\(track.isPlayable)\(extra) (\(reason))", category: .engine)
        }
    }

    /// AVPlayerItem.tracks-based audio track dump. For HLS sources
    /// `asset.tracks` is empty synchronously, only AVPlayerItem.tracks
    /// returns the resolved track list once the playlist + init.mp4
    /// have been parsed. Logs one line per audio track with sample
    /// rate, channel count, bit depth, format ID, and channel layout
    /// tag (the multichannel-routing diagnostic).
    private static func dumpPlayerItemTracks(_ item: AVPlayerItem, sid: Int) {
        let tracks = item.tracks
        if tracks.isEmpty {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.tracks empty (readyToPlay)", category: .engine)
            return
        }
        for itemTrack in tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            let fourcc: String
            var extra = ""
            if let fmt = assetTrack.formatDescriptions.first {
                let cm = fmt as! CMFormatDescription
                fourcc = fourccString(CMFormatDescriptionGetMediaSubType(cm))
                if assetTrack.mediaType == .audio {
                    extra = " " + audioFormatDescription(cm)
                } else if assetTrack.mediaType == .video {
                    extra = " " + videoFormatDescription(cm)
                }
            } else {
                fourcc = "?"
            }
            let trackLabel: String
            if assetTrack.mediaType == .audio {
                trackLabel = "audioTrack"
            } else if assetTrack.mediaType == .video {
                trackLabel = "videoTrack"
            } else {
                continue
            }
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(sid) item.\(trackLabel) codec='\(fourcc)' "
                + "enabled=\(itemTrack.isEnabled)\(extra) (readyToPlay)",
                category: .engine
            )
        }
    }

    /// Compact one-line summary of a CMFormatDescription for video
    /// tracks. Reads the picture dimensions plus the color attachments
    /// AVPlayer applied (primaries / transfer / matrix / range), which
    /// is what we need to compare against the source-side codecpar
    /// values that we log from the engine in `[HLSVideoEngine] DV
    /// source` / `prepared`. A mismatch here is a strong signal the
    /// DV / HDR signaling didn't survive the muxer round-trip.
    private static func videoFormatDescription(_ fmt: CMFormatDescription) -> String {
        var parts: [String] = []
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        parts.append("dim=\(dims.width)x\(dims.height)")
        let extensions = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
        if let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
            parts.append("primaries=\(primaries)")
        }
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
            parts.append("transfer=\(transfer)")
        }
        if let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            parts.append("matrix=\(matrix)")
        }
        if let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool {
            parts.append("fullRange=\(fullRange)")
        }
        return parts.joined(separator: " ")
    }

    /// One-line warning when the FLAC bridge has produced an N-channel
    /// track but the active audio route can only carry M < N channels
    /// of LPCM. Fires only for FLAC tracks because:
    ///
    ///   - Stream-copy paths (EAC3 / AC3 / AAC) tunnel through HDMI as
    ///     encoded bitstream, bypassing the LPCM channel-count limit.
    ///     A Sonos Arc with route.ch=2 still receives 7.1 surround via
    ///     EAC3 bitstream over eARC.
    ///   - FLAC bridge output is decoded to LPCM by AVPlayer, then
    ///     routed via the active port's LPCM channel count. If the
    ///     port can carry only stereo (e.g. Sonos Arc reports 2ch
    ///     LPCM via HDMI even with eARC, because the soundbar handles
    ///     multichannel exclusively via bitstream), the 8-channel
    ///     LPCM gets downmixed before reaching the sink. End result:
    ///     stereo from a TrueHD / DTS-HD MA source.
    ///
    /// This is a route capability mismatch, not a bug in the bridge.
    /// AVR setups with proper 7.1 LPCM-over-HDMI support (Denon /
    /// Marantz / NAD) carry the full 7.1 LPCM cleanly and don't
    /// trigger this warning.
    private static func warnIfFLACSurroundExceedsRoute(_ item: AVPlayerItem, sid: Int) {
        #if os(iOS) || os(tvOS)
        var trackChannels: Int = 0
        var isFLAC = false
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            guard assetTrack.mediaType == .audio else { continue }
            guard let fmt = assetTrack.formatDescriptions.first else { continue }
            let cm = fmt as! CMFormatDescription
            let codec = fourccString(CMFormatDescriptionGetMediaSubType(cm))
            if codec.lowercased() == "flac" {
                isFLAC = true
                if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(cm) {
                    trackChannels = Int(asbdPtr.pointee.mChannelsPerFrame)
                }
                break
            }
        }
        guard isFLAC, trackChannels > 2 else { return }
        let session = AVAudioSession.sharedInstance()
        let routeChannels = max(
            session.currentRoute.outputs.first?.channels?.count ?? 0,
            session.outputNumberOfChannels
        )
        guard routeChannels > 0, routeChannels < trackChannels else { return }
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) WARNING: FLAC bridge produced \(trackChannels)-channel "
            + "LPCM but active audio route carries only \(routeChannels) LPCM channels — tvOS "
            + "will downmix. Common cause: soundbars (Sonos Arc, etc.) accept multichannel only "
            + "via bitstream codecs (EAC3, Atmos, DD+), not LPCM. Stream-copy paths bypass this; "
            + "TrueHD / DTS-HD MA sources route through the FLAC bridge and hit the LPCM limit. "
            + "AVRs with 7.1 LPCM-over-HDMI support play these sources at full source channel "
            + "count without downmix.",
            category: .session
        )
        #endif
    }

    /// Warn when an EAC3 / AC3 multichannel track plays into a route
    /// the HDMI sink is reporting as stereo-only. Atmos (EAC3 with the
    /// `flag_ec3_extension_type_a` JOC marker set in dec3) is excluded
    /// from this warning because Atmos uses a 2-channel MAT 2.0 / IEC
    /// 61937 carrier — `ch=2` on the route is the correct, working
    /// state for an Atmos passthrough and does NOT mean stereo output.
    ///
    /// Why: plain DD+ 5.1 and DD 5.1 need either ch=6 LPCM or a
    /// bitstream passthrough negotiation that the sink advertises in
    /// its EDID. Sonos Arc (and similar soundbars) report ch=2 on the
    /// HDMI port when the sink is in stereo PCM mode — usually after a
    /// boot, an HDMI handshake glitch, or after the AVR/soundbar lost
    /// the Apple TV's audio format hint. AVPlayer can still try the
    /// bitstream-passthrough path, but Sonos can apparently reject it
    /// when ch=2 is advertised, falling back to PCM stereo. Common fix
    /// is a power cycle of the soundbar so EDID re-negotiates and ch=6
    /// becomes available, OR the user can flip Apple TV's audio format
    /// setting once to force a re-handshake.
    ///
    /// This is a route capability mismatch, not a bug in our pipeline.
    /// The EAC3 bitstream we deliver is identical across runs (we
    /// proved this with byte-level diff of the dec3 box and the first
    /// audio packet), so when one run plays surround and the next
    /// stereo on the same source, the difference is at the sink layer.
    private static func warnIfEAC3SurroundOnStereoRoute(_ item: AVPlayerItem, sid: Int) {
        #if os(iOS) || os(tvOS)
        var trackChannels: Int = 0
        var codecID: String = ""
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            guard assetTrack.mediaType == .audio else { continue }
            guard let fmt = assetTrack.formatDescriptions.first else { continue }
            let cm = fmt as! CMFormatDescription
            let codec = fourccString(CMFormatDescriptionGetMediaSubType(cm))
            let lower = codec.lowercased()
            if lower == "ec-3" || lower == "ac-3" {
                codecID = codec
                if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(cm) {
                    trackChannels = Int(asbdPtr.pointee.mChannelsPerFrame)
                }
                break
            }
        }
        guard !codecID.isEmpty, trackChannels > 2 else { return }
        let session = AVAudioSession.sharedInstance()
        let routeChannels = max(
            session.currentRoute.outputs.first?.channels?.count ?? 0,
            session.outputNumberOfChannels
        )
        guard routeChannels > 0, routeChannels < trackChannels else { return }
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) WARNING: \(codecID) \(trackChannels)-channel "
            + "track playing into a \(routeChannels)-channel route. tvOS will downmix to "
            + "\(routeChannels) channels. The encoded bitstream is correct (dec3/dac3 reports "
            + "5.1 with acmod=7+lfeon=1, packets carry the full multichannel content). The "
            + "route limit comes from the HDMI sink's current capability advertisement, not "
            + "from this engine. Common cause on soundbars: HDMI handshake landed in stereo "
            + "PCM mode after a reboot or audio-format change. Atmos (EAC3+JOC) is unaffected "
            + "because it tunnels through a 2-channel MAT carrier. Power cycle the sink or "
            + "flip Apple TV's audio format setting once to re-negotiate ch=6 LPCM / EAC3 "
            + "passthrough.",
            category: .session
        )
        #endif
    }

    /// Dump the active audio route's channel capability after the
    /// AVPlayerItem reaches readyToPlay. The route renegotiates when
    /// AVPlayer loads an asset, so the channel count we polled at
    /// AVAudioSession setup (engine init, before any asset existed)
    /// can differ from the post-load capability.
    ///
    /// `outputNumberOfChannels` is the actual channel count the route
    /// will carry — if the asset is 8-channel FLAC but the soundbar /
    /// AVR doesn't accept 7.1 LPCM via HDMI, the route stays at 2 and
    /// AVPlayer's PCM decoder downmixes upstream. EAC3 / Atmos avoids
    /// this because the bitstream tunnels through as encoded data
    /// without an LPCM intermediate.
    private static func dumpAudioRoute(sid: Int) {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let out = session.outputNumberOfChannels
        let pref = session.preferredOutputNumberOfChannels
        let maxCh = session.maximumOutputNumberOfChannels
        let route = session.currentRoute
        let outputDescs = route.outputs.map { port in
            let portName = port.portName
            let portType = port.portType.rawValue
            let nChannels = port.channels?.count ?? -1
            return "\(portName)[\(portType), ch=\(nChannels)]"
        }.joined(separator: ", ")
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) audioRoute output=\(out) preferred=\(pref) max=\(maxCh) "
            + "ports=[\(outputDescs)] (readyToPlay)",
            category: .engine
        )
        #endif
    }

    /// Read sample rate, channel count, and channel layout tag from
    /// a CMAudioFormatDescription. Used by `dumpAssetTracks` to expose
    /// what AVPlayer actually parsed for the audio track. Critical for
    /// multichannel sources: if libavformat's mov muxer wrote the
    /// codec / dfLa / chnl / chan boxes correctly, the channel layout
    /// tag here matches the source's spatial layout (kAudio...7_1_A for
    /// MPEG-style 7.1). If the tag comes back unknown or stereo, the
    /// downmix is happening at the AVPlayer parse layer rather than at
    /// the soundbar / route layer.
    private static func audioFormatDescription(_ fmt: CMFormatDescription) -> String {
        var parts: [String] = []
        if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            let asbd = asbdPtr.pointee
            parts.append("sr=\(Int(asbd.mSampleRate))")
            parts.append("ch=\(asbd.mChannelsPerFrame)")
            parts.append(String(format: "bits=%d", asbd.mBitsPerChannel))
            parts.append("fmt=\(fourccString(asbd.mFormatID))")
        }
        var layoutSize = 0
        if let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &layoutSize),
           layoutSize >= MemoryLayout<AudioChannelLayout>.size {
            let layout = layoutPtr.pointee
            parts.append("layoutTag=0x\(String(layout.mChannelLayoutTag, radix: 16))")
            if layout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
                parts.append("descs=\(layout.mNumberChannelDescriptions)")
            }
        } else {
            parts.append("layoutTag=<missing>")
        }
        return parts.joined(separator: " ")
    }

    /// Render a 4-byte CoreMedia FourCC subtype (e.g. 'hvc1', 'hev1',
    /// 'dvh1', 'avc1', 'mp4a') as a printable ASCII string. Used in
    /// failure-path diagnostics to surface the exact sample-entry
    /// codec tag AVPlayer saw, which lets us tell whether the source
    /// was hev1 / dvhe (DrHurt's known-rejected forms from
    /// AetherEngine#2) versus hvc1 / dvh1 (the accepted forms).
    private static func fourccString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let chars = bytes.map { (b: UInt8) -> Character in
            (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : "."
        }
        return String(chars)
    }
}
