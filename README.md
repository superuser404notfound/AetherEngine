<p align="center">
  <img src="https://img.shields.io/badge/License-LGPL%20v3-blue.svg" alt="License: LGPL v3">
  <img src="https://img.shields.io/badge/iOS-16%2B-000000?logo=apple" alt="iOS 16+">
  <img src="https://img.shields.io/badge/tvOS-16%2B-000000?logo=apple" alt="tvOS 16+">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.0+">
</p>

# SteelPlayer

A lightweight video player engine for Apple platforms. FFmpeg handles the containers, VideoToolbox handles the decoding, Apple's synchronizer handles the timing. **Your app provides the UI — SteelPlayer provides the engine.**

> **~3,400 lines of Swift.** No bloat, no abstractions for abstractions. Just a clean pipeline from URL to pixels.

---

## Why SteelPlayer?

Most video player libraries try to do everything — UI, controls, playlists, analytics. SteelPlayer does one thing well: **decode and render video with perfect A/V sync.** You get a `CALayer` and a simple API. The rest is yours.

- **No UIKit/AppKit dependency** — works in any view hierarchy
- **No Metal shaders** — uses Apple's native `AVSampleBufferDisplayLayer`
- **No network stack** — uses `URLSession` like every other Apple app
- **No opinions** — play, pause, seek. That's it.

---

## Features

### Video

| | |
|---|---|
| **Containers** | MKV, MP4, AVI, MPEG-TS, WebM, OGG, FLV |
| **HW decode** | H.264, HEVC, HEVC Main10 — via VideoToolbox |
| **SW decode** | AV1, VP9 — FFmpeg fallback with pixel buffer pooling |
| **HDR10** | 10-bit P010 output, BT.2020/PQ color metadata on every frame |
| **Dolby Vision** | Profile 5, 8.1, 8.4 on DV-capable displays; HDR10 fallback on others |
| **HLG** | Hybrid Log-Gamma detection and correct transfer function tagging |
| **B-frames** | 4-frame reorder buffer for correct presentation order |

### Audio

| | |
|---|---|
| **Codecs** | AAC, AC3, EAC3, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, ALAC, PCM |
| **Surround** | 5.1 and 7.1 multichannel output with `AudioChannelLayout` mapping |
| **Spatial Audio** | AirPods Pro/Max and HomePod spatialization (automatic) |
| **HDMI** | Multichannel PCM over HDMI eARC — receiver handles surround |
| **Tracks** | Runtime audio track switching |

> **Note on Dolby Atmos:** tvOS does not provide audio passthrough for third-party apps. Atmos content is decoded to 7.1 PCM — same as Infuse, Plex, and all other third-party players. Object-based metadata and height channels are lost during decode. Only Apple's own TV app outputs true Atmos.

### Playback

| | |
|---|---|
| **A/V Sync** | `AVSampleBufferRenderSynchronizer` master clock |
| **Speed** | 0.5x to 2.0x playback speed |
| **Volume** | Programmable volume (0.0–1.0) |
| **Seeking** | Decoder-first flush + skip-to-target — no stale frames, no fast-forward |
| **Streaming** | HTTP Range requests with double-buffered prefetch |
| **Live** | Chunked streaming via URLSession delegate (no Content-Length required) |
| **Resilience** | Automatic retry with exponential backoff on network errors |
| **Lifecycle** | Background pause, memory warning handling (iOS/tvOS) |

---

## Quick Start

### Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/SteelPlayer", branch: "main")
]
```

### Use

```swift
import SteelPlayer

let player = try SteelPlayer()

// Embed in your view hierarchy
myView.layer.addSublayer(player.videoLayer)

// Load and play
try await player.load(url: videoURL)
try await player.load(url: videoURL, startPosition: 347.5) // resume

// Controls
player.play()
player.pause()
player.togglePlayPause()
await player.seek(to: 120.0)
player.stop()

// Volume and speed
player.volume = 0.5
player.setRate(1.5)

// Audio tracks
player.selectAudioTrack(index: trackID)

// Observe (Combine @Published)
player.$state         // .idle, .loading, .playing, .paused, .seeking, .error
player.$currentTime   // Double (seconds)
player.$duration      // Double (seconds)
player.$progress      // Float (0.0–1.0)
player.$videoFormat   // .sdr, .hdr10, .dolbyVision, .hlg

