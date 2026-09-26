# Examples

Three samples covering different audiences:

- **MinimalPlayer**: source-only SwiftUI drop-in for **developers** integrating AetherEngine into their own apps. Read the file, paste it into your Xcode project, change the URL.
- **LiveHost**: the live-TV half that MinimalPlayer leaves out, the four contracts a channel needs and none of which is a compile error when it is missing.
- **DemoPlayerMac**: standalone macOS SwiftPM app for **testers** wanting to exercise the engine against their own media without writing host code. `swift run` opens a window; drop a file on it to play.

## MinimalPlayer

[`MinimalPlayer/MinimalPlayerApp.swift`](MinimalPlayer/MinimalPlayerApp.swift) is a complete SwiftUI app entry point that loads, plays, and reports state for a single source URL, comments and UI state plumbing included.

### Try it in 5 minutes

1. **Create an Xcode project.** File › New › Project. Pick the SwiftUI template for the platform you want (tvOS / iOS / macOS App). Any product name; no tests target needed.

2. **Add AetherEngine as a Swift Package dependency.** File › Add Package Dependencies, paste:
   ```
   https://github.com/superuser404notfound/AetherEngine
   ```
   Dependency Rule: Up to Next Major Version, starting from `7.18.2`. Add the `AetherEngine` library product to your app target.

3. **Drop the file in.** Replace the Xcode template's default `App.swift` (or whatever the generated `@main` file is called) with the contents of [`MinimalPlayerApp.swift`](MinimalPlayer/MinimalPlayerApp.swift). The file is self-contained: it defines both the `@main App` struct and the `ContentView`.

4. **Point at a real source URL.** Edit the `sourceURL` line:
   ```swift
   @State private var sourceURL = URL(string: "https://example.com/your-video.mkv")!
   ```
   Use any file://, http://, or https:// URL the engine can demux. MKV / MP4 / WebM / MPEG-TS / AVI all work.

5. **Run.** Hit ▶︎ in Xcode. The Load button kicks off the demux + HLS-fMP4 pipeline; Play / Pause / Stop hit the engine directly. State, time, duration, and detected video format update live via the engine's Combine publishers.

### What's not in the minimal example

To stay readable the sample omits things real apps care about:

- **Subtitles.** `engine.subtitleTracks` lists them; `engine.selectSubtitleTrack(index:)` activates one. `engine.$subtitleCues` publishes the cues (text or `CGImage`) that the host paints over the surface.
- **Audio track switching.** `engine.audioTracks` + `engine.selectAudioTrack(index:)`.
- **Resume position.** `engine.load(url:, startPosition: 347.5)`.
- **HTTP headers** for authenticated sources. Pass them in `LoadOptions(httpHeaders: [...])`.
- **HDR / Dolby Vision routing on tvOS.** Requires the engine-driven sole-writer pattern (see README › Host setup on tvOS). The minimal sample relies on default routing; for production tvOS hosts on HDR content, set `appliesPreferredDisplayCriteriaAutomatically = false` on your `AVPlayerViewController` and pass `LoadOptions(matchContentEnabled:, panelIsInHDRMode:)` populated from the runtime EDR state.
- **Now Playing / lock-screen integration.** Subscribe to `engine.$currentAVPlayer` and feed it to `MPNowPlayingSession`. See `Sodalite` for a reference implementation.

For all of these, read [docs/api.md](../docs/api.md), the full public surface with the contracts spelled out, or the inline docstrings on `AetherEngine`, `LoadOptions`, and `TrackInfo` in `Sources/AetherEngine/`.

## LiveHost

[`LiveHost/LiveChannelHost.swift`](LiveHost/LiveChannelHost.swift) is the part of a live integration that no compiler will ask you about. Every piece in it exists because a shipping host got it wrong first:

1. **`liveSourceReset`.** The engine parked a session it cannot revive and is asking for a fresh `load`. Unsubscribed, the channel stops while the engine still reports a session, which from the outside is a freeze with nothing in the log.
2. **The retune needs its own guard.** Routing the answer into the manual channel-change path is the right shape, but that path carries no spacing rule, because a human paces it. Driven by the engine it loops on a dead upstream. One retune in flight, a minimum spacing, a bounded count, and then the exhausted case surfaced rather than swallowed.
3. **`CancellationError` out of `load()` is not a failure.** It is what a superseded load throws, so every zap produces one.
4. **The audio tap ends with its session**, including on a session-preserving reload, so a consumer re-installs on stream end.

Copy the shape, not the numbers. It is a skeleton rather than an app: the UI surfaces are stubs for yours.

Both loose samples are compiled by the package's `ExampleSources` target, so `swift build` and CI fail when one stops matching the API. They are never a product, so nothing reaches a consumer's build.

## DemoPlayerMac

[`DemoPlayerMac/`](DemoPlayerMac/README.md) is a runnable macOS SwiftPM app. Built against AetherEngine via a local path so it stays in lock-step with the engine source it ships alongside. The point is to play any media file end-to-end in under a minute:

```bash
cd Examples/DemoPlayerMac
swift run
```

A *AetherEngine Demo* window opens. Drag a video file onto it; playback starts. Click or press space to toggle play / pause; escape to stop. A corner badge shows `native` or `sw` so bug reporters can attribute the source to the right backend in repro posts.

No transport bar, no subtitle picker, no settings, by design. The demonstrator's job is to prove playback; anything past that belongs in a real host app like [Sodalite](https://github.com/superuser404notfound/Sodalite).

For shipping a notarized `.dmg` end users can download (the long-form goal of [issue #18](https://github.com/superuser404notfound/AetherEngine/issues/18)), see [`DemoPlayerMac/Scripts/build-dmg.sh`](DemoPlayerMac/Scripts/build-dmg.sh): universal binary, Hardened Runtime, Gatekeeper-accepted. Requires a Developer ID Application certificate; setup steps are in the script's docstring.
