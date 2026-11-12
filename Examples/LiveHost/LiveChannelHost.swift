// LiveChannelHost.swift
//
// The parts of a live integration that are not a compile error when you get
// them wrong. MinimalPlayerApp shows the smallest viable player; this shows
// what a channel needs on top of it, and every piece here exists because a
// shipping host got it wrong first.
//
// Four contracts, all of them documented in docs/api.md, all of them silent
// when unanswered:
//
//   1. liveSourceReset. The engine parked a session it cannot revive and is
//      asking for a fresh load. Unsubscribed, the channel stops while the
//      engine still reports a session, which from the outside is a freeze.
//   2. The retune needs its own guard. A manual zap path carries none,
//      because a human paces it; driven by the engine it loops on a dead
//      upstream. Spend the bound out loud: a ladder ending on a silent
//      return is the same dead channel with a counter behind it.
//   3. CancellationError out of load() is not a failure. It is what a load
//      throws when a newer load or a stop supersedes it, so every zap
//      produces one, and a host that treats "load threw" as a failure
//      reacts to its own navigation.
//   4. The audio tap is bound to its session and ends with it, including on
//      a session-preserving reload. Re-install on stream end.
//
// Copy the shape, not the numbers. One retune in flight, 20 s apart, three
// per session is what the reference host settles on; your channel budget is
// yours.

import AetherEngine
import Combine
import Foundation

@MainActor
final class LiveChannelHost {

    private let engine: AetherEngine
    private var cancellables: Set<AnyCancellable> = []

    /// The URL the current channel was tuned with. An IPTV channel has a fixed
    /// one and reloads it verbatim; a session-negotiating backend (a Jellyfin
    /// live transcode) resolves a new one per retune instead. Both are correct
    /// answers to the same signal.
    private var channelURL: URL?

    // MARK: The retune guard (contract 2)

    private var retuneInFlight = false
    private var retuneCount = 0
    private var lastRetuneAt: Date?

    private static let retuneSpacing: TimeInterval = 20
    private static let retuneBudget = 3

    // MARK: Host surfaces, replace with your own UI

    /// True while nothing is on screen yet. Lifted on the first frame, which is
    /// NOT `state == .playing`: the native path publishes that as an intent
    /// before the item is ready, so a cover lifted there lifts onto black.
    private(set) var showsLoadingCover = true

    private func present(error: String) { /* your error UI */ }
    private func record(failure: String, domain: String?, code: Int?) { /* your analytics */ }
    private func channelIsDead(_ reason: String) { /* your "channel unavailable" UI */ }

    // MARK: - Wiring

    init(engine: AetherEngine) {
        self.engine = engine

        // Contract 1. Subscribe once per engine, and note that this is a subject
        // rather than a published value: it has no replay, so a subscription
        // made after the fact hears nothing.
        engine.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleLiveSourceReset() }
            .store(in: &cancellables)

