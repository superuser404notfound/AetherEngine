# Dolby Vision pulse test

A measurement, not a test. It answers whether a television is *using* the Dolby Vision metadata a
player hands it, as opposed to merely switching into a Dolby Vision mode and showing the base layer.
The badge cannot tell those apart. A pulse can.

The clips hold the pixels constant. After a 144 frame pre-roll, only the RPU switches between two
states A and B every 72 frames (about three seconds, ten cycles, a 66 second clip). If the panel
applies the metadata, the picture brightens and darkens in step with the switches, and a phone
filming the screen sees it. If the RPU is ignored, the filmed picture is steady, apart from drift.
Running the same clip through different players puts the engine's Profile 7 FEL route next to Apple's
own and says whether the route is real Dolby Vision. The evidence this was built for is in
[docs/dolby-vision-fel.md](../../docs/dolby-vision-fel.md).

A variant, `p7fel_el.mp4`, keeps the RPU constant and switches only the enhancement-layer residual on
six patches. It answers a different question: whether the composed FEL pixels, not just the metadata,
reach the panel.

Nothing here is a unit test and none of it runs in CI beyond compiling. It needs a television, an
Apple TV and a phone on a tripod.

## What is in here

| path | what |
| --- | --- |
| `Scripts/gen_pulse.py` | the synthetic pattern, the RPU configs for every variant, the EL residual design |
| `Scripts/build.sh` | builds the clips (x265, dovi_tool, MP4Box) into `out/` |
| `Scripts/fel_count.py` | the counter clips: BL and EL each carry their own frame number; also reads them back from composed frames |
| `Scripts/serve.py` | static server with HTTP Range support, which AVFoundation requires |
| `Scripts/run_tv.sh` | builds and installs the host on an Apple TV, serves the clips, plays a sequence |
| `Scripts/cut.py` | cuts one phone recording into one piece per arm from the app's wall-clock log |
| `Scripts/analyze.py` | reads a phone recording back and prints a verdict per arm |
| `Scripts/report.py` | turns the cut arms into the change-per-patch table, the phase-A levels and the all-arms figure |
| `Scripts/check_el.py` | checks on the Mac that the EL clip carries the designed residual in B and none in A |
| `Scripts/dump_attachments.swift` | prints what VideoToolbox attaches to a decoded Dolby Vision frame, with a hash of the RPU |
| `Scripts/sim_recording.py` | a fake phone recording, to prove the analysis before trusting a real one |
| `Device/` | the tvOS host app (xcodegen project, committed generated project) |
| `Device/PulseEngine/` | the local package the host links the engine through; it enables the engine's `DualLayerDolbyVision` trait |

## Tools

`x265`, `dovi_tool`, `MP4Box` (gpac), `ffmpeg`/`ffprobe`, `curl`, Python 3 with `numpy`, and `Pillow`
for the optional plots (`analyze.py --png`, `report.py --png`; `cut.py` writes its per-arm `.png` only
when Pillow is installed). On macOS: `brew install x265 dovi_tool gpac ffmpeg`,
`python3 -m pip install numpy pillow`. `xcodegen` only if the Xcode project is regenerated.

Tested with ffmpeg 9.0.2, dovi_tool 2.3.4, x265 4.3, MP4Box (GPAC) 26.07, Python 3.14 with numpy 2.3
and Pillow 12.1, and Xcode 27.0 (tvOS 27 SDK), on an LG C1 filmed with a phone.

## Build the clips

```bash
Scripts/build.sh
```

Everything lands in `out/` (override with `PULSE_OUT`), which is gitignored; no media is committed.
The 4K encode takes a few minutes and is skipped when `out/base.hevc` exists.

