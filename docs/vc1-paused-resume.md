# Paused VC-1 cold-resume qualification

This patch follows [#973](https://github.com/superuser404notfound/AetherEngine/issues/973),
already present in the branch base `5e8eec74f0601888acce940e5dedabce66a6f64e`.
Starting the paused decode loop does not give a cold VC-1 decoder references when a transport
stream seek lands mid-GOP. On the downstream nonzero-origin VC-1/TrueHD M2TS sample, #973
alone produced a concealed gray picture; priming from an earlier keyframe restored the
paused picture, silence, and continuous playback on resume on a physical Apple TV.

## Scope and limits

Only a non-live, seekable software VC-1 session at a nonzero **paused** cold start changes.
The demuxer is still exclusively owned by load. Seek back four seconds (not before the
source origin), then admit a video key packet at or before the requested source PTS and
no more than eight seconds earlier. Peeking preserves that key packet for either the disk
cache producer or the direct reader. The existing target filter and stopped clock remain
at the original resume time. H.264/HEVC, WMV1/2/3, autoplay and zero-start paths are unchanged.

Preparation uses an eight-second seek/read deadline and checks cancellation, EOF, target
crossing, 8,192 packets and 32 MiB of cumulative packet data. The byte limit is checked
**after** reading a packet; it is not a hard allocator limit on one packet. A blocking
`file://` filesystem read cannot promise an eight-second hard interruption. Missing or
out-of-window keys fail reposition instead of publishing a false ready picture. Long GOPs
without a usable key in this window are deliberately not qualified yet. No production
pixel-content heuristic, temporary playback or FFmpeg/display-layer change is included.

## Evidence and remaining ready gate

`SoftwareVC1PausedResumeTests` uses synthetic HEVC packets to test only key admission,
key preservation, EOF, cancellation and budget failures. It does **not** establish VC-1
reference decoding. The optional `VC1PausedResumeIntegrationTests` checks an actual paused
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
