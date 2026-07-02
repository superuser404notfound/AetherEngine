#!/usr/bin/env bash
# Generate a small set of synthetic test clips under ./Fixtures/ for
# engine validation runs. Each clip is short (5 s) and deterministic
# (FFmpeg's testsrc2 source filter), so the output is reproducible
# across machines and copyright-clean. The clips exercise the four
# codec paths AetherEngine cares about:
#
#   sdr-h264.mp4    - H.264 BT.709, native AVPlayer path
#   hdr10-hevc.mp4  - HEVC Main10 BT.2020 / PQ, native AVPlayer path with HDR
#   av1.mp4         - AV1, software dav1d path on devices without HW
#   vp9.webm        - VP9, software libavcodec path
#
# plus two clips for RestartTimelineContinuityTests (the suite skips
# those tests when the clips are absent, e.g. on CI):
#
#   restart-witness-av.mp4        - H.264 B-frames + AAC, 12 s (3 segments)
#   restart-witness-leadaudio.mp4 - same, video delayed 0.3 s so audio leads
#   restart-witness-subs.mkv      - same as MKV with an embedded SRT track (pump tap)
#
# Real-world DV / Atmos / multichannel sources have to come from your
# own library. Drop those into ./Fixtures/user/ (also gitignored)
# and reference them from aetherctl runs.
#
# Usage:
#   ./Scripts/fetch-fixtures.sh
#
# Requires:
#   - ffmpeg with libx264, libx265, libaom-av1, libvpx-vp9 enabled.
#     macOS: `brew install ffmpeg` covers all four codecs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/Fixtures"
mkdir -p "$FIXTURES_DIR/user"

# Drop a README into the user dir on first run so the gitignore +
# intent are obvious if someone goes looking.
USER_README="$FIXTURES_DIR/user/README.md"
if [[ ! -f "$USER_README" ]]; then
    cat > "$USER_README" <<'EOF'
# user fixtures

This directory is gitignored. Drop real-world test sources here
(Dolby Vision MKVs, Atmos EAC3+JOC streams, multichannel sources,
etc.) and reference them from `aetherctl probe / serve / validate`
runs without worrying about accidentally pushing them.
EOF
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg not on PATH. Install with: brew install ffmpeg" >&2
    exit 1
fi

echo "Fixtures dir: $FIXTURES_DIR"
echo ""

# H.264 SDR 1080p
echo "→ sdr-h264.mp4 (H.264 BT.709 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    "$FIXTURES_DIR/sdr-h264.mp4"

# HEVC HDR10 1080p
echo "→ hdr10-hevc.mp4 (HEVC Main10 BT.2020 / PQ 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -vf "format=yuv420p10le" \
    -c:v libx265 -preset ultrafast \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1" \
    -pix_fmt yuv420p10le \
    -tag:v hvc1 \
    "$FIXTURES_DIR/hdr10-hevc.mp4"

# AV1 SDR 1080p
echo "→ av1.mp4 (AV1 1080p @ 24fps, low CPU preset)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libaom-av1 -crf 30 -b:v 0 -cpu-used 8 \
    "$FIXTURES_DIR/av1.mp4"

# VP9 SDR 1080p
echo "→ vp9.webm (VP9 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libvpx-vp9 -crf 30 -b:v 0 -cpu-used 8 \
    "$FIXTURES_DIR/vp9.webm"

# Restart-continuity witness: A/V with real B-frame reorder (bf 3) and a keyframe
# every 2 s so the 4 s segment plan cuts on keyframes. Drives
# RestartTimelineContinuityTests (continuous vs restarted segment equality).
echo "→ restart-witness-av.mp4 (H.264 B-frames + AAC mono, 12s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=12:size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=12" \
    -c:v libx264 -preset veryfast -bf 3 -g 48 -pix_fmt yuv420p -b:v 200k \
    -c:a aac -b:a 48k -ac 1 -shortest \
    "$FIXTURES_DIR/restart-witness-av.mp4"

# Same content with the video track delayed 0.3 s, so the audio leads the
# video anchor at head-of-stream (the leading-audio guard scenario).
echo "→ restart-witness-leadaudio.mp4 (audio leads video by 0.3s, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -itsoffset 0.3 -i "$FIXTURES_DIR/restart-witness-av.mp4" \
    -i "$FIXTURES_DIR/restart-witness-av.mp4" \
    -map 0:v -map 1:a -c copy -t 8 \
    "$FIXTURES_DIR/restart-witness-leadaudio.mp4"

# Same content as MKV with an embedded SRT track (the subtitle pump-tap scenario,
# SubtitlePumpTapTests).
echo "→ restart-witness-subs.mkv (embedded SRT track)"
SRT_TMP="$(mktemp -t witness-subs).srt"
cat > "$SRT_TMP" <<'SRT'
1
00:00:00,500 --> 00:00:02,000
First cue

2
00:00:02,500 --> 00:00:04,500
Second cue crossing the first boundary

3
00:00:05,000 --> 00:00:07,000
Third cue

4
00:00:08,200 --> 00:00:10,000
Fourth cue

5
00:00:10,500 --> 00:00:11,500
Fifth cue
SRT
ffmpeg -hide_banner -loglevel error -y \
    -i "$FIXTURES_DIR/restart-witness-av.mp4" -i "$SRT_TMP" \
    -map 0:v -map 0:a -map 1:0 -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng \
    "$FIXTURES_DIR/restart-witness-subs.mkv"
rm -f "$SRT_TMP"

echo ""
echo "Done. Try:"
echo "  swift run aetherctl probe $FIXTURES_DIR/sdr-h264.mp4"
echo "  swift run aetherctl probe $FIXTURES_DIR/hdr10-hevc.mp4"
echo "  swift run aetherctl validate $FIXTURES_DIR/av1.mp4"
echo ""
echo "Real-world DV / Atmos sources go in $FIXTURES_DIR/user/ (gitignored)."
