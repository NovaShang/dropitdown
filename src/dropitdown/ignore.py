from __future__ import annotations

import fnmatch
import os
import tomllib
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from dropitdown.config import (
    CONFIG_DIR,
    CONFIG_PATH,
    DEFAULT_IGNORE_DIRS,
)

IGNORE_PATH = CONFIG_DIR / "ignore"


def _ensure_seeded() -> None:
    """Create the ignore file on first use, seeding with defaults + any
    legacy ignore_dirs from the TOML config."""
    if IGNORE_PATH.exists():
        return
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    migrated: list[str] = []
    if CONFIG_PATH.exists():
        try:
            with CONFIG_PATH.open("rb") as f:
                data = tomllib.load(f)
            migrated = list(data.get("ignore_dirs", []))
        except (tomllib.TOMLDecodeError, OSError):
            pass

    seen = set()
    seeds: list[str] = []
    for p in list(DEFAULT_IGNORE_DIRS) + migrated:
        if p not in seen:
            seen.add(p)
            seeds.append(p)

    lines = [
        "# DropItDown ignore patterns — managed by you and the LLM.",
        "# gitignore-style:",
        "#   - one pattern per line",
        "#   - blank lines and # comments ignored",
        "#   - bare name (e.g. 'Larian Studios') matches any dir with that name",
        "#   - '/' makes the pattern anchored to the archive root",
        "#   - glob: * matches anything except /, ? matches a single char",
        "",
    ]
    lines.extend(seeds)
    lines.append("")
    IGNORE_PATH.write_text("\n".join(lines))


def load() -> list[str]:
    """Return current ignore patterns (comments/blanks stripped)."""
    _ensure_seeded()
    patterns: list[str] = []
    for line in IGNORE_PATH.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        patterns.append(s)
    return patterns


def add(patterns: list[str], reason: str = "") -> list[str]:
    """Append new patterns. Skips ones already present. Returns added list."""
    _ensure_seeded()
    existing = set(load())
    added: list[str] = []
    for p in patterns:
        s = (p or "").strip()
        if not s or s in existing:
            continue
        existing.add(s)
        added.append(s)
    if not added:
        return []
    with IGNORE_PATH.open("a") as f:
        tag = reason.strip() if reason else "LLM"
        f.write(f"\n# added by LLM: {tag}\n")
        for p in added:
            f.write(f"{p}\n")
    return added


def is_ignored(rel_path: Path, patterns: list[str]) -> bool:
    """Check whether rel_path (relative to scan root) matches any pattern."""
    parts = rel_path.parts
    full = str(rel_path)
    for raw in patterns:
        p = raw.strip().rstrip("/")
        if not p:
            continue
        if "/" in p:
            if fnmatch.fnmatchcase(full, p):
                return True
            if full == p or full.startswith(p + "/"):
                return True
        else:
            for seg in parts:
                if fnmatch.fnmatchcase(seg, p):
                    return True
    return False


@dataclass
class TreeEntry:
    path: str          # relative to scan root
    depth: int
    n_subdirs: int     # immediate children dirs visible after ignore
    n_files: int       # immediate children files visible after ignore
    has_deeper: bool   # True if max_depth cut off subdirs we didn't include


@dataclass
class TreeListing:
    entries: list[TreeEntry] = field(default_factory=list)
    total_before_cap: int = 0
    truncated: bool = False  # True if we dropped entries to fit max_paths


def _direct_children(
    abs_dir: Path,
    rel_dir: Path,
    patterns: list[str],
) -> tuple[list[str], int]:
    """Count direct subdirs (returned) and direct files (count only), both
    filtered by dotfiles + ignore patterns."""
    subdirs: list[str] = []
    n_files = 0
    try:
        entries = list(os.scandir(abs_dir))
    except OSError:
        return subdirs, n_files
    for e in entries:
        if e.name.startswith("."):
            continue
        child_rel = (rel_dir / e.name) if str(rel_dir) != "." else Path(e.name)
        if is_ignored(child_rel, patterns):
            continue
        try:
            if e.is_dir(follow_symlinks=False):
                subdirs.append(e.name)
            elif e.is_file(follow_symlinks=False):
                n_files += 1
        except OSError:
            continue
    return subdirs, n_files


