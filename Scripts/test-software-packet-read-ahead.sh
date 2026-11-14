#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-packet-read-ahead.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation concurrency/data test; no macOS/iOS application target is built. The three
# Diagnostics files are the real ones, not stubs: the read-ahead logs its QoS transitions (AE#519),
# and a standalone build that shimmed those would compile a different file from the one it claims to
# cover. Each is self-contained (Foundation / os / Darwin), so the list stays cheap. A new dependency
# in the file under test lands here as a link error, which is the whole point of a separate build.
xcrun swiftc \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareStoredPacket.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketCoverage.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareAudioPacketCoverage.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareVideoPacketCoverage.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketDiskFIFO.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketStore.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketReadAhead.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/LiveTimelineFold.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/EngineLog.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/LogRedaction.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/QoSClassName.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwarePacketReadAheadStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