| clip | profile | what switches |
| --- | --- | --- |
| `pulse_l2.mp4` | 8.1 | L2 trims at 100/600/1000/4000 nit targets, neutral and extreme |
| `pulse_l1.mp4` | 8.1 | L1 `max_pq`, 100 nit and 10000 nit |
| `pulse_null.mp4` | 8.1 | nothing: L1 constant, trims neutral, the same shot boundaries as `l2` |
| `p7fel_{l2,l1,null}.mp4` | 7 FEL | the same three RPUs, enhancement layer flat (zero residual) |
| `p7fel_el.mp4` | 7 FEL | the RPU never changes; a positive luma residual on six patches in phase B |
| `p7fel_count_{null,l2}.mp4` | 7 FEL | counter clips: "BL nnnn" in the base layer, "EL nnnn" in the residual only; `l2` pulses the RPU as `pulse_l2` |
| `count_mel.mp4` | 8.1 | the counter clip's base layer alone (no EL numbers), the MEL/AVPlayer control |

The Profile 7 clips need a FEL RPU to start from. `build.sh` fetches dovi_tool's own 384 byte test
RPU once and checks its hash:

```
https://raw.githubusercontent.com/quietvoid/dovi_tool/ef85991cfc31e26bc3ffed76364965f29f9fd281/assets/tests/fel_orig.bin
```

It is the same file Homebrew installs under `$(brew --prefix dovi_tool)/share/dovi_tool/assets/tests/`.
The mapping and NLQ parameters stay as that file has them in every frame, so the composed picture is
the same in every phase; only L1/L2/L5/L6 are replaced per frame.

The pattern carries what the analysis reads: four corner squares that locate the screen in the camera
image, an orientation tag, twelve grey patches from 0.1 to 10000 nit, eight colour patches, a PQ ramp,
and a strip of sixteen cells that is the frame counter (the clip frame number in Gray code with two
parity bits, so the analysis knows which phase is on screen). Frames whose counter does not decode
(slates, black during the mode switch, motion blur) are dropped.

## The arms

One phone recording covers a whole sequence. The host plays the arms back to back with a five second
slate on black naming the arm and a live UTC clock between them, then the switch into the video mode.
Nothing is touched during the run.

| arm | mode | clip | what it is | expected if the RPU is used |
| --- | --- | --- | --- | --- |
| P | `avplayer` | `pulse_l2` | AVPlayer, Apple's own path | pulses. **If not, stop: the TV or its settings cannot show the test** |
| V1 | `vt` | `pulse_l2` | AVAssetReader (VideoToolbox) into an `AVSampleBufferDisplayLayer`, Apple's attachments | pulses if the display layer carries Dolby Vision at all |
| V2 | `vtcopy` | `pulse_l2` | as V1, every frame copied into our own IOSurface pool, Apple's RPU bytes re-attached | pulses if buffer origin does not matter |
| S | `vtstrip` | `pulse_l2` | as V2 with no Dolby attachments | steady; this is what HDR10-in-Dolby-Vision looks like |
| T | `engine` | `p7fel_l2` | AetherEngine FEL route (`preferDualLayerDolbyVision: true`) | **the question** |
| N | `engine` | `p7fel_null` | AetherEngine FEL route, metadata never changes | steady (camera and TV drift only) |
| P1 | `avplayer` | `pulse_l1` | AVPlayer, `max_pq` switches | pulses (highlights) |
| T1 | `engine` | `p7fel_l1` | AetherEngine FEL route | the same as P1 |
| TE | `engine` | `p7fel_el` | FEL route, only the residual switches | pulses on the six patches only if the composed pixels reach the panel |
| NE | `enginenofel` | `p7fel_el` | `preferDualLayerDolbyVision: false`: native 8.1 route, EL dropped | steady |
| T (count) | `engine` | `p7fel_count_null` | FEL route on the counter clip, constant RPU | "BL nnnn" and "EL nnnn" show the same number |
| NE (count) | `enginenofel` | `p7fel_count_null` | native 8.1 route, EL dropped | the EL panel stays empty |
| TL | `engine` | `p7fel_count_l2` | FEL route, counter clip, the RPU pulses as in `pulse_l2` | the same numbers, and the picture pulses |
| PM | `avplayer` | `count_mel` | AVPlayer on the base layer alone as 8.1 (what a MEL player shows) | no EL numbers |
| SOAK | `soak` | any FEL clip | `engine` for `minutes=` with a `seeks=` schedule | not a pulse arm, see below |

