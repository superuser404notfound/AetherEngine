<p align="center">
  <img src=".github/aetherengine-logo.png" alt="AetherEngine" width="180">
</p>

<h1 align="center">AetherEngine</h1>

<p align="center">
  <b>A media player engine for Apple platforms.</b><br>
  FFmpeg demuxes. VideoToolbox decodes. AVPlayer handles Dolby Atmos.<br>
  Video, live TV with DVR timeshift, or a lean audio-only path with system Now-Playing. You ship the UI.
</p>

<p align="center">
  <a href="https://github.com/superuser404notfound/AetherEngine/releases/latest"><img src="https://img.shields.io/github/v/release/superuser404notfound/AetherEngine?label=release&color=blue"></a>
  <a href="https://github.com/superuser404notfound/AetherEngine/actions/workflows/ci.yml"><img src="https://github.com/superuser404notfound/AetherEngine/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/AetherEngine"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FAetherEngine%2Fbadge%3Ftype%3Dswift-versions"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/AetherEngine"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FAetherEngine%2Fbadge%3Ftype%3Dplatforms"></a>
  <img src="https://img.shields.io/badge/Swift-6.4%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-LGPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
  <a href="https://aetherengine.superuser404.de"><img src="https://img.shields.io/badge/docs-aetherengine.superuser404.de-4a6eff"></a>
  <a href="https://discord.gg/P7NvpzNqnG"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white"></a>
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

---

## What it is

AetherEngine is a video and audio player engine for iOS, tvOS, macOS and visionOS. It plays almost any file or stream and keeps Apple's own HDR, Dolby Vision and Dolby Atmos handling intact.

- **FFmpeg** opens the file. **VideoToolbox** decodes in hardware. **AVPlayer** presents the picture and passes Dolby Atmos through.
- Formats Apple cannot decode go to the engine's own software decoder (dav1d, libavcodec).
- You get one view and a few `async` methods. You build the controls.

## Highlights

- **Plays nearly everything:** MKV, MP4, WebM, MPEG-TS, AVI, WMV, DVD and Blu-ray ISOs, on-demand MPEG-DASH, and every codec FFmpeg knows. [Full list](docs/features.md)
- **HDR done right:** HDR10, HDR10+, HLG, and Dolby Vision Profiles 5, 7, 8 and AV1 Profile 10, with the real display switch on Apple TV.
- **Dolby Atmos:** E-AC-3 Atmos is passed through untouched, to HDMI receivers and to AirPods with spatial audio.
- **Lossless height channels from TrueHD and DTS:X** as an optional component.
- **Subtitles of every kind:** text, ASS, PGS, DVB, DVD, teletext, closed captions, external files, and subtitles that survive Picture in Picture and AirPlay.
- **Live TV:** HLS ingest, DVR timeshift, recording over the same connection, and recovery when a channel breaks.
- **Any source:** URLs, your own byte reader (`IOReader`), and SMB shares.
- **No UI, no analytics, no surprises.** Nothing leaves the device.

## Quick start

Add the package:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "7.63.0")
```

Play a video:

```swift
import AetherEngine
import SwiftUI

let player = try AetherEngine()

struct PlayerView: View {
    var body: some View { AetherPlayerSurface(engine: player) }
}

