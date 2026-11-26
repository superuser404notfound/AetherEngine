#!/usr/bin/env python3
"""Fail on the two test shapes CONTRIBUTING.md forbids, before they reach a loaded runner.

  - `try? await Task.sleep`: the `try?` swallows the cancellation a `.timeLimit` trait sends, the
    sleep then returns at once, and a wait loop spins hot until the CI job's own ceiling kills it
    (one 30 minute hang on main, with the log of the killed job discarded).
  - `DispatchQueue.global(...).async` / `.asyncAfter`: the global pool does not start a block while
    its workers are blocked, which a full parallel run of this suite produces (35 s and counting,
    against 3 ms for a detached thread). Parking or timing work goes on `Thread.detachNewThread`.
  - `.timeLimit` under 3 minutes: the limit is the hang catcher, and a green run of this suite has
    hundreds of tests above 60 s, so one minute reported healthy tests as hangs (20 at once on
    2026-10-26). Two minutes went the same way: on the all-traits job even trivial tests read about
    99 s, and a software-host restore test that takes 4 s locally ran 67 to 103 s green, then 121 s
    red (2026-11-13). The house value is `.minutes(3)`.
  - `.offCooperativePoolOneLane` with a `.timeLimit` under 5 minutes: every suite with that trait
    shares one lane, and the time a case waits for it counts against its limit. On 2026-11-26 the
    first case of a new GPU suite with a 3 minute limit waited behind the other GPU suites and timed
    out (274 s in the queue on the rerun). Short cases belong on `.offCooperativePool` instead.

A line that is a justified exception carries `// hygiene: allow <reason>`. Comments and string literals
that only mention a pattern are not flagged. Stdlib only, so it runs on the ubuntu docs job.

Usage: check-test-hygiene.py [root]   (default: the repo's Tests/ directory)
"""
import pathlib
import re
import sys

RULES = [
    (re.compile(r"try\?\s*await\s+Task\.sleep"),
     "try? swallows the .timeLimit cancellation; use try await (or do/catch and return)"),
    (re.compile(r"DispatchQueue\.global\([^)]*\)\.async"),
    "the global pool starves under a full run; use Thread.detachNewThread"),
    (re.compile(r"\.timeLimit\(\s*\.(seconds|milliseconds)\(|\.timeLimit\(\s*\.minutes\(\s*[12]\s*\)"),
     "a time limit under 3 minutes is a coin flip on the runner; use .minutes(3)"),
]
ALLOW = re.compile(r"//\s*hygiene:\s*allow\s+\S")
ATTRIBUTE = re.compile(r"@(Suite|Test)\b\s*\(")
ONE_LANE = re.compile(r"\.offCooperativePoolOneLane\b")
UNDER_FIVE = re.compile(r"\.timeLimit\(\s*\.(seconds|milliseconds)\(|\.timeLimit\(\s*\.minutes\(\s*[1-4]\s*\)")
ONE_LANE_WHY = ("a one-lane suite waits for the lane inside its time limit; use .timeLimit(.minutes(5)) "
                "or more")


def code_part(line: str) -> str:
    """The line without its `//` comment and with string literal contents blanked."""
    out = []
    in_string = False
    i = 0
    while i < len(line):
        c = line[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append(c)
            i += 1
            continue
        if c == '"':
            in_string = True
        elif line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out)


def one_lane_findings(path: pathlib.Path, lines: list[str]) -> list[str]:
    """`@Suite(...)` / `@Test(...)` attributes, over as many lines as they span, that pair the one-lane
    trait with a limit under five minutes."""
    findings = []
    for start, line in enumerate(lines):
        code = code_part(line)
        match = ATTRIBUTE.search(code)
        if not match:
            continue
        text, allowed, depth = "", False, 0
        for offset, raw in enumerate(lines[start:start + 12]):
            part = code_part(raw)
            if offset == 0:
                part = part[match.end() - 1:]
            allowed = allowed or bool(ALLOW.search(raw))
            text += part + " "
            depth += part.count("(") - part.count(")")
            if depth <= 0:
                break
        if not allowed and ONE_LANE.search(text) and UNDER_FIVE.search(text):
            findings.append(f"{path}:{start + 1}: {ONE_LANE_WHY}")
    return findings


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "Tests"
    findings = []
    for path in sorted(root.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        findings.extend(one_lane_findings(path, lines))
        for number, line in enumerate(lines, 1):
            if ALLOW.search(line):
                continue
            code = code_part(line)
            for pattern, why in RULES:
                if pattern.search(code):
                    findings.append(f"{path}:{number}: {why}")
    for finding in findings:
        print(finding)
    if findings:
        print(f"\n{len(findings)} test hygiene violation(s); see CONTRIBUTING.md, or mark a justified "
              "exception with `// hygiene: allow <reason>`.")
        return 1
    print("test hygiene: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
