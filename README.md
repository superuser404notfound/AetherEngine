<p align="center">
  <img src="https://img.shields.io/badge/License-LGPL%20v3-blue.svg" alt="License: LGPL v3">
  <img src="https://img.shields.io/badge/iOS-16%2B-000000?logo=apple" alt="iOS 16+">
  <img src="https://img.shields.io/badge/tvOS-16%2B-000000?logo=apple" alt="tvOS 16+">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.0+">
</p>

# AetherEngine

A video player engine for Apple platforms. FFmpeg demuxes, VideoToolbox decodes, AVPlayer handles Dolby Atmos, and Apple's synchronizer ties it all together. **Your app provides the UI — AetherEngine provides the engine.**

---

## Why AetherEngine?

Most video player libraries try to do everything — UI, controls, playlists, analytics. AetherEngine does one thing well: **decode and render video with perfect A/V sync, including Dolby Atmos.** You get a `CALayer` and a simple API. The rest is yours.

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
| **SW decode** | AV1, VP9 — FFmpeg fallback with SIMD-optimized pixel buffer pooling |
| **HDR10** | 10-bit P010 output, BT.2020/PQ color metadata on every frame |
| **Dolby Vision** | Profile 5, 8.1, 8.4 on DV-capable displays; HDR10 fallback on others |
| **HLG** | Hybrid Log-Gamma detection and correct transfer function tagging |
| **B-frames** | 4-frame reorder buffer for correct presentation order |

### Audio

| | |
|---|---|
| **Codecs** | AAC, AC3, EAC3, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, ALAC, PCM |
| **Dolby Atmos** | EAC3+JOC passthrough via AVPlayer + local HLS (MAT 2.0 wrapping) |
| **Surround** | 5.1 and 7.1 multichannel output with correct `AudioChannelLayout` mapping |
| **AC3 passthrough** | Direct compressed audio feed — no decode overhead |
| **Spatial Audio** | AirPods Pro/Max and HomePod spatialization (automatic) |
| **HDMI** | Multichannel PCM over HDMI eARC — receiver handles surround |
| **Tracks** | Runtime audio track switching with seamless A/V sync |

### Dolby Atmos Architecture

For Dolby Atmos (EAC3+JOC), AetherEngine uses a three-thread architecture that decouples audio from video back-pressure. Non-Atmos codecs use the simpler single-thread demux with inline decode.

```
Demux Thread ──┬── Audio Packets ──► HLS Audio Engine (AVPlayer)
               │                     ├── FMP4 Muxer (EAC3 → fMP4 + dec3/JOC)
               │                     ├── Local HTTP Server (HLS playlist)
               │                     └── AVPlayer (Dolby MAT 2.0 passthrough)
               │
               └── Video Packets ──► Video Decode Queue
                                     ├── VideoToolbox or FFmpeg
                                     └── AVSampleBufferDisplayLayer
                                          (controlTimebase synced to AVPlayer)
```

- **Auto-calibrated A/V sync** — measures the natural clock drift between CMTimebase and AVPlayer, then corrects deviations >50ms automatically
- **Seek-safe** — filters pre-keyframe audio packets and corrects streamOffset to the actual first audio PTS
- **Fallback** — if AVPlayer fails, falls back to FFmpeg PCM decode

### Playback

| | |
|---|---|
| **A/V Sync** | `AVSampleBufferRenderSynchronizer` for PCM, auto-calibrated `CMTimebase` for Atmos |
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
    .package(url: "https://github.com/superuser404notfound/AetherEngine", branch: "main")
]
```

### Use

```swift
import AetherEngine

let player = try AetherEngine()

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
Sources/AetherEngine/
├── AetherEngine.swift             Public API + demux→decode orchestration
├── PlayerState.swift              PlaybackState, VideoFormat, TrackInfo
├── Demuxer/
│   ├── Demuxer.swift              FFmpeg AVFormatContext wrapper
│   └── AVIOReader.swift           HTTP streaming via URLSession
├── Decoder/
│   ├── VideoDecoder.swift         VideoToolbox HW decode + HDR/DV handling
│   └── SoftwareVideoDecoder.swift FFmpeg SW decode + sws_scale pixel buffer pool
├── Renderer/
│   └── SampleBufferRenderer.swift AVSampleBufferDisplayLayer + B-frame reorder
└── Audio/
    ├── AudioDecoder.swift         FFmpeg decode + libswresample → multichannel PCM
    ├── AudioOutput.swift          AVSampleBufferAudioRenderer + spatial audio
    ├── HLSAudioEngine.swift       AVPlayer + CMTimebase sync for Dolby Atmos
    ├── HLSAudioServer.swift       Local HTTP server for HLS segments
    └── FMP4AudioMuxer.swift       EAC3 → fMP4 with dec3/JOC Atmos metadata
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
 ├─ VT HW Decode     ├─ EAC3+JOC → fMP4 Muxer → HLS → AVPlayer (Atmos)
 ├─ FFmpeg SW         └─ All other → FFmpeg PCM → AudioRenderer
 │
 ▼                    │
CVPixelBuffer        ▼
 │               CMSampleBuffer
 ▼                    │
Reorder Buffer       ▼
 │               AudioRenderer
 ▼                    │
DisplayLayer ─── Synchronizer / CMTimebase ──┘
```

---

## HDR & Dolby Vision

AetherEngine automatically detects HDR content and configures the decode pipeline:

| Content | Pixel Format | Color Tags | DV Metadata |
|---|---|---|---|
| H.264 (SDR) | 8-bit NV12 | — | — |
| HEVC Main10 (HDR10) | 10-bit P010 | BT.2020 + PQ | — |
| HEVC Main10 (DV Profile 8) on DV display | 10-bit P010 | BT.2020 + PQ | Propagated |
| HEVC Main10 (DV Profile 8) on HDR10 display | 10-bit P010 | BT.2020 + PQ | Stripped |
| AV1 (HDR) | 10-bit P010 | BT.2020 + PQ | — |

**Host app responsibility:** Set `AVDisplayCriteria` on tvOS to trigger the TV's HDR mode switch before starting playback. AetherEngine reports `videoFormat` — the host app decides when and how to switch display modes.

---

## Audio Routing

| Codec | Engine | Output |
|---|---|---|
| **EAC3+JOC** (Atmos, profile=30) | HLS AVPlayer + fMP4 Muxer | Dolby Atmos passthrough (MAT 2.0) |
| **EAC3** (5.1) | FFmpeg + libswresample | Multichannel Float32 PCM |
| **AC3** | FFmpeg + libswresample | Multichannel Float32 PCM |
| **AAC, FLAC, Opus, etc.** | FFmpeg + libswresample | Multichannel Float32 PCM |

Atmos detection uses `codecpar.profile == 30` (`FF_PROFILE_EAC3_DDP_ATMOS`), set by FFmpeg's EAC3 parser when JOC is detected — no server metadata needed. Non-Atmos EAC3 is decoded by FFmpeg to preserve full dynamics (Apple's internal decoder applies dialnorm/DRC attenuation).

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
