# Integration harnesses

Checks that need a running engine + a real media file, so they cannot run under `swift test`.

Related, and elsewhere because it needs to build for tvOS: `Probes/TransportProbe/` measures whether
a held `URLSessionStreamTask` gives real backpressure and survives an origin that refuses new
requests for minutes at a time (AE#377, #310, #220). It is its own package, since the engine's
package scheme carries `aetherctl` and cannot build for a device.

## `avplayer-open-check.swift` (#15, E8)

Proves AVPlayer can OPEN the loopback HLS master that carries the native WebVTT `SUBTITLES`
rendition, reaches `.readyToPlay`, and exposes at least one legible (subtitle) media-selection
option. This is the open-time guard #55 lacked: muxing timed text into the A/V fMP4 silently
failed the AVPlayer open, so the conformant separate-rendition shape needs an explicit
"does it open and expose the option" check.

The harness imports only Foundation + AVFoundation (never AetherEngine): it talks to the engine
over the loopback HTTP server exactly like a real client, so it validates the served bytes.

### What you need

A media file with at least one embedded TEXT subtitle track (subrip / mov_text / ASS; not a
bitmap track like PGS/VOBSUB). `Fixtures/user/embedded-subs.mkv` is one, but `Fixtures/` is
gitignored (local-only). Generate an equivalent in a few seconds with ffmpeg:

```bash
# 5s 1080p h264 test pattern + a subrip text subtitle track muxed into MKV
printf '1\n00:00:00,500 --> 00:00:02,000\nhello from a text subtitle\n\n2\n00:00:02,500 --> 00:00:04,500\nsecond cue\n' > /tmp/subs.srt
ffmpeg -y -f lavfi -i testsrc=duration=5:size=1920x1080:rate=24 \
       -i /tmp/subs.srt \
       -c:v libx264 -pix_fmt yuv420p -c:s srt \
       /tmp/embedded-subs.mkv
# sanity: stream[1] should be codec_type=subtitle codec_name=subrip
ffprobe -v error -show_entries stream=index,codec_type,codec_name /tmp/embedded-subs.mkv
```

### Run it

```bash
# 1. Build the CLI
swift build

# 2. Serve the file with the native subtitle rendition requested (parks; note the printed URL).
#    --native-subs takes an index for CLI compatibility but ignores it: any value attaches one cue
#    store per embedded text track, so the master advertises a SUBTITLES rendition for each.
.build/debug/aetherctl serve --native-subs 0 /tmp/embedded-subs.mkv
#    -> "=== PLAYBACK URL ===" prints e.g. http://127.0.0.1:58494/<token>/media.m3u8
#       <token> is a per-session 32-character hex path segment; a request without it gets a 404.

# 3. In another shell, point the harness at the master playlist (NOT media.m3u8; the rendition
#    lives only in the master): the printed URL with its file name set to master.m3u8, token kept.
swift Tests/Integration/avplayer-open-check.swift http://127.0.0.1:<port>/<token>/master.m3u8 30

# 4. Ctrl-C the aetherctl process when done.
```

### Expected output (captured 2026-06-29, macOS 26.5, Xcode 26)

Against `master.m3u8` (the capture predates the session token, which now sits between the port and
the file name):

```
[harness] opening http://127.0.0.1:58494/<token>/master.m3u8  (timeout 30s)
[harness] AVPlayerItem.status = .readyToPlay
[harness] legible media-selection options: 1
[harness]   [0] displayName="Subtitle 1" lang=nil mediaType=sbtl
[harness] PASS: readyToPlay + 1 legible option(s) against the loopback master
```

Negative control against `media.m3u8` (no rendition in the media playlist) correctly reports
`legible media-selection options: 0` and exits 1.

Exit codes: `0` = readyToPlay AND >= 1 legible option; `1` = failed / timeout / no option;
`2` = bad usage. On `.failed` the harness dumps `AVPlayerItem.errorLog()` (status code, domain,
comment, URI) so an open failure names itself.

### Notes for on-device verification

- The served `.vtt` segments are header-only in the CLI path because the lazy embedded-subtitle
  readers that fill the cue stores are wired by the host (Sodalite), not by `aetherctl serve`.
  Exposure of the legible option does not need cues present (AVPlayer lists options from the
  master's `EXT-X-MEDIA` tags), so this harness validates open + exposure, not cue rendering.
  Cue rendering in the PiP window is verified by selecting the track in the host app.
- The CLI serves `media.m3u8` as the playback URL here because it defaults to `dvModeAvailable=true`
  (`effectiveDvMode` makes `sourceIsHDR` true, which keeps routing media-direct). On a real device
  with an SDR source the force-master path (#15, E6) serves the master directly. Either way the
  master endpoint exists and carries the rendition; the harness targets it explicitly.
- The one timing choice to verify on-device is the WebVTT cue alignment: segments use absolute
  media-timeline times + `X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000`. If PiP subtitles appear
  shifted by the segment start, flip `relativeToStart: true` at the single provider call site
  (`VideoSegmentProvider.nativeSubtitleVTT(ordinal:segmentIndex:)`); see `WebVTTBuilder.segment`.