Sequences (`SEQ=` for `run_tv.sh`): `main` is P V1 V2 T N S P1 T1 P, about 11 minutes; the closing P
repeats the first and checks drift over the session. `el` is TE NE T, about 4 minutes. `vt` is P V1
V2 S. `count` is T NE TL PM on the counter clips, about 5 minutes. `soak` is one long arm.

The counter clips are read by eye on the recording, not by `analyze.py`. Each layer carries its own frame
number: the base layer draws "BL 0123" in its pixels, the enhancement layer draws "EL 0123" in its residual
only, with a slower "S042" row (frame / 24) for when the fast digits blur on camera, and a Gray-code cell row
per layer. Composed correctly, both sides show the same number. A route that drops the residual shows an
empty EL panel; one that pairs the wrong EL picture shows a different number; TL shows that the RPU is
applied on top of the composed residual. Both layers use one fixed GOP, so their picture order matches.
tvOS AVPlayer does not play single-track Profile 7, so the AVPlayer control is the 8.1 base layer (PM).
Off the TV, `Scripts/fel_count.py read <frames.yuv>` decodes both code rows from raw 3840x2160 yuv420p
frames of any composer's output and prints `ok`, `MISMATCH` or `no-EL` per frame.

The soak arm is not a pulse measurement. It plays a FEL title for several minutes through a seek
schedule and reports one line, `soak summary: played= seeks= droppedFrames= composeFailures=
peakFootprintMB= endFootprintMB= route=`. Check `route=` first: it reads `FEL` only if the engine's
dual-layer decoder reported a FEL stream (or a summary line with a failure), and a run that never took the route reports zero compose failures
for the wrong reason.

## Run on an Apple TV

The dual-layer route is an optional component of the engine, compiled only with its
`DualLayerDolbyVision` package trait. The host gets it through `Device/PulseEngine/Package.swift`, which
depends on the engine with that trait set, because XcodeGen cannot set a package's traits itself. Without
the trait every `engine` and `soak` arm would play the native route, so the host checks
`AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn` before the first arm, shows a slate
saying the trait is missing, logs an `ERROR` line and exits with status 70.

The host app takes its arms from the environment variable `PULSE_ARMS`:

```
label|mode|url[|k=v;k=v],label|mode|url,...
```

Arms are comma separated; a soak's `seeks=at@to,at@to` list contains commas too, so a piece that does
not look like `label|mode|...` continues the previous arm's parameters.
`xcrun devicectl device process launch --environment-variables` does deliver environment to an app
process. That is not true of an XCTest bundle on tvOS, which is why the transport probe cannot use it.

```bash
DEVICE="<devicectl name or id>" TEAM=<team id> Scripts/run_tv.sh
```

`xcrun devicectl list devices` names the devices. Options, all environment variables:

| variable | default | what it is |
| --- | --- | --- |
| `DEVICE` | required | the Apple TV |
| `TEAM` | none | development team id for signing |
| `PULSE_BUNDLE_PREFIX` | `de.superuser404.dolbyvisionpulse` | the app's id is `<prefix>.host`; set it when a team cannot register the default |
| `SEQ` | `main` | `main`, `el`, `vt`, `count` or `soak` |
| `SOAK_URL`, `SOAK_MIN`, `SOAK_SEEKS` | none, 5, `60@1800,150@600,240@3000` | the soak arm: a URL or a file under `out/`, minutes, `at@to` seek schedule in seconds |
| `PULSE_OUT` | `out/` | where the clips are |
| `IFACE` | first of `en0`, `en1` with an address | the network interface whose address the Apple TV fetches the clips from |
| `DEVELOPER_DIR` | `xcode-select -p` | the Xcode to build with |

