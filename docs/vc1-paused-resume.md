# VC-1 shared reference-preroll qualification

This patch follows [#973](https://github.com/superuser404notfound/AetherEngine/issues/973),
already present in the branch base `5e8eec74f0601888acce940e5dedabce66a6f64e`.
Starting the paused decode loop does not give a cold VC-1 decoder references when a transport
stream seek lands mid-GOP. On the downstream nonzero-origin VC-1/TrueHD M2TS sample, #973
alone produced a concealed gray picture; priming from an earlier keyframe restored the
paused picture, silence, and continuous playback on resume on a physical Apple TV.

## Scope and limits

Non-live, seekable software VC-1 uses the same reference preparation for nonzero loads
and transport source seeks, whether paused or playing. Cache hits keep resident preroll
and do not touch the source. Cache misses park the producer and decode loop before entering
the serial seek queue. Seek back four seconds (not before the source origin), and preserve
a key packet at or before the target, at most eight seconds earlier. Existing target filters,
clock and playback intent remain unchanged; paused seek does not start a decode loop.

Preparation has at most eight seconds within the operation's existing 30-second budget,
plus 8,192-packet and 32-MiB bounds. Missing/future keys, EOF, read errors or probe exhaustion
fall back to the original reposition with the remaining budget. That seek drops peeked
packets and clears latched AVIO errors; a failed fallback remains stalled, never ready.
A single packet may exceed the byte limit before it is rejected. Lock waits and blocking
filesystem reads are not hard wall-clock bounded. No production pixel heuristic is used.

Generation checks reject obsolete work before admission and fallback. A cancelled whole
load closes its demuxer because teardown follows. Superseded/cancelled transport work does
not close the reusable demuxer; a newer queued operation clears old read state on reposition.
Cancellation without a successor settles the host window as a failed positioning operation.
H.264/HEVC, other codecs and zero-start loads keep the existing path.

## Evidence and remaining ready gate

`SoftwareVC1ReferencePrerollTests` uses synthetic HEVC packets to test only key admission,
key preservation, EOF, cancellation and budget failures. It does **not** establish VC-1
reference decoding. A controllably parked custom source also drives the actual off-main load
preparation boundary: cancellation must call through demux close to the source, end the blocked
positioning operation and refuse reference admission. This covers cancellation during preparation,
not real VC-1 decoding or a slow HTTP server. The optional `VC1PausedResumeIntegrationTests` checks an actual paused
software-host picture, source PTS and stopped clock, but is skipped without its fixture.

That harness currently expects a VC-1/TrueHD M2TS with source origin 600 seconds and visible
contrast at session positions 789.92911257 and 796.46233333. Those are the two downstream
reproduction points; no private file or access URL is distributed. With a locally authorized
copy matching that contract, run:

```sh
AETHER_VC1_RESUME_FILE=/absolute/path/to/authorized-sample.m2ts \
  swift test --filter VC1PausedResumeIntegrationTests
```

The luminance assertion is specific to those contrasted scenes, not a general definition
of a valid video frame. Device evidence belongs to the downstream build, not automatically
to this extracted public patch.

**Draft / not ready:** supply a small legally redistributable VC-1 fixture or an independently
reproducible generator, record its source/license/hash, and wire real decode into default CI.
Demonstrate failure on the exact unpatched base and success with this patch. Include offset
origin, short/long GOP, cancellation during slow preparation, and the existing #973 paused
first-frame regressions. Ordinary policy-test success must not close this gate.

## Shared-path follow-up

The same authorized local VC-1 sample reproduced a gray **first decoder output** after
both cold open and warm decoder flush. Reference priming restored scene contrast at both
targets in ordinary and strict-pool runs. Ordinary paused host seek retains the old layer
and parks decoding; this is not evidence of sustained gray on a physical TV after paused seek.
`VC1ReferencePrerollIntegrationTests` captures synchronous first outputs for cold/warm decoders;
it shares the optional fixture contract above and does not supply the missing public sample.
Policy tests cover successful/failed fallback, remaining budget, key bounds and a parked source:
cancelled load closes it, cancelled/superseded transport leaves it open for the next seek.
