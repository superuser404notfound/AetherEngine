#!/bin/zsh
# Builds the HDR10 host, installs it on an Apple TV, serves the clips from this Mac and plays an arm
# sequence with the console attached. Watch the 777 and 1000 nit markers during each arm (README).
#
#   DEVICE="Apple TV" ./run_tv.sh               build + install, then SEQ=main (a 1 min setup arm and six
#                                               arms, about 4 min; SETUP=0 skips the setup arm)
#   DEVICE=... ./run_tv.sh --no-build           play only (app already installed)
#   DEVICE=... SEQ=pulse ./run_tv.sh            no camera: a steady arm, then the metadata switching every
#                                               3 s with and without the chain (about 2 min, watch by eye)
#   DEVICE=... SEQ=cp ./run_tv.sh               the chain pulse alone, for filming: setup, then CP 30 s
#   DEVICE=... SEQ=control ./run_tv.sh          the pulse's control: AVPlayer with the 1000 and the 4000
#                                               nit clip, steady and alternating, then the engine's pulse
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

if [[ -n "${IFACE:-}" ]]; then
  IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
  [[ -n "$IP" ]] || { echo "no IP address on IFACE=$IFACE"; exit 1; }
else
  IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  [[ -n "$IP" ]] || { echo "no IP address on en0 or en1: set IFACE=<interface> or join the Apple TV's network"; exit 1; }
fi
B="http://$IP:$PORT"
S="secs=$SECS"
# SETUP (SETUP_SECS, default 60; SETUP=0 to skip; main, pulse, cp and control) plays the pattern on loop, so the television's HDR
# picture settings, or a camera's exposure, can be set on it before anything is measured.
SETUP_ARM=""
[[ "${SETUP:-1}" != 0 ]] && SETUP_ARM="SETUP|setup|$B/pattern_24.mp4|secs=${SETUP_SECS:-60},"
case "$SEQ" in
  main)
    ARMS="${SETUP_ARM}P|avplayer|$B/pattern_24.mp4|$S,N|native|$B/pattern_24.mp4|$S,S|software|$B/pattern_24.mp4|$S,M|meta|$B/pattern_24.mp4|$S,C|chain|$B/pattern_24.mp4|$S,CM|chainmeta|$B/pattern_24.mp4|$S" ;;
  pulse)
    # S first, so the steady look is fresh when the pulse arms start. 30 s is ten switches.
    ARMS="${SETUP_ARM}S|software|$B/pattern_24.mp4|secs=15,SP|pulse|$B/pattern_24.mp4|secs=30,CP|chainpulse|$B/pattern_24.mp4|secs=30" ;;
  cp)
    # A pulse is its own reference, so CP alone answers for the engine's own buffers.
    ARMS="${SETUP_ARM}CP|chainpulse|$B/pattern_24.mp4|secs=30" ;;
  control)
    # Does the television visibly follow HDR10 metadata at all? P and P4 differ only in metadata, AP
    # alternates them every 6 s through AVPlayer, SP is the engine's pulse for comparison.
    ARMS="${SETUP_ARM}P|avplayer|$B/pattern_24.mp4|secs=15,P4|avplayer|$B/pattern_24_m4000.mp4|secs=15,AP|avpulse|$B/pattern_24.mp4|secs=48,SP|pulse|$B/pattern_24.mp4|secs=30" ;;
  pace)
    ARMS="S24|software|$B/pattern_24.mp4|secs=25,C24|chain|$B/pattern_24.mp4|secs=25,S60|software|$B/pattern_60.mp4|secs=25,C60|chain|$B/pattern_60.mp4|secs=25" ;;
  *) echo "unknown SEQ=$SEQ (main|pulse|cp|control|pace)"; exit 1 ;;
esac
# Only the clips this sequence plays have to exist.
# avpulse also plays the clip's _m4000 twin.
for clip in $(print -r -- "$ARMS" | grep -o "pattern_[0-9a-z_]*\.mp4" | sort -u) \
            $(print -r -- "$ARMS" | grep -o "avpulse|[^|]*/pattern_[0-9]*\.mp4" | grep -o "pattern_[0-9]*" | sed 's/$/_m4000.mp4/'); do
  [[ -s "$OUT/$clip" ]] || { echo "no $OUT/$clip: run Scripts/build.sh first"; exit 1; }
done

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

# Apple's signed python3: with the macOS firewall on, an unsigned one (Homebrew's) accepts the Apple TV's
# connection and loses it at once, and every arm fails with "network connection was lost".
SERVER_PY=python3
[[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import http.server' 2>/dev/null && SERVER_PY=/usr/bin/python3
"$SERVER_PY" "$SERVE" $PORT "$IP" "$OUT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
# Wait until the server answers on the address the Apple TV uses (Xcode's python starts slowly).
for _ in {1..20}; do curl -s -m 2 -o /dev/null -r 0-0 "$B/pattern_24.mp4" && break; sleep 0.5; done
curl -s -m 2 -o /dev/null -r 0-0 "$B/pattern_24.mp4" || { echo "the clip server does not answer on $B (firewall?)"; exit 1; }

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
