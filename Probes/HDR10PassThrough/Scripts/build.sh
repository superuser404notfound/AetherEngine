#!/bin/zsh
# Builds the HDR10 pass-through clips into $HDR10_OUT (default ../out, gitignored). Needs ffmpeg with
# libx265 and python3 + numpy. Each 4K encode takes a few minutes (the pattern is flat, so x265's
# veryfast preset loses nothing); a clip that exists is kept.
#
#   pattern_24.mp4   3840x2160 at 23.976, 40 s
#   pattern_60.mp4   3840x2160 at 59.94, 30 s
#
# Both are HEVC Main10, BT.2020, PQ, with the clip's own HDR10 metadata: mastering display 1000 nit
# (minimum 0.005), MaxCLL 1000, MaxFALL 400. The probe's values (777 nit, 345/123) differ from every
# one of them, so a television's info screen tells whose metadata it shows. A silent stereo AAC track
# rides along so every route has an audio clock.
set -euo pipefail
HERE=${0:A:h}
OUT=${HDR10_OUT:-$HERE/../out}
mkdir -p "$OUT"
OUT=${OUT:A}

command -v ffmpeg >/dev/null || { echo "missing tool: ffmpeg (brew install ffmpeg)"; exit 1; }
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265 || { echo "this ffmpeg has no libx265"; exit 1; }
python3 -c 'import numpy' 2>/dev/null || { echo "missing python module: numpy (python3 -m pip install numpy)"; exit 1; }

MASTER="G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50)"

build() {
  local name=$1 num=$2 den=$3 seconds=$4 gop=$5
  [[ -s "$OUT/$name.mp4" ]] && { echo "$name.mp4 exists, kept"; return; }
  local frames=$(( seconds * num / den ))
  echo "encoding $name.mp4 ($frames frames)"
  python3 "$HERE/gen_pattern.py" $frames $num $den | ffmpeg -hide_banner -loglevel error -y \
    -f rawvideo -pix_fmt yuv420p10le -s 3840x2160 -framerate $num/$den -i - \
    -f lavfi -i anullsrc=r=48000:cl=stereo \
    -map 0:v -map 1:a -shortest \
    -c:v libx265 -preset veryfast -crf 16 -pix_fmt yuv420p10le \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
    -x265-params "hdr10=1:hdr10-opt=1:repeat-headers=1:aud=1:keyint=$gop:min-keyint=$gop:no-scenecut=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:master-display=$MASTER:max-cll=1000,400" \
    -tag:v hvc1 -c:a aac -b:a 64k -movflags +faststart "$OUT/$name.mp4.tmp.mp4"
  mv "$OUT/$name.mp4.tmp.mp4" "$OUT/$name.mp4"
}

# Arguments pick clips (`build.sh pattern_24`); none builds both.
for clip in ${@:-pattern_24 pattern_60}; do
  case $clip in
    pattern_24) build pattern_24 24000 1001 40 48 ;;
    pattern_60) build pattern_60 60000 1001 30 120 ;;
    *) echo "unknown clip $clip (pattern_24, pattern_60)"; exit 1 ;;
  esac
done

# What the files declare, for the run log.
if command -v ffprobe >/dev/null; then
  for f in pattern_24 pattern_60; do
    [[ -s "$OUT/$f.mp4" ]] || continue
    echo "$f: $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,color_transfer,color_primaries -of csv=p=0 "$OUT/$f.mp4")"
  done
fi
echo "clips in $OUT"
