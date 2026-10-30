#!/bin/zsh
# Builds the pulse clips into $PULSE_OUT (default ../out, gitignored): one HEVC encode of the synthetic
# pattern, then one MP4 per RPU variant. Needs x265, dovi_tool, MP4Box (gpac), curl, python3 + numpy (the analysis scripts also need ffmpeg).
# The 4K encode takes a few minutes; every intermediate is kept and reused, delete it to rebuild it.
#
#   pulse_{l2,l1,null}.mp4   Profile 8.1, the RPU switches (l2: trims, l1: max_pq, null: never)
#   p7fel_{l2,l1,null}.mp4   Profile 7 FEL, same RPUs; the enhancement layer is flat (zero residual)
#   p7mel_l1.mp4             p7fel_l1 with its RPU rewritten as MEL (el_type MEL), the enhancement-layer probe's control
#   p7fel_el.mp4             Profile 7 FEL, constant RPU; the enhancement-layer residual switches
#   p7fel_count_{null,l2}.mp4  Profile 7 FEL counter clips (fel_count.py): BL and EL each carry their own frame
#                            number, the EL one as residual only; null: constant RPU, l2: the RPU pulses as in pulse_l2
#   count_mel.mp4            control: the counter clip's base layer alone as Profile 8.1 (no EL numbers)
set -euo pipefail
HERE=${0:A:h}
OUT=${PULSE_OUT:-$HERE/../out}
mkdir -p "$OUT"
OUT=${OUT:A}
cd "$OUT"
GEN=$HERE/gen_pulse.py

for tool in x265 dovi_tool MP4Box python3 curl; do
  command -v $tool >/dev/null || { echo "missing tool: $tool (brew install x265 dovi_tool gpac)"; exit 1; }
done
python3 -c 'import numpy' 2>/dev/null || { echo "missing python module: numpy (python3 -m pip install numpy)"; exit 1; }

for v in l2 l1 null; do
  python3 "$GEN" rpu-json $v > rpu_$v.json
  dovi_tool generate -j rpu_$v.json -o rpu_$v.bin
done

if [[ ! -s base.hevc ]]; then
  python3 "$GEN" frames | x265 --input - --input-res 3840x2160 --fps 24000/1001 \
    --input-depth 10 --input-csp i420 --output-depth 10 --profile main10 \
    --preset fast --crf 14 --keyint 48 --min-keyint 48 --no-scenecut --no-open-gop \
    --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc --range limited \
    --master-display "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(100000000,50)" \
    --max-cll "10000,400" --hdr10 --hdr10-opt --repeat-headers --aud \
    --vbv-bufsize 100000 --vbv-maxrate 100000 \
    --frames 1584 -o base.hevc.tmp
  mv base.hevc.tmp base.hevc
fi

for v in l2 l1 null; do
  dovi_tool inject-rpu -i base.hevc --rpu-in rpu_$v.bin -o pulse_$v.hevc
  rm -f pulse_$v.mp4
  MP4Box -add pulse_$v.hevc:fps=24000/1001:dvp=f8.1 -brand mp42isom -ab dby1 -quiet -new pulse_$v.mp4
  rm pulse_$v.hevc
done

# ---- Profile 7 FEL variants, for the engine's FEL route (arms T, N, T1) ----
# RPU: dovi_tool's own FEL test RPU, duplicated to every frame, with L1/L2/L5/L6 replaced per frame
# from the generated 8.1 RPUs. The mapping and NLQ stay constant, so the composed pixels are identical
# in every frame and phase. EL: flat 512 (= nlq_offset), i.e. zero residual.
#
# The template is a 384-byte file in dovi_tool's repository, fetched once from a pinned commit and
# checked by hash:
#   https://github.com/quietvoid/dovi_tool/blob/$FEL_COMMIT/assets/tests/fel_orig.bin
# (Homebrew also ships it under $(brew --prefix dovi_tool)/share/dovi_tool/assets/tests/.)
FEL_COMMIT=ef85991cfc31e26bc3ffed76364965f29f9fd281
FEL_SHA=b2b27714b7279c4e24d1a795cb6f95d3ad06745db96d360698ee0932184117a0
if [[ ! -s fel_template.bin ]]; then
  curl -fsSL -o fel_template.bin https://raw.githubusercontent.com/quietvoid/dovi_tool/$FEL_COMMIT/assets/tests/fel_orig.bin
fi
[[ "$(shasum -a 256 fel_template.bin | cut -d' ' -f1)" == "$FEL_SHA" ]] || {
  echo "fel_template.bin does not match the expected fel_orig.bin (sha256 $FEL_SHA); delete it and retry"; exit 1; }

if [[ ! -s el.hevc ]]; then
  python3 -c "
import sys
y = bytes([0x00, 0x02]) * (1920 * 1080)
c = bytes([0x00, 0x02]) * (960 * 540)
f = y + c + c
for _ in range(1584): sys.stdout.buffer.write(f)
" | x265 --input - --input-res 1920x1080 --fps 24000/1001 --input-depth 10 --input-csp i420 \
    --output-depth 10 --profile main10 --preset fast --crf 20 --keyint 48 --min-keyint 48 \
    --no-scenecut --no-open-gop --repeat-headers --aud --frames 1584 -o el.hevc.tmp
  mv el.hevc.tmp el.hevc
