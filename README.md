# SteelPlayer

Open-source FFmpeg + Metal video player engine for Apple platforms.

## Features

- **FFmpeg demuxing** — plays any container (MKV, MP4, AVI, TS, WebM, ...)
- **Hardware-accelerated decoding** — VideoToolbox for H.264, HEVC (incl. Main10), VP9
- **Metal rendering** — direct-to-CAMetalLayer, zero-copy texture pipeline
- **HDR support** — HDR10, HDR10+, HLG, Dolby Vision with BT.2390 tone mapping to SDR
- **Audio** — AVSampleBufferAudioRenderer with multichannel + Atmos passthrough
- **Subtitles** — SRT, SSA/ASS, PGS bitmap
- **Cross-platform** — iOS 16+, tvOS 16+, macOS 13+

## Why SteelPlayer?

Apple's AVPlayer cannot play HDR content on SDR displays — it hangs indefinitely on HEVC Main10 HLS streams when Match Dynamic Range is off. Every other player that solves this (Infuse, JellyTV, VLC) uses a custom FFmpeg-based engine. SteelPlayer is the open-source version of that engine.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/SteelPlayer", from: "0.1.0")
]
```

## Usage

```swift
import SteelPlayer

let player = SteelPlayer()

// Add the Metal layer to your view
myView.layer.addSublayer(player.metalLayer)

// Load and play
try await player.load(url: videoURL)
player.play()

// Observe state
player.$state.sink { state in
    print("State: \(state)")
}
```

## Architecture

```
SteelPlayer
├── Demuxer      — FFmpeg AVFormatContext wrapper
├── Decoder      — VideoToolbox HW + FFmpeg SW fallback  
├── Renderer     — CAMetalLayer + Metal shaders (HDR tone mapping)
├── Audio        — AVSampleBufferAudioRenderer
├── Sync         — PTS-based A/V synchronization
└── Subtitles    — Text + bitmap subtitle rendering
```

## Roadmap

- [x] Package skeleton + public API
- [ ] Phase 1: Demuxer + VideoToolbox decoder + Metal renderer (first frame)
- [ ] Phase 2: Audio output + A/V sync
- [ ] Phase 3: Seeking + scrubbing
- [ ] Phase 4: HDR10/DV tone mapping
- [ ] Phase 5: Edge cases + stability
- [ ] Phase 6: Subtitle support
- [ ] Phase 7: App Store readiness

## License

LGPL 3.0 — App Store compatible when dynamically linked.
