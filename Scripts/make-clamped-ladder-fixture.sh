#!/usr/bin/env bash
# Reproduces an MP4 whose writer dropped `ctts` and then forced its decode-order presentation times
# to be monotonic: every sample reports PTS == DTS, an anchor keeps its own time, and each B picture
# that follows it in decode order is pushed 1001 ticks (a third of a 29.97 fps frame) past the picture
# decoded before it. The decode ladder then has no single step, which the #409 classifier needs.
# QuickTime and the Files app (AVFoundation) show such a file with its pictures stepping back and
# forth; FFmpeg-based players reorder by picture order count and look right.
#
# Some writers push the anchors as well (the reporting file has P pictures 1001 ticks past the picture
# before them), so the anchors no longer measure a step either. pushed-anchors.mp4 reproduces that by
# adding 1001 ticks to every other picture before the clamp, away from the end of each GOP so the
# keyframes keep their own time.
#
#   bframes-healthy.mp4  H.264 High 1280x720 29.97 fps, B pyramid, GOP 90, 30 s + AAC (the twin)
#   clamped-ladder.mp4   the same stream, ctts dropped, ladder clamped as above
#   pushed-anchors.mp4   the same stream, ctts dropped, anchors pushed too
#   p-run-healthy.mp4    (x264 CLI only) every GOP opens on twelve P pictures before its first B
#   p-run-clamped.mp4    the same stream, ctts dropped, clamped as clamped-ladder.mp4
#
# The clamp also pushes some keyframes (the 630th picture here, by 1001 ticks), as the reporting
# files do on most GOP boundaries; the repair continues the sequence before them instead.
# p-run-healthy.mp4 is written through Matroska, so its timestamps sit on whole milliseconds and the
# twins agree in display order rather than in value.
#
# testsrc2 draws a frame counter and a moving bar, so the order is visible by eye.
#
# Usage:
#   ./Scripts/make-clamped-ladder-fixture.sh [output-dir] [--check]
#
# --check builds aetherctl and prints the #409 verdict (pktdump) and the decoded order (swdecode)
# for both clamped files. Requires ffmpeg with libx264 (macOS: `brew install ffmpeg`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Fixtures/clamped-ladder"
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) OUT="$arg" ;;
  esac
done
mkdir -p "$OUT"
FF=(ffmpeg -hide_banner -loglevel error -y)

"${FF[@]}" \
  -f lavfi -i "testsrc2=size=1280x720:rate=30000/1001:duration=30" \
  -f lavfi -i "sine=frequency=440:duration=30" \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -bf 3 -g 90 -x264-params b-pyramid=normal \
  -c:a aac -b:a 128k -video_track_timescale 90000 -movflags +faststart \
  "$OUT/bframes-healthy.mp4"

# setts runs per packet in decode order, so PREV_OUTDTS is the timestamp just written: the clamp
# keeps every anchor (its PTS is already past everything before it) and pushes each B picture.
"${FF[@]}" -i "$OUT/bframes-healthy.mp4" -map 0 -c copy \
  -bsf:v 'setts=ts=max(PTS\,PREV_OUTDTS+1001)' -video_track_timescale 90000 -movflags +faststart \
  "$OUT/clamped-ladder.mp4"

# N counts packets in decode order, so mod(N, 2) pushes P and B pictures alike. The last ten pictures
# of each GOP are left alone so the push does not run on into the next keyframe.
"${FF[@]}" -i "$OUT/bframes-healthy.mp4" -map 0 -c copy \
  -bsf:v 'setts=ts=max(PTS+1001*mod(N\,2)*lt(mod(N\,90)\,80)\,PREV_OUTDTS+1001)' \
  -video_track_timescale 90000 -movflags +faststart \
  "$OUT/pushed-anchors.mp4"

FIXTURES=(clamped-ladder.mp4 pushed-anchors.mp4)

# A writer that opens each GOP on a run of P pictures leaves the first twelve sampled pictures in
# order, so the probe has to sample on to the first B picture. ffmpeg's libx264 wrapper cannot force
# frame types; the x264 CLI does it with a qpfile.
if command -v x264 >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  { echo "0 I -1"; for i in $(seq 1 12); do echo "$i P -1"; echo "$((i + 90)) P -1"; echo "$((i + 180)) P -1"; done; echo "90 I -1"; echo "180 I -1"; } \
    | sort -n > "$TMP/qp.txt"
  "${FF[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=30000/1001:duration=10" -pix_fmt yuv420p \
    -f yuv4mpegpipe "$TMP/src.y4m"
  x264 --quiet --preset veryfast --crf 23 --bframes 3 --b-pyramid normal --b-adapt 0 --keyint 90 \
    --min-keyint 90 --scenecut 0 --qpfile "$TMP/qp.txt" -o "$TMP/p-run.mkv" "$TMP/src.y4m" 2>/dev/null
  "${FF[@]}" -i "$TMP/p-run.mkv" -c:v copy -video_track_timescale 90000 -movflags +faststart \
    "$OUT/p-run-healthy.mp4"
  "${FF[@]}" -i "$OUT/p-run-healthy.mp4" -map 0 -c copy \
    -bsf:v 'setts=ts=max(PTS\,PREV_OUTDTS+1001)' -video_track_timescale 90000 -movflags +faststart \
    "$OUT/p-run-clamped.mp4"
  rm -rf "$TMP"
  echo "wrote $OUT/p-run-healthy.mp4"
  FIXTURES+=(p-run-clamped.mp4)
else
  echo "x264 not found: skipping p-run-*.mp4"
fi
echo "wrote $OUT/bframes-healthy.mp4"
for name in "${FIXTURES[@]}"; do
  echo "wrote $OUT/$name"
  ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$OUT/$name" \
    | awk -F, -v name="$name" 'NR > 1 { step[$2 - prev]++ } { if ($1 == $2) same++; prev = $2; n++ }
        END { printf "%s: %d packets, PTS == DTS on %d, DTS steps:", name, n, same
              for (s in step) printf " %s x%d", s, step[s]; print "" }'
done

if [[ $CHECK -eq 1 ]]; then
  swift build --package-path "$REPO_ROOT" --product aetherctl >/dev/null 2>&1
  CTL="$(swift build --package-path "$REPO_ROOT" --product aetherctl --show-bin-path 2>/dev/null)/aetherctl"
  for name in "${FIXTURES[@]}"; do
    echo "$name:"
    "$CTL" pktdump --count 12 "$OUT/$name" 2>&1 | grep -E '#409' || echo "no #409 verdict line"
    "$CTL" swdecode --frames 300 "$OUT/$name" 2>&1 | grep -E 'Steps backwards' || true
  done
fi
