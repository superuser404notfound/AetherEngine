# Partial H.264 MP4 composition-offset regression

**Summary.** A reported H.264 MP4 played normally at the head but juddered persistently after a seek to about 700 s. Its `ctts` (composition offset) table carries real offsets only for the first 3272 samples and zero for the rest, so the later pictures arrive with PTS equal to DTS while their picture order is actually reordered. The fix is a narrow repair policy: it rebuilds presentation order from complete POC (picture order count) rank and the existing timestamp slots, keeps the original DTS, and hands packets back untouched whenever it cannot prove its case. Status: fixed. A generated regression proves the packet and decoder behavior, a privately retained run on the real source passed, and the reporter verified the downstream build on an Apple TV 4K. It is not a general VFR timestamp reconstructor.

## The reported file

**Symptom.** Short playback at the head looked normal. Seeking to about 700 seconds caused persistent judder. A short healthy-head check does not prove that uninterrupted playback stays healthy past the malformed region.

**Source characteristics:**

- MP4, progressive SDR H.264 High level 4.0, 1920x1080, nominal 30000/1001, time base 1/90000.
- AAC-LC 48 kHz. No HDR / Dolby Vision.
- Video duration about 9438 seconds, 282860 samples. The edit/index lead is 6006 ticks.
- No private source name, path, URL, packet payload or raw device log is published.

**What inspection found:**

- Direct sample-table inspection showed meaningful `ctts` offsets in the first 3272 samples, followed by one run of 279588 zero offsets. The table covers every sample; it is not a truncated binary box.
- At 700 seconds, all 240 inspected video packets had PTS equal to DTS, but the parsed POC reversed 68 times.
- Decoding a bounded 120-frame slice gave 34 original frame-PTS regressions. FFmpeg's monotonic `best_effort_timestamp` is synthesized, so it does not prove those original times correct.
- The device kept reporting about 30 FPS, enough buffered data, and no aggregate drops or stalls. Those metrics do not show which picture owns which time.

**Why a fixed cadence does not work.** The first faulty sequence also changes interval: eleven 3600-tick steps, followed by 3003/3004 ticks within the same GOP. A short fixed-cadence prototype fixed the later seek but failed at the continuous boundary. It is not the submitted fix. The submitted policy uses complete POC rank and the existing timestamp slots, and keeps the original DTS instead of moving the already published index axis.

## Generated regression

Run on an Apple Silicon / Xcode development host with `ffmpeg` (built with libx264), `ruby` and `python3` on the path:

```sh
bash Scripts/test-h264-partial-composition-controls.sh
```

**FFmpeg checkout.** The runtime compiler uses the exact `FFmpegBuild` revision in `Package.resolved`. After normal package resolution it defaults to `.build/checkouts/FFmpegBuild`. If needed, set `AETHER_FFMPEG_CHECKOUT` to an existing checkout at that exact revision. The script does not resolve or update dependencies itself.

**Fixtures.** All are generated solid colour plus tone, not an excerpt of any private film. The generators clear only `ctts` offset fields, without changing box lengths, DTS, compressed packets or audio.

1. A healthy prefix, with later offsets cleared.
2. Only the middle cleared, so the broken-to-healthy boundary is also tested.
3. Scene-cut shaped: a 30-picture zero-offset sequence followed by one of 420.
4. The whole head without offsets, with a decode cadence change, plus its untouched healthy control (`Scripts/tests/make-missing-head-fixture.py`).
5. Hierarchical B pictures (forward distance 3, backward depth 2): a damaged tail and a damaged middle, each checked against its healthy twin as an exact PTS oracle (`--partial-hierarchical`, `AETHER_TIMESTAMP_HEALTHY_TWIN`), plus the healthy twin on its own.

**Why the third fixture exists.** A uniform one-second GOP cannot reach the ceiling of a policy that holds a whole sequence, so it also cannot show that ceiling gone. Measured at 30 fps with one stereo AAC track, a sequence-wide hold was ended by its interleaved packet budget at between 390 and 420 pictures, because 420 video packets carry about 656 audio packets with them. Reading the slot instead of holding a plan removes the ceiling rather than raising it: the deepest wait on that fixture is 6 packets, and the whole 1200-picture file comes back identical to its healthy twin.

**What the executable checks.** It runs the actual parser and repair session against two decoders: original versus repaired packet timestamps. It asserts:

- zero repaired frame-PTS regressions,
- exact original DTS,
- payload, metadata and non-video packets preserved,
- zero tracked packet balance.

Runtime checks cover seek and back-seek, both continuous boundaries, EOF, abandoned pending/ready queues, missing timestamps after confirmation, and the interleaved-packet budget. Numeric tests cover mixed cadence, quantization, incomplete / field / duplicate POC, insufficient lead, and integer overflow.

## Results

**Real source (privately retained).** The runtime check passed at 0, 700, back to 0, 107, 112, 3600 and 9400 seconds. Original frame-PTS regressions at those points were 0/49/0/20/50/48/46; all repaired results were zero. The 107-second check crosses the first faulty sequence without a seek at the actual boundary.

**Generated fixture.** It also proves recovery back into healthy offsets without changing them.

**Device.** The reporter verified the downstream implementation on an Apple TV 4K (3rd generation), tvOS 26.6 beta (23L773), with the original source on the native hardware H.264 route. The scoped upstream branch contains the same repair and the post-review malformed-timestamp guard. It does not include the host's diagnostic framework, UI customizations, Matroska repair or software cache changes.

## Limits

- The generated fixture proves the packet / decoder regression. It is not claimed to visually reproduce the original movie's native judder.
- A refusal costs the repair, never the session. Every held packet is handed back exactly as it arrived, the rest of that sequence streams through, and the next IDR is a fresh candidate. The judder this policy removes is a far smaller failure than a source read that stops.
- This is a narrow compatibility policy, not a general VFR timestamp reconstructor. It requires a corroborated healthy origin and complete closed progressive POC sequences. Unsupported input is not re-timed by guessing its average frame rate.
- Other operating systems, interlaced / open-GOP sources and arbitrary malformed timelines have not been certified by the reported physical test.
