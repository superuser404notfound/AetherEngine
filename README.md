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

| | |
|---|---|
| **Containers** | MKV, MP4, AVI, MPEG-TS, WebM, OGG, FLV |
| **Video (HW)** | H.264, HEVC, HEVC Main10 — via VideoToolbox |
| **Video (SW)** | AV1, VP9, and anything FFmpeg supports — automatic fallback |
| **Audio** | AAC, AC3, EAC3, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, ALAC, PCM |
| **Streaming** | HTTP Range requests with double-buffered prefetch |
| **Live streams** | Chunked streaming via URLSession delegate (no Content-Length required) |
| **A/V Sync** | `AVSampleBufferRenderSynchronizer` as master clock |
| **B-frames** | 4-frame reorder buffer for correct presentation order |
| **Seeking** | Flush + demuxer seek + skip-to-target (no visual fast-forward) |
| **Audio tracks** | Runtime audio track switching |
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

// Switch audio tracks
player.selectAudioTrack(index: trackID)

// Observe state changes (Combine)
player.$state.sink { state in ... }       // .idle, .loading, .playing, .paused, .seeking, .error
player.$currentTime.sink { time in ... }  // seconds as Double
player.$duration.sink { dur in ... }      // total duration
player.$progress.sink { p in ... }        // 0.0 ... 1.0

// Track metadata
player.audioTracks      // [TrackInfo] — id, name, codec, language, channels
player.subtitleTracks   // [TrackInfo]
```

---

## Architecture

```
Sources/SteelPlayer/
├── SteelPlayer.swift              → Public API, demux→decode orchestration
├── PlayerState.swift              → PlaybackState enum, TrackInfo struct
├── Demuxer/
│   ├── Demuxer.swift              → FFmpeg AVFormatContext wrapper
│   └── AVIOReader.swift           → HTTP streaming via URLSession
├── Decoder/
│   ├── VideoDecoder.swift         → VideoToolbox hardware decode
│   └── SoftwareVideoDecoder.swift → FFmpeg software decode fallback
├── Renderer/
│   └── SampleBufferRenderer.swift → AVSampleBufferDisplayLayer + B-frame reorder
└── Audio/
    ├── AudioDecoder.swift         → FFmpeg decode + libswresample → Float32 PCM
    └── AudioOutput.swift          → AVSampleBufferAudioRenderer + RenderSynchronizer
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
