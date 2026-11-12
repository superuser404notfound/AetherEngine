#!/usr/bin/env python3
"""Validate the relative links and heading anchors in the docs the website publishes.

The docs site (aetherengine-website) runs starlight-links-validator over the rendered
pages and fails the build on a broken anchor. That check lives in a different repo and
only runs AFTER a push to main, so a bad anchor ships first and is discovered second:
`docs/api.md` linked `formats.md#dolby-vision` against a heading that slugs to
`#dolby-vision-signaling`, and the site build failed on every dispatch from 6.58.0 until
it was noticed two releases later.

This is the same check, in this repo, before the merge. It is deliberately not a general
Markdown linter: it validates exactly what a broken link costs someone, on the site and
on GitHub alike.

  - a relative link to a repo file that does not exist
  - an anchor, same-file or cross-file, that no heading produces

Absolute URLs are not fetched; a link checker that reaches the network is a flake source
and would fail on every rate limit and every temporary outage.

Anchors are slugged the way GitHub and Starlight both do it (github-slugger): lowercase,
drop everything that is not a letter, digit, hyphen, underscore or space, then whitespace
runs become single hyphens, with `-1`, `-2` suffixes for repeats. Verified against the two
cross-file anchors this repo already carries.

Usage:  Scripts/check-doc-links.py [--root DIR]
Exit:   0 clean, 1 broken links found (each one printed with file, line and a suggestion).
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
import unicodedata
from pathlib import Path

# The pages the website publishes, i.e. the files whose anchors are load-bearing off
# GitHub as well. Mirrors the DOCS map in the website's scripts/sync-docs.mjs. A file
# outside this set is still checked for existence when linked, just not crawled.
PUBLISHED = [
    "docs/api.md",
    "docs/formats.md",
    "docs/architecture.md",
    "docs/architecture-native.md",
    "docs/architecture-software.md",
    "docs/source-map.md",
    "docs/cli.md",
    "docs/guide.md",
    "docs/installation.md",
    "docs/features.md",
    "docs/comparison.md",
    "docs/licensing.md",
    "docs/dolby-vision-fel.md",
    "docs/measurements.md",
    "CHANGELOG.md",
    "README.md",
]

# [text](target) and ![alt](target). Rejects a target containing whitespace or a paren so
# a nested-paren link degrades to "not matched" rather than to a wrong target.
LINK = re.compile(r"!?\[(?P<text>[^\]]*)\]\((?P<target>[^()\s]+)\)")

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^(?P<hashes>#{1,6})\s+(?P<text>.+?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"""<a\s[^>]*\bid=["'](?P<id>[^"']+)["']""", re.IGNORECASE)

SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def slug(text: str) -> str:
    """github-slugger's transform, which is also what Starlight gives a heading."""
    # Inline markdown never reaches the rendered heading text.
    text = re.sub(r"`([^`]*)`", r"\1", text)             # code spans
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links and images
    text = re.sub(r"\*\*([^*]+)\*\*|__([^_]+)__", lambda m: m.group(1) or m.group(2), text)
    text = re.sub(r"(?<!\w)[*_]([^*_]+)[*_](?!\w)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)                  # inline HTML
    text = unicodedata.normalize("NFC", text)
    text = text.strip().lower()
    kept = [c for c in text if c.isalnum() or c in "-_" or c.isspace()]
    # Each remaining space becomes its own hyphen. Runs are NOT collapsed: dropping the
    # punctuation out of "Disc (DVD / Blu-ray ISO)" leaves two spaces where the slash was,
    # and the anchor really is `disc-dvd--blu-ray-iso`. Verified against the rendered site.
    return re.sub(r"\s", "-", "".join(kept).strip())


def anchors_of(markdown: str, drop_first_h1: bool = True) -> set[str]:
    """Every fragment the rendered page answers to, deduped the way the slugger does.

    `drop_first_h1` mirrors the website's sync step, which removes the leading H1 because
    Starlight renders the title from frontmatter instead (the rendered H1 carries `_top`).
    So the H1's GitHub anchor resolves on GitHub and 404s on the site, and the stricter of
    the two is the one worth enforcing.
    """
    seen: dict[str, int] = {}
    out: set[str] = {"_top"} if drop_first_h1 else set()
    in_fence = False
    first_h1_seen = False
    for line in markdown.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for match in HTML_ANCHOR.finditer(line):
            out.add(match.group("id"))
        heading = HEADING.match(line)
        if not heading:
            continue
        if drop_first_h1 and not first_h1_seen and len(heading.group("hashes")) == 1:
            first_h1_seen = True
            continue
        base = slug(heading.group("text"))
        if not base:
            continue
        # Starlight's smartypants turns "--" in plain heading text (not inside a code span)
        # into an en-dash, which the slugger then drops; GitHub keeps both hyphens. The same
        # heading then answers to two different anchors, so a link can only work on one of
        # the two sites. Such a heading is no valid link target: reword it, or put the flag
        # in backticks. Found when "### customio --live spool" failed the website build.
        if re.search(r"--", re.sub(r"`[^`]*`", "", heading.group("text"))):
            seen[base] = seen.get(base, 0) + 1
            continue
        count = seen.get(base, 0)
        seen[base] = count + 1
        out.add(base if count == 0 else f"{base}-{count}")
    return out


def check(root: Path) -> list[str]:
    cache: dict[Path, set[str]] = {}

    def anchors_for(path: Path) -> set[str]:
        if path not in cache:
            cache[path] = anchors_of(path.read_text(encoding="utf-8"))
        return cache[path]

    problems: list[str] = []
    for relative in PUBLISHED:
        source = root / relative
        if not source.exists():
            problems.append(f"{relative}: listed as published but missing from the repo")
            continue
        for lineno, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
            for match in LINK.finditer(line):
                target = match.group("target")
                if SCHEME.match(target):
                    continue  # http(s), mailto: not our business
                path_part, _, fragment = target.partition("#")

                if path_part:
                    resolved = (source.parent / path_part).resolve()
                    try:
                        shown = resolved.relative_to(root.resolve())
                    except ValueError:
                        problems.append(
                            f"{relative}:{lineno}: `{target}` escapes the repository")
                        continue
                    if not resolved.exists():
                        problems.append(
                            f"{relative}:{lineno}: `{target}` points at {shown}, which does not exist")
                        continue
                else:
                    resolved, shown = source, Path(relative)

                if not fragment or resolved.suffix.lower() != ".md":
                    continue
                available = anchors_for(resolved)
                if fragment in available:
                    continue
                near = difflib.get_close_matches(fragment, sorted(available), n=1, cutoff=0.5)
                hint = f", closest heading is #{near[0]}" if near else ""
                problems.append(
                    f"{relative}:{lineno}: `{target}` has no heading #{fragment} in {shown}{hint}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path)
    args = parser.parse_args()

    problems = check(args.root)
    if problems:
        print(f"Found {len(problems)} broken link(s) in the published docs:\n", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "\nThe docs site validates these anchors at build time, so each one fails"
            "\nthe website build after the push. Fix them here instead.",
            file=sys.stderr)
        return 1
    print(f"All relative links and anchors in {len(PUBLISHED)} published docs resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
