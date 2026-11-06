#!/usr/bin/env python3
"""Prints the crash reports a test process left behind, for the CI log.

    Scripts/ci-print-crash-reports.py <marker-file> [process-name ...]

A test process that dies on a signal reads as exit 1 with no backtrace: `swift test` only says
"exited with unexpected signal code 11", and the report macOS writes stays on the runner VM, which is
gone after the job. This prints every report newer than <marker-file> from a test process
(`xctest` and `swiftpm-testing-helper` unless names are given): the exception, the abort message,
and the crashed thread's frames, plus the last exception backtrace when there is one. ReportCrash
writes the report several seconds after the process is gone, so this waits up to 30 s for one. It
never fails the step itself. The match is by process name because the report redacts the path.
"""
import glob
import json
import os
import sys
import time

TEST_PROCESSES = set(sys.argv[2:]) or {"xctest", "swiftpm-testing-helper"}
WAIT_SECONDS = 30
MAX_FRAMES = 60


def frame_line(frame, images):
    image = images[frame["imageIndex"]] if frame.get("imageIndex", -1) < len(images) else {}
    name = image.get("name", "?")
    symbol = frame.get("symbol")
    where = f"{symbol} + {frame.get('symbolLocation', 0)}" if symbol else hex(frame.get("imageOffset", 0))
    source = frame.get("sourceFile")
    if source:
        where += f" ({os.path.basename(source)}:{frame.get('sourceLine', '?')})"
    return f"{name:<32} {where}"


def report(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        header_line, _, body_text = f.read().partition("\n")
    header = json.loads(header_line)
    body = json.loads(body_text)
    proc = body.get("procName") or header.get("app_name", "")
    if proc not in TEST_PROCESSES:
        return False

    images = body.get("usedImages", [])
    print(f"::group::crash report {os.path.basename(path)} ({proc}, pid {body.get('pid')})")
    print(f"exception: {json.dumps(body.get('exception'))}")
    if body.get("termination"):
        print(f"termination: {json.dumps(body['termination'])}")
    for key, value in (body.get("asi") or {}).items():
        print(f"abort message ({key}): {' | '.join(value) if isinstance(value, list) else value}")

    if body.get("lastExceptionBacktrace"):
        print("last exception backtrace:")
        for frame in body["lastExceptionBacktrace"][:MAX_FRAMES]:
            print("  " + frame_line(frame, images))

    threads = body.get("threads", [])
    faulting = body.get("faultingThread")
    if faulting is not None and faulting < len(threads):
        thread = threads[faulting]
        label = thread.get("name") or thread.get("queue") or ""
        print(f"crashed thread {faulting} {label}:")
        for frame in thread.get("frames", [])[:MAX_FRAMES]:
            print("  " + frame_line(frame, images))
    print("::endgroup::")
    return True


def new_reports(marker):
    paths = []
    for directory in ("~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"):
        for path in glob.glob(os.path.join(os.path.expanduser(directory), "*.ips")):
            if os.path.getmtime(path) > marker:
                paths.append(path)
    return sorted(paths)


def main():
    marker = os.path.getmtime(sys.argv[1])
    found = 0
    seen = set()
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        for path in new_reports(marker):
            if path in seen:
                continue
            seen.add(path)
            try:
                found += report(path)
            except (OSError, ValueError, KeyError, IndexError) as error:
                print(f"{path}: unreadable crash report ({error})")
        if found or time.monotonic() >= deadline:
            break
        time.sleep(2)
    if not found:
        print("no crash report from a test process (a plain test failure, or ReportCrash wrote none)")


if __name__ == "__main__":
    main()
