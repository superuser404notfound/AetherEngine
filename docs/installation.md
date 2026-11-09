# Installation

How to add AetherEngine to an app, what it needs, and how to turn on the optional components.

- [Add the package](#add-the-package)
- [Requirements](#requirements)
- [Optional components](#optional-components)
- [Privacy manifest](#privacy-manifest)
- [Stability and versioning](#stability-and-versioning)

## Add the package

Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "7.62.0")
```

Then link the `AetherEngine` product. Add `AetherEngineSMB` too if you want to play from SMB shares ([guide.md › SMB shares](guide.md#smb-shares)).

Next step: [guide.md › First player](guide.md#first-player).

## Requirements

| | Min |
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
| `ci.yml` | Every change | Tests on macOS, and builds the test target for the iOS and tvOS Simulator |
| `ci-extended.yml` | Nightly, and before each release | Release build, visionOS, and the device SDKs with every optional component |
| `xcode26-compat.yml` | Weekly (best effort), and before each release | Builds the package for tvOS and iOS with Xcode 26.3 (Swift 6.2). A break there is known before a release ships, but it does not block one. |

**AV1 / VP9 registration on older Xcode.** `VTRegisterSupplementalVideoDecoderIfAvailable` first appears in the mobile SDKs of Xcode 26.2. A narrow compile-time guard uses Swift 6.2.3 as a stand-in for that SDK in stock Xcode bundles. In stock Xcode 26.0 / 26.1 it leaves those calls out and keeps hardware queries and the software fallback. It does not mean the rest of the package builds there, and it does not lower the supported toolchain. A separately installed newer Swift toolchain paired with an older SDK is not covered by this guard. The macOS registration path is unchanged.

**Older OS versions.** The 7.x line raised the floor from iOS 16, tvOS 17 and macOS 14. A project that still supports those pins the 6.x line with `.upToNextMajor(from: "6.89.1")`.

## Optional components

Five components are only compiled when a host asks for them. Each sits behind a package trait that is **off by default**.

| Trait | Compiles and links | Without it |
| --- | --- | --- |
| `TrueHDObjectAudio` | [LibTrueHD](https://github.com/superuser404notfound/LibTrueHD) and the bed regression | TrueHD Atmos keeps the channel bridge whatever `objectAudioRendering` asks |
| `DTSXObjectAudio` | the DTS:X decoder (FFmpeg's `dca` with FFmpegBuild's height patch, no extra library) and the bed regression that builds the layout from its 7.1 bed | DTS:X keeps the channel bridge whatever `objectAudioRendering` asks |
| `DualLayerDolbyVision` | the Profile 7 FEL dual-layer composer (`DualLayerVideoDecoder`, its Metal composer and the per-frame display metadata); not recommended for distributed apps, see below | a Profile 7 source keeps the native route whatever `preferDualLayerDolbyVision` asks |
| `DolbyVisionStillReshaping` | the reshaping that turns a Dolby Vision Profile 5 / AV1 Profile 10.0 frame into a still | such a source has no scrub stills, I-frame stills or held picture (`supportsCacheBackedStills` is false); playback is unaffected |
| `DolbyVisionFelCurves` | the fold of a Profile 7 FEL enhancement layer into the Profile 8.1 RPU on the native route (the stream's mapping kept, the luma residual added to its luma curve per scene) ([Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route)) | the native route's Profile 8.1 conversion drops the enhancement layer, as before |

**What "off" means.** Without its trait, a component is not in the binary. Its code is not compiled, and a library behind it is neither linked nor resolved (it disappears from the host's `Package.resolved`). The options that ask for it stay in the API, so a host compiles the same either way. They then do nothing, and the session log says why:

- `TrueHD Atmos rendering requested but not built in (TrueHDObjectAudio trait off)`
- `DV P7 dual-layer route: not taken (built without the DualLayerDolbyVision trait)`

To hide a setting your build cannot honour, ask `AetherEngine.OptionalComponent`, for example `AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn`.

**Patents.** These components may be subject to third-party patent licensing. Integrators who enable them are responsible for their own licensing.

### Profile 7 FEL: prefer `DolbyVisionFelCurves`

Both `DolbyVisionFelCurves` and `DualLayerDolbyVision` bring back a FEL source's enhancement layer, in different ways. **A host without a Dolby Vision licence should build `DolbyVisionFelCurves`.**

| | `DolbyVisionFelCurves` (curve fold) | `DualLayerDolbyVision` (composer) |
| --- | --- | --- |
| How | Keeps the disc's own mapping in the Profile 8.1 RPU and adds only the enhancement layer's luma residual to the luma curve, per scene | Reconstructs the picture in the engine, evaluating the RPU's MMR chroma prediction and the enhancement layer on every pixel |
| Patents | Leaves every evaluation of the mapping to the platform's licensed decoder; the engine never applies a mapping to a pixel or forms a composed picture | These steps are covered by live Dolby patents (the MMR family runs to 2032) |
| Route | Native, with everything it keeps: Picture in Picture, AirPlay, scrub stills, subtitles | Software host |
| Result | Within 0.8 to 2.1 Delta E ITP of the composed FEL picture on three UHD Blu-ray samples (2.5 to 8.9 without it) | The full composed picture |
| Missing | The enhancement layer's local detail (12-bit refinement, grain) | |

See [Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

### Turning traits on

List the traits on the package dependency:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "7.62.0",
         traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision", "DolbyVisionStillReshaping"])
```

**Xcode project.** Set a remote package's traits in the package dependency editor (Project › Package Dependencies). Xcode stores them in the `.pbxproj`.

**XcodeGen** cannot express traits yet (2.45.4 silently drops a `traits:` key on a package). Two workarounds:

1. Patch the generated `.pbxproj` after each generate: a `traits = ( TrueHDObjectAudio, DTSXObjectAudio, );` list in the package's `XCRemoteSwiftPackageReference`, which Xcode 27 builds with.
2. Depend on a small local package that depends on AetherEngine with the traits set and re-exports it (`@_exported import AetherEngine`). [Probes/AllTraits](../Probes/AllTraits/Package.swift) is such a package with every trait on, and `Probes/DolbyVisionPulse/Device/PulseEngine` one with `DualLayerDolbyVision` alone.

**Building the engine itself** with traits: `swift build --traits TrueHDObjectAudio,DTSXObjectAudio,DualLayerDolbyVision,DolbyVisionStillReshaping` (or `--enable-all-traits`). CI builds and tests both the default and the all-traits configuration, and builds the all-traits engine for tvOS and iOS through `Probes/AllTraits`.

## Privacy manifest

The engine ships a `PrivacyInfo.xcprivacy` in its resource bundle for the required-reason APIs it calls (#920):

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

Teams that want to opt into minor versions explicitly pin `.upToNextMinor(from: "7.62.0")`.
