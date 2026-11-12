#!/usr/bin/env python3
"""Check that docs/source-map.md names every Swift source file.

The source map is the one place that says which file owns what. It only stays useful if
it is complete: a docs audit on 2026-11-12 found 202 of 471 files missing from it, the
whole aetherctl target and two folders without a section, because nothing noticed when a
new file landed.

The check is deliberately loose about WHERE a file is named: any backticked mention of
its file name anywhere in docs/source-map.md counts (a table row, a note, a folder
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

DOC = "docs/source-map.md"

# `Foo.swift`, `Bar+Baz.swift`, `Folder/Qux.swift`: the last path component is the name.
NAMED = re.compile(r"`(?:[^`]*/)?(?P<name>[^`/]+\.swift)`")


def check(root: Path) -> list[Path]:
    named = {m.group("name") for m in NAMED.finditer((root / DOC).read_text())}
    sources = sorted((root / "Sources").rglob("*.swift"))
    return [p.relative_to(root) for p in sources if p.name not in named]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path)
    args = parser.parse_args()

    missing = check(args.root)
    if missing:
        print(f"{len(missing)} Swift file(s) not named in {DOC}:\n",
              file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        print(
            "\nAdd a one-line row for each under its folder's table, in the existing format.",
            file=sys.stderr)
        return 1
    total = sum(1 for _ in (args.root / "Sources").rglob("*.swift"))
    print(f"All {total} Swift files under Sources/ are named in {DOC}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
