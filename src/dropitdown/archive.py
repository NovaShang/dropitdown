from __future__ import annotations

import shutil
from datetime import date
from pathlib import Path
from urllib.parse import quote

from dropitdown.classify import Classification


def _unique_path(target: Path) -> Path:
    """If target exists, append ' (2)', ' (3)' to the stem until unique."""
    if not target.exists():
        return target
    stem = target.stem
    suffix = target.suffix
    parent = target.parent
    i = 2
    while True:
        candidate = parent / f"{stem} ({i}){suffix}"
        if not candidate.exists():
            return candidate
        i += 1


def archive_file(
    source: Path,
    archive_root: Path,
    md_root: Path,
    classification: Classification,
    markdown_body: str,
) -> tuple[Path, Path]:
    """Move source into archive root, write a paired MD note in md root. Return both final paths."""
    category = classification.category_path.strip("/") or "Uncategorized"

    archive_dir = archive_root / category
    md_dir = md_root / category
    archive_dir.mkdir(parents=True, exist_ok=True)
    md_dir.mkdir(parents=True, exist_ok=True)

    archived_path = _unique_path(archive_dir / source.name)
    shutil.move(str(source), archived_path)

    md_name = archived_path.stem + ".md"
    md_path = _unique_path(md_dir / md_name)

    file_uri = "file://" + quote(str(archived_path.resolve()))
    safe_summary = classification.summary.replace('"', '\\"')
    frontmatter = (
        "---\n"
        f'original_file: "{file_uri}"\n'
        f"archived_at: {date.today().isoformat()}\n"
        f'summary: "{safe_summary}"\n'
        f'category: "{category}"\n'
        "---\n\n"
    )
    md_path.write_text(frontmatter + markdown_body, encoding="utf-8")

    return archived_path, md_path


def undo(
    source_path: Path,
    archived_path: Path,
    restore_dir: Path | None = None,
) -> tuple[bool, str]:
    """Move archived file back. If restore_dir is given, file lands there
    (basename only); otherwise back to source_path. MD note is left alone."""
    if not archived_path.exists():
        return False, f"Archived file no longer exists: {archived_path}"
    if restore_dir is not None:
        restore_dir.mkdir(parents=True, exist_ok=True)
        target = _unique_path(restore_dir / archived_path.name)
    else:
        if source_path.exists():
            return False, f"Original location is occupied: {source_path}"
        source_path.parent.mkdir(parents=True, exist_ok=True)
        target = source_path
    shutil.move(str(archived_path), target)
    return True, f"Restored to {target}"
