#!/usr/bin/env python3
"""Check that the Source map in docs/architecture.md names every Swift source file.

The Source map is the one place that says which file owns what. It only stays useful if
it is complete: a docs audit on 2026-11-12 found 202 of 471 files missing from it, the
whole aetherctl target and two folders without a section, because nothing noticed when a
new file landed.

The check is deliberately loose about WHERE a file is named: any backticked mention of
its file name inside the "## Source map" section counts (a table row, a note, a folder
intro). It does not check that the row sits under the right folder heading or that the
description is still true; it catches the file nobody wrote a line for.

Usage:  Scripts/check-source-map.py [--root DIR]
Exit:   0 every file named, 1 files missing (each one printed with its path).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DOC = "docs/architecture.md"
SECTION = "## Source map"

# `Foo.swift`, `Bar+Baz.swift`, `Folder/Qux.swift`: the last path component is the name.
NAMED = re.compile(r"`(?:[^`]*/)?(?P<name>[^`/]+\.swift)`")


def source_map(markdown: str) -> str:
    """The text from the Source map heading up to the next level-two heading."""
    lines = markdown.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == SECTION)
    except StopIteration:
        raise SystemExit(f"{DOC}: no '{SECTION}' heading found")
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")),
        len(lines))
    return "\n".join(lines[start:end])


def check(root: Path) -> list[Path]:
    named = {m.group("name") for m in NAMED.finditer(source_map((root / DOC).read_text()))}
    sources = sorted((root / "Sources").rglob("*.swift"))
    return [p.relative_to(root) for p in sources if p.name not in named]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path)
    args = parser.parse_args()

    missing = check(args.root)
    if missing:
        print(f"{len(missing)} Swift file(s) not named in the Source map of {DOC}:\n",
              file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        print(
            "\nAdd a one-line row for each under its folder's table, in the existing format.",
            file=sys.stderr)
        return 1
    total = sum(1 for _ in (args.root / "Sources").rglob("*.swift"))
    print(f"All {total} Swift files under Sources/ are named in the Source map.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
