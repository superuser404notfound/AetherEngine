# AVI MPEG-4 cache timing reproduction

**Summary.** An AVI with MPEG-4 ASP B-frames plays, but the software packet cache could not publish video coverage or seek anchors for it, because the VFW decode-order repair path deliberately clears generated packet PTS. The fix keeps that repair and instead uses the existing MPEG-4 parser's display clock, checked against timestamps from the same decoder. Status: fixed for seekable, non-live AVI MPEG-4 software-cache sessions, covered by synthetic fixtures and unit tests, and confirmed downstream on an Apple TV 4K (third generation). This page shows how to generate the samples, reproduce the original bug, and exercise the capacity and eviction cases.

## The problem

- An AVI with MPEG-4 ASP B-frames takes the existing VFW decode-order repair path.
- That path deliberately clears generated packet PTS.
- Playback can still advance, but a packet cache that indexes only packet PTS cannot publish video coverage or seek anchors.
- Re-enabling generated PTS is not a safe fix: it undoes the ordering repair discussed in issues #407 and #516 / PR #517.

## Generate the samples

Run from the repository root with FFmpeg and ffprobe on PATH:

```sh
python3 Scripts/generate-avi-mpeg4-cache-fixture.py
```

The script uses only FFmpeg's generated color/test pattern and sine-wave sources. It downloads nothing and reads no user media. Following the repository convention of generating test clips on demand, it writes these files under the ignored `build/avi-mpeg4-cache/` directory:

| File | Content |
|---|---|
| `mpeg4-cache.avi` | Moving test pattern, AVI/XVID MPEG-4 Advanced Simple Profile, B-frames, 160x90, 30000/1001 fps, MP3 mono at 48 kHz, about fifteen seconds. |
| `decoder-fixture.avi` | Black 32x32 MPEG-4 B-frames at 25 fps, no audio, ten seconds. Its packets are also embedded in `MPEG4CacheTimingFixture.swift`, so automated tests need neither FFmpeg executables nor an external file. |
| `manifest.json` | Encoder version, generated-file SHA-256 and ffprobe metadata. Different encoder versions can produce different bytes, so the manifest identifies the exact local output; it does not promise byte identity across versions. |

To regenerate the embedded test packets explicitly:

```sh
python3 Scripts/generate-avi-mpeg4-cache-fixture.py \
  --fixture-swift Tests/AetherEngineTests/MPEG4CacheTimingFixture.swift
```

The generated sources and embedded test data contain no third-party media and are contributed under the repository's license.

## Observe the original bug

You need a seekable HTTP origin with byte-range support, and a host that displays or logs `engine.residentRanges`.

- A direct local-file load can bypass software read-ahead, so it is not equivalent.
- A plain Python HTTP server does not reliably provide the required Range behavior.

For a local host, use the repository's Range-capable origin:

```sh
python3 Scripts/slowrange.py build/avi-mpeg4-cache/mpeg4-cache.avi 8873 100000 0
```

Load `http://127.0.0.1:8873/mpeg4-cache.avi` in the host, and stop the origin with Ctrl-C after testing. This helper binds loopback; a separate device needs its own reachable Range-capable origin.

1. Load the remote VOD with normal software packet caching enabled.
2. Play until the decoder has crossed a complete GOP, then pause.
3. Watch packet-cache bytes, `residentRanges` and cached seeks while the source keeps filling. Leave the VFW PTS repair enabled.

**Before the fix:** video packet PTS is missing, and video coverage / keyframe anchors stay empty despite cached data.

**After the fix:** the existing MPEG-4 parser's display clock is qualified against timestamps from the same decoder. Confirmed video coverage intersects the selected audio and uses retained keyframes. The original packet PTS, DTS and payload stay unchanged.

## Read-ahead capacity and eviction

The optional long sample exercises a fast origin that runs far ahead of playback:

```sh
python3 Scripts/generate-avi-mpeg4-cache-fixture.py --long
```

This also produces a low-bitrate, forty-minute blue clip with a tone. To use it:

1. Set `LoadOptions.forwardBufferSegments` to `Int.max` (the engine applies its own clamp), and allow enough session cache budget to read it.
2. Pause near the start.
3. Check that retiring temporary parser/decoder pairing entries does not move the beginning of already-confirmed resident coverage. An early cached seek must still replay the retained original packets.
4. Actual disk eviction or purgeable memory reclamation must remove those ranges and make old cursors miss.

This capacity case guards the new implementation. It is not a second defect claimed against the unmodified upstream code. Automated tests use a smaller equivalent pairing capacity and cover both disk and purgeable-memory stores, including a deterministically forced history purge that does not depend on system memory pressure.

To exercise both implementations in a host, repeat with `LoadOptions.softwarePacketCacheStorage` set to `.memory` and `.disk`. Leave normal budget/volume safeguards enabled.

```sh
swift test --filter 'SoftwarePacketCacheTiming|SoftwareResidentRanges|SoftwarePacketMemoryFIFO|VFWDecodeOrderPTSRepair'
```

## Scope and evidence

What the change covers:

- Only seekable, non-live AVI MPEG-4 software-cache sessions that already suppress generated PTS.
- Split, multiple-picture or ambiguous packet ownership stays conservatively uncovered. This is not a general packed-AVI fix.
- Cold source epochs requalify the axis, and callbacks from retired epochs are ignored.
- It adds no new public API, and changes neither the spool envelope version nor the existing decoder ordering / timestamp repair.

Evidence:

- The source fix was tested downstream on Apple TV 4K (third generation), tvOS 27.2, with ordinary AVI/XVID MPEG-4 ASP B-frame media and MP3 audio. The user confirmed buffer display, growth, and playback after seeks inside retained ranges.
- That device result is separate from the public synthetic fixtures and the tests of this extracted patch.
- It is not a claim that every AVI variant, host platform or release configuration has been validated.
