# HDR10 pass-through check

A measurement, not a test. It answers one question for AE#957 (madVR-style video processing, step 2):
**when the engine renders a frame of its own on the software path, does the HDR10 metadata it attaches
reach the television?**

Tone mapping to a panel's real peak only pays off if it does. tvOS has no `CAEDRMetadata` and no
`wantsExtendedDynamicRangeContent`, so the only lever is the attachments on the pixel buffer handed to
`AVSampleBufferDisplayLayer`. Nobody has measured whether that layer forwards them to HDMI.

**Verdict (2026-11-13, Apple TV 4K A12, tvOS 27.2, LG G4): yes.** The television follows HDR10 metadata
the engine attaches, on VideoToolbox's buffers and on the engine's own (the chain), mid-stream, within
about 2 s. Read from a filmed pulse, see the results below.

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
  Brightness, Dynamic Tone Mapping: Off; it shows only while HDR plays, which is what the setup arm is
  for). The television then tone-maps by the metadata it received, so the upper patches of the row look
  different with different metadata. How exactly depends on the television, so **compare arms against
  each other**, not against an expected curve:
  - **M against S**: the same decoded frames, with the probe's metadata and with none.
  - **CM against C**: the same through the frame chain.
  - P and N show the television's picture with the clip's own metadata.

  If M looks like S, and CM like C, the metadata did not change what the television does. If they
  differ, it arrived.

Take the photos with a phone from one spot (leaning on something), with the exposure locked low enough
that the 10000 patch is grey, not white (iPhone: press and hold until "AE/AF LOCK", then drag the sun
down). The eye adapts and an automatic exposure brightens each photo, so neither compares across arms.

Keep the bright part of the picture small. An OLED lowers its peak when much of the screen is bright:
a first version of this pattern, about 30% bright, held a 77 inch LG G4 below 777 nit, so every patch
above that looked the same in every arm. The pattern now has about 4% of the screen above 100 nit.

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
corner. Take one photo per arm from the same spot with the exposure locked (and, with an analyser or info
screen, note the peak, MaxCLL and MaxFALL it shows).

`SEQ=main` (the default):

| arm | mode | what plays | HDR10 metadata the engine sends |
|---|---|---|---|
| SETUP | `setup` | the clip on loop, 60 s, nothing measured | the TV is in HDR10: set Dynamic Tone Mapping to Off now (`SETUP=0` skips it) |
| P | `avplayer` | plain AVPlayer, Apple's own path | the clip's (the reference) |
| N | `native` | the engine, native route | the clip's |
| S | `software` | software path, probe `log`: VideoToolbox's buffer as decoded | the clip's, attached by the decoder (see below) |
| M | `meta` | software path, the probe's values on VideoToolbox's buffer | the probe's |
| C | `chain` | software path, `FrameChain` into a buffer of our own, attachments copied | the clip's, as S |
| CM | `chainmeta` | both: our own buffer, the probe's values | the probe's |

CM is the arm step 3 depends on: a buffer the engine rendered itself, with metadata the engine chose.

`SEQ=pulse` needs no camera, about 2 minutes:

| arm | mode | what plays | HDR10 metadata the engine sends |
|---|---|---|---|
| S | `software` | 15 s, VideoToolbox's buffer as decoded | the clip's: the steady control |
| SP | `pulse` | 30 s, the probe's values on VideoToolbox's buffer | 777 nit / MaxCLL 345, then 4000 / 4000, switching every 3 s |
| CP | `chainpulse` | 30 s, our own buffer from the chain | the same switching |

The picture never changes, only the metadata. Watch the patches from 1000 to 10000 nit and the two
squares. If the television reads the metadata, it tone-maps them brighter and dimmer every 3 s (the 345
nit set compresses them less than the 4000 nit one). If they hold still, it did not take the change: it
may ignore metadata that changes mid-stream, so a steady picture is "not shown", not "not delivered".

`SEQ=control` checks the instrument: does this television visibly follow HDR10 metadata at all? It
needs `pattern_24_m4000.mp4` (`Scripts/build.sh pattern_24_m4000`), the same pixels with 4000 nit
metadata.

| arm | mode | what plays |
|---|---|---|
| P | `avplayer` | 15 s, the 1000 nit clip through AVPlayer |
| P4 | `avplayer` | 15 s, the 4000 nit clip through AVPlayer |
| AP | `avpulse` | 48 s, AVPlayer alternating the two every 6 s |
| SP | `pulse` | 30 s, the engine's pulse, for comparison |

If P and P4 or AP differ and SP does not, the television can show the difference and the engine's
metadata does not get through. If none of them differ, this television cannot answer the question by
eye, and only an HDMI analyser can.