fi
print '{"duplicate":[{"source":0,"offset":1,"length":1583}]}' > fel_dup.json
dovi_tool editor -i fel_template.bin -j fel_dup.json -o fel_1584.bin
for v in l2 null l1; do
  print "{\"source_rpu\":\"rpu_$v.bin\",\"rpu_levels\":[1,2,5,6]}" > fel_levels_$v.json
  dovi_tool editor -i fel_1584.bin -j fel_levels_$v.json -o fel_rpu_$v.bin
  dovi_tool inject-rpu -i el.hevc --rpu-in fel_rpu_$v.bin -o el_$v.hevc
  dovi_tool mux --bl base.hevc --el el_$v.hevc -o p7_$v.hevc
  rm -f p7fel_$v.mp4
  MP4Box -add p7_$v.hevc:fps=24000/1001:dvp=f7.6 -brand mp42isom -ab dby1 -quiet -new p7fel_$v.mp4
  rm el_$v.hevc p7_$v.hevc
done

# ---- p7mel_l1: the l1 clip with its RPU rewritten as MEL (dovi_tool mode 1), the MEL control for the
# enhancement-layer probe (DolbyVisionEnhancementLayerProbeTests) ----
MP4Box -raw 1 p7fel_l1.mp4 -out p7fel_l1_raw.hevc -quiet
dovi_tool -m 1 convert p7fel_l1_raw.hevc -o p7mel_l1.hevc
rm -f p7mel_l1.mp4
MP4Box -add p7mel_l1.hevc:fps=24000/1001:dvp=f7.6 -brand mp42isom -ab dby1 -quiet -new p7mel_l1.mp4
rm p7fel_l1_raw.hevc p7mel_l1.hevc

# ---- p7fel_el: constant RPU (the `null` one), the EL residual switches (arms TE, NE) ----
# EL: flat 512 in phase A; in phase B a positive luma residual on a set of patches (gen_pulse.py
# el-design), flat 512 elsewhere. Same 1920x1080 / x265 settings as el.hevc.
if [[ ! -s el_resid.hevc ]]; then
  python3 "$GEN" el-frames | x265 --input - --input-res 1920x1080 --fps 24000/1001 --input-depth 10 \
    --input-csp i420 --output-depth 10 --profile main10 --preset fast --crf 20 --keyint 48 --min-keyint 48 \
    --no-scenecut --no-open-gop --repeat-headers --aud --frames 1584 -o el_resid.hevc.tmp
  mv el_resid.hevc.tmp el_resid.hevc
fi
dovi_tool inject-rpu -i el_resid.hevc --rpu-in fel_rpu_null.bin -o el_el.hevc
dovi_tool mux --bl base.hevc --el el_el.hevc -o p7_el.hevc
rm -f p7fel_el.mp4
MP4Box -add p7_el.hevc:fps=24000/1001:dvp=f7.6 -brand mp42isom -ab dby1 -quiet -new p7fel_el.mp4
rm el_el.hevc p7_el.hevc

# ---- Counter clips (arms T, NE, TL, PM of SEQ=count) ----
# Same RPUs as p7fel_null / p7fel_l2. Both layers get the same fixed GOP (no adaptive B-frame placement,
# 3 B-frames, pyramid), so BL and EL picture order match and a composer that pairs the wrong EL picture
# shows a different EL number. Two more encodes (4K BL, 1080p EL), a few minutes each.
COUNT=$HERE/fel_count.py
GOP=(--preset fast --keyint 48 --min-keyint 48 --no-scenecut --no-open-gop --bframes 3 --b-adapt 0 --b-pyramid
     --repeat-headers --aud --fps 24000/1001 --input-depth 10 --input-csp i420 --output-depth 10 --profile main10
     --frames 1584)
if [[ ! -s count_bl.hevc ]]; then
  python3 "$COUNT" frames | x265 --input - --input-res 3840x2160 "${GOP[@]}" --crf 14 \
    --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc --range limited \
    --master-display "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(100000000,50)" \
    --max-cll "10000,400" --hdr10 --hdr10-opt --vbv-bufsize 100000 --vbv-maxrate 100000 -o count_bl.hevc.tmp
  mv count_bl.hevc.tmp count_bl.hevc
fi
if [[ ! -s count_el.hevc ]]; then
  python3 "$COUNT" el-frames | x265 --input - --input-res 1920x1080 "${GOP[@]}" --crf 12 -o count_el.hevc.tmp
  mv count_el.hevc.tmp count_el.hevc
fi
for v in null l2; do
  dovi_tool inject-rpu -i count_el.hevc --rpu-in fel_rpu_$v.bin -o count_el_$v.hevc
  dovi_tool mux --bl count_bl.hevc --el count_el_$v.hevc -o count_p7_$v.hevc
  rm -f p7fel_count_$v.mp4
  MP4Box -add count_p7_$v.hevc:fps=24000/1001:dvp=f7.6 -brand mp42isom -ab dby1 -quiet -new p7fel_count_$v.mp4
  rm count_el_$v.hevc count_p7_$v.hevc
done
dovi_tool inject-rpu -i count_bl.hevc --rpu-in rpu_null.bin -o count_mel.hevc
rm -f count_mel.mp4
MP4Box -add count_mel.hevc:fps=24000/1001:dvp=f8.1 -brand mp42isom -ab dby1 -quiet -new count_mel.mp4
rm count_mel.hevc
ls -la "$OUT"/*.mp4
