# How it compares

On Apple platforms the choice is usually between two kinds of player:

- **AVPlayer:** deep OS integration, but only the formats Apple ships.
- **A VLC- or mpv-based engine:** plays almost anything, but renders its own frames and bypasses the system's Dolby Vision, Atmos and HDR handling.

AetherEngine aims for both: FFmpeg's format coverage on top of VideoToolbox and AVPlayer, so Dolby Vision, Atmos and Match Content keep working. It uses the platform where the platform is best (hardware decode, Dolby Vision display, Atmos passthrough) and falls back to its own software path (dav1d, libavcodec) only for formats VideoToolbox cannot handle.

**KSPlayer** is the closest alternative. It reaches the same result through the same AVPlayer route, but it ships as a full player with its own UI. Its free build is GPL; a paid LGPL tier unlocks AV1 hardware decoding, the full demuxer and decoder set, and a list of playback features its own feature matrix names. AetherEngine is an engine you embed and drive from your own SwiftUI, with that codec and HDR coverage in the open-source core.

## Feature comparison

| | AetherEngine | KSPlayer | AVPlayer | VLCKit | libmpv |
| --- | --- | --- | --- | --- | --- |
| **Approach** | Embeddable engine, Apple-only | Full player with bundled UI, FFmpeg + AVPlayer, Apple-only | Apple's built-in player | libVLC wrapped for Apple | libmpv, cross-platform |
| **Container & codec breadth** | Wide, FFmpeg demux | Wide, FFmpeg demux | Narrow, Apple's set | Wide | Wide |
| **Hardware decode** | VideoToolbox, dav1d SW fallback | VideoToolbox, FFmpeg SW fallback | VideoToolbox | VideoToolbox plus software | VideoToolbox plus software |
| **Dolby Vision** | P5, P7 as 8.1 (or opt-in FEL dual-layer), P8.1, P8.4, AV1 P10.x, real display switch | P5, P8 via AVPlayer; their matrix lists P5 HDR display without overheating as paid LGPL | P5 and P8.1 only | Tone-maps, no DV display | Tone-maps, no DV display |
| **Dolby Atmos** | EAC3+JOC stream-copied (HDMI MAT, spatial) | EAC3+JOC via AVPlayer | EAC3+JOC passthrough | Decodes to PCM, no object passthrough | No Atmos passthrough on Apple |
| **TrueHD / DTS:X heights** | Speaker bed up to 9.1.6 built from the stream's lossless 7.1, steered by its objects or heights, delivered as lossless 24-bit PCM, APAC on AirPlay (optional components) | 7.1 core (FFmpeg decode) | Not played | 7.1 core | 7.1 core |
| **HDR on tvOS** | Native Match Content switch | Native Match Content on AVPlayer path, else Metal tone-map | Native Match Content | Software tone-mapping | Software tone-mapping |
| **Rendering & UI** | OS-native, you ship SwiftUI | Own Metal renderer, bundled controls | OS-native, you ship UI | Own renderer, bundled controls | Own renderer, bundled OSC |
| **Apple TV / App Store** | Yes, LGPL plus store exception | Free build GPL, paid LGPL tier for AV1 hardware decode and the full decoder set | Yes | Yes, LGPL | Not practical, GPL, no tvOS |

## Measured

The table above is qualitative. The numbers below are measured on 4K HDR HEVC in Matroska, the container media servers actually serve, at 38 Mbit/s and at 90 Mbit/s (the rate of a UHD remux).

How it was measured:

- Every engine plays each file twice: from local disk, and over HTTP from a local range origin with a fixed latency and a shared link rate. Media servers deliver over HTTP, and an engine's network reader is not its file reader.
- The numbers come from [aetherengine-bench](https://github.com/superuser404notfound/aetherengine-bench). This project's author runs it, so its method, its raw data and the cases where AetherEngine does not win are all in that repository.
- AVPlayer does not open Matroska at all. On MP4, the one container it plays, it uses less than every engine here; see that repository's README.

Measured on Apple-M1 (MacBookAir10,1), macOS 27.0, hevc-4k-hdr10.mkv (38 Mbit/s), hevc-4k-hdr10-90m.mkv (90 Mbit/s), each from local disk and over HTTP from a local range origin at 1000 Mbit/s shared, 20 ms latency per request, windowed, 3840x2160 px rendered, 60 s, median of 2.
MacBookAir10,1 is fanless: sustained decode can reach thermal pressure, which is why the protocol has cooldowns between runs and discards throttled windows.

**hevc-4k-hdr10.mkv (38 Mbit/s)**

| | Source | GPU power | CPU load | RSS | Peak footprint | Plays |
| --- | --- | --- | --- | --- | --- | --- |
| **AetherEngine** | disk | 41 mW | 4.4% of a core | 342 MB | 323 MB | Yes |
| | HTTP | 40 mW | 5.4% of a core | 336 MB | 350 MB | Yes |
| **KSPlayer** | disk | 43 mW | 5.8% of a core | 333 MB | 772 MB | Yes |
| | HTTP | 41 mW | 6.4% of a core | 357 MB | 496 MB | Yes |
| **AVPlayer** | disk | | | | | n/a (refuses hevc-4k-hdr10.mkv: This media format is not supported.) |
| | HTTP | | | | | n/a (refuses hevc-4k-hdr10.mkv: This media format is not supported.) |
| **VLCKit** | disk | 266 mW | 15.0% of a core | 111 MB | 281 MB | Yes |
| | HTTP | 244 mW | 17.0% of a core | 122 MB | 300 MB | Yes |
| **libmpv** | disk | 887 mW | 20.7% of a core | 475 MB | 933 MB | Yes |
| | HTTP | 892 mW | 21.5% of a core | 629 MB | 1191 MB | Yes |

Launch failures on hevc-4k-hdr10.mkv (crashes that were retried, not refusals, see the aetherengine-bench README): KSPlayer 1 (HTTP).

**hevc-4k-hdr10-90m.mkv (90 Mbit/s)**

| | Source | GPU power | CPU load | RSS | Peak footprint | Plays |
| --- | --- | --- | --- | --- | --- | --- |
| **AetherEngine** | disk | 40 mW | 6.6% of a core | 577 MB | 681 MB | Yes |
| | HTTP | 40 mW | 9.3% of a core | 557 MB | 700 MB | Yes |
| **KSPlayer** | disk | 41 mW | 6.7% of a core | 589 MB | 1040 MB | Yes |
| | HTTP | 41 mW | 7.6% of a core | 578 MB | 703 MB | Yes |
| **AVPlayer** | disk | | | | | n/a (refuses hevc-4k-hdr10-90m.mkv: This media format is not supported.) |
| | HTTP | | | | | n/a (refuses hevc-4k-hdr10-90m.mkv: This media format is not supported.) |
| **VLCKit** | disk | 235 mW | 16.2% of a core | 117 MB | 314 MB | Yes |
| | HTTP | 235 mW | 18.4% of a core | 135 MB | 325 MB | Yes |
| **libmpv** | disk | 953 mW | 21.5% of a core | 501 MB | 980 MB | Yes |
| | HTTP | 962 mW | 22.3% of a core | 684 MB | 1188 MB | Yes |

Launch failures on hevc-4k-hdr10-90m.mkv (crashes that were retried, not refusals, see the aetherengine-bench README): KSPlayer 4 (disk).

Frame delivery and output (median; resolution, bit depth and HDR transfer are informational per engine only, shown as 'varies across repeats' when they disagree, see the aetherengine-bench README):
*hevc-4k-hdr10.mkv*
- **AetherEngine, disk**: 1438/1438 delivered/expected, dropped 0, 3840x1714, 10-bit, hdr10, rendered into 3840x2160.
- **AetherEngine, HTTP**: 1441/1438 delivered/expected, dropped 0, 3840x1714, 10-bit, hdr10, rendered into 3840x2160.
- **KSPlayer, disk**: 1440/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, SMPTE_ST_2084_PQ, rendered into 3840x2160. Served via **KSMEPlayer**.
- **KSPlayer, HTTP**: 1440/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, SMPTE_ST_2084_PQ, rendered into 3840x2160. Served via **KSMEPlayer**.
- **VLCKit, disk**: 1451/1440 delivered/expected, dropped 0, 3840x1714, bit depth and color transfer not reported by this engine, rendered into 3840x2160.
- **VLCKit, HTTP**: 1454/1440 delivered/expected, dropped 0, 3840x1714, bit depth and color transfer not reported by this engine, rendered into 3840x2160.
- **libmpv, disk**: 1443/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, pq, rendered into 3840x2160.
- **libmpv, HTTP**: 1443/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, pq, rendered into 3840x2160.
*hevc-4k-hdr10-90m.mkv*
- **AetherEngine, disk**: 1436/1438 delivered/expected, dropped 0, 3840x1714, 10-bit, hdr10, rendered into 3840x2160.
- **AetherEngine, HTTP**: 1439/1438 delivered/expected, dropped 0, 3840x1714, 10-bit, hdr10, rendered into 3840x2160.
- **KSPlayer, disk**: 1440/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, SMPTE_ST_2084_PQ, rendered into 3840x2160. Served via **KSMEPlayer**.
- **KSPlayer, HTTP**: 1440/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, SMPTE_ST_2084_PQ, rendered into 3840x2160. Served via **KSMEPlayer**.
- **VLCKit, disk**: 1454/1440 delivered/expected, dropped 0, 3840x1714, bit depth and color transfer not reported by this engine, rendered into 3840x2160.
- **VLCKit, HTTP**: 1452/1440 delivered/expected, dropped 0, 3840x1714, bit depth and color transfer not reported by this engine, rendered into 3840x2160.
- **libmpv, disk**: 1442/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, pq, rendered into 3840x2160.
- **libmpv, HTTP**: 1443/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, pq, rendered into 3840x2160.

Versions: AetherEngine 7.15.2, KSPlayer 2.3.4, AVPlayer macOS 27.0, VLCKit 4.0.0-alpha.21, libmpv mpv v0.41.0.

Power figures are package power with an idle baseline subtracted, so they are attributable to the run and not to the machine.
CPU package power was measured for every run but is not published above: the idle baseline drifts with load enough that one engine's own repeats can disagree more than the column would be used to show between engines. For example, on hevc-4k-hdr10.mkv KSPlayer measured 76 to 267 mW of CPU package power across its own repeats, a 3.5x range. Recorded for every run in Results/; see "Known gaps" in the aetherengine-bench README for the full reasoning.
libmpv is measured with --hwdec=auto-safe (hardware decode), not mpv's own software-decode default, see "Fairness decisions" in the aetherengine-bench README.
Peak footprint is the kernel's lifetime maximum of the player process's physical footprint (what the system's memory limit acts on), load phase included; RSS is the mean over the measured window. Decoding that happens in a system service (VideoToolbox) is in neither.
The hevc-4k-hdr10-90m.mkv rows come from a second run of the same protocol, build and origin on the same day and machine. A tvOS Simulator had been left running in the background for the first half of the main run, which raised idle package power to 188 to 214 mW (19 to 26 mW once it was shut down). Both hevc-4k-hdr10-90m.mkv baselines failed validation under it, so that fixture was measured again. The hevc-4k-hdr10.mkv baselines were taken under it too and passed; the GPU idle baseline stayed under 0.05 mW throughout, and CPU load, RSS and footprint are not baseline-subtracted, so none of the published columns moved with it.
Method and raw results: https://github.com/superuser404notfound/aetherengine-bench
