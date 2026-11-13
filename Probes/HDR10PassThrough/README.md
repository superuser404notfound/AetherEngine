# HDR10 pass-through check

A measurement, not a test. It answers one question for AE#957 (madVR-style video processing, step 2):
**when the engine renders a frame of its own on the software path, does the HDR10 metadata it attaches
reach the television?**

Tone mapping to a panel's real peak only pays off if it does. tvOS has no `CAEDRMetadata` and no
`wantsExtendedDynamicRangeContent`, so the only lever is the attachments on the pixel buffer handed to
`AVSampleBufferDisplayLayer`. Nobody has measured whether that layer forwards them to HDMI.

**Verdict so far: not measured.** Fill in the results table below.

## How it tells whose metadata arrived

The pattern clips carry their own HDR10 metadata. The engine probe (`AETHER_HDR10_PROBE`, see
[architecture-software.md, HDR10 pass-through probe](../../docs/architecture-software.md#hdr10-pass-through-probe))
can attach different values. The two sets share no number:

| | mastering peak | mastering min | MaxCLL | MaxFALL |
|---|---|---|---|---|
| the clip's own | 1000 nit | 0.005 nit | 1000 | 400 |
| the probe's | 777 nit | 0.005 nit | 345 | 123 |

Two ways to tell which set arrived:

- **An HDMI analyser or a signal-info screen**, where the television has one that shows the incoming
  static metadata. Many do not. LG's hidden "HDMI Signal Override" menu *sets* the metadata instead of
  showing it: do not use it for this, and do not change anything in it.
- **The picture**, with the television's dynamic tone mapping off (LG: Picture, Advanced Settings,
  Brightness, Dynamic Tone Mapping: Off; note the old value and put it back afterwards). The television
  then tone-maps by the metadata: below its peak it uses MaxCLL as the brightest value in the content.
  - The clip's metadata (MaxCLL 1000): the **777 and 1000 nit markers look different**, and the row
    of patches keeps getting brighter up to the 1000 patch.
  - The probe's metadata (MaxCLL 345): both markers are above 345, so they **look the same**, and the
    row stops getting brighter at about the 300 to 400 patch.

Compare each arm with P, Apple's own player on the same clip. A phone photo of each arm, with the
camera's exposure locked, makes the comparison easy.

## What is in here

| path | what |
| --- | --- |
| `Scripts/gen_pattern.py` | the pattern: grey patches, markers, a moving bar and a frame counter (raw yuv420p10le) |
| `Scripts/build.sh` | encodes the two clips (ffmpeg + libx265) into `out/` |
| `Scripts/run_tv.sh` | builds and installs the host on an Apple TV, serves the clips, plays a sequence |
| `Device/` | the tvOS host app (xcodegen project, committed generated project) |

The clip server is the pulse probe's (`../DolbyVisionPulse/Scripts/serve.py`), which supports HTTP
Range requests as AVFoundation requires.

## Tools

`ffmpeg` with `libx265`, Python 3 with `numpy`, and Xcode with the tvOS SDK. On macOS:
`brew install ffmpeg`, `python3 -m pip install numpy`. `xcodegen` only if the Xcode project is
regenerated.

## Build the clips

```bash
Scripts/build.sh
```

| clip | size | rate | length | GOP |
|---|---|---|---|---|
| `pattern_24.mp4` | 3840x2160 | 23.976 | 40 s | 48 |
| `pattern_60.mp4` | 3840x2160 | 59.94 | 30 s | 120 |

Both are HEVC Main10, BT.2020, PQ, with a silent stereo AAC track so every route has an audio clock.
Each encode takes a few minutes; an existing clip is kept.

## Set up

- Television: HDR10 input, the input's enhanced or deep-colour HDMI mode on (LG: HDMI Ultra HD Deep
  Colour), dynamic tone mapping off for the run (see above), a cinema or filmmaker picture mode.
- Apple TV: Settings, Video and Audio, Match Content: Match Dynamic Range and Match Frame Rate on.
  Format SDR or the highest the television takes; Match Content does the switch.
- The Mac and the Apple TV on one network, the Apple TV paired with Xcode
  (`xcrun devicectl list devices` lists it).

## Care for the television

Nothing here can harm a television. HDR10 metadata only describes the content; the television's own
firmware decides how bright the panel goes and never exceeds its limits, whatever a patch or MaxCLL says.

The one thing to mind is an OLED panel and a still picture. So the patches drift on a small circle (8
pixels, one turn every 20 s), arms are short (25 s, `SECS` to change), and the run ends on the home
screen. A full `main` sequence shows the pattern for about 3.5 minutes, the setup arm included, far
below what leaves lasting retention. A faint afterimage right after a run fades within minutes, or
with the panel's own refresh. Do not pause on the pattern or leave the app running unattended.

## Run

```bash
DEVICE="Living Room" Scripts/run_tv.sh
```

Each arm shows a 6 s slate with its label and what to expect, then plays 25 s with the label in a
corner. For each arm, note whether the 777 and 1000 markers look the same or different (and, with an
analyser or info screen, the peak, MaxCLL and MaxFALL it shows).

`SEQ=main` (the default):

| arm | mode | what plays | metadata that should arrive if it works |
|---|---|---|---|
| SETUP | `setup` | the clip on loop, 60 s, nothing measured | the TV is in HDR10: set Dynamic Tone Mapping to Off now (`SETUP=0` skips it) |
| P | `avplayer` | plain AVPlayer, Apple's own path | the clip's (the reference) |
| N | `native` | the engine, native route | the clip's |
| S | `software` | software path, probe `log`: VideoToolbox's buffer as decoded | the clip's, if VideoToolbox attaches it |
| M | `meta` | software path, the probe's values on VideoToolbox's buffer | the probe's |
| C | `chain` | software path, `FrameChain` into a buffer of our own, attachments copied | the clip's |
| CM | `chainmeta` | both: our own buffer, the probe's values | the probe's |

CM is the arm step 3 depends on: a buffer the engine rendered itself, with metadata the engine chose.

`SEQ=pace` checks frame pacing with the chain in the loop: S and C on both clips, 25 s each.
Film the moving bar and the frame counter; a stall or a jump is a dropped or repeated frame. Each arm's
summary line reports `droppedFrames`.

After the run, the script pulls the app's log and prints the `[HDR10Probe]` lines (what the first
frame carried before and after, what the format description built from it carries, GPU time per
48-frame window, `chain built` once per picture size) and each arm's summary.

## Results

| date | Apple TV | tvOS | television | P | N | S | M | C | CM | pacing 24 / 60 |
|---|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | | |

Write each cell as `differ` or `same` for the two markers, or as what an analyser showed
(`1000/1000/400`, `777/345/123`, `none` for HDR10 with no static metadata). `SDR` if the television left
HDR.

## Reading it

- **CM shows the probe's values** (markers the same, or 777/345/123): the display layer forwards per-buffer metadata. Step 3 (tone mapping
  with metadata of our own) can go ahead.
- **CM shows the clip's values** (markers differ, or 1000/1000/400): the layer forwards something, but from the stream, not from our buffer.
  Look at the `[HDR10Probe] first frame` line: if the format description built from our buffer carries
  the probe's values, the layer reads them from somewhere else.
- **CM shows none or SDR** (with no metadata an LG assumes a 4000 nit master, so the markers differ less than on P): the layer forwards nothing from our buffer. Tone mapping must then target a
  fixed, assumed panel, or stay off on tvOS.
- **S differs from P**: VideoToolbox's buffer already lacks the metadata. That is a separate finding,
  and the `[HDR10Probe] first frame` line says which key is missing.