try await player.load(url: videoURL)
player.play()
```

Read the state from the published properties (`player.$state`, `player.clock.$currentTime`, `player.audioTracks`, `player.$subtitleCues`, ...). The [host guide](docs/guide.md) walks through everything a real player needs, and [`Examples/MinimalPlayer`](Examples/MinimalPlayer/MinimalPlayerApp.swift) is a complete single-file player to copy.

**On tvOS**, read [tvOS host setup](docs/guide.md#tvos-host-setup) before you ship HDR content.

## Documentation

Also available as a searchable site: **[aetherengine.superuser404.de](https://aetherengine.superuser404.de)**.

| Document | What is in it |
| --- | --- |
| [Installation](docs/installation.md) | Adding the package, requirements, optional components, versioning |
| [Host guide](docs/guide.md) | Building a player: loading, state, tracks, subtitles, live TV, tvOS setup, logging |
| [Features](docs/features.md) | What the engine plays and does, area by area |
| [API reference](docs/api.md) | Every public API, and the contracts your app has to answer |
| [Formats](docs/formats.md) | Codecs, containers, HDR, audio, subtitles, discs, known limits, in depth |
| [Architecture](docs/architecture.md) | How the playback pipelines work, and which file does what |
| [Dolby Vision FEL](docs/dolby-vision-fel.md) | How Profile 7 FEL is played |
| [aetherctl](docs/cli.md) | The command-line tool that runs the real engine on a Mac |
| [How it compares](docs/comparison.md) | AetherEngine next to AVPlayer, KSPlayer, VLCKit and libmpv, with measurements |
| [Licensing](docs/licensing.md) | What you need to do to ship the engine and its dependencies |
| [Changelog](CHANGELOG.md) | Every release |

## Requirements

| | Min |
| --- | --- |
| iOS | 18.0 |
| tvOS | 18.0 |
| macOS | 15.0 |
| visionOS | 1.0 |
| Swift | 6.4 |
| Xcode | 27.0 |

Details on toolchains, CI and older OS versions: [Installation › Requirements](docs/installation.md#requirements).

## Optional components

Five components are only built when you turn on their package trait: height channels from TrueHD (`TrueHDObjectAudio`) and DTS:X (`DTSXObjectAudio`), the Dolby Vision FEL curve fold (`DolbyVisionFelCurves`), the FEL dual-layer composer (`DualLayerDolbyVision`), and Dolby Vision stills (`DolbyVisionStillReshaping`). They may need third-party patent licences. How to turn them on and which FEL option to choose: [Installation › Optional components](docs/installation.md#optional-components).

## How it compares

AVPlayer has the best OS integration but plays only Apple's formats. VLCKit and libmpv play everything but bypass Apple's Dolby Vision, Atmos and HDR handling. AetherEngine combines both. Feature table and power, CPU and memory measurements: [How it compares](docs/comparison.md).

## Used by

<!-- used-by:start -->
- [Sodalite](https://github.com/superuser404notfound/Sodalite): native Jellyfin client for Apple TV.
- [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer): native macOS media player.
- [NowSeen](https://discord.com/invite/7AFh3Hy8p4): IPTV / Manifest app for tvOS.
- [KSKPix](https://ksktech.dev/kskpix): KSKPix is a premium IPTV player for Live TV, Movies & Series.
- [Syravo](https://syravo.app): Xtream Codes, Jellyfin and radio client for iPhone, iPad and Apple TV.
- [KIPTV](https://kiptv.app): Premium, cross-platform IPTV Player.
- [Silo](https://github.com/Silo-Server/silo-apple): native iOS, tvOS and macOS client for the Silo self-hosted media server.
- [File Box](https://apps.apple.com/app/id6765818194): File Box is a simple and practical local file manager on iPhone and iPad.
- [Moonfin](https://github.com/Moonfin-Client/Moonfin-Core): A multi-platform third party Jellyfin client.
- [Snappier IPTV](https://apps.apple.com/gb/app/snappier-iptv/id1579702567): IPTV App for iOS/iPadOS and tvOS.
- [stashy](https://stashy.shelf.am/): iOS/tvOS native player for stash.
- [Gflix](https://gflixhub.app/): A flawless media app for your media.
- [Melon Video](https://apps.apple.com/ca/app/melon-video/id6811750997): Video Player for Vision Pro.
- [WUW IPTV Player](https://apps.apple.com/tr/app/wuw-iptv-player-smart-m3u-tv/id6759220800): Watch U Want — or simply WUW — your IPTV player for iPhone, iPad, Mac, Apple TV and Apple Vision Pro.
- [GiVo Stream](https://givostreamapp.com): media player for iPhone, iPad and Apple TV with bring-your-own playlists, live timeshift, DVR and VOD.
- [LillyPlayer](https://lillyplayer.com): The all-in-one IPTV and media player for Apple TV, iPhone and iPad (live TV, EPG, replay, Jellyfin, Plex, SMB...).
- [Plozz](https://plozz.app): Free forever open source native app for iPhone, iPad, and Apple TV. Supports Jellyfin, Plex, Emby, Silo, IPTV, SMB, WebDAV and more.
- [Crivid IPTV Player](https://apps.apple.com/app/id6783083716): IPTV player for M3U and Xtream on Apple TV.
- [HipTV](https://hiptv.app): A cross-platform, synchronized IPTV player.
- [ZeoPlayer](https://apps.apple.com/app/id6792761598): Modern media player for iPhone, iPad, Mac, Apple TV and Apple Vision Pro with HDR, Dolby Vision, spatial audio and SMB support.
- [Theamo](https://theamo.app): IPTV player and TV guide for iPhone, iPad and Apple TV.
- [Lume](https://github.com/bilipp/Lume/): SwiftUI native open source IPTV and media player for iOS, tvOS and macOS.
- [Prowlogue](https://prowlogue.app/): Native Apple TV client for the Jellyfin media server.
- [BoraMin](https://github.com/jonpurdy/boramin): A native, minimal, iCloud-syncing SMB and HTTP(S) video player for tvOS, iPhone, and Mac.
<!-- used-by:end -->

Shipping something on AetherEngine? [Submit it](https://github.com/superuser404notfound/AetherEngine/issues/new?template=used-by-submission.yml) to get listed here and on [aetherengine.superuser404.de](https://aetherengine.superuser404.de).

## Stability and versioning

AetherEngine follows [Semantic Versioning](https://semver.org). Every `public` declaration in `Sources/AetherEngine/` is part of the contract: a major version breaks it, a minor version adds to it, a patch fixes bugs. Details: [Installation › Stability and versioning](docs/installation.md#stability-and-versioning).

## License

[LGPL-3.0 with an App Store exception](LICENSE): you can ship the engine in App Store apps, and changes to the engine itself stay LGPL. FFmpeg and the other dependencies keep their own licences. What you need to do: [Licensing](docs/licensing.md).

## Support

If the engine is useful to you, you can support its development on [Ko-fi](https://ko-fi.com/superuser404). Questions and chat: [Discord](https://discord.gg/P7NvpzNqnG).

## Built with

AetherEngine is vibe-coded, designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). Nearly every commit carries a `Co-Authored-By: Claude` trailer.