// Track info
player.audioTracks    // [TrackInfo] — id, name, codec, language, channels
player.subtitleTracks // [TrackInfo]
```

---

## Architecture

```
Sources/SteelPlayer/
├── SteelPlayer.swift              Public API + demux→decode orchestration
├── PlayerState.swift              PlaybackState, VideoFormat, TrackInfo
├── Demuxer/
│   ├── Demuxer.swift              FFmpeg AVFormatContext wrapper
│   └── AVIOReader.swift           HTTP streaming via URLSession
├── Decoder/
│   ├── VideoDecoder.swift         VideoToolbox HW decode + HDR/DV handling
│   └── SoftwareVideoDecoder.swift FFmpeg SW decode + pixel buffer pool
├── Renderer/
│   └── SampleBufferRenderer.swift AVSampleBufferDisplayLayer + B-frame reorder
└── Audio/
    ├── AudioDecoder.swift         FFmpeg decode + libswresample → multichannel PCM
    └── AudioOutput.swift          AVSampleBufferAudioRenderer + spatial audio
```

### Pipeline

```
URL
 │
 ▼
AVIO (URLSession — Range requests or chunked streaming)
 │
 ▼
FFmpeg Demuxer → AVPackets
 │                    │
 ▼                    ▼
Video                Audio
 │                    │
 ▼                    ▼
VideoToolbox HW      FFmpeg SW Decode
  or FFmpeg SW       + libswresample
 │                    │
 ▼                    ▼
CVPixelBuffer        CMSampleBuffer
(8-bit or 10-bit     (multichannel
 + color metadata)    Float32 PCM)
 │                    │
 ▼                    ▼
Reorder Buffer       AVSampleBuffer
(4 frames)           AudioRenderer
 │                    │
 ▼                    ▼
AVSampleBuffer  ─────────────────────┐
DisplayLayer                         │
 │                                   │
 └── AVSampleBufferRenderSynchronizer (master clock) ──┘
```

---

## HDR & Dolby Vision

SteelPlayer automatically detects HDR content and configures the decode pipeline accordingly:

| Content | Pixel Format | Color Tags | DV Metadata |
|---|---|---|---|
| H.264 (SDR) | 8-bit NV12 | — | — |
| HEVC Main (SDR) | 8-bit NV12 | — | — |
| HEVC Main10 (HDR10) | 10-bit P010 | BT.2020 + PQ | — |
| HEVC Main10 (DV Profile 8) on DV display | 10-bit P010 | BT.2020 + PQ | Propagated |
| HEVC Main10 (DV Profile 8) on HDR10 display | 10-bit P010 | BT.2020 + PQ | Stripped |
| AV1 (HDR) | 10-bit P010 | BT.2020 + PQ | — |

**How it works:**

- Bit depth is detected from codec profile and transfer function — not just `bits_per_raw_sample` (which can be 0)
- BT.2020/PQ color metadata is explicitly attached to every HDR pixel buffer, ensuring correct display rendering even when VideoToolbox strips attachments
- DV per-frame metadata (RPU) is enabled only when `AVPlayer.availableHDRModes` confirms the display supports Dolby Vision — non-DV displays get clean HDR10 output
- `videoFormat` reports what's actually being **output** (`.hdr10` on non-DV displays), not what the content contains

**Host app responsibility:** Set `AVDisplayCriteria` on tvOS to trigger the TV's HDR mode switch before starting playback. SteelPlayer reports `videoFormat` — the host app decides when and how to switch display modes.

---

## Surround Sound & Spatial Audio

- All audio codecs decoded to **multichannel Float32 PCM** via FFmpeg + libswresample
- `AudioChannelLayout` mapping for mono, stereo, 5.1, 7.1 ensures correct speaker positions
- `AVAudioSession.setSupportsMultichannelContent(true)` for proper surround output
- `renderer.allowedAudioSpatializationFormats = .multichannel` for AirPods/HomePod spatial audio
- On **Apple TV 4K**: multichannel PCM over HDMI eARC — receiver handles surround decoding
- On **AirPods Pro/Max**: Apple spatializes multichannel content automatically
- On **HomePod**: spatial rendering for multichannel sources

### Platform Limitation: Atmos

tvOS does not expose audio bitstream passthrough to third-party apps (as of tvOS 26). All audio is decoded to PCM:

- **Works:** 5.1 and 7.1 surround with correct channel layout
- **Lost:** Dolby Atmos object metadata and height channels
- **Same constraint** applies to Infuse, Plex, Swiftfin, and all third-party players
- Architecture is ready for passthrough when Apple provides the API

---

## Dependencies

| Dependency | License | Purpose |
|---|---|---|
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL 3.0 | Minimal FFmpeg 7.1 xcframeworks |
| VideoToolbox | System | Hardware video decoding |
| AVFoundation | System | Audio/video output, synchronization, HDR detection |
| CoreMedia | System | Sample buffers + timing |

---

## Requirements

| | Minimum |
|---|---|
| iOS | 16.0 |
| tvOS | 16.0 |
| macOS | 14.0 |
| Swift | 6.0 |
| Xcode | 16.0 |

---

## License

[LGPL 3.0](LICENSE) — App Store compatible when dynamically linked.
