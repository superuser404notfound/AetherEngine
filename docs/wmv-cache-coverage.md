# WMV1/2 software packet-cache qualification

WMV1 and WMV2 use the existing successor-PTS coverage model with a one-timestamp
lookahead. This avoids holes when a Matroska packet declares 33 ms but adjacent
presentation timestamps differ by 34 ms. It changes coverage metadata, not packet
timestamps, decoding, storage selection or the renderer. WMV3 remains separate and
unqualified; the name “WMV” is not sufficient evidence for all three codecs.

## Packet contract

FFmpeg's [WMV1 decoder](https://github.com/FFmpeg/FFmpeg/blob/1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7/libavcodec/msmpeg4dec.c)
rejects picture types other than I/P for this codec, while the
[WMV2 decoder](https://github.com/FFmpeg/FFmpeg/blob/1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7/libavcodec/wmv2dec.c)
reads a one-bit I/P picture type. Neither has B-picture reordering. This is the
codec rationale for depth one, not a guarantee that arbitrary container timestamps
are valid. Complete selected-stream packets must still be retained before their
PTS enters the model. Missing or late PTS invalidates coverage until reset; gaps
larger than the existing one-second limit remain discontinuities. EOF does not
invent an end for the final picture, whose successor is unknown.

## Reproducible fixtures and tests

`WMVPacketCoverageTests` demuxes and decodes both fixtures with the package's fixed
FFmpeg dependency. All 120 packet PTS must match all 120 decoded picture PTS in
order. The same packet envelopes feed the real disk and memory read-ahead stores:
the strict-duration control fragments, while the codec-selected model permits
seeks into the former rounding holes. Separate cases cover source-axis offsets,
missing/late PTS, real two-second gaps, consumed-history eviction and epoch reset.
Mutated timing cases are metadata fault injection, not newly authored video.
The memory fixture disables kernel purging for deterministic history assertions;
existing memory-FIFO tests cover the separate purge contract. Host tests do not
claim physical playback, remote throughput or real memory-pressure acceptance.

Fixtures contain only FFmpeg-generated `testsrc2` pixels, with no third-party
media. Generator: FFmpeg 8.1.2. Run for each `CODEC` value `wmv1` and `wmv2`:

```sh
ffmpeg -fflags +bitexact -f lavfi -i testsrc2=size=64x48:rate=30000/1001 \
  -frames:v 120 -an -c:v CODEC -flags:v +bitexact -g 15 -map_metadata -1 \
  -fflags +bitexact CODEC.mkv
```

The embedded base64 lives in `Tests/AetherEngineTests/Support/WMVCoverageFixtures.swift`.
It is contributed under the repository license, together with the tests. Each
decode verifies the SHA-256 of the exact embedded bytes:

| Codec | Bytes | SHA-256 |
| --- | ---: | --- |
| WMV1 | 25888 | `3759b1d463ad98c4425ebfbbd86601bb019436411389403a43c17f3800607e79` |
| WMV2 | 29159 | `eab7821908f7fadee0f785b92867641f1fdba6f2035e664bf85348297bcd862d` |

The tests require no downloaded samples, external encoder or environment variables.