`SEQ=pace` checks frame pacing with the chain in the loop: S and C on both clips, 25 s each.
Film the moving bar and the frame counter; a stall or a jump is a dropped or repeated frame. Each arm's
summary line reports `droppedFrames`.

`SEQ=bench` needs no camera and nothing bright: about 1 minute.

| arm | mode | what plays |
|---|---|---|
| B | `bench` | nothing; `AetherEngine.runPerFrameBenchmarks` on this Apple TV (the cases are in [docs/cli.md](../../docs/cli.md#bench)) |
| S | `software` | 20 s of the software path, for the decoder's `output metadata over N frames` line |

The report is saved as `runs/bench_<date>.json`. With `BASELINE=runs/bench_<older>.json` the script
also runs `aetherctl bench --compare` against it and prints the verdict. In the S line, `copied` on
every frame means each 4K frame costs a full copy (about 7 ms on an A12); it should read `as decoded`.

After the run, the script pulls the app's log and prints the `[HDR10Probe]` lines (what the first
frame carried before and after, what the format description built from it carries, GPU time per
48-frame window, `chain built` once per picture size) and each arm's summary.

## Results

| date | Apple TV | tvOS | television | engine side | M vs S | CM vs C | pacing 24 / 60 |
|---|---|---|---|---|---|---|---|
| 2026-11-13 | 4K (2nd gen), A12 | 27.2 | LG OLED77G4 | M and CM carry 777 / 345 / 123 to the display layer; S and C none | not read (pattern too bright, photos auto-exposed) | not read | chain 10.5 ms mean, 13.9 ms max per 4K frame; 0 and 1 dropped frames in 25 s at 23.976 |
| 2026-11-13 | same | 27.2 | same | `SEQ=control` and `SEQ=cp`, filmed (below) | SP pulses: the TV follows metadata on VideoToolbox's buffers | CP pulses: the TV follows metadata on the engine's own buffers | SP 0, CP 1 dropped frame in 30 s |

**Read from a video, 2026-11-13.** The pulse is invisible by eye but measurable on film. An iPhone filmed
`SEQ=control` with exposure locked low (AE/AF lock, then exposure down until the top patches are grey).
The raw 10-bit HLG luma of each patch was read per frame, and the ratio of the 4000 nit patch to the
1500 nit patch tracks the TV's tone curve while staying independent of the camera's exposure:

| part | metadata | 4000 / 1500 ratio |
|---|---|---|
| P | clip, 1000 nit | 0.987 (flat top: the TV clips above about 1500) |
| P4 | clip, 4000 nit | 1.061 (a roll-off up to 4000) |
| AP | AVPlayer, 1000 / 4000 every 6 s | follows the switches, +0.054, about 2 s behind them |
| SP | engine `pulse`, 345 / 4000 every 3 s | follows the switches, +0.026, 1.75 s behind them; the same fit at other periods gives at most 0.009 |
| CP | engine `chain+pulse` (`SEQ=cp`), the same switching | follows the switches, +0.033, swinging 1.00 to 1.06; the same fit at other periods gives at most 0.018 (19 s usable, the camera's exposure lock slipped) |

So a metadata change the engine makes mid-stream, on VideoToolbox's buffers and on its own, reaches the LG G4, which
takes about 2 s to settle into a new curve. Smaller than AP, because 3 s phases leave it little time to
settle.

Write the M and CM cells as `differ` or `alike` against S and C, from the photos, or as what an analyser
showed (`777/345/123`, `none` for HDR10 with no static metadata). `SDR` if the television left HDR.

**Found on the way, and fixed:** on tvOS 27.2 (A12) VideoToolbox attaches no mastering display or content
light level to the frames it decodes from this clip, though the stream carries both in SEI messages and in
the `hvcC`. The 2026-11-13 runs above were made before the fix, so S and C sent none there (the
`[HDR10Probe] first frame` line showed `mdcv=- cll=-`). The decoder now attaches the stream's values, so S
and C send the clip's 1000 nit / 1000 / 400.

## Reading it

- **CM differs from C** (or an analyser shows 777/345/123 on CM): the display layer forwards the metadata
  on the engine's own buffer to the television. Step 3 (tone mapping with metadata of our own) can go
  ahead, and the software path can send the stream's metadata the same way.
- **CM looks like C, but M differs from S**: the layer forwards metadata only on the decoder's buffers.
  Compare the `[HDR10Probe] first frame` lines of M and CM.
- **SP and CP both pulse**: the television reads per-buffer metadata on both kinds of buffer, the same
  answer as "CM differs from C". **Only SP pulses**: as "CM looks like C, but M differs from S".
- **Both alike**: the layer forwards nothing per buffer. Tone mapping must then target a fixed, assumed
  panel, or stay off on tvOS.
