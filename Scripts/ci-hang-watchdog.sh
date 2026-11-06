#!/usr/bin/env bash
# Runs a command and, if it outlives a deadline, prints a stack sample of every process under it
# before killing it.
#
#   Scripts/ci-hang-watchdog.sh <minutes> <command> [args...]
#
# A test process that hangs as a whole (no test finishing, the per-test time limits not firing)
# leaves nothing to read: the job runs into its timeout, the runner kills it, and the log holds the
# `started` line of nearly every test, because the results are still in the pipe buffer. The stacks
# are the only record of what it was waiting on. Exit status is the command's own, or 124 after a
# hang.
set -uo pipefail

minutes=$1
shift

# Crash reports newer than this are the command's (Scripts/ci-print-crash-reports.py).
marker=$(mktemp)

"$@" &
cmd=$!

descendants() {
  local pid
  for pid in $(pgrep -P "$1"); do
    echo "$pid"
    descendants "$pid"
  done
}

deadline=$((SECONDS + minutes * 60))
while kill -0 "$cmd" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::$* still running after $minutes min, sampling every process under it"
    for pid in $(descendants "$cmd"); do
      name=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      [ -n "$name" ] || continue
      echo "::group::sample $pid ($name)"
      sample "$pid" 3 -mayDie 2>&1 || true
      echo "::endgroup::"
    done
    # Listed once: after the TERM the parent may be gone and its children reparented, so a second
    # walk would miss exactly the hung ones the KILL is for.
    tree="$cmd $(descendants "$cmd")"
    kill -TERM $tree 2>/dev/null || true
    sleep 5
    kill -KILL $tree 2>/dev/null || true
    exit 124
  fi
  sleep 5
done

wait "$cmd"
status=$?
# Above 128 the test process died on a signal; its crash report is the only backtrace there is.
# `swift test` folds a child's signal into a plain 1, so 1 is looked at too.
if [ "$status" -eq 1 ] || [ "$status" -gt 128 ]; then
  python3 "$(dirname "$0")/ci-print-crash-reports.py" "$marker" ${CRASH_REPORT_PROCESSES:-} || true
fi
rm -f "$marker"
exit "$status"
