#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-recovery-point.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation host check, not a macOS/iOS application target.
xcrun swiftc \
  "$TASK_ROOT/Sources/AetherEngine/Decoder/H264RecoveryPoint.swift" \
  "$TASK_ROOT/Scripts/tests/H264RecoveryPointStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
