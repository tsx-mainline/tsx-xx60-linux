#!/usr/bin/env python3
"""Check that every relative Markdown link/anchor in README.md and docs/*.md
resolves: the target file exists, and a `#heading-slug` fragment (its own or
another doc's) matches an actual heading. External (http/https/mailto) links
are not checked. Run from the repo root: python3 ci/check-doc-links.py
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["README.md"] + sorted(glob.glob(os.path.join(ROOT, "docs", "*.md")))
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def slugify(heading: str) -> str:
    heading = heading.strip().lower()
    heading = re.sub(r"[^\w\s-]", "", heading)
    heading = re.sub(r"\s+", "-", heading)
    return heading


def heading_slugs(text: str) -> set:
    slugs = set()
    for _, raw in re.findall(r"^(#{1,6})\s+(.*)$", text, re.M):
        raw = re.sub(r"`([^`]*)`", r"\1", raw)
        slug = slugify(raw)
        base, i = slug, 1
        while slug in slugs:
            i += 1
            slug = f"{base}-{i}"
        slugs.add(slug)
    return slugs


def main() -> int:
    anchors = {}
    for path in FILES:
        if os.path.exists(path):
            anchors[path] = heading_slugs(open(path, encoding="utf-8").read())

    errors = []
    for path in FILES:
        if not os.path.exists(path):
            errors.append(f"{path}: file listed but missing")
            continue
        text = open(path, encoding="utf-8").read()
        for m in LINK_RE.finditer(text):
            target = m.group(1)
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            if target.startswith("#"):
                frag = target[1:]
                if frag and frag not in anchors.get(path, set()):
                    errors.append(f"{path}: broken self-anchor {target}")
                continue
            link_path, _, frag = target.partition("#")
            if not link_path:
                continue
            full = os.path.normpath(os.path.join(os.path.dirname(path), link_path))
            if not os.path.exists(full):
                errors.append(f"{path}: broken link {target} -> {os.path.relpath(full, ROOT)}")
                continue
            if frag and full in anchors and frag not in anchors[full]:
                errors.append(f"{path}: broken anchor {target}")

    for e in errors:
        print(e)
    print(f"checked {len(FILES)} files, {len(errors)} broken link(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
