# Live replay and video progress validation

**Summary.** Field logs from four Apple devices showed short decoded-output gaps on live MPEG-TS, the longest (9.549 s on a Mac) lining up with a held source boundary. A controlled repro found the cause: when an outgoing access unit is cut inside its bytes, a partial copy can reach the decoder next to the intact returning copy (or, untimed, push the intact one out as replay), and VideoToolbox then rejects the damaged picture and the damage runs to the next IDR. The fix makes `LivePacketReplayGuard.verifiedPacketOrder` keep the returning copy, but only inside a batch whose replay is already verified, and quarantines untimed fragments with their damaged boundary. A separate, opt-in option, `LoadOptions.nativeVideoFrameRecovery`, adds bounded repair when decoded output stalls. Status: fixed with failing-before / passing-after regressions. It still needs a rerun on the reporter's four devices, and without the original packet stream it is not proof that every observed gap had this cause.

## Physical-device evidence, 12 October 2026

The reporter ran an integrated downstream build (1.1.15 build 13, engine `a79335531075cc99d42d18bb4d65e96a64c30cea`, upstream 7.35.1) on four real Apple devices.

- All 26 diagnostic archive parts were verified by count and SHA-256: 8,465 records, of which 219 belonged to an older iPad build and were excluded.
- Private media, provider addresses, credentials and support identifiers are omitted.
- Exact hardware models were not captured. The Mac ran the iPad-compatible app.

| Device / OS | Actual media and scenario | Observation before this correction |
| --- | --- | --- |
| Mac / macOS 27.0.1 (26A434) | Live MPEG-TS, H.264 High 1280x720 / 25 fps / SDR; AAC-LC stereo 44.1 kHz; 10 s video segments | 11 verified replay removals; five decoded-output gaps of 0.423 to 9.549 s |
| iPhone / iOS 26.6.1 (23G83) | Four live MPEG-TS loads, H.264 High 720p/1080p / 25 fps / SDR with AAC-LC; manual seeking and four PiP entry/exit pairs | Nine replay removals; three 1.000 to 1.175 s output gaps; two separately identified system audio interruptions |
| iPad / iPadOS 26.6.1 (23G83) | MKV VOD, H.264 Main 1920x800 / 23.976 fps / SDR; AAC-LC 5.1 48 kHz; resume at 2852.5 s and PiP | 2.56 s load-to-playing, one 0.89 s buffering interval, inline readiness restored after PiP; decoded-output sampling was not enabled by this host for VOD |
| Apple TV / tvOS 27.0 (24J361) | Live MPEG-TS, H.264 High 1920x1080 / 25 fps / SDR; AAC-LC stereo 48 kHz; 2 s initial segments | Seven replay removals; four 0.528 to 0.691 s output gaps, all self-resolving |

**Across devices:**

- Live load-to-playing was 0.90 to 1.47 s, with seekability observed within 1.73 to 1.93 s.
- No unsolicited backward movement appeared in sampled clocks. The one clear backward movement followed an explicit ten-second seek command.
- No source/consumer reopen or compatibility fallback was observed.
- All five PiP exits restored inline layer readiness.
- These are observations of the integrated fork, not isolated device tests of each PR.

**The strongest Mac correlation.** A held source boundary at 36700.140 s, with source origin 36589.660 s, has an item position of exactly 110.480 s: the last decoded picture before the 9.549 s gap. The next picture was at 120.000 s. Other Mac gaps also ended at ten-second boundaries. The item clock kept progressing, buffered media remained, and `AVPlayerLayer.isReadyForDisplay` stayed true. That flag describes first-picture readiness, not continuing picture progress. Decoded-output gaps do not by themselves prove an identical freeze on the physical screen, and the archives contain no raw media.

## Reproduced admission defect

The existing flagged-PES regression preserved every picture. So merely setting `AV_PKT_FLAG_CORRUPT` on otherwise intact bytes did not reproduce this case. Cutting the actual transport bytes inside an outgoing access unit did:

1. The demuxer reported a corrupt packet, and the admission guard held the boundary.
2. A later partial outgoing access unit emerged **without** the corrupt flag.
3. After both tracks proved replay, the held batch contained that partial picture and its intact returning copy at the same original DTS and PTS.
4. Exact-payload deduplication kept both, because the payloads differ. The muxer's monotonic guard bumped the second DTS by one tick: 800 original video packets became 801.
5. Apple's VideoToolbox decoder rejected the malformed picture with `codecBadDataErr` (`-8969`). A long reference chain explains why the damage can persist to the next IDR.