def scan_tree(
    root: Path,
    patterns: list[str],
    max_depth: int = 3,
    max_paths: int = 300,
) -> TreeListing:
    """Walk root with ignore + depth filtering. Returns a TreeListing whose
    entries are post-order sorted (children before their parent).

    - max_depth: how many levels under root to descend (1 = top-level only).
    - max_paths: cap on entries shown. When exceeded, deepest entries are
      dropped first; `truncated=True` lets the caller tell the LLM.
    """
    if not root.exists():
        return TreeListing()
    root = root.resolve()

    # First pass: collect raw entries with metadata. Use os.walk for the
    # descent + in-place pruning.
    raw: list[TreeEntry] = []
    for dirpath, dirnames, _ in os.walk(root):
        rel = Path(dirpath).resolve().relative_to(root)
        depth = len(rel.parts)
        if depth > max_depth:
            dirnames[:] = []
            continue

        abs_here = Path(dirpath)
        kept_subs, n_files = _direct_children(abs_here, rel, patterns)
        # Mirror the filter onto os.walk's dirnames so descent honors ignores.
        dirnames[:] = [d for d in dirnames if d in set(kept_subs)]

        if depth == max_depth:
            has_deeper = len(kept_subs) > 0
            dirnames[:] = []
        else:
            has_deeper = False

        if str(rel) != ".":
            raw.append(TreeEntry(
                path=str(rel),
                depth=depth,
                n_subdirs=len(kept_subs),
                n_files=n_files,
                has_deeper=has_deeper,
            ))

    total = len(raw)

    # Cap selection: keep shallow entries when truncating (they carry more
    # categorization signal).
    raw.sort(key=lambda e: (e.depth, e.path))
    capped = raw[:max_paths]
    truncated = total > max_paths

    # Display order: post-order — children before their parent.
    ordered = _post_order(capped)

    return TreeListing(
        entries=ordered,
        total_before_cap=total,
        truncated=truncated,
    )


def _post_order(entries: list[TreeEntry]) -> list[TreeEntry]:
    """Reorder so each parent appears AFTER all its kept descendants."""
    by_path = {e.path: e for e in entries}
    children: dict[str | None, list[TreeEntry]] = defaultdict(list)
    roots: list[TreeEntry] = []
    for e in entries:
        parent = str(Path(e.path).parent) if "/" in e.path else None
        if parent in by_path:
            children[parent].append(e)
        else:
            roots.append(e)

    out: list[TreeEntry] = []

    def walk(node: TreeEntry) -> None:
        for c in sorted(children[node.path], key=lambda x: x.path):
            walk(c)
        out.append(node)

    for r in sorted(roots, key=lambda x: x.path):
        walk(r)
    return out


def format_listing(listing: TreeListing, label: str) -> str:
    """Render a TreeListing as a section for the LLM system prompt."""
    if not listing.entries:
        return f"{label}:\n(empty)"
    head = f"{label}:"
    if listing.truncated:
        head = (
            f"{label} (showing {len(listing.entries)} of "
            f"{listing.total_before_cap}; use list_subtree to explore):"
        )
    lines = [head]
    for e in listing.entries:
        marker = " +deeper" if e.has_deeper else ""
        lines.append(
            f"- {e.path} ({e.n_subdirs}d/{e.n_files}f{marker})"
        )
    return "\n".join(lines)


def list_subtree(
    root: Path,
    rel_path: str,
    patterns: list[str],
    max_depth: int = 3,
) -> str:
    """Format the contents of `root/rel_path` recursively up to 3 levels.
    Returned as a plain text block for tool result. Empty / missing paths
    return a clear message."""
    sub_root = (root / rel_path).resolve()
    if not sub_root.exists():
        return f"Path does not exist under archive root: {rel_path}"
    if not sub_root.is_dir():
        return f"Not a directory: {rel_path}"
    # Guard: sub_root must stay under root.
    try:
        sub_root.relative_to(root.resolve())
    except ValueError:
        return f"Path escapes archive root: {rel_path}"

    listing = scan_tree(sub_root, patterns, max_depth=max_depth, max_paths=200)
    if not listing.entries:
        return f"{rel_path}: (no visible content within {max_depth} levels)"
    out = [f"Contents of {rel_path} (up to {max_depth} levels):"]
    for e in listing.entries:
        marker = " +deeper" if e.has_deeper else ""
        out.append(f"- {rel_path}/{e.path} ({e.n_subdirs}d/{e.n_files}f{marker})")
    if listing.truncated:
        out.append(f"(truncated: {listing.total_before_cap} total entries)")
    return "\n".join(out)
