"""Report missing repository-local targets referenced by Markdown files."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_DIRECTORIES = {
    ".git",
    ".zig-cache",
    ".zig-global-cache",
    ".zig-local-cache",
    "node_modules",
    "zig-cache",
    "zig-out",
    "zig-pkg",
    # WPT is a vendored submodule. Its documentation intentionally contains
    # links resolved by the upstream site/build tooling, not repository-local
    # files, so validating it here produces false failures whenever WPT is
    # updated independently of Zibra.
    "upstream",
}
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))")
REFERENCE_LINK = re.compile(
    r"^\s{0,3}\[[^\]]+\]:\s*(?:<([^>]+)>|([^\s]+))"
)
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def markdown_files() -> list[Path]:
    return sorted(
        path
        for path in REPOSITORY_ROOT.rglob("*.md")
        if not EXCLUDED_DIRECTORIES.intersection(path.relative_to(REPOSITORY_ROOT).parts)
    )


def local_targets(markdown: Path) -> list[tuple[int, str]]:
    targets: list[tuple[int, str]] = []
    fence_marker: str | None = None
    for line_number, line in enumerate(
        markdown.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if match := FENCE.match(line):
            marker = match.group(1)[0]
            if fence_marker is None:
                fence_marker = marker
            elif fence_marker == marker:
                fence_marker = None
            continue
        if fence_marker is not None:
            continue

        # Code spans often demonstrate Markdown syntax and are not links.
        searchable = re.sub(r"`[^`]*`", "", line)
        for pattern in (INLINE_LINK, REFERENCE_LINK):
            for match in pattern.finditer(searchable):
                target = match.group(1) or match.group(2)
                if target:
                    targets.append((line_number, target))
    return targets


def resolve_local_target(markdown: Path, target: str) -> Path | None:
    if target.startswith(("#", "//")):
        return None

    parsed = urlsplit(target)
    if parsed.scheme or not parsed.path:
        return None

    decoded_path = unquote(parsed.path)
    if decoded_path.startswith("/"):
        candidate = REPOSITORY_ROOT / decoded_path.lstrip("/")
    else:
        candidate = markdown.parent / decoded_path
    return candidate.resolve(strict=False)


def main() -> int:
    missing: list[str] = []
    files = markdown_files()
    for markdown in files:
        for line_number, target in local_targets(markdown):
            resolved = resolve_local_target(markdown, target)
            if resolved is None:
                continue
            try:
                repository_path = resolved.relative_to(REPOSITORY_ROOT)
            except ValueError:
                missing.append(
                    f"{markdown.relative_to(REPOSITORY_ROOT)}:{line_number}: "
                    f"local link escapes the repository: {target}"
                )
                continue
            if not resolved.exists():
                missing.append(
                    f"{markdown.relative_to(REPOSITORY_ROOT)}:{line_number}: "
                    f"missing local link {target!r} (resolved to {repository_path})"
                )

    if missing:
        print("Markdown link check failed:", file=sys.stderr)
        for diagnostic in missing:
            print(f"  {diagnostic}", file=sys.stderr)
        return 1

    print(f"Checked local links in {len(files)} Markdown files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
