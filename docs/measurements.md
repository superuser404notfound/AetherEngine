# Measurements

This page keeps the dated measurements behind the rules in the other docs. Read it to learn why a rule is what it is, or to repeat a measurement.

- Each rule lives on its own page, in the present tense. This page keeps the numbers, the engine versions and the rounds that led to it.
- Each entry opens with what was measured and what it decided, then links the current rule.
- Nothing here is a contract: a later engine may read differently.

**Contents**

- [aetherctl and harness measurements](#aetherctl-and-harness-measurements): readings taken with the CLI and its fixtures
- [Engine architecture](#engine-architecture): the evidence behind the architecture pages
- [Host API](#host-api): live join, subtitle reach and API history behind api.md

## aetherctl and harness measurements

Measured with [`aetherctl`](cli.md) and its fixtures. Each entry names the command it was taken with.

### play: fastZap against an own origin (AE#374)

Measured: behind an origin of its own, a fastZap join serves on the upstream's TARGETDURATION, not on the engine's finer re-cut. Driving that shape is why `play` got the profile switch (`--standard-join`).

Current rule: [cli.md › Live join and cushion](cli.md#live-join-and-cushion).

`live` has carried the profile switch for its own raw-TS fixture since AE#195, but that fixture has no upstream playlist. The served `#EXT-X-TARGETDURATION` is floored by the UPSTREAM's observed arrival cadence (`LiveCadencePolicy`), and that floor sizes the holdback the first serve waits for. So fastZap against an origin of one's own, the shape a downstream player actually ships, could not be driven from here at all. Measured on the same 1 s-GOP seed, `--preroll 0 --realtime`:

- Raw TS with no playlist serves at 1.325 s on TARGETDURATION 1 (holdback 3 s, full cushion). Since AE#670 the engine's own GOP-bound cut carries 1.5x headroom, so that row now seals at 2.
- The same content behind an `hlsfixture` origin cutting 2 s segments serves on TARGETDURATION **2** (holdback 6 s), although the engine re-cut it at 1 s.

### play: the decode-path lever (#461)

No measurement, a change of lever: `play --sw` now sets `LoadOptions.preferredDecodePath = .software`, the shipping per-session lever.

Current rule: [cli.md › Software path](cli.md#software-path---sw).

Before #461, `play --sw` drove the process-global `setForceSoftwarePathForTesting` hook, which `live --sw` and `dvr` still use.

### play: the live-start hold (AE#440)

Measured: the live-start hold (a still first picture before playback rolls) does not reproduce on this harness, and that is itself the finding. `--live-start-immediately` therefore only drives the engine end of a device A/B.

Current rule: `--live-start-immediately` in [cli.md › Live loads](cli.md#live-loads).

Measured on 6 window geometries against the raw-TS fixture at `--realtime --preroll 0` (a shallow window under the holdback, a window exactly at it, and a deep window from `--preroll 6/12/30`): the gap between `layer.isReadyForDisplay=true` and `timeControlStatus=playing` stayed between 10 and 60 ms every time, against 1.5 to 2.8 s reported on an Apple TV 4K over the same shape. Loopback answers at memory speed, so AVPlayer's buffering-rate evaluation concludes at once. So the flag proves nothing from a Mac. The device A/B has since run (AE#440, on 6.53.0), and it is what turned the default on. See the live-join section of `api.md` for its numbers.

### play: audio delay rounds (AE#464)

Measured: `play` reproduces the AE#464 audio-delay defects without hardware. Each round below shows the log before and after its fix.

Current rule and the healthy readings: [cli.md › Audio delay](cli.md#audio-delay---audio-delay---switch-audio-delay).

**Round 2 (`--paused`, three presses in one turn).** `--switch-audio-delay` is repeatable and `--paused` mounts with `autoplay = false`; together they reproduce the round-2 pair of AE#464 without hardware.

- `--paused --host-calls play` is a host that owns transport (mounts paused, plays next to its own load). The rebuild the engine raises for a nudge has no such caller. Before the fix, item #2 settled `timeControlStatus=paused reason=- t+0.00s`, never reached `playing`, and the producer parked on `#65 backpressure PARK (advance) ... (consumer paused)`, while the run still ended `VERDICT: OK`. After it: `#2 timeControlStatus=playing t+0.06s`.
- Three presses inside one runloop turn (`--switch-audio-delay 50@15000 --switch-audio-delay 100@15003 --switch-audio-delay 150@15006`) stack three reloads, two superseded by generation. Before the fix the survivor loaded `startPos=nil` and cut `seg0+` on a session 14.90 s in. After it: `startPos=14.90s`, `initial producer anchored at idx=3` and `seg3+`.

**Round 3 (three presses at the SAME delay).** `--switch-audio-delay 50@15000 --switch-audio-delay 100@15000 --switch-audio-delay 150@15000` is the in-flight latch's arm.

- Before: four loads dispatched, two `load superseded`, and two `AE#464: the re-cut at the playhead failed (CancellationError())` lines naming values (+50 ms, +100 ms) that were already superseded. The session then sat at `state=paused cur=14.90` from t=15 to t=19 and still ended `VERDICT: OK`.
- After: two loads, zero superseded, two `folded into the re-anchor already in flight` lines, the same `cutting seg3+ with audio delay +150 ms`, and the session playing through.
- The paused half was the transport park: a rebuild stacked behind one in flight read `.loading` and had no host to ask, so it wrote `autoplay = false` onto a session that was playing.

**`--reload-applying autoplay=false`** drives the third answer a correction can give: neither applied nor refused. Before round 3 the field was named inside `#460: reload applying httpHeaders, autoplay` and then overwritten. Now it gets `#460: autoplay not applied, the session owns it`. The run prints the returned partition next to it (`#460 outcome applied=[] sessionOwned=[autoplay] rebuilt=false`). Since round 4 no rebuild follows: the session plays on without a `#361 startup` line, where it used to pay a full one for a field it decides itself.

**Pressing into a rebuild window.** `--reload-applying-at 14990 --switch-audio-delay 150@15000` aims a press squarely into a rebuild window, where `videoRoute` is `.none` because there is no route to ask. That used to answer `this session's audio timestamps are not the engine's to move (route=none)` one line above the muxer cutting with the value. Now it answers `set while the session is being rebuilt; the load in flight reads it from the options and delivers it`.

**Round 5 (two presses a re-anchor apart).** `--switch-audio-delay 50@15000 --switch-audio-delay 100@15060`; the band is 50 to 90 ms on an M1 against a 300 s H.264 + AAC fixture. The second press arrives after the first rebuild has returned and written `.playing`, but before the new host has published a position.

- Before the fix it read the zero `load()` had written and rebuilt at the head: `#3 mount seek: item axis 0.00s`, `cutting seg0+`, on every run from 15050 to 15090.
- After it: `#3 mount seek: item axis 14.90s` and `cutting seg3+` on every run.
- Control: `--start-position 100 --seek-every 12 --seek-count 1 --seek-pattern 0 --switch-audio-delay 50@12450`. A seek retires the parked position, so the rebuild after a genuine seek to 0 still mounts at `0.00s`, not at the 100 s the load was handed.

**Live-only sessions.** `play --live` without `--dvr-window` is the live-only shape, and it shows the re-anchor gate: `AE#464: audio delay = +150 ms stands, but this session cannot re-anchor at the playhead (state=playing, live=true); it arrives at the next seam`. With `--dvr-window 1800` the same run takes the re-anchor and re-cuts. Before round 2 the gate read `liveWindow != nil`, which is true for both, so the live-only session took a rebuild that rejoins at the edge.

### Picture probe and segment placement (AE#418, AE#481)

Measured: AVPlayer places a segment where the playlist puts it, and how far a placement sits below its axis is a distance read in seconds, not a property of the source. This is the history of segment placement on the native path; each round lists what it found and the log lines it added.

Current rule: [cli.md › Picture probe](cli.md#picture-probe---picture-probe).

**The first finding.** AVPlayer presents a segment at the position the PLAYLIST gives it, not at the tfdt it carries, and then plays continuously from there. So a gate that opened below its boundary shifts the whole run by the re-aim (`axisErr=-13.583` on a 13.583 s re-aim, constant for the run).

**Round 3: a second oracle that works on a device with no capture card.** `AVPlayerItem.loadedTimeRanges`: the range holding the playhead begins where AVPlayer PLACED that run, so `advertised - rangeStart` is the axis it composed onto, measured instead of assumed. The engine reads it after every VOD seam and says what it found: `#418 segN placement confirmed`, or `#418 segN placed on base Xs, not Ys`. The second is a placement this side counted that AVPlayer discarded (a fetch during a seek burst, which is a fetch and not a placement). Against the picture probe the two oracles agree exactly: a resume predicting a seam at `52.000` reads `loaded [52.000-64.958]`, and a far seek predicting `21.000` reads `[21.000-38.622]`.

**Round 4: the reading WINS.** Round 3 collapsed the measured base onto the nearest axis the session had already published. That made the prediction the yardstick for the measurement meant to check it:

- a base matching no prediction was refused (a reporter's session composed to `-26.152` while two readings 400 s of media apart both said `-10.93`, and ended 42.6 s out);
- a base a frame or two off was called a confirmation, so that difference stayed in the axis and the next placement composed on top of it.

What decides now is where the reading came from: a run that overlaps nothing the item held when the placement was recorded, or one that opened ABOVE it. A start that walked DOWNWARD is the same run backfilling, which AVPlayer does after a run opens, and is never read. The lines are:

- `#418 segN placement confirmed` (residual under a millisecond)
- `#418 segN placed on base Xs, not Ys (... residual Zs)`
- `#418 segN opened no run of its own to measure`
- `#418 segN superseded before it was measured`

Round 4 also needs a fixture with B-FRAMES, and `Scripts/timecode-fixture.sh` now writes one (`tc-bframes.mkv`). `-preset ultrafast` disables them, so on `tc-drought.mkv` a segment's dts and pts are one number and the gate's offset is the same either way. On real content they are not: the gate opens on a random-access point in DECODE order, and taking the offset there put the axis `video_delay` frames under the truth on every epoch. The pair isolates exactly that.

**Round 8: how far a placement sits below its axis is MEASURED, in seconds.** Rounds 5, 6 and 7 read that distance as a multiple of the epoch's presentation lead: round 5 shipped the multiple as arithmetic, round 6 measured it per source, round 7 held the median of its readings. The premise was that the distance is a geometry of the source. It is not. `Scripts/timecode-fixture.sh` writes three clips identical except for their reorder depth. Same burst arm over a throttled origin (`Scripts/slowrange.py`, 3200 kbps + 100 ms), `--picture-probe` reading the axis off AVPlayer's own video output, 2 runs each, every run identical:

| clip | gate lead | placement 2 sits | placement 3 sits |
|---|---|---|---|
| `tc-cues-lie.mkv` | 0.000 (no reordering) | 0.000 below its axis | **0.042 below its axis** |
| `tc-bf1-cues-lie.mkv` | 0.042 (one frame) | 0.000 | 0.083 |
| `tc-bf-cues-lie.mkv` | 0.083 (two frames) | 0.083 | 0.125 |

The bold cell retires the model. That clip has `has_b_frames=0` and every gate opens with `lead=0`, yet its third placement still sits a frame below its axis. A quantity that is nonzero where the lead is exactly zero is not a multiple of the lead, and no coefficient can express it. The middle row retires the source-law premise separately: one source, two placements, 0.000 then 0.083.

So the session now carries the distance in the units it corrects, reads it off the same placement reading that already measures the base, and every reading teaches it, a confirmation included. That also fixes the starvation round 7 shipped: only a placement carrying a lead could teach, and on a source without reordering, or on any session whose placements are AE#412 re-cuts (worth 0 and lead 0 by construction), there never is one. Measured on `tc-wide-cues-lie.mkv`: 13 of 13 placements across two runs carried `lead 0.000s`, so the parameter could not move at all.

Each `placed` line names what it composed with (`sitting 0.083s below its axis`), and a reading that moves it says so: `#418 segN sat Xs below the axis it composed on, not Ys; the next composition starts there`. An item's FIRST placement is no longer a special case: with nothing measured yet the distance is zero, which is what AVPlayer does there (measured base 0.000 on every arm of every fixture). The gate-open line still prints `lead=`, now purely as a source fact.

**Round 9: the lesson on the reading's own line.** Round 8 printed only the MOVES, and two different things were silent under that. Every verdict line now ends in one of three clauses:

- `taught the distance Xs`: an own-run reading that moved it, with the `sat` line under it.
- `taught the standing distance Xs again`: an own-run reading that agreed with it.
- `taught nothing, read off a rebuilt timeline; the distance stays Xs`. This is the useful one. A rebuilt-timeline reading corrects the axis like any other (by 28.000 s on `tc-wide-cues-lie.mkv`), and round 7 refuses it the parameter on purpose, so its correction line was otherwise indistinguishable from one that had just taught a 28 s lesson.

**AE#481: the axis belongs to the RUN.** A seek burst heals this case inside a second, so those ten rounds could not see it. The axis belongs to the RUN a re-aimed segment opened, not to the timeline from its advertised start on. Run the same chain with the re-anchoring seek LAST (`--seek-count 5 --seek-pattern 65,60,70,58,75`, served through `Scripts/slowrange.py` at 600 kbps / 300 ms): the picture reads `pic - picItem` of -9.000 at item 53.000 and 0.000 everywhere the landing goes, while the session keeps mapping with -9.000 and `capErr` sits at +9.017 to the end of the run.

A seek landing now reads what its run carries, and says so: `#481 the run holding the landing at item Xs opens at Ys, which is segN's own playlist position, so it carries Zs and not the Ws this session was mapping with`.

- The discriminator is that opening, asked of ONE segment: the first one the local server answered after the seek, whose content opens that run. It goes into a timeline carrying an axis at the seam that axis predicts, and into a timeline carrying nothing at its own position. Those are round 7's two admissible answers.
- Asked of the whole plan, the same rule publishes on a coincidence (31 boundaries over 120 s against a half-second tolerance: measured, a 0.000 axis written into a timeline carrying -27.875 s).
- Measured on the arm above, `capErr` goes from +9.037 to +0.037: 216 frames, and the only unambiguous number in the set. The 24-seek arms it must not touch are unchanged (10 placements, axis -34.376, no reading fired in 2 of 2 runs).
- On the two slow arms the `capErr` tail moves onto the same one-frame lattice pair the fast arm sits on (`+0.009` / `-0.033`). That is a sub-frame move and carries no accuracy claim either way. An earlier revision of this paragraph read it as an improvement from 0.0230 and 0.0411 to 0.0162, which is the mistake AE#418 round 11 documents on both sides of that thread.

### hlsfixture: TARGETDURATION and window depth (AE#374, AE#447)

Measured: neither padding the advertised TARGETDURATION nor deepening the upstream window changes a fastZap join. Since 6.56.0 the engine does not read the advertised value at all.

Current rule: [cli.md › TARGETDURATION and window depth](cli.md#targetduration-and-window-depth---target-duration---window).

`--target-duration N` advertises a `#EXT-X-TARGETDURATION` independent of the real cut size. `--window N` sets how many segments the sliding window keeps visible. Packagers commonly pad the target duration (`segment + 1`) to widen a client's patience for an unchanged playlist. A downstream host asked whether that padding was what its live joins were paying for. Neither shape could be expressed here before, so the question could not be answered by measurement.

Measured against pre-cut GOP-aligned segments, `play --live --fast-zap` entering on a saturated window, three passes per row, engine 6.34.1:

| origin cut | advertised TD | window | served TD | first serve held |
|---|---|---|---|---|
| 2 s | 3 (padded) | 3 | 3 | 2.004 / 2.010 / 2.010 s |
| 2 s | 2 (`ceil(max EXTINF)`) | 3 | **3** | 2.010 s, three times |
| 2 s | 3 | 5 | 3 | 2.001 / 2.007 / 2.010 s |
| 2 s | 5 (over-padded) | 3 | **5** | 2.010 s, three times |
| 1 s | 2 (padded) | 3 | 2 | 1.001 / 1.010 / 1.010 s |
| 1 s | 1 (`ceil(max EXTINF)`) | 3 | **2** | 1.005 / 1.007 / 1.010 s |
| 1 s | 2 | 7 | 2 | 1.003 / 1.005 / 1.010 s |
| 0.5 s GOP inside 1 s segments | 2 | 3 | 2 | **0.510 s, three times** |

**At 6.34.1, removing the padding changed nothing.** That finding is the defect AE#447 later fixed. The served TARGETDURATION was `max(advertised, ceil(observed arrival cadence), ceil(max own EXTINF), ceil(1.5 x cut target))`. A strict-realtime origin's real inter-arrival gap is always a hair above the nominal cut, so the `ceil` landed on `cut + 1` whether or not the origin advertised it. "The padding is not what you pay for" was right; "there is nothing to pay" was not. Both terms were wrong for the same reason: an arrival interval is a cadence, and `ceil` treats it as a segment duration.

**From 6.56.0** the advertised value is not read at all (it is printed in the seal line and nowhere else). A measured cadence enters as the TARGETDURATION its patience actually needs, `ceil(gap / 1.5)`, because `1.5 x TD` is the unchanged-playlist tolerance the floor exists to satisfy. On the same 2 s origin advertising 3, measured on this harness:

- before: served TD **3, then 4, then 4** across three joins, holdback 9 s then 12 s twice. It escalated because the gate's own wait was being measured as the source's cadence.
- after: served TD **2** on every join, holdback 6 s, measured floor 2.019 to 2.141 s.

Deepening the window changes nothing either. The ingest joins exactly three segments behind the edge at window 3, 5 and 7, so a deeper upstream window never becomes a deeper cushion. What moves is the cut, because the fastZap grace is `min(2.0, max(0.5, own cut duration))` and the engine re-cuts at the source GOP.

**Over-padding costs elsewhere.** TD 5 on 2 s cuts still serves in 2.010 s, because the bounded fastZap exit fires on the grace either way. But the served playlist then carries a 15 s holdback, so AVPlayer targets that far behind the live edge for the rest of the session. Since 6.56.0 an over-padded advert cannot produce that: only the source's own segments and its closed inter-arrival gaps can.

**The seal line** shows the whole derivation, once per session:

```
[HLSVideoEngine] live TARGETDURATION sealed at 2s (holdback 6.000s): max EXTINF 2.000s,
  1.5 x cut target 0.750s, measured floor 2.069s needs 2s of patience;
  upstream advertises 3.000s (reported, not used)
```

**This harness cannot reproduce the last term (AE#447 round 2).** After the four fixes above, the reporter's device still sealed at 3 while that same line printed `max EXTINF 2.000s`. A live EXTINF is `nextStart - startSeconds`, a difference of two accumulated item-axis doubles. So a strictly 2.000 s GOP whose first segment starts at 0.060 s yields the odd `2.0000000000000004`. `ceil` charges a whole second for it, and the seal takes the max over the window, so one such segment is enough (6 of his 80 were). The fixture here starts its first segment at exactly 0 and cuts at a binary-exact duration, so its differences are exactly 2.0, and five joins in a row sealed at 2. The case lives in `Issue447TargetDurationEvidenceTests` instead, built by accumulating the way the producer accumulates. Since **6.56.0** every term is taken at the resolution the playlist serves (`#EXTINF` is written with `%.3f`), so the seal line can be checked against itself: what it prints is what decided it.

### hlsfixture: pricing the bounded start (AE#594)

Measured: flooring fastZap's bounded start at the full holdback costs one more segment minus the grace, which matters only at coarse cadences. The stall risk of the shallower window could not be priced on this harness.

Current rule: `AETHER_BOUNDED_START_FLOOR` in [cli.md › TARGETDURATION and window depth](cli.md#targetduration-and-window-depth---target-duration---window).

`fastZap`'s bounded start serves once two segments exist plus a clamped grace. That window can be shallower than the holdback the same manifest advertises. `AETHER_BOUNDED_START_FLOOR=1` is a measurement arm, not a policy: it skips the bounded branch, so the wait ends at the full cushion or at the 30 s outer deadline.

Both arms against an `hlsfixture` origin of pre-cut GOP-aligned segments, `play --live --fast-zap --seconds 45`, two passes per row (three for 6 s / A):

| origin cut | arm | gate held | first manifest | first picture | `-16832` |
|---|---|---|---|---|---|
| 1 s | A (bounded) | 3.028 s | 2 segs / 2.000 s **<** 3 s holdback | 3.47 s | 0 |
| 1 s | B (floored) | 3.068 s | 3 segs / 3.000 s >= 3 s holdback | 3.26 s | 0 |
| 3 s | A | 8.252 s | 2 segs / 6.000 s **<** 9 s holdback | 9.64 s | 0 |
| 3 s | B | 9.458 s | 3 segs / 9.000 s >= 9 s holdback | 9.65 s | 0 |
| 6 s | A | 14.342 s | 2 segs / 12.000 s **<** 18 s holdback | 16.72 s | 0 |
| 6 s | B | 18.597 s | 3 segs / 18.000 s >= 18 s holdback | 18.79 s | 0 |

**The floor costs exactly one more segment minus the grace.** The gate deltas: +0.04 s at a 1 s cut (the 1.0 s grace covers the whole wait), +1.21 s at 3 s and +4.26 s at 6 s, where the grace clamps to 2.0 s. At the picture: +0.00, +0.01 and +2.07 s. So the trade is real only at coarse cadences, and free at fine ones.

**This harness cannot price the other half.** `-16832` never appeared, in any cadence, in either arm, across thirteen runs. Do not read that as "the shallow window is safe". The session here joins at the HEAD of the served window (`cur` starts at the window's first sample and advances 1x) instead of seeking to edge-minus-holdback, so the state the issue is about is never entered. The per-tick `edge=` and `behind=` cannot check that either: `edge` stays pinned at its first value for the whole run and `behind` is derived from it, with or without `--dvr-window`. The stall half needs a field capture or an origin that reproduces the seek, not this table.

### hlsfixture: an origin that delivers late (AE#684, AE#686)

Measured against an origin that delivers late: the live seal now asks for the whole upstream segment, a join is equalised over the phases of mixed segment lengths, and the first-serve latch (AE#686) is on by default since 7.28.2. The entry also records what a Mac cannot observe about sound against picture.

Current rule: [cli.md › A late-delivering origin](cli.md#a-late-delivering-origin-scriptshls-burst-originpy).

`hlsfixture` publishes on a metronome, and a metronome is the one thing an IPTV origin is not. The defect AE#684 reported only exists when a delivery arrives later than the segment is long, so it could be read off a device log and reproduced nowhere.

`Scripts/hls-burst-origin.py` serves a sliding playlist over pre-cut segments and publishes segment k at `end of k - prefill + delays[k % n]`. The MEAN cadence stays the segment duration (the origin never falls behind real time), while the gap between two deliveries follows the cycle. Its options, the fixture command and the run used here are in [cli.md › A late-delivering origin](cli.md#a-late-delivering-origin-scriptshls-burst-originpy); the runs below used `play --live --live-ingest --fast-zap --seconds 180`.

That cycle makes the origin's own gaps run 3.6 to 8.3 s. On the loopback they arrive 3.0 to 9.3 s apart, because the ingest reloads the upstream playlist every half segment, and a delivery that just missed a reload waits for the next. **The served window changes once per UPSTREAM segment, up to one and a half of them apart, however finely the engine re-cuts it.**

Under `.fastZap` the cut is the 2 s GOP and `max EXTINF` reads 2.000 s. Through 7.25.1 the upstream's 6 s entered only through the cadence floor, as `ceil(6 / 1.5)` = 4. That division is right for a MEASURED gap, which is a robust maximum. A segment duration is the other end of the distribution: the period the source delivers at when nothing is late. So the client's patience (`1.5 x 4` = 6.0 s) was exactly one period, and the 12 s holdback left 2.7 s at the low point of the sawtooth.

The cost is not the `-12888` itself, but what AVPlayer does next: it skips a reload. Measured here and on an Apple TV alike: polls every 2.00 s, then 4.00 s (macOS) or 5.03 s (tvOS) of nothing after the error. The stall lands inside that hole, with the next delivery already listed 1.9 to 2.6 s earlier.

**The seal now asks for the upstream segment whole** and takes as much of it as the join pays for. On an upstream of uniform segment length the join itself is not deepened: one more upstream segment would be one more download before the first picture on every zap, which AE#678 measured and declined. So three 6 s segments are 18 s joined, 16 s cut, and a seal of 5:

```
[HLSVideoEngine] live TARGETDURATION sealed at 5s (holdback 15.000s): max EXTINF 2.000s,
  1.5 x cut target 0.750s, measured floor 6.000s needs 4s of patience,
  upstream segment 6.000s (one delivery, however finely it is cut here), of which the join
  pays 5s of 6s (16.000s cut of the 18.000s it listed); upstream advertises 6.000s (reported, not used)
```

One 180 s run per arm on that origin, same deliveries (four gaps above 9.0 s in each):

| | sealed | join | `-12888` | `playbackStalled` | `#524` running thin |
|---|---|---|---|---|---|
| 7.25.1 | TD 4, holdback 12 s | 3 segments | 5 | 1 | 4 |
| join-bound seal | TD 5, holdback 15 s | 3 segments | 3 | 0 | 0 |

That is fewer, not none, and it is the honest size of what a seal one second higher buys. 7.5 s of patience still loses to a 9 s gap, but the 15 s holdback leaves 5.7 s at the low point where 12 s left 2.7 s. That is the difference between surviving AVPlayer's skipped reload and not. A join one segment deeper (TD 6, holdback 18 s) drew none of either in three such runs and was not shipped: it cost 3.81 s against 4.98 s to the first picture behind an 8 Mbit/s link. The device capture this came from had 10 of its 110 gaps above 9 s and 5 above 12 s. So the field expectation is fewer `-12888` and far fewer stalls, not zero.

**Mixed segment lengths (`--durs 6,4`): both phases must read alike.** The join counts seconds back from the newest segment. So `--prefill 8` (a 4 s segment newest) joined four segments and sealed 6, while `--prefill 7` (a 6 s one newest) met the 16 s coverage at three, cut 14 s and sealed 4 (7.25.1's value), on about four tunes in ten.

The join is now equalised over the phases of one listing: a tune never loads more than the deepest tune of the same channel already did. That is the deepest the coverage rule takes over this tune and the tunes one, two, ... segments earlier that its own join still reaches, at most one above its own depth. `--window 8`, mild jitter (`--delays 0.2,0.5,0.3,0.8,0.25,0.6`), three 60 s runs per arm and phase:

| `--durs` | phase | | sealed | join | `-12888` | first picture behind 8 Mbit/s (median) |
|---|---|---|---|---|---|---|
| 6,4 | `--prefill 7` | 7.25.1 | TD 4, holdback 12 s | 3 segments, 16 s | 1 / 0 / 1 | 3.47 s |
| 6,4 | `--prefill 7` | now | TD 6, holdback 18 s | 4 segments, 20 s | 0 / 0 / 0 | 4.23 s |
| 6,4 | `--prefill 8` | 7.25.1 | TD 4, holdback 12 s | 4 segments, 20 s | 1 / 1 / 0 | 4.27 s |
| 6,4 | `--prefill 8` | now | TD 6, holdback 18 s | 4 segments, 20 s | 0 / 0 / 0 | 4.26 s |
| 10,8 | both | 7.25.1 | TD 7, holdback 21 s | 3 segments, 28 or 26 s | 0 / 0 / 0, 1 / 1 / 1 | 5.86 s, 5.52 s |
| 10,8 | both | now | TD 8, holdback 24 s | 3 segments, 28 or 26 s | 0 / 0 / 0, 1 / 1 / 1 | 5.88 s, 5.59 s |
| 6,6,4 | all three | 7.25.1 | TD 4, holdback 12 s | 3 segments, 16 s | 0 to 2 per run | 3.45 s, 3.43 s, 3.46 s |
| 6,6,4 | all three | now | TD 4, holdback 12 s | 3 segments, 16 s | 0 to 1 per run | 3.47 s, 3.47 s, 3.48 s |

No run stalled in either arm. The extra segment on 6,4 is the short one, and the other phase already loads it. The equalising stops there on purpose:

- 10,8 and 6,6,4 join three in every phase, so nothing is added and their first picture is main's.
- 10,8 seals what its three segments pay (8). 6,6,4 cuts 14 s in every phase and keeps 4, so it is not helped.
- A first version took one segment more on any mixed-length join that could not pay its seal. That cost those two shapes a segment on every tune (6.19 s to 8.12 s, and 3.81 s to 4.98 s).
- Uniform upstreams keep their three segments (`--dur 6`: TD 5, `--dur 10`: TD 9).
- A demuxed audio rendition is joined by the same rule (6,4 behind a master: 4 + 4 in both phases).

One start does get slower. A host that fetches fewer segments at a time than the join has (`play --max-concurrent-requests 1 ... --rate-kbps 14000`) used to be served at 12 s of cut content, and now waits for the join to be handed over or for the grace: 2.79 to 3.08 s before and 3.27 to 3.28 s after with `--prefill 8`, 2.80 to 2.83 s and 3.44 to 3.49 s with `--prefill 7`.

**Whether a join is spent is a fact, not arithmetic.** The seal may only be taken short once the join has nothing more to give. "Cut content plus one segment reaches the summed EXTINF" is not that fact: `--dur 6.3` over 6 s of media never adds up, and a first version built on the sum sealed the full value there and took the bounded start (2.23 s to first picture against 0.20 s). The reader states the fact instead: the whole join batch is committed, its FIFO is empty, and the cutter is parked waiting for the next delivery. Three runs per arm on each inflated shape with three segments listed: served at once in all six (0.000 to 0.034 s of hold), TD 5 on 6 s media and TD 9 on 10 s.

Two more shapes belong to the same fact:

- **Demuxed audio.** Run the origin twice, video-only and audio-only segments behind a master. The cutter parks on the AUDIO reader when the audio ends a little before the video, so the fact is stated for the cutter, not the video reader: both join batches committed and either reader dry. Read off the video reader alone it never became true: 2.2 s to first picture under `.fastZap` and 10.4 s under `.standard`. Now 0.18 to 0.21 s in all six cells (6 s and 10 s `.fastZap`, 10 s `.standard`, audio aligned and 0.2 s short, three runs each), as on 7.25.1.
- **A join slower than the `.fastZap` grace** (`play --max-concurrent-requests 1` behind `--rate-kbps 4000`). It is served by the bounded start before it is spent, seals the full 6 or 10 over a window under its holdback, and draws a `-16832` warning at the start. First picture 5.05 to 6.08 s against 7.05 to 8.26 s on 7.25.1 (which still pays the second grace there), and no `-12888` against 1 to 3.

**The gate held the second playlist request too.** AVPlayer opens with two `/media.m3u8` requests. Each re-enters `waitForFirstLiveSegment`, and on a bounded start each waited its own grace (`GET /media.m3u8` at 2.81 s, `GET /init.mp4` at 4.83 s). On an ingest the gate now opens for good once a manifest has gone out. On a source the engine cuts itself it did not until 7.28.2 (next paragraph). That second grace is the "+2.07 s at the picture" of the AE#594 table above; removing it there also leaves the session up to 2 s closer to the producing edge, which is that issue's open question. The raw-TS control (`live --fast-zap --realtime --preroll 0`, two seeds, two runs per arm) reads the same in both arms: first manifest at 3.84 to 3.96 s, `init.mp4` at 6.11 to 6.33 s, first picture at 6.20 to 6.58 s, playhead 6.3 to 6.8 s behind the wall clock. The AE#594 table stands as printed.

**AE#686 applies the same latch to a source the engine cuts itself, by default since 7.28.2.** It started as a measurement arm (`AETHER_FIRST_SERVE_LATCH_ALL=1`, 7.26.3), because what it may cost (a session closer to the producing edge for its whole life) needs a device that seeks to edge-minus-holdback, which this harness does not. The reporter's Apple TV A/B answered that. On 1080p59.94 raw TS with 1.001 s segments, every bounded start reached its picture 1.003 to 1.039 s sooner with the latch, the session sat 0.5 to 1.5 s nearer the edge after 60 s, and 18 latched launches logged no stall, `-16832` or `-12888`. A rebuild from a backlog served a full cushion in both arms, so the latch had nothing to skip there. `AETHER_FIRST_SERVE_LATCH_ALL=0` restores the old gate, read once per process. Both arms print how long AVPlayer's second plain request waited, once per session:

```
[HLSVideoEngine] repeat live manifest request held 2.003s, fastZap bounded start after 2.000s grace
[HLSVideoEngine] repeat live manifest request held 0.000s, first-serve latch
```

`live --fast-zap --realtime --preroll 0 --seconds 40`, two runs per arm, interleaved:

| seed | arm | first manifest | second request held | `GET /init.mp4` | sustained advance | `item=` at the end | stalls |
|---|---|---|---|---|---|---|---|
| `h264-ts-sample.ts` (2 s cuts) | off | 3.76 to 3.94 s, 2 segments | 2.003 s | 6.10 to 6.14 s | 7.4 to 7.7 s | 34.78 to 34.95 s | 0 |
| `h264-ts-sample.ts` | on | 3.94 s, 2 segments | 0.000 s | 4.08 s | 5.2 to 5.3 s | 36.57 to 37.20 s | 0 |
| 1080p59.94, 1 s GOP | off | 1.22 to 1.23 s, 3 segments | 1.011 s | 2.43 s | 3.2 s | 38.30 to 38.40 s | 0 |
| 1080p59.94, 1 s GOP | on | 1.24 s, 3 segments | 0.000 s | 1.41 to 1.44 s | 1.1 s | 39.19 to 39.30 s | 0 |

The latch removes exactly the grace, and the session ends that much closer to the edge. On the device that cost no stall.

The full matrix (6 s and 10 s segments, 3, 4 and 8 listed, both profiles, three runs per arm) is in `api.md` under the live join. `.standard` adds `--standard-join` to the `play` line.

**Sound against picture, in the bytes.** `play --served-url` hands over the init segment, the cache holds the rest, and decoding their concatenation gives the presentation time of every flash and every beep onset. 147 of 148 seconds of a served session read **-0.3 ms** (the very first beep reads +19.7 ms, the decoder starting), across a 12 s outage, with no audio frame of any duration but 1024 samples and no gap at any segment seam. A fresh item re-fetches the same cached segments, so a rebuild cannot change that.

What a rebuild does change is which segment the item starts on and where in it. A segment's sound does not begin where its picture does: the cut is taken on the video keyframe, and a transport stream interleaves audio behind video. On this fixture the sound opens between 11 ms after and 208 ms before the picture, segment by segment. Each item now says what it started on:

```
[AetherEngine] #684 item #1 starts at its own 4.000s: segment 2 + 0.000s, whose picture
  opens at 4.000s and whose sound runs 3.979..5.963s (it opens 21 ms before the picture)
```

Each `live seg-N finalized` line carries `sound=first..last`.

The PICTURE half is measurable here: the same origin over a 24 fps twin that carries `Scripts/timecode-fixture.sh`'s block row, `play --picture-probe`, and an outage long enough to close the window (`--freeze-at 14 --freeze-seconds 14`). Four runs, each rebuilt with `#EXT-X-START:TIME-OFFSET=41.95,PRECISE=YES` at `segment 34 + 1.95s`, each fetching seg31 first, whose sound opens 208 ms before its picture. `axisErr` reads +12.000 on all 70 ticks of the first item, and +40.000 on all 38 of the rebuilt one, whose playlist begins 28 s later. The picture sits on the item clock to the frame on both. So AVPlayer does not anchor an item on the earliest sample of the first segment it loads, and a mid-segment placement moves nothing on the video side.

**What AVPlayer's audio renderer makes of it is not observable from a Mac.** An `MTAudioProcessingTap` on an HLS item is created without error and never called (0 callbacks in 12 s), and capturing the output needs a grant no headless run has. A report of sound and picture drifting apart after a rebuild therefore needs:

- a device,
- this fixture (a beep that should land on a flash is the one sync test a viewer can read without instruments),
- the three log lines: the `#454 placing` line, the `#684 item` line, and the AE#440 line that says whether the start was forced.

### play: resume landing (AE#724)

Measured: a resume on a long-GOP source moved the software host's clock back to the keyframe's first audio sample, up to a GOP before the target. The clock now stays on the resume target.

Current rule: [cli.md › Resume landing](cli.md#resume-landing-ae724). Fixture and commands are there (`gop240.mp4`, `play --sw --start-position 17.3`).

The plain clock-advances check could not see AE#724, because the broken session kept advancing, only from the wrong place. A resume on a long-GOP source repositions to the keyframe before its target, so its first decoded audio sample arrives up to a GOP early, and the software host used to move its clock back onto that sample. Ten-second GOPs reproduce it; two-second ones never do.

Before the fix both read `clock re-anchored to first sample: anchor=9.984s (load anchor 17.300s ...)` and `cur=10.8` at the first tick. After it: `cur=18.2` and no re-anchor.

`--paused` alone (no `play`) is not judged, but its ticks are the observable for the second half of the same report. A paused resume read `cur=0.00` until play, because the host published its still unarmed synchronizer over the anchor. It now reads `cur=17.30`.

### `customio --live` spool (AE#445, AE#460, AE#461)

Measured: the custom-source live harness found that host reader callbacks ran on the pump's undrained thread (AE#445), and its reload arms showed two reloads that ignored what they were asked (AE#460, AE#461).

Current rule: [cli.md › The `--live` spool](cli.md#the---live-spool-ae445).

**Why the harness exists (AE#445).** Before AE#445 the custom-source live shape had no harness at all. The defect it found (host reader callbacks ran on the pump's undrained thread) was reachable by every custom reader and visible to none of the engine's own buckets.

**The reader arms.** AE#445 round 1 shipped only the Foundation arm and measured ratio 1.00 before the bridge pool and 0.00 after, which looked like the reporter's defect reproduced and fixed. It was not: his adapter `pread`s and allocates nothing, so the run had reproduced the harness's own retention with his signature. A harness that brings the cause with it matches the shape and answers a different question. Only a second arm that allocates nothing can tell those apart.

**`--reload-at` before the AE#460 follow-up.** Before that follow-up, the `--reload-at` run reported 15.0 MB (61 s of source) and a playhead of 1.90 s: the reopen rewound the host's spool to its base and re-read the whole delivered window.

**`--reload-decode-path` before the AE#461 follow-up.** Before that follow-up, the `--reload-decode-path` run logged `#460: reload applying preferredDecodePath` and then `backend native -> native, decoder=VideoToolbox H264 (HW)`: accepted, named in the log, ignored.

**`--host-carry` (AE#445 round 3).** Round 3's census on the reporter's device pinned his footprint to ONE `REALLOC`-tagged block, growing on an exact x1.25 ladder and holding every byte the session had consumed. That factor is Foundation's: `Data` grows a large buffer by `newLength >> 2`, while `av_fast_realloc` adds a sixteenth and FFmpeg's AVIO dynamic buffer a half. So the block is a Swift `Data`. The one `Data` shape that grows like that while its `count` stays tiny is a parse carry consumed from the front with `removeFirst`. That only advances the slice's lower bound and leaves the backing store holding everything below it.

### `audiotap --software` (#400)

`audiotap --software` exists because the software audio path had no harness, and that gap was real: a multichannel trap shipped (#400).

Current rule: [cli.md › audiotap](cli.md#audiotap).

With no harness here, a force unwrap that trapped on the FIRST buffer of any multichannel track shipped in 6.1.3 and survived to main (#400). The silent-downmix defect under it only showed once the trap was gone.

## Engine architecture

Measurements behind [architecture.md](architecture.md), [architecture-native.md](architecture-native.md) and [architecture-software.md](architecture-software.md).

### Segment cutting by decode time

Observed: comparing a packet's DTS against PTS-valued boundaries split GOPs across segments and showed blocky corruption after a rebuffer. That is why every segment now opens on its own random-access point.

Current rule: [architecture-native.md › Cutting segments at runtime](architecture-native.md#cutting-segments-at-runtime).

The earlier code assigned each packet to a segment by its DTS against PTS-valued boundaries. With B-frame reorder, a keyframe whose DTS trailed its PTS fell into the previous segment, so the next segment started mid-GOP and depended on its predecessor. A fresh decode at that boundary (rebuffer recovery) showed brief blocky corruption (#92).

### Native scrub picture latency

Measured: on a native AVKit scrub the picture arrives a fetch and a decode after the producer restart drains, 1.4 s on a WAN source in the reporting host's capture. So a scrub's window ends when the picture reaches the restarted region, not when the restart drains.

Current rule: [architecture-native.md › Seek events](architecture-native.md#seek-events).

### Lost subtitle selection after a background teardown

Observed: a background teardown lost an explicitly picked subtitle track, because the reload took its snapshot after the teardown had wiped the state. The same split broke the native host shell (Sodalite#149). That is why a teardown now hands its state to the reload that follows it.

Current rule: [architecture-native.md › What a teardown hands the reload that follows it](architecture-native.md#what-a-teardown-hands-the-reload-that-follows-it).

Every reload path snapshots the state it restores (the #170 subtitle carryover, the audio pick, the disc title) right before its own `stopInternal`. That only works while teardown and reload are the same call. The background path splits them: it tears down when the app sleeps and reloads on return. So the reload's snapshot ran long after the state was wiped, and restored nothing.

For subtitles that left the rebuilt session without a drain target: no cue was delivered and every delivery log stayed silent, which looked like a delivery bug rather than a lost selection. Only an explicitly picked track was lost; an auto-picked one came back through the reload's re-run of preferred-language selection.

The native host shell had the same split (Sodalite#149): checking `playbackBackend` alone threw away the `NativeAVPlayerHost` the teardown had kept, and the viewer came back from a tvOS screensaver to playing video with a dead system Now-Playing card.

### Dual-layer in-place output metadata

Measured on the Mac only: writing output metadata in place changes no pixel, so the dual-layer base-layer decoder does it (`allowsInPlaceOutputMetadata`).

Current rule: [architecture-software.md › VideoToolbox output metadata](architecture-software.md#videotoolbox-output-metadata).

The check: 240 frames of two real FEL clips were bit-identical with and without the copy. A long-GOP picture comparison on the Apple TV decoder is still open.

### HDR10 metadata on the software path reaches the television (AE#957)

Measured on an Apple TV 4K (A12, tvOS 27.2) into an LG OLED77G4 on 2026-11-13: mastering display and content light level attached to the buffers given to `AVSampleBufferDisplayLayer` reach the television, on VideoToolbox's buffers and on buffers the engine rendered itself.

Current rule: [architecture-software.md › HDR10 pass-through probe](architecture-software.md#hdr10-pass-through-probe).

The check: the probe's pulse modes switch the metadata every 3 s on an unchanged picture. Filmed with the exposure locked, the ratio of the 4000 to the 1500 nit patch follows each switch about 2 s later, as it does when AVPlayer switches between a 1000 and a 4000 nit clip. Numbers and method: [`Probes/HDR10PassThrough`](../Probes/HDR10PassThrough/README.md). Also found: VideoToolbox attaches no HDR10 metadata to the frames it decodes, so the software path today sends none.

### Software channel layout mismatch

Measured per channel: a channel layout tag that disagreed with the resampler's order misplaced every layout except 5.0 and 5.1. The tag and the resampler layout now come from functions held against each other by a test.

Current rule: [architecture-software.md › Audio channel layout and timestamps](architecture-software.md#audio-channel-layout-and-timestamps).

**The channel layout on the format description must name the order the resampler wrote** (#401). `AudioDecoder` resamples into the layout from `makeResamplerOutputLayout` and stamps the tag from `audioChannelLayoutTag`. If the two disagree, the renderer places audio where the decoder never put it. Measured per channel, the earlier pairing:

- moved every channel of a 7.1 track and put the LFE hard left at full gain,
- put a 4.0 centre hard left,
- mixed a 2.1 LFE into both channels instead of dropping it.

Only 5.0 and 5.1 lined up, which is why nobody noticed. The two functions now live side by side, and a test holds them against each other twice: once structurally, and once by rendering each channel through a real downmix. 6.1 is the one channel count CoreAudio has no matching tag for, so the resampler is pointed at 6.1(back) rather than leaving the common tags for a `UseChannelDescriptions` layout.

### Parked video read wait

Observed on sources slower than real time (AE#1025): the on-demand loop paused at the wrong times, starved the renderer while it waited, and resumed 2 s late. Three rules came out of it: a pause arm, a 20 ms cap on the parked read wait, and a full layer counting as ready on resume.

Current rule: [architecture-software.md › Rebuffering on the on-demand loop](architecture-software.md#rebuffering-on-the-on-demand-loop).

- The on-demand loop pauses only once its pause arm is open: the source has either built `AudioLookaheadPolicy.rebufferResumeLeadSeconds` of lead once, or let the clock run `starvedLeadSeconds` (one second) past the last audio fed (AE#1025). The first keeps an exactly-realtime origin, whose lead sits at its start offset, from pausing at every start. The second catches a source slower than real time from the first byte, which never builds that lead and used to run the clock on over a starved read-ahead with the phase at `.playing`. A seek closes the arm again.
- While video is parked, the on-demand loop's read waits at most `parkedVideoReadWaitSeconds` (20 ms) for the source before it hands parked video to the renderer again. The loop is the only thread that does that, so an unbounded wait on a slow source let the renderer run dry and fed it a third of the frame rate (AE#1025).
- The resume after such a pause starts the clock through the video preroll, and a full layer counts as ready there (`SampleBufferRenderer.prerollSatisfied`): the frames handed over sit at or behind the stopped clock and nothing more fits until it runs, so the gate used to wait out `AudioOutput.prerollTimeout` and the clock stood 2 s longer with the phase already back at `.playing`. A start or a seek begins with a flushed layer and still waits for `videoPrerollSeconds`.

### Live pause read as playing

Observed: before the current `playbackPhase` rule, a live source that merely paused read as `.playing` over a still picture for the whole reader stall timeout. Only the reader's reconnect promoted it to `.stalled`.

Current rule: [architecture.md › Playback status (`playbackPhase`)](architecture.md#playback-status-playbackphase).

By then a host app watching the clock had already reloaded the session, and the fresh join behind the same frozen burst replayed what it had just shown.

### Audio host buffering axis

Observed: up to and including 6.30.1 the audio host fed no buffering axis at all. A dead progressive stream (an internet-radio origin dropping the connection) stayed `.playing` with a frozen clock, and a host had nothing but the clock to watch.

Current rule: [architecture.md › Playback status (`playbackPhase`)](architecture.md#playback-status-playbackphase).

### Reader stall hidden behind seeking

Measured on a killed LAN origin: the engine's own recovery seeks hid the outage for 29 s and 41 s. So the reader axis now outranks `isSeeking`.

Current rule: [architecture.md › Playback status (`playbackPhase`)](architecture.md#playback-status-playbackphase).

**The reader axis outranks `isSeeking` (#410).** A seek cannot land on a source that stopped delivering, so the seek level stays up as long as the seek stays alive, and that seek is not always the host's. The producer's restart coalescer issues its own `nativeScrub` seeks while recovering, so the engine's own recovery used to hide the outage it was recovering from (measured at 29 s and 41 s on a killed LAN origin). A seek stays visible through `isSeeking` and `seekEvents`; the reader axis is visible nowhere else. On a delivering source nothing changes: the reader is `flowing` and a seek reads `.seeking` as before.

- The flag is `true` while the reader retries, and `false` once it has used up its retry ladder (#410). Then the reader is out of the read, the producer's reopen owns the recovery, and the source is still down. Before, the dying reader reported `flowing` on its way out (only so the next reader's dedupe gate could not strand the phase), and the whole reopen window looked like a healthy source.

- A metered detour fetch (429 / 503 / 509 on the arm that carries a throttling origin, #69/#71) now reports `reconnecting`, and its give-up reports `exhausted`. Before, it charged the ladder but told the axis nothing.

### tvOS packet cache disk appends

Measured on an Apple TV 4K: the disk store's appends took 100 to 600 ms while a download ran. That is why the rule below keeps the tvOS packet cache off disk.

Current rule: [architecture-software.md › Storage](architecture-software.md#storage).

The demux thread stalled behind those appends, and video it had already parked reached the decoder late. AVPlayer also keeps its progressive-download cache in memory on tvOS.

### Packet cache producer QoS

Measured on an idle M1: a producer kept in the efficiency class drains about a third of what a responsive one does. So the producer's priority adapts to its reserve instead of staying demoted.

Current rule: [architecture-software.md › Producer thread priority](architecture-software.md#producer-thread-priority).

**Why not stay demoted.** A permanently demoted producer is a priority inversion the scheduler cannot see: the consumer waits on an `NSCondition`, and a condition donates no priority to the thread it waits for. It costs throughput, not only fairness. On an idle 8-core M1 with negligible consumer decode cost, the efficiency-class producer drained 147 MB of an 80 Mbit/s source in 60 s, where the responsive one drained 438 MB, with seven cores free the whole time. Lifting only the thread's disk-I/O policy on the same class brought it to 528 MB. So the cause is the class throttling the spool writes the producer makes for every packet, and it needs no CPU contention.

**What the adaptive choice keeps.** Over a 100 s steady state it keeps 2165 ms of efficiency-class CPU, against 2145 ms for a permanently demoted producer and 1 ms for a permanently responsive one, at identical total CPU.

### Cooperative pool exhaustion on CI

Observed on CI: blocking work parked every thread of Swift's cooperative pool (the shared thread pool async tasks run on) for half a minute at a time. So the full suite has to pass with the pool narrowed to one thread.

Current rule: [architecture.md › Blocking work and the cooperative pool](architecture.md#blocking-work-and-the-cooperative-pool).

**Background.** On a 3-core runner the suite parked all three pool threads for half a minute at a time, until a 120 s time limit fired at 151 s: the time limit's watchdog is a task on the same pool. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` narrows the pool to one thread and reproduces this on any Mac. The full suite has to pass under it.

### MP4 without composition offsets

Measured through AVFoundation's own decoder: an MP4 without composition offsets, on a stream that reorders pictures, shows 45 of 66 pictures at another picture's time. That is why the native route repairs these files.

Current rule: [architecture-native.md › MP4 without composition offsets](architecture-native.md#mp4-without-composition-offsets).

**The problem.** Some writers emit a sample table with no `ctts` while the H.264 or HEVC bitstream still reorders pictures. Every sample then reports `PTS == DTS`. The native route stream-copies those timestamps into fMP4, so AVPlayer is handed decode order as presentation order: each future reference picture is shown before the B pictures that come before it. Measured through AVFoundation's own decoder on a twin pair (one encode muxed twice, composition offsets removed from one): 45 of 66 pictures landed at a time belonging to a different picture, and the content order stepped backwards 30 times (#409).

Reported by @orut34iop; the HEVC case (#699) by @ijuniorfu.

### Writers that push timestamps

Measured on three reporting files: writers that push decode-order timestamps to keep them monotonic leave B pictures out of order in every player. These readings set the repair's limits: how late a keyframe may be pushed, how far the cutter reaches back, how many pictures a head is sampled for, and the shift clamp.

Current rule: [architecture-native.md › Writers that push timestamps to keep them monotonic](architecture-native.md#writers-that-push-timestamps-to-keep-them-monotonic).

**The problem.** Some writers go one step further: after dropping `ctts` they force the decode-order presentation times to be monotonic. Each B picture (and on some files each anchor too) decoded after another picture is pushed 1001 ticks (at 90 kHz, a third of a 29.97 fps frame) past the picture before it. There is then no ladder to read a step from. The reporting file (H.264 High, 720p, GOP 90) stepped 3003 on 87% of its samples and 1001, 2252, 9009 or 12012 on the rest. The probe skipped it as non-uniform, and QuickTime, the Files app and both engine routes showed the B pictures out of order.

The VUI (the frame-rate field in the stream's own parameter sets) is what tells 24 from 23.976 on a short clip whose pushed tail drags the average. On all three reporting files it named the exact rate (23, 29.97 and 29.0002 fps).

**Pushed keyframes.** The writer pushes keyframes as well, and only ever later. On both reporting files they sat 0 to 4 pictures after the end of the GOP before them, which left a gap or put the next GOP in front of the last pictures of the previous one. So a later IDR continues the sequence before it. The exception is an IDR later than the reorder delay plus two and a half pictures, which is a real discontinuity. A third reporting file at 29 fps kept its keyframes four pictures late for a hundred seconds.

**Clock drift.** Counting alone follows the stated rate, and the writer's clock is not quite that (the third file states 29.0002 fps and writes 29.003). The chain drifted 61 ms behind the writer over 19 minutes and overlapped 3 times where an earlier keyframe pulled it back. A continued sequence therefore also leans toward the earliest origin the pictures before it point to, by at most an eighth of a picture per GOP, which removed both. (The writer only ever pushes a picture later, so the earliest origin is the nearest the truth.) A seek landing holds its first **8 pictures** and takes the earliest origin they point to in the same way.

**Segment boundaries.** A keyframe placed back like this sits before its index entry, by at most the reorder delay plus two and a half pictures, while the HLS segment plan is built from the index. The VOD cutter and the restart gate therefore reach that far back for the keyframe each boundary names, never as far as the keyframe before it. Without the reach, the keyframe stayed in the previous segment and the next one opened on audio, mid-GOP: `aetherctl segverify` counted that on 25 of 40 segments of the 23 fps file and 22 of the 29.97 fps one. All 40 are independent now, and so are segments a restart produced.

**Long P runs.** The second reporting file opens every GOP on twelve P pictures before its first B. So a head that has not reordered after twelve pictures, with `PTS == DTS` throughout, is sampled on to its first regression plus a mini-GOP, up to
**48 pictures**. The sampled span is checked against the rounded step with a tick per picture to spare, which is what the third file's head needed.

**Shift clamp.** The shift is what puts the first keyframe on the stream's start time. It is clamped to **16 pictures** because this writer left the keyframe four pictures ahead.

### Clamped timestamp ladders

Measured: the repair for clamped timestamp ladders takes every generated twin from up to 169 backward steps to 0.

Current rule: [architecture-native.md › Writers that push timestamps to keep them monotonic](architecture-native.md#writers-that-push-timestamps-to-keep-them-monotonic).

**Measured** on generated twins from `Scripts/make-clamped-ladder-fixture.sh` (900 pictures at 29.97 fps):

| Fixture | Before | After |
| --- | --- | --- |
| Base twin, AVPlayer route | 169 backward steps | 0 |
| Base twin, software route | 44 backward steps | 0 |
| `pushed-anchors.mp4` (pushes the anchors too) | left untouched ("anchors do not agree on a step"), 44 backward steps on the software route | repaired, 0 |
| `p-run-clamped.mp4` (x264 CLI only, twelve P pictures opening every GOP) | 99 of 239 backward steps | 0 |

The repaired fixtures now demux to the healthy twin's timestamps, including the GOP whose keyframe the clamp pushed.

### Matroska slots in coding order

Measured on a generated twin: a Matroska writer that hands out presentation slots in coding order makes 15 of 30 frame times step backwards. The repair moves each slot to the picture displayed there, which takes that to 0.

Current rule: [architecture-native.md › Matroska with presentation slots in coding order](architecture-native.md#matroska-with-presentation-slots-in-coding-order).

**The problem.** Matroska block timestamps are presentation timestamps by specification, and the format has no composition-offset table to lose. A writer that fills them packet by packet while the bitstream reorders pictures has therefore not lost anything: every presentation slot is still in the file. Each one just arrived attached to the picture that was *decoded* at that position rather than the one that is *displayed* there. On the reporting asset the first slots are 0, 40, 73, 107, 140, and the decoder emitted them as 0, 73, 107, 140, 40: one stepped-back presentation clock per mini-GOP for the length of the file. Measured through the engine's own software decoder on a generated twin, 15 of 30 frame times stepped backwards before the repair and 0 after (#511).

- Nothing fits a cadence. A ladder quantized from a fractional frame rate is reproduced exactly rather than to within a tick, and a slot the writer clamped onto its cluster origin survives as written (the reporting asset has one, 7 ticks below the 1001/30 lattice its other 59 slots sit on).

**Latency.** The slot a picture needs is a packet away, not a plan away. A picture coded ahead of the slot it owns waits for the packet carrying that slot, which is the mini-GOP reorder: three video packets on the reporting asset, in a 60-picture sequence. Nothing waits for the end of a sequence.

### Subtitle side reader link sharing

Current rule: [architecture-native.md › Sharing the link with video](architecture-native.md#sharing-the-link-with-video).

Measured on a bench with 1.4x link headroom: giving video priority over the subtitle side reader improved far-seek landings about 45% at the median and halved the side reader's share of the link.

### Subtitle cue pipeline reports

Field reports behind the subtitle cue pipeline: each paragraph below names the rule a report set and what the viewer saw before it (the "report:" figures).

Current rule: [architecture-native.md › Subtitle cue pipeline](architecture-native.md#subtitle-cue-pipeline).

**Reading from 15 s behind the landing (AE#1022).** Every session reads from 15 s behind its landing, in either role. Before, it read from 2 s behind and claimed its coverage only from the landing itself, so a set that began just before a start position or a far seek stayed unproven at any reach.

**Ending a PGS cue at the next stored packet.** Without that close, the drain window's forward edge decides the end whenever it falls between a set and its clear: the set publishes open, the cursor moves past it, and the next thing to touch it is a composition at the next landing, tens or hundreds of seconds later (report: 3.55 s authored, 76.7 s delivered, and 817 s in the same session).

Where the store genuinely has nothing after a set (its harvest frontier, a stream cut short), the cue stays open and #357's boundary close still owns it. Inventing an end there is the laundering this replaced.

**The last resort: the seek boundary (#357).** A seek can outrun the successor, and the retention prune cannot help (it filters on `endTime`, which a placeholder end never ages out of). So a jump past an open cue used to leave it in the published window, covering the new playhead until the next composition displaced it. On a seek, the drain now closes every still-open cue that began before its reconstruction window (playhead minus the 15 s backscan) at that window's start: past that line nothing is re-decoded, so nothing there can be confirmed as still open.

**Holes in the packet store.** After a seek, the pump restarts behind the landing and fills forward, while the store still holds an island the previous run harvested further ahead. The drain window then reads as "packets, hole, packets". Decoding across that hole carries the drain cursor to its far side, and the cursor only moves forward: the hole's packets land a second later and are never read. A stretch of the film then carries no subtitles at all until some later seek resets the window behind it, and the set before the hole is closed at the island rather than at its own clear (report: eleven authored sets delivered as two).

There is no other tick budget (#941 round 3). Ticks once ran on wall time and expired during seeks and rebuffers while the playhead stood still, which decoded the island over the sets the refill was about to harvest.

**Three runs meeting (#941).** Harvest order (the drain stops where the store's packet sequence runs backwards, the sign of two runs meeting) still sees only half of it. Seek past the producer's front and straight back into the stretch that jump skipped, and three runs meet: the original one up to just past the landing, the forward one's island further on, and the restart behind the landing that has not written anything yet. The island was harvested after the near side, so the sequence ASCENDS across the hole, no pair descends, and the first tick decoded straight across, losing every set the restart then harvested in between (report: seven consecutive sets on a 1x link). A re-harvest of the island does the same to a wait that did fire, because it stamps the island newer than the held position.

**The ledger decides alone (#1021).** Order also sees holes that are not there. A track selected at load starts the forward prefetch with the session, so the prefetch stores the next 75 s first. The main reader then reads each of those packets again a few seconds ahead of the playhead, and a re-harvest takes the fresh sequence. Every pair at the main reader's front descends, and the drain stopped at each one: it never got more than about 4 s ahead of the playhead, so a host's advance offset showed nothing until the first seek.

**Release on the far side.** A wait now ends when the playhead closes on the FAR side of the hole (within `subtitleDrainHarvestGapReleaseLeadSeconds`), not on the near one. A refill at about 1x keeps the playhead just behind the filling run, so it passes the last packet before the hole while the hole is still ahead, and releasing there decoded the island over the sets the refill was a second from harvesting.

**The landing after a seek.** A hole behind the playhead has a third face: the landing itself. The gate that reconstructs the active line at a seek target seeds it from the newest set decoded behind the playhead, and that set is the active line only if nothing on its stream happened in between. The store's silence is read as that proof, and over a stretch nobody read, it proves nothing. A run re-aimed just after it harvested a set leaves that set's own clear on the far side of the skipped ground. The set then decodes at the landing looking unclosed and publishes over the new scene, ending at the next stored packet, which is the far side of the authored silence rather than its own successor (report: a two-second sound-effect caption standing ten seconds over the wrong scene, on both an Apple TV 4K and a Mac).

## Host API

Measurements and API history behind [api.md](api.md).

### The clock after `.ended`

Measured: two paths kept their clock running past the end of media, so a session left standing after `.ended` published a growing position. Both park now.

Current rule: [api.md › `.ended` is terminal](api.md#ended-is-terminal).

- Through 6.28.0 the software path's master clock kept its rate past end of media, so a session left standing published a position that grew without bound (20.13 s on a 12.0 s source after 20 s, against 11.97 s from a native session on the same file). A host reading the clock after `.ended` on those builds sees that, not a drifting session (AE#374).
- The audio-only path (a source without a video track, decoded through FFmpeg) had the same defect through 7.27.0 and parks the same way since (AE#694).

### Live resume clamp

Measured: a live resume whose position had slid out of the window moved silently. That is why `liveResumeClamped` exists.

Current rule: [api.md › Live: a resume that had to move](api.md#live-a-resume-that-had-to-move).

On the harness, with a 30 s window and a 70 s pause, the playhead sat at 93881.2, the window slid to 93890.0...93920.0 underneath it, and the resume landed at 93895.0 without a word. A viewer who paused a match came back to it continuing somewhere else, with nothing on screen to say why.

### Live join: sealing over the upstream segment

Measured against late-delivering origins: sealing a live join over the whole upstream segment cuts `-12888` errors and stalls, at the cost of a deeper holdback. The seal (the TARGETDURATION the engine serves, which sets the holdback AVPlayer keeps behind the live edge) is bounded by what the join pays for.

Current rule: [api.md › Where a live start's seconds go](api.md#where-a-live-starts-seconds-go).

`.fastZap` carries 1.5 x GOP headroom because a broadcast whose GOPs ran 1.0 to 2.4 s sealed TARGETDURATION 1 on its first three GOPs and then broke `EXTINF <= TD` on every longer one (AE#670).

#### An ingested HLS upstream: sealing over the whole upstream segment (AE#684)

**An ingested HLS upstream seals over the segment it is delivered in, as far as its join pays for it, under either profile.**

The engine re-cuts an upstream segment (at its GOPs under `.fastZap`, at about 4 s under `.standard`). But the window still changes only once per UPSTREAM segment. So what the seal asks for is the longest segment the upstream has served, whole. (`ceil(segment / 1.5)` used to leave the client a patience of exactly one delivery.) The upstream's advertised target duration is still not read.

The seal is bounded three ways:

1. **By the join, which is not deepened for it on an upstream of uniform segment length.** A seal is a holdback of `3 x` itself, and the join there is the three upstream segments it was before. (One more would be one more download before the first picture on every zap, which AE#678 measured and declined.) Their last GOP stays open until the next delivery, so three 6 s segments are 18 s joined and 16 s cut: the seal is 5, the largest value whose holdback that window holds, not 6. Three 10 s segments cut 28 s and seal 9.
2. **By a ceiling.** Segments longer than 10 s (`LiveEdgePolicy.upstreamSegmentSealCeilingSeconds`) are not asked for whole: a 20 s one seals 14, as it did before, because the live-only window is 60 s.
3. **Never under what it was.** Where the old value already covered the segment nothing moves: 2 s segments keep 2 and a 6 s holdback, and `.standard` keeps its 6 on anything up to 6 s.

**Alternating segment lengths.** The one addition to the join is that it is equalised over the PHASES of an upstream whose segment lengths alternate: a tune never loads more than the deepest tune of the same channel already did.

- Before: alternating 6 s and 4 s segments joined four (20 s listed, 18 s cut, seal 6) with a 4 s one newest, and three (16 s listed, 14 s cut, seal 4, as in 7.25.1) with a 6 s one newest. So the same channel behaved differently from one tune to the next.
- Now: the depth is the deepest the coverage rule takes over the tune itself and the tunes one, two, ... segments earlier that its own join still reaches, at most one segment above its own. Both phases join four and seal 6.
- Cost: the three-segment phase (about four tunes in ten on that shape) loads one additional short segment at the join, which the other six already load. 3.47 s to 4.23 s to first picture behind an 8 Mbit/s link, median of five, against 4.27 s in the other phase on either build.
- Shapes whose phases already joined alike keep their join and what it pays: 10 s / 8 s stays at three segments and seals 8 (7 before); 6 s / 6 s / 4 s stays at three and seals 4, unchanged; a shape like 6 s / 5 s keeps a seal that follows the phase (5 in one, 4 in the other), because equalising is about how much a tune loads, not about what it seals.

**What the log says.** The seal line says what was paid (`of which the join pays 5s of 6s (16.000s cut of the 18.000s it listed)`). "The join has no more to give" is a fact the reader states (its join batch is handed over and its consumer is waiting), not arithmetic on EXTINF, which a playlist that rounds its durations up would fail.

**Demuxed audio.** With a demuxed audio rendition the fact is the cutter's rather than one reader's: both join batches handed over and the cutter waiting on either of them. An audio rendition whose segments end a little before the video's runs dry first, and the video reader is then never the one being waited on. Measured with three runs per arm on three listed segments, audio aligned and audio 0.2 s short: first picture 0.18 to 0.21 s against 0.17 to 0.36 s on 7.25.1, TD 5 on 6 s and 9 on 10 s under both profiles.

**A slow join.** A join that is SLOWER than the `.fastZap` grace (a single-connection provider or a slow link) takes the bounded start before the grace is spent, and then seals the full value (6 or 10, not 5 or 9) over a window shorter than its holdback. AVPlayer notes that with a `-16832` warning at the start. Measured one request at a time behind a 4 to 5 Mbit/s link, that start is not worse than 7.25.1's: first picture 5.05 to 6.08 s against 7.05 to 8.26 s, no `-12888` where 7.25.1 drew 1 to 3.

**Net effect on the seal and holdback:**

| Upstream | Before | Now |
| --- | --- | --- |
| uniform 6 s, `.fastZap` | seal 4 (holdback 12 s) | seal 5 (holdback 15 s) |
| uniform 10 s, either profile | seal 7 (21 s) | seal 9 (27 s) |
| alternating 6 s / 4 s, both phases | seal 4 (12 s) | seal 6 (18 s) |
| 3 s segments with 1 s GOPs | seal 2 | unchanged at 2: three joined segments cut 8 s, which pays for no more, so the patience of one delivery this issue is about stays as it is there |

**Costs.**

- **Time to first picture on uniform upstreams** (the join, and with a host that fetches in parallel the time to the first picture) is what it was. Behind an 8 Mbit/s link, three runs per arm: 3.81 to 4.04 s before and 3.80 to 3.85 s after on 6 s segments; 6.15 to 6.36 s and 6.18 to 6.28 s on 10 s ones.
- **A host that allows fewer parallel requests than the join has segments** (`maxConcurrentSourceRequests` of 3 or less) sees its first picture later than before. The gate now waits for the join to be handed over, where it used to serve at 12 s of cut content. One request at a time behind 14 Mbit/s on the mixed shape, three runs per arm: 2.79 to 3.08 s before and 3.27 to 3.28 s after in the four-segment phase; 2.80 to 2.83 s and 3.44 to 3.49 s in the phase that now also loads the extra segment.
- **Standing latency** behind the upstream's edge: 3 s more on uniform 6 s segments, 6 s on alternating 6 s / 4 s and on 10 s ones, 3 s on 10 s / 8 s.

**Measurements.** On loopback against `Scripts/hls-burst-origin.py` (deliveries 3 to 9.3 s apart on 6 s segments), 60 s per run, three runs per arm and row, 7.25.1 against this. First picture is 0.17 to 0.51 s in both arms wherever a row does not say otherwise:

| upstream, profile, segments listed | 7.25.1 | now |
|---|---|---|
| 6 s, `.fastZap`, 3 | TD 4, 1 x `-12888` per run, 2 stalls in 3 runs | TD 5, none |
| 6 s, `.fastZap`, 4 | TD 4, 2 x `-12888` per run, 2 stalls in 3 runs | TD 5, 1 to 2 x `-12888`, no stall |
| 6 s, `.fastZap`, 8 | TD 4, 1 to 3 x `-12888`, 3 stalls in 3 runs | TD 5, 0 to 2 x `-12888`, no stall |
| 10 s, `.fastZap`, 3 / 4 / 8 | TD 7, 1 x `-12888` in 7 of 9 runs, window closed and item rebuilt in 4 of 9 | TD 9, none in 9 of 9 |
| 10 s, `.standard`, 3 / 8 | TD 7, item rebuilt in 6 of 6 runs | TD 9, none in 6 of 6 |
| 6 s, `.standard`, 3 / 8 | TD 6, first picture 6.18 to 6.53 s | unchanged: TD 6, 6.28 to 6.46 s |

**What it does not do:**

- On a 6 s provider `-12888` still comes. Over one 180 s run: 5 of them and a stall before, 3 and no stall after. 7.5 s of patience still loses to a 9 s gap; what changed is the holdback under it. (A join one segment deeper seals 6 and drew none in three such runs; it was measured and not shipped, for the download it costs.)
- `.standard` on 6 s segments still takes about 6.3 s to its first picture, waiting for the next upstream segment, exactly as before. Its seal there is its own `1.5 x cut target` floor, which three joined segments never covered.
- A real outage longer than the holdback's low point stalls under any of these. The capture that started this had 10 of its 110 delivery gaps above 9 s.

### Live join: filling the cushion from the origin's window

Measured: joining deeper into an origin's own window takes the first picture from 2.22 s to 0.20 s on 2 s segments, so the join fills its cushion from that window (6.77.0).

Current rule: [api.md › An HLS source with its own window fills the cushion at the join](api.md#an-hls-source-with-its-own-window-fills-the-cushion-at-the-join).

#### An HLS source with its own window fills the cushion at the join (6.77.0)

**An HLS source with a window of its own fills that cushion at the join rather than in wall clock.**

The ingest used to enter a live playlist three segments behind the edge. Three joined segments finalize only two downstream, because the last one stays open until the next arrives. The cushion wants three, so the gate then waited one upstream segment duration for content the origin was already holding in its window. The join now takes the coverage its own policy always targeted, which on short segments is several times three.

Measured against `hlsfixture --window 8` with `play --live --fast-zap`, three runs per row:

| Channel | First picture before | After |
| --- | --- | --- |
| 2 s segments | **2.22 s** | **0.20 s** |
| 1 s segments | **0.41 to 1.22 s** | **0.18 to 0.20 s** |

The spread is the second half of the finding: before the change, the number depended on where in the upstream segment cycle the tune landed.

- A window at the three-segment floor has nothing deeper to offer and is unchanged. So is a long-segment provider, whose coverage target was already met inside the old bound.
- The deeper entry is not paid back later. Both arms fetch up to the same upstream segment number at the same wall clock, so it is caught up at I/O speed instead of becoming a standing lag behind the live edge.
- It does not touch a source with no playlist at all (raw MPEG-TS over HTTP). There is no window to enter further back into, and the content does not exist yet.

### Live join: the hold after the first serve

Measured on an Apple TV 4K: after a live serve, AVPlayer can hold the first picture still for 1.5 to 2.8 s. `liveJoinStartsImmediately`, on by default since 6.55.0, cuts that tail short.

Current rule: [api.md › The tail after the first serve, and which signal survives it](api.md#the-tail-after-the-first-serve-and-which-signal-survives-it).

#### The tail after the first serve, and which signal survives it

A serve is not motion. After it, AVPlayer can present the first frame, publish `waitingToPlayAtSpecifiedRate` with `AVPlayerWaitingToMinimizeStallsReason`, and hold that frame perfectly still while it decides whether its cushion will sustain playback.

- A host measured 1.5 to 2.8 s of bit-static picture there on 9 of 11 consecutive tunes on an Apple TV 4K, confirmed against an HDMI capture, with the engine's clock advancing throughout (AE#440).
- Nothing on the item shortens it: `preferredForwardBufferDuration` measured inert, because the wait is a rate evaluation and not a buffer target.
- It does not reproduce on a macOS loopback harness in any window geometry. Treat it as a policy of the player on the device, not as something the served playlist can be shaped out of.

Two consequences for a host:

**Key chrome on `$playbackPhase`, not on `state` or `$hasFirstFrameReadyForDisplay`.** Both of those fire before the rate rolls, and honestly so: one is intent and the other is a picture. `playbackPhase` is `.loading` for the whole hold and turns `.playing` on the roll.

**`liveJoinStartsImmediately` cuts the hold short**, once per load, on a live session, over a buffer AVPlayer reports as non-empty and that carries at least 1.5 s ahead of the playhead. It is the other half of the trade `.fastZap` already prices: playback begins on a thinner cushion, so a source that hiccups just after the join rebuffers where it would otherwise have started later and played through. Every later hold in the session keeps AVPlayer's own policy, so a mid-stream rebuffer is untouched.

**It is on by default since 6.55.0**, based on a device A/B. Two runs of ten channel changes on the reported stack, control then lever:

| | control | lever |
|---|---|---|
| press to moving picture, warm | 6.4 / 6.5 / 7.2 s | 4.3 / 4.8 / 5.1 / 5.6 s |
| press to first PICTURE | 3.4-3.9 s | 3.4-3.9 s |
| stalls / dropped frames | 0 / 0 | 0 / 0 |
| cold joins | ~6.5 s | ~6.5 s |

First picture is unchanged, so the lever removes exactly the frozen tail and nothing else. The cold case is untouched, because the guards keep it out of a starved join. Set it `false` to keep AVPlayer's own policy for the join.

**Why a depth and not just the empty flag.** `isPlaybackBufferEmpty` is the precondition `AVPlayer.h` documents, not a measure of safety: one served fragment reads `false` exactly as a four-second cushion does. Sampling the buffer across every hold in the control run above read non-empty with **3.7 to 4.9 s** ahead of the playhead for the hold's whole duration. So the hold on that stack is always AVPlayer waiting on its own rate estimate, never starvation at the edge. That is why cutting it short cost nothing there. It is also why the guard reads the depth: behind the same `false`, a starved join holds a fraction of a second, and starting there would trade a still picture for an immediate stall.

- The depth is the contiguous span ahead of the playhead, so an island past a gap does not count.
- When the floor is not met the engine says so once per load (`leaving the stall-avoidance wait alone (buffer ahead ...s, ...)`), which separates the two mechanisms in a report after the fact.

**And the item has to be able to play (AE#684).** The depth is measured from the item's own `currentTime()`, and before `readyToPlay` that is where the loader began fetching, not where playback will begin. Under an `EXT-X-START` placement (how a rejoin lands a fresh item at the place the session held), AVPlayer fetches from about 6 s below the target first, so the reading is the lookback itself. One device capture shows `buffer ahead 4.00s` from a playhead of 48.00 s on an item placed at 53.908 s, every second of it behind the start, and `playImmediately` 36 ms before the item was ready. It was the one item of five in that capture to be forced, and the one its viewer reported out of sync; that is a correlation, not yet a mechanism.

A hold on an item that cannot play yet is now left alone (`leaving the stall-avoidance wait alone on an item that cannot play yet ...; asked again at readiness`) and decided again when the item becomes ready, from the playhead it really starts on.

### `seekableLiveRange` before it asked the cache

Measured on the loopback harness: a `seekableLiveRange` computed by arithmetic alone over-promised the rewind depth. It now asks the cache.

Current rule: [api.md › The rewind depth a live session really has](api.md#the-rewind-depth-a-live-session-really-has).

`seekableLiveRange` used to be `max(0, edgeTime - dvrWindowSeconds) ... edgeTime`, pure arithmetic that never asked the cache. It over-promised in two regimes:

- **The session's own start.** A session that joined a source already 181 s into its timeline advertised a floor of 0.00 for its whole run; a seek to 0.20 landed at 181.66, the first position ever written. The over-promise is exactly the join offset, so it is small on a source whose timeline starts with the session and large on one that does not.
- **Retention shallower than the window.** With `dvrWindowSeconds: 30` on 1 s segments, the cache kept 24 s, and the advertised bound claimed 30.

### Subtitle offset reach and prefetch cost

Measured with `aetherctl` over HTTP: what a subtitle offset reach and the subtitle prefetch cost in reads from the source.

Current rule: [api.md › Cue retention](api.md#cue-retention).

- **Later-only reach** (`maximumSubtitleAdvanceSeconds = 0`, later range in `maximumSubtitleDelaySeconds`). Measured with `aetherctl` over HTTP on a 70 s, 20 Mbit/s MKV with a PGS set every 3 s, at 48 s: later 60 / earlier 0 kept 16 decoded sets behind the playhead against 6 at a reach of 0, and its prefetch stayed in the landing role (parked after 5 packets), where a reach of 60 read the file to its end a second time (375 MB requested against 215 MB).
- **The forward prefetch (AE#1015).** On a remote MKV or MP4 it downloads the video a second time: a minute of 1080p read 243.6 MB with an embedded SRT selected against 104.5 MB without.
- **The bitmap landing role (AE#1022).** Measured on a 2.7 Mbit/s 1080p MKV over HTTP, four seeks: 168 MB against 87 MB without it, and 299 MB at the default reach.

### API history notes

Short notes on how an API behaved before its current rule. Each note starts with the API it belongs to; the current rule is that API's section in [api.md](api.md).

- **Software-path escalation.** Before 7.9.0 a native item AVPlayer refused on its merits always ended as `.error`; `escalatesToSoftwarePath = false` restores that.
- **Lapsed credentials.** Before the 401/403 ladder, twelve unproductive reconnects took about 80 s with the same refused header.
- **`autoplay` corrections.** Before AE#464 round 4, a correction of `autoplay` spent a teardown: a visible restart bought for a field the rebuild decides for itself.
- **`preferredDecodePath` on a custom source.** It was briefly in neither group: the reopen picked its host from the backend the session was already on, so a decode-path correction on a custom source was accepted, logged and then ignored.
- **Failed corrections on a custom source.** The custom-source branch used to publish its error and return as if the session had come back, so a correction could report success while the session sat in `.error`. It now throws what the rebuild threw, as the URL branch always has.
- **Before `preferredDecodePath` (#461)** the only levers were:
  - `setForceSoftwarePathForTesting`, which is process-global and so drags every concurrent session on a shared engine
  - presenting a custom `IOReader` whose seek fails, which reaches the software host by costing the source its seeks, its mid-session audio switch, its title switch and `reloadAtCurrentPosition` itself
- **FLAC bridge with no output.** Before AE#641 the FLAC route played silently while reporting `.bridged`.
- **`$activeAudioDecoder` before AE#462** was wrong on the software path, where it was built from the probe's track list and so named a decoder that had refused to open.
- **Cancelling a load.** Before cancellation reached the load's budgets, an unreachable live origin held a cancelled load for about 19 s.
- **`.sourceRefused`.** Before it existed, a refusal and a corrupt file both arrived as "Invalid data found when processing input".
- **`.audioBridgeProducedNoOutput`** used to arrive as `.vodSourceFailed`, which reads as a dead source and ends a fallback ladder.
- **`.storageExhausted`** used to arrive as `.vodSourceFailed` or `.audioBridgeProducedNoOutput`.
- **`.sourceFabricatesRanges`.** Such an origin used to play repeated or shifted audio and video, or arrive as `.vodSourceFailed` / `.softwarePipelineFailed`.
- **`.sourceCertificateRejected` on the native path.** The URL error sits under AVFoundation's own error, where nothing used to look.
- **`supportsCacheBackedStills`.** Before AE#605 it was false on every software session, live included.
- **`panelPresentsDolbyVision` and packaging.** 6.72.0 gave the non-DV branch its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, which is why Profile 5, 8.1 and 8.4 serve byte-identical manifests and segments with or without the assertion.
- **The `-15628` stall.** The `-15628` an HDR10-only panel showed on the DV packaging in May 2026 (AE#4) is a stall rather than an item failure, and it is no longer `panelPresentsDolbyVision`'s to own either: the same packaging reaches such a panel with or without it since 6.72.0 / 6.73.0, and it did not reproduce on tvOS 26.6.