**The fix.** `LivePacketReplayGuard.verifiedPacketOrder` now reconciles video copies by both DTS and PTS, **only inside the pending batch after replay is verified on the participating tracks**. It keeps the returning copy and restores decode order. It does not:

- erase source history,
- deduplicate arbitrary timestamps,
- collapse audio payloads,
- treat an unrelated programme's clock reset as replay.

Native remux and software/DVR admission both use the same operation. Numeric `ReplayVideoBoundary` diagnostics report flagged damage, replacements, missing replacements, unflagged copies superseded, and untimed fragments removed from the verified outgoing boundary.

**The untimed fragment.** A second controlled 320x180 fixture exposed an **untimed** unflagged fragment after the corrupt outgoing PES. It escaped the timed boundary queue, acquired a synthetic DTS and advanced the admitted frontier. The intact returning reference picture was then discarded as replay. Quarantining that fragment with its damaged boundary fixes both routes. It is discarded only when replay is proven; ambiguous boundaries keep all packets.

- Before the fix: FFmpeg reported missing references and decode error flags, and actual native AVPlayer output paused for 5.310 s (last frame 24.720 s, next 30.040 s).
- After the fix: all 1,125 native-decoded pictures and timestamps matched the clean 45 s source, and the 38 s AVPlayer run showed no decoded-output gap.
- Setup: a local HTTP origin with synthetic H.264 High / 25 fps / 10 s closed GOP / two B-frames, AAC-LC stereo 44.1 kHz / SDR.
- The CLI's headless layer was not eligible for presentation recovery, so this result exercised the packet correction, not the watchdog.

This is a deterministic defect with a failing-before / passing-after regression, and it matches the boundary / reference-chain pattern seen in the field. Without the original private packet stream it is not proof that every observed gap had this cause.

## Bounded presentation protection

`LoadOptions.nativeVideoFrameRecovery` is separate from the existing observational `nativeVideoFrameDiagnostics` option. Hosts enable decoded-output repair explicitly.

- Only previously productive, freshly sampled SDR output can supply a stall signal.
- It uses the existing bounded current-position nudge/reload ladder.
- The ladder excludes short gaps, PiP, background, external playback, pause, seeks, hidden layers and source starvation.
- Unavailable sampling cannot trigger repairs or rearm exhausted attempts.
- Sustained healthy decoded progress rearms the ladder. A layer that is briefly ready after an item swap is not enough.
- Source identity, retained DVR and viewing position stay intact.

## Regression method and limits

**Fixture.** The shared generated fixture is 32 s of H.264 High, 32x32 / 25 fps / 8-bit SDR, 10 s closed GOPs and two B-frames, plus AAC-LC stereo 44.1 kHz. The test needs no private media and no external executable.

**Cases.** A flagged outgoing PES; actual byte truncation inside a predicted picture; and truncation inside a keyframe, at two byte offsets. Unit cases also cover an untimed fragment with and without verified replay.

**Method:**

- Compare all 800 software-decoded pictures against the clean source.
- Remux clean and replay inputs through the real producer, then pass every compressed output picture through Apple's VideoToolbox decoder. Compare all 800 BGRA pixel hashes and presentation timestamps, not just packet counts.
- Keep demux/decoder work off the cooperative executor, check cancellation between packets, and drain native asynchronous/delayed frames before comparing.
- Replay the observed short and long gap durations through the recovery policy. Verify that short gaps, stopped clocks, delayed or unavailable sampling, seeks and excluded presentation cannot create repeated repair loops.

**A false alarm along the way.** An exploratory AVAssetReader check at first read only the first fragment of a concatenated, unindexed HLS-fragment file, also for a clean FFmpeg-generated control. That was a limitation of the test container, not evidence that the engine lost 600 pictures. The final native decoder comparison uses the complete demuxed packet sequence.

**Limits.** The VideoToolbox comparison verifies native decoding. Live AVPlayer smoke tests separately exercise the actual HLS consumer. Neither replaces a new run on the reporter's four physical devices after this correction.

## CI and strict-pool reproducibility

The standalone PR's first run at `48c6aafd` passed:

- the complete normal macOS suite,
- the new five-seam native-decoder cases in both normal and strict-pool runs,
- iOS Simulator plus release CLI, tvOS/visionOS Simulator, and documentation checks.

Its strict-pool run reported one failure in the unchanged `SourcePrewarmAdoptionTests.fullyWarmedSourceOpensWithNoConnection`: two requests were observed where one was expected. That test and the prewarm implementation have no changes in this PR. A complete local rerun using `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build --disable-xctest` passed all 4,376 Swift Testing tests in 603 suites. No prewarm code or assertion was changed or disabled. The later documentation-only commit requests another CI run; a later green run does not erase the original intermittent result.
