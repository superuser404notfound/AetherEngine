# SteelPlayer

Open-source FFmpeg + VideoToolbox video player engine for Apple platforms.

[![License: LGPL v3](https://img.shields.io/badge/License-LGPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B%20%7C%20tvOS%2016%2B%20%7C%20macOS%2014%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange)]()

A cross-platform media player library that handles demuxing, hardware-accelerated decoding, and frame-perfect video output. No UIKit/AppKit dependency -- your app provides the UI, SteelPlayer provides the engine.

## Features

- **FFmpeg demuxing** -- MKV, MP4, AVI, MPEG-TS, WebM, OGG, FLV
- **VideoToolbox hardware decoding** -- H.264, HEVC (including Main10 for HDR)
- **FFmpeg software decoding** -- fallback for codecs without HW support
- **AVSampleBufferDisplayLayer** -- Apple-native frame pacing with cadence correction
- **Audio decoding** -- AC3, EAC3, AAC, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, ALAC, PCM
- **A/V synchronization** -- AVSampleBufferRenderSynchronizer handles both audio and video
- **HTTP streaming** -- custom AVIO context with async double-buffered URLSession
- **Seeking** -- flush + demuxer seek + decoder restart

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/SteelPlayer", branch: "main")
]
```

## Usage

```swift
import SteelPlayer

let player = try SteelPlayer()

// Add the video layer to your view hierarchy
myView.layer.addSublayer(player.videoLayer)

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
│   ├── Demuxer.swift              FFmpeg AVFormatContext wrapper
│   └── AVIOReader.swift           HTTP streaming via URLSession (double-buffered)
├── Decoder/
│   ├── VideoDecoder.swift         VideoToolbox HW decode (H.264/HEVC)
│   └── SoftwareVideoDecoder.swift FFmpeg SW decode fallback
├── Renderer/
│   └── SampleBufferRenderer.swift AVSampleBufferDisplayLayer + B-frame reorder
├── Audio/
│   ├── AudioDecoder.swift         FFmpeg SW decode + libswresample
│   └── AudioOutput.swift          AVSampleBufferAudioRenderer + Synchronizer
├── SteelPlayer.swift              Public API + demux→decode orchestration
└── PlayerState.swift              PlaybackState enum + TrackInfo struct
```

### Pipeline

```
URL → AVIO (URLSession, async double-buffer)
  → FFmpeg Demuxer → AVPackets
    ├─ Video → VideoToolbox HW Decode → CVPixelBuffer
    │        → Reorder Buffer (B-frames) → AVSampleBufferDisplayLayer
    └─ Audio → FFmpeg SW Decode + libswresample → Float32 PCM
             → CMSampleBuffer → AVSampleBufferAudioRenderer
    └─ Both synced via AVSampleBufferRenderSynchronizer (master clock)
```

## Dependencies

- **[FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild)** (LGPL 3.0) -- minimal FFmpeg 7.1 xcframeworks (avcodec, avformat, avutil, swresample)
- **VideoToolbox** -- hardware video decode (system)
- **AVFoundation** -- audio/video output (system)

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 16.0+          |
| tvOS     | 16.0+          |
| macOS    | 14.0+          |
| Swift    | 6.0+           |

## License

[LGPL 3.0](LICENSE) -- App Store compatible when dynamically linked.