        // The system turned captions on by itself (muted playback, skip back, a
        // language mismatch). The engine deselected its own rendition and hands
        // the ask over; answer it with a track of your own, or ignore it.
        engine.systemCaptionRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.answerCaptionRequest(request) }
            .store(in: &cancellables)

        // A session that dies after the load returned arrives here and nowhere
        // else. Show the message, but classify on `errorInfo`: half of these
        // sentences are the engine's own and half are AVFoundation's
        // `localizedDescription` forwarded verbatim, which is in the device's
        // language, so a bucket keyed on the text loses every non-English
        // device. The info is assigned before the state, so it is already this
        // failure's own by the time this sink runs.
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak engine] state in
                guard case .error(let message) = state else { return }
                self?.present(error: message)
                if let info = engine?.errorInfo {
                    self?.record(failure: info.kind.rawValue,
                                 domain: info.underlyingDomain,
                                 code: info.underlyingCode)
                }
            }
            .store(in: &cancellables)

        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                if ready { self?.showsLoadingCover = false }
            }
            .store(in: &cancellables)
    }

    // MARK: - Tuning

    /// A viewer picking a channel. The retune budget belongs to the session the
    /// engine is fighting for, so a deliberate tune starts a fresh one.
    func tune(to url: URL, headers: [String: String] = [:]) async {
        channelURL = url
        retuneCount = 0
        lastRetuneAt = nil
        showsLoadingCover = true
        await load(url, headers: headers)
    }

    private func load(_ url: URL, headers: [String: String] = [:]) async {
        do {
            _ = try await engine.load(url: url, options: LoadOptions(
                httpHeaders: headers,          // rides into the AVURLAsset on the bypass
                isLive: true,
                liveJoinProfile: .fastZap,     // zap latency over lean-back holdback
                nativeRemoteHLS: true
            ))
        } catch is CancellationError {
            // Contract 3. A newer load or a stop replaced this one. The
            // successor owns the session; there is nothing to report and
            // nothing to retry.
            return
        } catch {
            // The engine published `.error` with the same failure, so this is
            // one event with two signals rather than two failures. Counting
            // both is how a demotion ladder doubles its own numbers.
            present(error: error.localizedDescription)
        }
    }

    // MARK: - The retune (contracts 1 and 2)

    private func handleLiveSourceReset() {
        guard let url = channelURL else { return }

        // A second reset riding an in-flight retune is dropped rather than
        // queued, and logged: a latch that sticks (a hung load) must be
        // visible instead of silently eating every later recovery.
        guard !retuneInFlight else {
            EngineLog.emit("[LiveHost] retune skipped, already in flight (count=\(retuneCount))")
            return
        }

        let tooSoon = lastRetuneAt.map { Date().timeIntervalSince($0) < Self.retuneSpacing } ?? false
        guard retuneCount < Self.retuneBudget, !tooSoon else {
            // The bound is spent. This is the honest end of the ladder and it
            // has to be visible: the viewer is looking at a dead channel either
            // way, and only one of the two outcomes can be acted on.
            EngineLog.emit("[LiveHost] retune exhausted (count=\(retuneCount) tooSoon=\(tooSoon))")
            channelIsDead("The live stream keeps failing. Please try the channel again.")
            return
        }

        retuneInFlight = true
        retuneCount += 1
        lastRetuneAt = Date()
        showsLoadingCover = true

        Task { [weak self] in
            guard let self else { return }
            // Reloading the SAME url is the cheap answer rather than a no-op:
            // the engine remembers the #168 carriage verdict per exact absolute
            // URL for six hours, so the retune skips the native mount the first
            // load already failed. A URL carrying a rotated per-session token
            // misses that memory and re-pays the discovery every lap.
            await self.load(url)
            self.retuneInFlight = false
        }
    }

    // MARK: - Captions

    private func answerCaptionRequest(_ request: SystemCaptionRequest) {
        guard let language = request.language,
              let track = engine.subtitleTracks.first(where: { $0.language == language })
        else { return }
        engine.selectSubtitleTrack(index: track.id)
    }

    // MARK: - Audio tap (contract 4), optional

    /// Consume decoded playback audio (live transcription, ShazamKit). The
    /// stream belongs to the session it was installed against, so this loops:
    /// when it finishes, the session it followed is gone, and following the
    /// next one means installing again.
    func startAudioTap() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                let stream = self.engine.installAudioTap()
                guard self.engine.audioTapHasDeliverySource else {
                    // Nothing will ever arrive on this session (no audio track,
                    // or a backend with no tap path). Fail loudly here rather
                    // than awaiting an empty stream forever.
                    EngineLog.emit("[LiveHost] audio tap has no delivery source")
                    return
                }
                for await buffer in stream {
                    _ = buffer   // hand buffer.buffer / buffer.sourceTime to your consumer
                }
                // The stream ended: a load, a stop, or a session-preserving
                // reload (an audio or subtitle switch). Loop and re-install.
            }
        }
    }
}
