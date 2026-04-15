<p align="center">
  <img src="https://img.shields.io/badge/License-LGPL%20v3-blue.svg" alt="License: LGPL v3">
  <img src="https://img.shields.io/badge/iOS-16%2B-000000?logo=apple" alt="iOS 16+">
  <img src="https://img.shields.io/badge/tvOS-16%2B-000000?logo=apple" alt="tvOS 16+">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.0+">
</p>

# SteelPlayer

A lightweight video player engine for Apple platforms. FFmpeg handles the containers, VideoToolbox handles the decoding, Apple's synchronizer handles the timing. **Your app provides the UI — SteelPlayer provides the engine.**

> **2,500 lines of Swift.** No bloat, no abstractions for abstractions. Just a clean pipeline from URL to pixels.

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
| **Video (HW)** | H.264, HEVC, HEVC Main10 — via VideoToolbox |
| **Video (SW)** | AV1, VP9, and anything FFmpeg supports — automatic fallback |
| **HDR10** | 10-bit P010 output with BT.2020/PQ color metadata |
| **Dolby Vision** | Profile 5, 8.1, 8.4 — automatic metadata propagation via VideoToolbox |
| **HLG** | Hybrid Log-Gamma support with correct transfer function |
| **B-frames** | 4-frame reorder buffer for correct presentation order |

### Audio

| | |
|---|---|
| **Codecs** | AAC, AC3, EAC3, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, ALAC, PCM |
| **Surround** | 5.1 and 7.1 multichannel output with proper channel layout mapping |
| **Spatial Audio** | AirPods Pro/Max and HomePod spatialization (automatic) |
| **HDMI eARC** | Apple TV outputs multichannel PCM as Dolby MAT 2.0 to receivers |
| **Audio tracks** | Runtime audio track switching |

### Playback

| | |
|---|---|
| **A/V Sync** | `AVSampleBufferRenderSynchronizer` as master clock |
| **Speed control** | 0.5x to 2.0x playback speed |
| **Volume** | Programmable volume control |
| **Seeking** | Flush + demuxer seek + skip-to-target (no visual fast-forward) |
| **Streaming** | HTTP Range requests with double-buffered prefetch |
| **Live streams** | Chunked streaming via URLSession delegate |
| **Error recovery** | Automatic retry with exponential backoff on network errors |
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

// Create the player
let player = try SteelPlayer()

// Add the video layer to your view
myView.layer.addSublayer(player.videoLayer)

// Load and play
try await player.load(url: videoURL)

// Controls
player.play()
player.pause()
player.togglePlayPause()
await player.seek(to: 120.0)   // jump to 2:00
player.stop()

// Resume from a saved position
try await player.load(url: videoURL, startPosition: 347.5)

// Volume and speed
player.volume = 0.5            // 0.0 = mute, 1.0 = full
player.setRate(1.5)            // 0.5x to 2.0x

// Switch audio tracks
player.selectAudioTrack(index: trackID)

// Observe state changes (Combine)
player.$state.sink { state in ... }         // .idle, .loading, .playing, .paused, .seeking, .error
player.$currentTime.sink { time in ... }    // seconds as Double
player.$duration.sink { dur in ... }        // total duration
player.$progress.sink { p in ... }          // 0.0 ... 1.0
player.$videoFormat.sink { fmt in ... }     // .sdr, .hdr10, .dolbyVision, .hlg

// Track metadata
player.audioTracks      // [TrackInfo] — id, name, codec, language, channels
player.subtitleTracks   // [TrackInfo]
```

---

## Architecture

```
Sources/SteelPlayer/
├── SteelPlayer.swift              → Public API, demux→decode orchestration
├── PlayerState.swift              → PlaybackState, VideoFormat, TrackInfo
├── Demuxer/
│   ├── Demuxer.swift              → FFmpeg AVFormatContext wrapper
│   └── AVIOReader.swift           → HTTP streaming via URLSession
├── Decoder/
│   ├── VideoDecoder.swift         → VideoToolbox HW decode (H.264/HEVC/AV1)
│   └── SoftwareVideoDecoder.swift → FFmpeg SW decode fallback + color metadata
├── Renderer/
│   └── SampleBufferRenderer.swift → AVSampleBufferDisplayLayer + B-frame reorder
└── Audio/
    ├── AudioDecoder.swift         → FFmpeg decode + libswresample → multichannel PCM
    └── AudioOutput.swift          → AVSampleBufferAudioRenderer + spatial audio
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
(8-bit or 10-bit)    (multichannel PCM)
 │                    │
 ▼                    ▼
Reorder Buffer       AVSampleBuffer
(4 frames)           AudioRenderer
 │                    │
 ▼                    ▼
AVSampleBuffer       ──────────────┐
DisplayLayer                       │
 │                                 │
 └──── AVSampleBufferRenderSynchronizer (master clock) ────┘
```

---

## HDR & Dolby Vision

SteelPlayer automatically detects and handles HDR content:

- **HEVC/AV1** streams are decoded to **10-bit P010** pixel buffers
- **H.264** streams stay at **8-bit NV12** (no HDR support in H.264)
- VideoToolbox's `PropagatePerFrameHDRDisplayMetadata` (enabled by default) carries **Dolby Vision metadata** through the pipeline automatically
- **No manual RPU parsing** — DV Profile 5, 8.1, and 8.4 work out of the box
- Color space metadata (BT.2020, PQ, HLG) is attached to pixel buffers for correct display rendering

The `videoFormat` property reports the detected format: `.sdr`, `.hdr10`, `.dolbyVision`, or `.hlg`.

---

## Surround Sound & Spatial Audio

- FFmpeg decodes all audio codecs (AC3, EAC3, TrueHD, DTS, AAC, etc.) to **multichannel Float32 PCM**
- Proper `AudioChannelLayout` mapping ensures correct speaker positions (mono through 7.1)
- On **Apple TV 4K**: multichannel PCM is encoded as **Dolby MAT 2.0** over HDMI eARC — your receiver handles the rest
- On **AirPods Pro/Max**: spatial audio spatialization is enabled automatically
- On **HomePod**: multichannel content plays with full spatial rendering

---

## Dependencies

| Dependency | License | Purpose |
|---|---|---|
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL 3.0 | Minimal FFmpeg 7.1 xcframeworks |
| VideoToolbox | System | Hardware video decoding |
| AVFoundation | System | Audio/video output + synchronization |
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
