import Foundation
import AVFAudio

/// Opt-in decoded PCM audio tap (#95). See docs/architecture.md, "Audio tap".
extension AetherEngine {

    /// Install the tap on the currently loaded item and return its buffer stream.
    /// Mono Float32 48 kHz (`AetherEngine.audioTapFormat`), source-PTS timestamps, lossy under
    /// pressure, never stalls playback. One tap per engine: installing again finishes the
    /// previous stream. `load()` and `stop()` finish it too (opt-in is per load). With no
    /// active playback session (or a video-only source) the returned stream finishes
    /// immediately.
    @MainActor
    public func installAudioTap() -> AsyncStream<AudioTapBuffer> {
        removeAudioTap()
        let controller = AudioTapController()
        audioTapController = controller

        let stream: AsyncStream<AudioTapBuffer>
        let kind = AudioTapReaderSelection.kind(
            backend: playbackBackend,
            hasLoopbackSession: nativeVideoSession != nil,
            nativeRemoteHLS: loadedOptions.nativeRemoteHLS,
            hasLoadedURL: loadedURL != nil)
        switch kind {
        case .loopback:
            stream = controller.makeStream { onStop in
                guard let reader = makeNativeTapReader(controller: controller) else { return }
                reader.start()
                onStop { reader.stop() }
            }
        case .remoteHLS:
            stream = controller.makeStream { onStop in
                guard let reader = makeRemoteHLSTapReader(controller: controller) else { return }
                reader.start()
                onStop { reader.stop() }
            }
        case .software:
            stream = controller.makeStream { onStop in
                guard softwareHost != nil else { return }
                installSoftwareTapSink(controller: controller)
                onStop { [weak self] in self?.softwareHost?.audioTapSink = nil }
            }
        case .none:
            stream = controller.makeStream { _ in }
        }
        // No session / no audio track / backend .none: nothing will ever yield, finish now.
        if !controller.hasDeliverySource { controller.teardown() }
        EngineLog.emit("[AetherEngine] audio tap installed (backend=\(playbackBackend.rawValue) "
            + "live=\(controller.hasDeliverySource))", category: .engine)
        return stream
    }

    /// Remove the tap and finish its stream. Safe to call when none is installed.
    @MainActor
    public func removeAudioTap() {
        audioTapController?.teardown()
        audioTapController = nil
    }

    /// Whether the installed tap has a live delivery source. Read synchronously right after
    /// `installAudioTap()`: false means the stream will finish without yielding (no session,
    /// video-only source, or a backend with no tap path), so the host can fail loudly instead
    /// of awaiting an empty stream.
    @MainActor
    public var audioTapHasDeliverySource: Bool {
        audioTapController?.hasDeliverySource ?? false
    }

    @MainActor
    private func makeNativeTapReader(controller: AudioTapController) -> LoopbackAudioReader? {
        guard let session = nativeVideoSession,
              let cache = session.cache,
              let provider = session.provider,
              let yield = controller.makeYield() else { return nil }
        // Video-only source: no audio pipeline was built, nothing to tap.
        guard session.audioPipelineDescription != nil else {
            EngineLog.emit("[AudioTap] source has no audio track", category: .engine)
            return nil
        }
        let decoder = AudioTapSegmentDecoder()
        let mirror = renderedPositionMirror
        let live = isLive
        let deps = LoopbackAudioReader.Dependencies(
            playhead: { mirror.get() },
            shiftSeconds: { [weak session] in session?.playlistShiftSeconds ?? 0 },
            anchorIndex: { [weak cache] t in
                let mapped = provider.segmentIndex(forPlaylistTime: t)
                // Live: the sliding window can outrun the mapping; never anchor behind
                // what AVPlayer itself is fetching.
                return live ? max(mapped, cache?.targetIndex ?? 0) : mapped
            },
            initData: { [weak cache] idx in
                guard let cache else { return nil }
                return cache.initData(versionID: cache.initVersionID(forSegment: idx))
                    ?? cache.fetchInit(timeout: 2)
            },
            segmentData: { [weak cache] idx in cache?.peek(index: idx) },
            highestStoredIndex: { [weak cache] in cache?.highestStoredIndex ?? -1 },
            decodeSegment: { initBlob, seg in decoder.decode(initData: initBlob, segment: seg) },
            emit: yield
        )
        return LoopbackAudioReader(deps: deps)
    }

    @MainActor
    private func installSoftwareTapSink(controller: AudioTapController) {
        guard let host = softwareHost, let yield = controller.makeYield() else { return }
        let converter = AudioTapPCMConverter()
        host.audioTapSink = { sample in
            for buf in converter.convert(sample) { yield(buf) }
        }
    }

    @MainActor
    private func makeRemoteHLSTapReader(controller: AudioTapController) -> AudioTapHLSReader? {
        guard let masterURL = loadedURL, let yield = controller.makeYield() else { return nil }
        // Same headers the player's AVURLAsset sends (#119); header-enforcing IPTV origins 403
        // the tap's own playlist / segment fetches without them.
        let fetcher = AudioTapHLSFetcher(httpHeaders: loadedOptions.httpHeaders)
        let decoder = AudioTapSegmentDecoder()
        let base = AudioTapBaseBox(masterURL)
        // renderedPositionMirror is fed by loadRemoteHLS's $currentTime sink (shift 0 here, so it
        // equals the source-PTS playhead); AtomicDouble is safe to read off the ingest task.
        let deps = AudioTapHLSReader.Dependencies(
            playhead: { [mirror = renderedPositionMirror] in mirror.get() },
            mediaURL: masterURL,
            fetchPlaylist: { url in
                let (playlist, finalURL) = try await fetcher.fetchPlaylist(url)
                if let audioURI = AudioTapHLSVariantResolver.pickAudioURI(from: playlist),
                   let audioURL = HLSPlaylistParser.resolve(uri: audioURI, against: finalURL) {
                    let (mediaPlaylist, mediaFinal) = try await fetcher.fetchPlaylist(audioURL)
                    base.set(mediaFinal)
                    guard case .media(let media) = mediaPlaylist else {
                        throw AudioTapHLSFetcher.FetchError.invalidPlaylist("expected media playlist")
                    }
                    return media
                }
                base.set(finalURL)
                guard case .media(let media) = playlist else {
                    throw AudioTapHLSFetcher.FetchError.invalidPlaylist("expected media playlist")
                }
                return media
            },
            fetchSegment: { uri, crypt in
                guard let url = HLSPlaylistParser.resolve(uri: uri, against: base.get()) else {
                    throw AudioTapHLSFetcher.FetchError.unresolvable
                }
                return try await fetcher.fetchSegment(url, crypt: crypt, base: base.get())
            },
            decodeSegment: { decoder.decode(selfContainedSegment: $0) },
            emit: yield)
        return AudioTapHLSReader(deps: deps)
    }
}

/// Publishes the resolved media-playlist base URL from the async playlist resolve to the segment
/// fetch closure. Segments are relative to the media playlist (after a master -> rendition follow),
/// not the master URL, so the base is learned during resolution.
final class AudioTapBaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL
    init(_ url: URL) { self.url = url }
    func get() -> URL { lock.lock(); defer { lock.unlock() }; return url }
    func set(_ u: URL) { lock.lock(); url = u; lock.unlock() }
}
