// MinimalPlayerApp.swift
//
// Smallest viable AetherEngine integration. Drop this file into a new
// SwiftUI tvOS / iOS / macOS app, add the AetherEngine Swift Package as
// a dependency, set the file's @main App as the app entry point, and
// run. This file is the whole host, everything else (HDR routing,
// Atmos passthrough, codec dispatch, subtitle decoding) is the engine.
//
// Live TV needs four more contracts on top of this; they are in
// Examples/LiveHost/LiveChannelHost.swift.
//
// See Examples/README.md for the click-by-click setup.

import SwiftUI
import AetherEngine

@main
struct MinimalPlayerApp: App {

    /// Engine is created once for the app's lifetime. AetherEngine is
    /// designed to be a long-lived instance: hosts call `load(url:)`
    /// for each new title against the same engine rather than rebuilding
    /// the audio session + display-criteria controller per playback.
    let engine: AetherEngine = {
        do {
            let engine = try AetherEngine()
            // No AVPlayerViewController here, so the engine activates the audio session itself,
            // after the TV's mode switch and right before play() (AE#1110).
            engine.nativeAudioSessionActivationEnabled = true
            return engine
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
        }
    }
}

struct ContentView: View {
    let engine: AetherEngine

    /// Replace with a real source URL, file://, http://, or https://.
    /// AetherEngine probes the container, picks the right pipeline,
    /// and starts segment production automatically once `load` returns.
    @State private var sourceURL = URL(string: "https://example.com/your-video.mkv")!
    @State private var loadError: String?

    // Observed engine state. The engine publishes via Combine; SwiftUI
    // bridges them through `onReceive` modifiers below.
    @State private var playerState: PlaybackState = .idle
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var videoFormat: VideoFormat = .sdr

    var body: some View {
        VStack(spacing: 16) {
            // The render surface. SwiftUI variant; UIKit/AppKit hosts
            // use `AetherPlayerView()` and `engine.bind(view:)` instead.
            AetherPlayerSurface(engine: engine)
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)

            // Minimal transport. Real hosts replace this with a proper
            // focus-driven transport bar; this is just to prove the
            // engine reacts to commands.
            HStack(spacing: 24) {
                Button("Load") {
                    Task { await load() }
                }
                Button(playerState == .playing ? "Pause" : "Play") {
                    playerState == .playing ? engine.pause() : engine.play()
                }
                .disabled(playerState == .idle || playerState == .loading)
                Button("Stop") {
                    engine.stop()
                }
                .disabled(playerState == .idle)
            }

            // State readout. videoFormat tells you what dynamic range
            // the panel is currently presenting (already clamped to
            // panel capability, a DV source on a non-DV TV reads as
            // .hdr10, not .dolbyVision).
            VStack(alignment: .leading, spacing: 4) {
                Text("State: \(String(describing: playerState))")
                Text("Time: \(formatTime(currentTime)) / \(formatTime(duration))")
                Text("Format: \(String(describing: videoFormat))")
                if let err = loadError {
                    Text("Error: \(err)").foregroundStyle(.red)
                }
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding()
        .onReceive(engine.$state) { playerState = $0 }
        // The playback clock lives on engine.clock (a separate
        // ObservableObject) so its ~10 Hz ticks only re-render views
        // that explicitly opt in, like this one.
        .onReceive(engine.clock.$currentTime) { currentTime = $0 }
        .onReceive(engine.$duration) { duration = $0 }
        .onReceive(engine.$videoFormat) { videoFormat = $0 }
    }

    private func load() async {
        loadError = nil
        do {
            try await engine.load(url: sourceURL)
            engine.play()
        } catch {
            loadError = "\(error)"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
