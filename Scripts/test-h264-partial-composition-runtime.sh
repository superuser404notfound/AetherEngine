#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_FFMPEG_ROOT="${AETHER_FFMPEG_CHECKOUT:-$TASK_ROOT/.build/checkouts/FFmpegBuild}"
TASK_DRIVER="$TASK_ROOT/Scripts/tests/H264PartialCompositionRuntimeStandalone.swift"
TASK_EXPECTED_REVISION=$(/usr/bin/ruby -rjson -e \
  'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("pins").find { |p| p.fetch("identity") == "ffmpegbuild" }.fetch("state").fetch("revision")' "$TASK_ROOT/Package.resolved")
[[ $(git -C "$TASK_FFMPEG_ROOT" rev-parse HEAD) == "$TASK_EXPECTED_REVISION" ]] \
  || { echo 'Frozen FFmpegBuild revision mismatch' >&2; exit 2; }
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-timestamp-runtime.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
TASK_FRAMEWORK_ARGS=()
for TASK_LIBRARY in AetherLibavformat AetherLibavcodec AetherLibavutil AetherLibswresample AetherLibdav1d AetherLibzvbi; do
  TASK_DIR="$TASK_FFMPEG_ROOT/Sources/$TASK_LIBRARY.xcframework/macos-arm64_x86_64"
  [[ -f "$TASK_DIR/$TASK_LIBRARY.framework/$TASK_LIBRARY" ]] || exit 2
  TASK_FRAMEWORK_ARGS+=(-F "$TASK_DIR" -Xlinker -rpath -Xlinker "$TASK_DIR")
done
# Compile the actual timestamp sessions and parser against the exact bundled dependency.
# This is a focused command-line library check, never an iOS/macOS app build or SwiftPM resolve.
xcrun swiftc -swift-version 6 \
  "${TASK_FRAMEWORK_ARGS[@]}" -framework AetherLibavformat -framework AetherLibavcodec -framework AetherLibavutil \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/PacketBalanceTracker.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/EngineLog.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/LogRedaction.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Decoder/A53SEIParser.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Video/AnnexB.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Decoder/CCDataParser.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Decoder/ParserInit.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Video/H264CompositionOffsetRepair.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Video/H264PartialCompositionRepair.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Video/H264PartialCompositionRepairSession.swift" \
  "$TASK_DRIVER" -o "$TASK_TMP/check"
"$TASK_TMP/check" "$@"