`run_tv.sh --no-build` plays without rebuilding. The script builds `Device/DolbyVisionPulse.xcodeproj`,
installs it, serves `out/` from this Mac over plain http (`serve.py`; the host allows it), waits ten
seconds so the recording can be started, launches with `--console`, and afterwards pulls the app's own
log (`Library/Caches/pulse-log.txt`) off the device. A launch that ends non-zero, because the app
crashed or was killed, still gets its log pulled. Pull a crash report from the device yourself when
that happens.

In Xcode: open `Device/DolbyVisionPulse.xcodeproj`, pick the Apple TV, set `PULSE_ARMS` in the scheme's
environment variables and run. The host keeps the screen saver off, because an Apple TV that sleeps
mid-sequence suspends the process.

Apple TV settings: Format **4K SDR**, Match Content with **Dynamic Range** and **Frame Rate** on, and
leave the HDMI chroma and range settings alone between runs.

## Film it

**Television.** Dolby Vision on an LG OLED (the C1 was used): picture mode **Dolby Vision Cinema**,
not *Cinema Home*, which follows the room light. AI Picture Pro, AI Brightness, Energy Saving, OLED
Motion Pro, TruMotion and OLED Care's Logo Luminance Adjustment all off; the last two matter because
black frame insertion flickers on a phone and the logo dimming darkens static areas, which this
pattern is. LG keeps separate Dolby Vision and HDR10 settings and the Dolby Vision ones can only be
changed while Dolby Vision is playing, so set them during any Dolby Vision title. Dark room, ten minutes
of warm-up. Note whether the Dolby Vision badge shows on each arm; it says only that the TV is in
Dolby Vision mode, and the pulse is what says the RPU is used.

**Phone.** 4K at 30 fps (1080p 30 works), **HDR Video off** so the recording is not itself tone
mapped, Auto Low Light FPS off, Enhanced Stabilization off, Lock Camera on. On a tripod, with the
whole screen and all four corner squares filling most of the frame and nothing else bright in view.
Start recording before the launch; `run_tv.sh` waits ten seconds. Hands off until the sequence ends,
then stop.

**Exposure must be locked.** With auto exposure the camera compensates for the very brightness change
being measured. The stock Camera app's AE/AF lock (long press) **did not hold** here: exposure moved
on a locked frame. Use a manual camera app with a fixed ISO, a fixed shutter (1/30 or 1/60) and a
fixed white balance (5600 K), set so the brightest patch (top row, right end) is not blown out.
Blackmagic Camera is one. If the stock app is all there is, lock during the first arm's pre-roll and
treat the first run as a shakedown; the closing P arm repeats it.

## Cut and analyse

`cut.py` splits one recording into one piece per arm using the `[Pulse] wall=...` lines in the console
log (or the pulled app log), so the labels do not depend on counting runs in order.

```bash
python3 Scripts/cut.py recording.MOV tv_main_<stamp>.log --slates
```

The video's start comes from its QuickTime creation date, to a second. `--slates` writes one still per
slate; read the UTC clock off one and pass it back for sub-second alignment:

```bash
python3 Scripts/cut.py recording.MOV tv_main_<stamp>.log --sync 12.5=17:08:31.2
```

That is "the slate frame at 12.5 s of the video shows 17:08:31.2". The result is a table of arm, mode
and verdict, plus a `.mov` and `.json` per arm (and a `.png` when Pillow is installed) next to the recording.

To analyse a recording directly, labelling runs in order:

```bash
python3 Scripts/analyze.py recording.MOV --arms P,V1,V2,T,N,S,P1,T1,P --png result.png
```

## Report

`report.py` reads the arms directory `cut.py` wrote (`summary.json` and every `NN_<ARM>.json`) and prints
markdown: the change in camera brightness, B against A, per grey patch as a signed percent (FEL-route
rows in bold, a repeated arm labelled "(repeat)", an arm with no decoded run flagged), the number of
patches with |t| above 5 and the strongest t per arm, and the absolute phase-A levels of the arms that
show whether the panel was in Dolby Vision at all. `--png` draws every arm's trace in one figure.

