# 🎬 SteelPlayer

Open-source FFmpeg + Metal video player engine for Apple platforms.

[![License: LGPL v3](https://img.shields.io/badge/License-LGPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B%20%7C%20tvOS%2016%2B%20%7C%20macOS%2014%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)]()

A cross-platform media player library that handles demuxing, hardware-accelerated decoding, and Metal rendering. No UIKit/AppKit dependency — your app provides the UI, SteelPlayer provides the engine.

## Why SteelPlayer?

Apple's AVPlayer cannot reliably play HDR/Dolby Vision content on SDR displays — it hangs on HEVC Main10 HLS streams when Match Dynamic Range is off. Every commercial player that solves this (Infuse, JellyTV, VLC) uses a custom FFmpeg-based engine. **SteelPlayer is the open-source version of that engine.**

## Features

### Working Now (Phase 1 + 2)
- **FFmpeg demuxing** — opens any container (MKV, MP4, AVI, TS, WebM, ...)
- **VideoToolbox hardware decoding** — H.264 and HEVC (including Main10 for HDR)
- **Metal rendering** — direct-to-CAMetalLayer with zero-copy CVMetalTextureCache pipeline
- **Triple-buffered** render loop via CADisplayLink with in-flight semaphore
- **Aspect-fit viewport** — letterbox/pillarbox handled automatically
- **Thread-safe frame queue** — decoder pushes from VT callback thread, renderer pulls on display link
- **Audio decoding** — FFmpeg software decode with libswresample → interleaved Float32 PCM
- **Audio output** — AVSampleBufferAudioRenderer for low-latency playback
- **A/V synchronization** — AVSampleBufferRenderSynchronizer as master clock, PTS-based frame drop/wait in the render loop (±40ms tolerance)
- **Basic seeking** — flush + demuxer seek + decoder restart

### Coming Soon
- **Seeking** — keyframe-accurate with precise buffer management (Phase 3)
- **HDR tone mapping** — BT.2390-3 in Metal fragment shader for HDR10/HLG/DV→SDR (Phase 4)
- **Dolby Vision** — base layer decode with client-side tone mapping (Phase 4)
- **Subtitles** — SRT, SSA/ASS text + PGS bitmap (Phase 6)
- **Dolby Atmos** — passthrough via AVSampleBufferAudioRenderer (Phase 2)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/SteelPlayer", branch: "main")
]
```

Or in Xcode: File → Add Package Dependencies → paste the URL above.

## Usage

```swift
import SteelPlayer

let player = SteelPlayer()

// Add the Metal layer to your view hierarchy
myView.layer.addSublayer(player.metalLayer)

// Load and play
try await player.load(url: videoURL)

// Controls
player.pause()
player.play()
player.togglePlayPause()
await player.seek(to: 120.0)  // seek to 2:00
player.stop()

// Observe state
player.$state.sink { state in print("State: \(state)") }
player.$currentTime.sink { time in print("Time: \(time)") }
player.$progress.sink { progress in print("Progress: \(progress)") }
```

## Architecture

```
SteelPlayer
├── Demuxer/
│   └── Demuxer.swift           FFmpeg AVFormatContext wrapper
├── Decoder/
│   └── VideoDecoder.swift      VideoToolbox HW decode (H.264/HEVC → CVPixelBuffer)
├── Renderer/
│   ├── MetalRenderer.swift     CAMetalLayer + zero-copy texture pipeline
│   └── Shaders.metal           Fullscreen triangle + passthrough fragment
├── Audio/
│   ├── AudioDecoder.swift      FFmpeg SW decode → interleaved Float32 PCM
│   └── AudioOutput.swift       AVSampleBufferAudioRenderer + RenderSynchronizer
├── Sync/
│   └── FrameQueue.swift        Thread-safe decoded frame buffer
├── Subtitles/
│   └── (Phase 6)               SRT/SSA/PGS rendering
├── SteelPlayer.swift           Public API + demux→decode→render orchestration
└── PlayerState.swift           PlaybackState enum + TrackInfo struct
```

### Pipeline

```
URL → FFmpeg demuxer → AVPackets
    ├── video → VideoToolbox HW decoder → CVPixelBuffer → FrameQueue
    │          → CADisplayLink (synced to audio clock) → Metal renderer → Screen
    └── audio → FFmpeg SW decoder → libswresample → Float32 PCM
               → CMSampleBuffer → AVSampleBufferAudioRenderer → Speakers
                                  ↕
                    AVSampleBufferRenderSynchronizer (master clock)
```

## Roadmap

- [x] **Phase 0** — Package skeleton, public API, FFmpeg dependency
- [x] **Phase 1** — Demuxer + VideoToolbox decoder + Metal renderer + playback loop
- [x] **Phase 2** — Audio output + A/V synchronization
- [ ] **Phase 3** — Keyframe-accurate seeking + scrubbing
- [ ] **Phase 4** — HDR10/DV tone mapping (BT.2390-3 Metal shader)
- [ ] **Phase 5** — Edge cases, stability, error handling
- [ ] **Phase 6** — Subtitle support (SRT, SSA/ASS, PGS)
- [ ] **Phase 7** — App Store readiness + documentation

## Dependencies

- **[FFmpegKit](https://github.com/kingslay/FFmpegKit)** (LGPL 3.0) — prebuilt FFmpeg 6.1.x xcframeworks for iOS/tvOS/macOS
- **Metal** — Apple's GPU framework (system)
- **VideoToolbox** — Apple's hardware video decode (system)
- **AVFoundation** — Audio output (system)

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 16.0           |
| tvOS     | 16.0           |
| macOS    | 14.0           |
| Swift    | 5.9            |

## License

[LGPL 3.0](LICENSE) — App Store compatible when dynamically linked.

## Contributing

Contributions welcome! This project was born out of the need for a reliable open-source video player for Apple TV that handles HDR content properly. If you've hit the same wall with AVPlayer, you know why this exists.
