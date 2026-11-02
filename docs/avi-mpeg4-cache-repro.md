# AVI MPEG-4 cache timing reproduction

An AVI with MPEG-4 ASP B-frames takes the existing VFW decode-order repair path.
That path deliberately clears generated packet PTS. Playback can still advance,
but a packet cache that indexes only packet PTS cannot publish video coverage or
seek anchors. Re-enabling generated PTS is not a safe fix: it undoes the ordering
repair discussed in issues #407 and #516 / PR #517.

## Generate the samples

Run from the repository root with FFmpeg and ffprobe on PATH:

```sh
python3 Scripts/generate-avi-mpeg4-cache-fixture.py
```

The script uses only FFmpeg's generated color/test pattern and sine-wave sources.
It downloads nothing and reads no user media. It writes these files under the
ignored `build/avi-mpeg4-cache/` directory, following the repository convention of
generating test clips on demand:

- `mpeg4-cache.avi`: moving test pattern, AVI/XVID MPEG-4 Advanced Simple Profile,
  B-frames, 160x90, 30000/1001 fps, MP3 mono at 48 kHz, about fifteen seconds.
- `decoder-fixture.avi`: black 32x32 MPEG-4 B-frames at 25 fps, no audio, ten seconds.
  Its packets are also embedded in `MPEG4CacheTimingFixture.swift`, so automated
  tests need neither FFmpeg executables nor an external file.
- `manifest.json`: encoder version, generated-file SHA-256 and ffprobe metadata.
  Encoder versions can produce different bytes; the generated manifest identifies
  the exact local output rather than promising cross-version byte identity.

To regenerate the embedded test packets explicitly:

```sh
python3 Scripts/generate-avi-mpeg4-cache-fixture.py \
  --fixture-swift Tests/AetherEngineTests/MPEG4CacheTimingFixture.swift
```

The generated sources and embedded test data contain no third-party media and
are contributed under the repository's license.

## Observe the original bug

Serve `mpeg4-cache.avi` from a seekable HTTP origin with byte-range support, and
load that URL in a host that displays or logs `engine.residentRanges`. A direct
local-file load can bypass software read-ahead, so it is not equivalent. A plain
Python HTTP server does not reliably provide the required Range behavior.

For a local host, the repository already includes a Range-capable origin:

```sh
python3 Scripts/slowrange.py build/avi-mpeg4-cache/mpeg4-cache.avi 8873 100000 0
```

Use `http://127.0.0.1:8873/mpeg4-cache.avi` in the host and stop the origin with
Ctrl-C after testing. This helper binds loopback; a separate device needs its own
reachable Range-capable origin.

1. Load the remote VOD with normal software packet caching enabled.
2. Play until the decoder has crossed a complete GOP; then pause.
3. Observe packet-cache bytes, `residentRanges` and cached seeks while the source
   continues to fill. Leave the VFW PTS repair enabled.

On the affected code, video packet PTS is missing and video coverage / keyframe
anchors stay empty despite cached data. With this change, the existing MPEG-4
parser's display clock is qualified against timestamps from the same decoder;
confirmed video coverage intersects the selected audio and uses retained
keyframes. The original packet PTS, DTS and payload remain unchanged.

## Read-ahead capacity and eviction

The optional long sample exercises a fast origin that runs far ahead of playback:

```sh
python3 Scripts/generate-avi-mpeg4-cache-fixture.py --long
```

This additionally produces a low-bitrate, forty-minute blue clip with a tone.
Set `LoadOptions.forwardBufferSegments` to `Int.max` (the engine applies its own
clamp) and allow enough session cache budget to read it, then pause near the start,
and observe that retiring temporary parser/decoder pairing entries does not move
the beginning of already-confirmed resident coverage. An early cached seek must
still replay the retained original packets. Actual disk eviction or purgeable
memory reclamation must remove those ranges and make old cursors miss.

This capacity case guards the proposed implementation, not a second defect claimed
against the unmodified upstream code. Automated tests use a smaller equivalent
pairing capacity and cover both disk and purgeable-memory stores, including a
deterministically forced history purge without depending on system memory pressure.
To exercise both implementations in a host, repeat with
`LoadOptions.softwarePacketCacheStorage` set to `.memory` and `.disk`; leave normal
budget/volume safeguards enabled.

```sh
swift test --filter 'SoftwarePacketCacheTiming|SoftwareResidentRanges|SoftwarePacketMemoryFIFO|VFWDecodeOrderPTSRepair'
```

## Scope and evidence

The change is limited to seekable, non-live AVI MPEG-4 software-cache sessions
that already suppress generated PTS. Split, multiple-picture or ambiguous packet
ownership stays conservatively uncovered; this is not a general packed-AVI fix.
Cold source epochs requalify the axis, and callbacks from retired epochs are ignored.
It adds no new public API and changes neither the spool envelope version nor the
existing decoder ordering / timestamp repair.

The source fix was tested downstream on Apple TV 4K (third generation), tvOS 27.2,
with ordinary AVI/XVID MPEG-4 ASP B-frame media and MP3 audio: buffer display,
growth and playback after seeks inside retained ranges were confirmed by the user.
That downstream device result is separate from the public synthetic fixtures and
the tests of this extracted patch. It is not a claim that every AVI variant, host
platform or release configuration has been validated.
