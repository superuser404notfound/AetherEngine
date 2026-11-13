#!/bin/zsh
# Builds the HDR10 host, installs it on an Apple TV, serves the clips from this Mac and plays an arm
# sequence with the console attached. Watch the 777 and 1000 nit markers during each arm (README).
#
#   DEVICE="Apple TV" ./run_tv.sh               build + install, then SEQ=main (six arms, about 3 min)
#   DEVICE=... ./run_tv.sh --no-build           play only (app already installed)
#   DEVICE=... SEQ=pace ./run_tv.sh             frame pacing: software vs chain at 23.976 and 59.94
#
# Required: DEVICE, the Apple TV's name or identifier as `xcrun devicectl list devices` shows it. Use
#           the identifier when another device on the network has the same name.
# Optional: TEAM (development team id, for signing; a free personal team works), HDR10_BUNDLE_PREFIX (default
#           de.superuser404.hdr10passthrough), HDR10_OUT (clip directory, default ../out),
#           PORT (default 8766), DD (derived data path, default ../.dd, gitignored),
#           IFACE (network interface whose address the Apple TV fetches the clips from; default: the
#           first of en0, en1 that has an address), SECS (seconds per arm, default 25: enough to
#           read the info screen, and short, because the pattern is static and an OLED keeps it).
# Xcode is the one `xcode-select -p` points at; set DEVELOPER_DIR to use another.
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h}
: "${DEVICE:?set DEVICE to a devicectl name or id (xcrun devicectl list devices)}"
xcrun --find xcodebuild >/dev/null 2>&1 || { echo "no Xcode found: install it or run xcode-select -s <Xcode.app>/Contents/Developer"; exit 1; }
PREFIX=${HDR10_BUNDLE_PREFIX:-de.superuser404.hdr10passthrough}
BUNDLE=$PREFIX.host
OUT=${HDR10_OUT:-$ROOT/out}
PORT=${PORT:-8766}
DD=${DD:-$ROOT/.dd}
SEQ=${SEQ:-main}
SECS=${SECS:-25}
SERVE=$ROOT/../DolbyVisionPulse/Scripts/serve.py

for clip in pattern_24 pattern_60; do
  [[ -s "$OUT/$clip.mp4" ]] || { echo "no $OUT/$clip.mp4: run Scripts/build.sh first"; exit 1; }
done
if [[ -n "${IFACE:-}" ]]; then
  IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
  [[ -n "$IP" ]] || { echo "no IP address on IFACE=$IFACE"; exit 1; }
else
  IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  [[ -n "$IP" ]] || { echo "no IP address on en0 or en1: set IFACE=<interface> or join the Apple TV's network"; exit 1; }
fi
B="http://$IP:$PORT"
S="secs=$SECS"
case "$SEQ" in
  main)
    ARMS="P|avplayer|$B/pattern_24.mp4|$S,N|native|$B/pattern_24.mp4|$S,S|software|$B/pattern_24.mp4|$S,M|meta|$B/pattern_24.mp4|$S,C|chain|$B/pattern_24.mp4|$S,CM|chainmeta|$B/pattern_24.mp4|$S" ;;
  pace)
    ARMS="S24|software|$B/pattern_24.mp4|secs=25,C24|chain|$B/pattern_24.mp4|secs=25,S60|software|$B/pattern_60.mp4|secs=25,C60|chain|$B/pattern_60.mp4|secs=25" ;;
  *) echo "unknown SEQ=$SEQ (main|pace)"; exit 1 ;;
esac

if [[ "${1:-}" != "--no-build" ]]; then
  SIGN=()
  [[ -n "${TEAM:-}" ]] && SIGN=(DEVELOPMENT_TEAM="$TEAM")
  # Built for the Apple TV itself, not a generic tvOS device: a free (personal) team gets a provisioning
  # profile only for a device registered to it, and building for the device registers it. xcodebuild
  # names a device by its UDID, devicectl by its own identifier, so the UDID is looked up.
  INFO=$(mktemp)
  xcrun devicectl device info details --device "$DEVICE" --json-output "$INFO" >/dev/null
  UDID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["hardwareProperties"]["udid"])' "$INFO")
  rm -f "$INFO"
  xcodebuild -project "$ROOT/Device/HDR10PassThrough.xcodeproj" -scheme HDR10PassThrough \
    -destination "platform=tvOS,id=$UDID" -configuration Debug -derivedDataPath "$DD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    HDR10_BUNDLE_PREFIX="$PREFIX" "${SIGN[@]}" build | tail -1
  xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Debug-appletvos/HDR10PassThroughHost.app"
fi

python3 "$SERVE" $PORT "$IP" "$OUT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

LOG=tv_${SEQ}_$(date +%Y%m%d_%H%M%S).log
# `process launch` hands --environment-variables to the app process.
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console \
  --environment-variables "{\"HDR10_ARMS\":\"$ARMS\"}" $BUNDLE | tee "$LOG" || echo "(launch ended non-zero: app crashed or was killed; pulling the log anyway)"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier $BUNDLE --source Library/Caches/hdr10-log.txt --destination "${LOG%.log}.app.log" \
  >/dev/null 2>&1 || echo "(could not pull the app log)"
echo "log: $LOG (+ ${LOG%.log}.app.log)"
echo "--- what the engine attached and timed, and each arm's summary:"
grep -h -E "\[HDR10Probe\]|summary" "${LOG%.log}.app.log" 2>/dev/null || grep -h -E "\[HDR10Probe\]|summary" "$LOG" || true