```bash
python3 Scripts/report.py recording_arms --md report.md --png report.png
python3 Scripts/report.py recording_arms --levels-arms V1,V2,T,S --patches g10,g100,g400,g1000,g4000,g10000
```

## Check the clips before filming

A steady EL arm only means something if the clip carries the residual. `check_el.py` demuxes the BL and EL
of the muxed `.mp4` (`dovi_tool demux`), or takes an EL-only `.hevc`, decodes the EL to raw
`yuv420p10le` (no range conversion), and checks that the median EL code inside every `EL_PATCHES` box is
512 in phase A and the `el_design()` code in phase B (within one code value). It prints the share of EL
pixels away from 512 per phase (0 in A, about the patch area in B), the composed 10-bit change each patch
should show, and for an `.mp4` that the RPU is the same on every frame. It exits 1 on a failure, so the
flat-EL control clip fails phase B by design.

```bash
python3 Scripts/check_el.py out/p7fel_el.mp4
```

`dump_attachments.swift` decodes a Profile 8.1 clip through AVAssetReader, that is VideoToolbox's own
decoder, prints every attachment on the chosen frames' pixel buffers, and hashes `DolbyVisionRPUData` on
every frame. It shows the payload the platform attaches itself, to compare with what the engine attaches;
on a pulse clip the hash differs between an A frame and a B frame.

```bash
swift Scripts/dump_attachments.swift out/pulse_l2.mp4 0 200
```

## Reading the verdicts

For every patch and every B phase, the effect is `B - (A_before + A_after) / 2`, so slow drift cancels.
Per arm the output is a verdict, the eight patches that moved most (level, B-A change, relative change,
t statistic) and the lag in clip frames between the switch and the panel's response.

- **PULSE**: at least three patches with |t| above 5. **weak**: one or two. **steady**: none.
- **Real Dolby Vision**: T is about the same as P, and much larger than N.
- **Fake Dolby Vision** (the mode switches, the metadata is ignored): T is about N while P pulses.
- **V1 pulses, V2 does not**: tvOS cares where the buffer came from.
- **V2 pulses, T does not**: the problem is in our RPU bytes or our path, not the platform.
- **TE pulses on the six patches, NE steady**: the residual reaches the panel. The six are the 10, 100,
  400 and 1000 nit greys, red and cyan (about +17 % in 10-bit luma code value after composition); the
  other patches are in-frame controls and must not move.

N and NE are the drift floor. A verdict only means something against them.

## Proving the analysis first

`sim_recording.py` writes a fake phone recording of `pulse_l2.mp4`: filmed at 30 fps with perspective,
vignetting and noise, B phases darkened with a three frame latency for a `pulse` run, nothing for a
`steady` one.

```bash
python3 Scripts/sim_recording.py sim.mp4 pulse,steady        # about two minutes
python3 Scripts/analyze.py sim.mp4 --arms pulse,steady        # PULSE (28 patches), steady (0 patches)
```

`cut.py` can be exercised the same way with a hand-written log of `[Pulse] wall=<epoch> t=<s> slate
<label>`, `arm <label> start mode=<mode> url=<clip>` and `arm <label> end` lines and `--sync`.

## Caveats

- **The camera reports its own values, not nits.** The numbers are camera luma after its tone curve
  and exposure. They say whether a patch changed and by how much relative to itself, not by how many
  nits. Compare arms with each other, not with the clip's nominal levels.
- **A panel's own processing can mask or invent a pulse.** Dynamic tone mapping and ABL react to the
  frame's content, and the content here is constant, which is the point; the null arms measure what
  is left.
- **The pulse proves the metadata is consumed, not that it is applied correctly.** Whether the
  display-mapping result is right needs a colorimeter.
- **The EL arms' size depends on the composer.** The residual design assumes an identity-scaled
  BL-to-VDR luma map; `gen_pulse.py el-design` states the assumption and the verification is the
  measured size of the TE pulse.
- **Expect to run the whole sequence more than once.** A run where P does not pulse says nothing about
  the other arms.
