# MPEG1/2 cache qualification candidate

**Draft: not ready to merge.** The candidate adds MPEG1/2 to the existing depth-32
successor-PTS model. It does not modify timestamps, decoder, stores, audio eligibility,
storage defaults or downstream pins. A codec-wide admission needs field-picture
qualification which the fixtures below do not yet provide.

## Evidence and remaining gate

Millisecond Matroska packets declare 33 ms duration although adjacent presentation
PTS can differ by 34 ms. Duration-only ranges fragment; successor coverage can
represent retained presentation intervals without inventing the last picture's end.
B-picture decode order is different from presentation order.

The tests use the real Demuxer and the repository's fixed libavcodec, including a
true EOF drain, to compare every decoded picture PTS with the sorted packet PTS.
They do not use the CLI probe's flush/discard operation as drain evidence. This
boundary test is not SoftwareVideoDecoder deinterlacer, renderer or device acceptance.

Four generated fixtures cover MPEG1 progressive, MPEG2 progressive, interlaced
frame-coded MPEG2 and MPEG2 repeat-first-field pulldown. The interlaced fixture has
picture_structure=3: it is **not** separately coded top/bottom field pairs. Pulldown
has 30 repeat_first_field pictures out of 60, not 60 independently coded fields.

Before ready, supply reproducible, redistributable field-coded MPEG2 input and verify
its real demux packet / decoded presentation relationship in the fixed decoder and
both stores, including relevant container parser modes. The fixed FFmpeg
[mpegvideo parser](https://github.com/FFmpeg/FFmpeg/blob/1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7/libavcodec/mpegvideo_parser.c)
combines field boundaries but PARSER_FLAG_COMPLETE_FRAMES can bypass that parsing.
A codec name, video_delay value or one frame-coded Matroska result cannot prove all
containers satisfy the complete-picture contract. Missing or late timestamps still
invalidate coverage, but that does not by itself prove field-pair eligibility.

Attempts with mjpegtools 2.2.1_1 `mpeg2enc -I 2` at valid field geometries crashed;
a successful low-height attempt silently fell back to frame pictures. Neither is
accepted as field evidence. Its manual labels that encoder mode unsupported. No
external encoder, FFmpeg or coverage algorithm is changed to bypass this gate.
WMV3 is outside this PR.

## Reproduce generated fixtures

Only generated color pixels are included, contributed under the repository license;
no third-party movie, audio, credentials or tool binaries are included. Base64 data
in `Tests/AetherEngineTests/Support/MPEGCacheFixtures.swift` is hash checked at load.
Generation tools are FFmpeg 8.1.2 and mjpegtools mpeg2enc 2.2.1_1 (GPL tool only, not
an engine dependency). No generator runs at test time.

For `mpeg1` / `mpeg2` (replace CODEC with mpeg1video / mpeg2video):

```sh
ffmpeg -fflags +bitexact -f lavfi -i color=c=blue:size=64x64:rate=30000/1001 \
  -frames:v 120 -an -c:v CODEC -flags:v +bitexact -g 15 -bf 2 \
  -map_metadata -1 -fflags +bitexact output.mkv
```

For `interlaced`, use mpeg2video and replace the flags with
`-flags:v +bitexact+ildct+ilme -top 1`. These files contain 120 pictures each.

For `pulldown` (60 source pictures):

```sh
ffmpeg -f lavfi -i color=c=blue:size=64x64:rate=24000/1001 -frames:v 60 \
  -pix_fmt yuv420p -f yuv4mpegpipe pulldown.y4m
mpeg2enc -f 3 -n n -a 1 -b 1000 -q 8 -M 1 -I 0 -p -R 2 -g 15 -G 15 \
  -o pulldown.m2v < pulldown.y4m
ffmpeg -fflags +genpts+bitexact -i pulldown.m2v -c copy -map_metadata -1 \
  -fflags +bitexact pulldown.mkv
```

| Fixture | Bytes | SHA-256 |
| --- | ---: | --- |
| mpeg1 | 6614 | 540ba15e11ca2bd2bfdac34dcc02f07df0298227aa211135d38fdc9c5aac68f4 |
| mpeg2 | 7784 | 958078bfbf5deb00383cef33749d0edc9257f5ebac64421becc4f3e86a8ecc06 |
| interlaced | 7791 | 0067723902603b567c93581914d9a59a0b4d8e52c767c99855ae9e6de7e02616 |
| pulldown | 4640 | 7578b7521b8f95a91ad3afc04626c1c46b5336245e62ec94fde9adc04242dd76 |

## Cache matrix and limits

Real disk and memory FIFOs exercise rounded-duration holes, retained seeks, unknown
EOF tail, nonzero source clocks, reset/epoch, missing/late PTS, a two-second gap and
consumed-history eviction. Fault cases mutate packet metadata deliberately; eviction
repeats packet envelopes on separated time spans to force chunk retirement. They are
store tests, not newly encoded media or proof of decoding such mutated streams.
The memory store disables kernel purging for deterministic residency; physical
memory pressure and continuous remote playback remain separate acceptance work.

Rollback is to remove the MPEG codec admission line and retain strict duration
coverage. No downstream dependency or device version is changed by this PR.
