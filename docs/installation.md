# Installation

How to add AetherEngine to an app, what it needs, and how to turn on the optional components.

- [Add the package](#add-the-package)
- [Requirements](#requirements)
- [Optional components](#optional-components)
- [FFmpeg in the same app](#ffmpeg-in-the-same-app)
- [Privacy manifest](#privacy-manifest)
- [Stability and versioning](#stability-and-versioning)

## Add the package

Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "7.66.1")
```

Then link the `AetherEngine` product. Add `AetherEngineSMB` too if you want to play from SMB shares ([guide.md › SMB shares](guide.md#smb-shares)).

Next step: [guide.md › First player](guide.md#first-player).

## Requirements

| | Supported |
| --- | --- |
| iOS | 18.0 |
| tvOS | 18.0 |
| macOS | 15.0 |
| visionOS | 1.0 |
| Swift | 6.4 |
| Xcode | 27.0 |

**Toolchain.** The Swift and Xcode rows are the toolchain CI builds and tests with (GitHub's `xcode-27` image). Older toolchains are not supported. The OS floor stays at iOS / tvOS 18 and macOS 15, with newer calls behind `#available`.

What CI runs:

| Job | When | What |
| --- | --- | --- |
| `ci.yml` | Every change | Tests on macOS with and without the optional components, builds the test target for the iOS and tvOS Simulator, and checks the doc links |
| `ci-extended.yml` | Nightly, and before each release | Release build, visionOS, the device SDKs with every optional component, a test pass on a one-thread pool, and the probe harnesses |
| `xcode26-compat.yml` | Weekly (best effort), and before each release | Builds the package for tvOS and iOS with Xcode 26.3 (Swift 6.2). A break there is known before a release ships, but it does not block one. |

**Older OS versions.** The 7.x line raised the floor from iOS 16, tvOS 17 and macOS 14. A project that still supports those pins the 6.x line with `.upToNextMajor(from: "6.89.1")`.

**AV1 / VP9 registration on older Xcode.** `VTRegisterSupplementalVideoDecoderIfAvailable` first appears in the mobile SDKs of Xcode 26.2. A narrow compile-time guard handles older stock Xcode:

- It uses Swift 6.2.3 as a stand-in for that SDK in stock Xcode bundles.
- In stock Xcode 26.0 / 26.1 it leaves those calls out and keeps hardware queries and the software fallback.
- It does not mean the rest of the package builds there, and it does not lower the supported toolchain.
- It does not cover a separately installed newer Swift toolchain paired with an older SDK.

The macOS registration path is unchanged.

## Optional components

Five components are only compiled when a host asks for them. Each sits behind a package trait (a SwiftPM build switch set on the package dependency) that is **off by default**.

| Trait | Compiles and links | Without it |
| --- | --- | --- |
| `TrueHDObjectAudio` | [LibTrueHD](https://github.com/superuser404notfound/LibTrueHD) and the bed regression | TrueHD Atmos keeps the channel bridge whatever `objectAudioRendering` asks |
| `DTSXObjectAudio` | the DTS:X decoder (FFmpeg's `dca` with FFmpegBuild's height patch, no extra library) and the bed regression that builds the layout from its 7.1 bed | DTS:X keeps the channel bridge whatever `objectAudioRendering` asks |
| `DualLayerDolbyVision` | the Profile 7 FEL dual-layer composer (`DualLayerVideoDecoder`, its Metal composer and the per-frame display metadata); not recommended for distributed apps, see below | a Profile 7 source keeps the native route whatever `preferDualLayerDolbyVision` asks |
| `DolbyVisionStillReshaping` | the reshaping that turns a Dolby Vision Profile 5 / AV1 Profile 10.0 frame into a still | such a source has no scrub stills, I-frame stills or held picture (`supportsCacheBackedStills` is false); playback is unaffected |
| `DolbyVisionFelCurves` | the fold of a Profile 7 FEL enhancement layer into the Profile 8.1 RPU on the native route (the stream's mapping kept, the luma residual added to its luma curve per scene) ([Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route)) | the native route's Profile 8.1 conversion drops the enhancement layer |

In the table, the channel bridge is the default audio handling (decode, then re-encode as plain channels without heights). The bed regression builds the height layout from the stream's own lossless 7.1, steered by its objects or heights.

**What "off" means.** Without its trait, a component is not in the binary. Its code is not compiled, and a library behind it is neither linked nor resolved (it disappears from the host's `Package.resolved`). The options that ask for it stay in the API, so a host compiles the same either way. They then do nothing, and the session log says why:

- `TrueHD Atmos rendering requested but not built in (TrueHDObjectAudio trait off)`
- `DV P7 dual-layer route: not taken (built without the DualLayerDolbyVision trait)`

To hide a setting your build cannot honour, ask `AetherEngine.OptionalComponent`, for example `AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn`.

**Patents.** These components may be subject to third-party patent licensing. Integrators who enable them are responsible for their own licensing.

### Profile 7 FEL: prefer `DolbyVisionFelCurves`

**A host without a Dolby Vision licence should build `DolbyVisionFelCurves`.** Both `DolbyVisionFelCurves` and `DualLayerDolbyVision` bring back a FEL source's enhancement layer, in different ways.

- The composer evaluates the RPU's MMR chroma prediction and the enhancement layer on every pixel. The RPU is the Dolby Vision metadata that rides with each frame. These steps are covered by live Dolby patents (the MMR family runs to 2032).
- The curve fold leaves every evaluation of the mapping to the platform's licensed decoder.

| | `DolbyVisionFelCurves` (curve fold) | `DualLayerDolbyVision` (composer) |
| --- | --- | --- |
| Route | Native, with everything it keeps: Picture in Picture, AirPlay, scrub stills, subtitles | Software host |
| Missing | The enhancement layer's local detail (12-bit refinement, grain) | Nothing: it composes the full picture |

How each works and how close the fold gets to the composed picture: [Dolby Vision FEL › In one minute](dolby-vision-fel.md#in-one-minute) and [Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

### Turning traits on

List the traits on the package dependency:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "7.66.1",
         traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DolbyVisionFelCurves", "DolbyVisionStillReshaping"])
```

**Xcode project.** Set a remote package's traits in the package dependency editor (Project › Package Dependencies). Xcode stores them in the `.pbxproj`.

**XcodeGen** cannot express traits yet (2.45.4 silently drops a `traits:` key on a package). Two workarounds:

1. Patch the generated `.pbxproj` after each generate: a `traits = ( TrueHDObjectAudio, DTSXObjectAudio, );` list in the package's `XCRemoteSwiftPackageReference`, which Xcode 27 builds with.
2. Depend on a small local package that depends on AetherEngine with the traits set and re-exports it (`@_exported import AetherEngine`). [Probes/AllTraits](../Probes/AllTraits/Package.swift) is such a package with every trait on, and `Probes/DolbyVisionPulse/Device/PulseEngine` one with `DualLayerDolbyVision` alone.

**Building the engine itself** with traits: `swift build --traits TrueHDObjectAudio,DTSXObjectAudio,DualLayerDolbyVision,DolbyVisionFelCurves,DolbyVisionStillReshaping` (or `--enable-all-traits`). CI builds and tests both the default and the all-traits configuration on every change, and nightly builds the all-traits engine for tvOS and iOS through `Probes/AllTraits`.

## FFmpeg in the same app

Read this if your app links any other FFmpeg, directly or through another player (libVLC, KSPlayer, mpv, FFmpegKit). The engine has to bind to its own FFmpeg. The linker decides which FFmpeg it gets, not the package graph.

### One FFmpeg, and it has to be the engine's

**What the host must do:** make sure no second FFmpeg in the app serves the engine's FFmpeg calls. Check the `[FFmpeg]` line the first `init` logs.

AetherEngine calls `avcodec_*`, `avformat_*`, `avutil_*` and `swr_*` as ordinary external symbols. The host executable's link decides which binary serves them, so a second FFmpeg anywhere in the app can take the calls. Two setups do it, and neither announces itself:

- **A static FFmpeg pulled in with `-force_load`.** Its symbols become ordinary definitions inside the executable, and a definition in a `.o` beats a dylib for every other object in the same link.
- **A dependency that exports the same symbols.** libVLC is the common one. Keeping it beside AetherEngine is reasonable: the API is built around a fallback ladder (try one player, fall back to another), which invites exactly that pairing. CocoaPods sorts a pod ahead of a vendored framework, so libVLC's libavcodec wins by default.

The engine then runs against headers it was never compiled against: struct layouts, codec ids and the encoder set are whatever the other build decided.

The symptoms do not look like a linking problem. They look like an engine defect, in whatever the other build happens to be missing. Example (AE#396): a report of an audio-bridge defect on five fixtures and two devices was a second FFmpeg one major version behind. The engine's only trace was `flac bridge encoder absent from this FFmpeg build`, true about a build that was not the engine's. That line names the libavcodec that answered.

The first `AetherEngine()` in the process logs which FFmpeg answered, once. Install `EngineLog.handler` before creating the first engine to get the line in your own log:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

When a major version does not match the headers the engine compiled against, that line becomes an `ERROR:` naming the mismatch, the likely cause, and the two commands that show it:

```
$ nm -m <executable> | grep _avcodec_find_encoder     # which binary wins
(__TEXT,__text) external _avcodec_find_encoder        #   a definition in the executable itself
(undefined) external _avcodec_find_encoder (from MobileVLCKit)   #   or someone else's dylib

$ otool -L <executable>                               # and in what order
```

The fix is the host's, because nothing inside a library can reach it: link AetherEngine's frameworks ahead of the other FFmpeg, or drop the second copy. The majors the engine expects are the ones FFmpegBuild's headers declare for the pinned version. The line above prints both sides, so there is nothing to look up.

### Holding a second player beside the engine

**What the host must do:** nothing if the other player's FFmpeg is dynamic. If it is static, link the engine into a dynamic framework of your own instead of into the app.

A ladder that keeps KSPlayer, mpv or MobileVLCKit for the formats it already covers is a normal shape. Since FFmpegBuild 3.0.0 the engine's FFmpeg is named so it can live beside another:

- The frameworks ship as `AetherLibavcodec`, `AetherLibavformat`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter`, `AetherLibdav1d`, `AetherLibzimg` and `AetherLibzvbi`.
- The install names follow (`@rpath/AetherLibavcodec.framework/AetherLibavcodec`).

The prefix is what lets one package graph hold both. SwiftPM target names are unique across the whole dependency graph, and two framework bundles cannot share one path in `App.app/Frameworks/`.

**If the other FFmpeg is a set of dynamic frameworks**, that is the whole fix. Apple's linker uses a two-level namespace: each symbol reference records which dylib it came from. So the engine reaches its libavcodec and the other player reaches its own, in one process, with no link order to win.

**If the other FFmpeg is static**, no rename helps: `_avcodec_open2` is `_avcodec_open2` in every FFmpeg. Its symbols become definitions inside the executable, and the engine, statically linked beside them, binds to those. The fix is to stop linking the engine into the executable:

1. Add a dynamic framework target to your project, say `PlayerEngineKit`, and link the `AetherEngine` product into that target instead of into the app.
2. Embed the `AetherLib*` frameworks in the app as usual (Xcode does this for you when the package is linked).
3. Have the app talk only to `PlayerEngineKit`.

The engine's `_av*` references are then resolved when that framework links, against `AetherLibavcodec.framework`, and recorded as coming from it. Whatever the executable defines for its own player no longer takes part. The same construction lets MobileVLCKit's FFmpeg and FFmpegKit coexist.

Run these two commands once to confirm it, rather than trusting the arrangement:

```
$ nm -m PlayerEngineKit.framework/PlayerEngineKit | grep _avcodec_open2
(undefined) external _avcodec_open2 (from AetherLibavcodec)   # right: it comes from ours

$ otool -L PlayerEngineKit.framework/PlayerEngineKit | grep -i libavcodec
@rpath/AetherLibavcodec.framework/AetherLibavcodec
```

The engine also reports it: the `[FFmpeg] libavcodec …` line at `init` shows the versions that actually answered, not the ones it was built against, so a wrong binding shows up in the log before it shows up as a defect.

## Privacy manifest

The engine ships a `PrivacyInfo.xcprivacy` in its resource bundle. It declares the required-reason APIs it calls (APIs Apple makes an app justify):

| API category | Reason | Why |
| --- | --- | --- |
| System boot time | 35F9.1 | `systemUptime` for elapsed time |
| Disk space | E174.1 | Checked before packets spool to disk |
| File timestamp | C617.1, 3B52.1 | C617.1 for its own temp and cache files, 3B52.1 for local media the host opens |

The FFmpeg frameworks carry their own manifest from FFmpegBuild 3.10.2 on. Neither tracks or collects anything, so an app that embeds the engine has nothing of the engine's to add to its own manifest.

## Stability and versioning

AetherEngine uses [Semantic Versioning](https://semver.org). The public API (every `public` declaration in `Sources/AetherEngine/`) is the stability contract. `internal` types are not part of it.

| Bump | Means |
| --- | --- |
| Major | Removes or renames public symbols, or otherwise breaks adopters |
| Minor | Adds public API or codec / format support |
| Patch | Fixes bugs, no public API change |

Teams that want to opt into minor versions explicitly pin `.upToNextMinor(from: "7.66.1")`.
