#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-packet-disk-fifo.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation host check; does not build or validate a macOS/iOS application target.
xcrun swiftc -swift-version 6 \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketDiskFIFO.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Video/SessionDirectoryLiveness.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/EngineLog.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/LogRedaction.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwarePacketDiskFIFOStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
