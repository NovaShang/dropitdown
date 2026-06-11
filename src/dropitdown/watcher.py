from __future__ import annotations

import os
import queue
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from dropitdown import archive, classify, convert, ignore, journal, notify
from dropitdown.config import Config

console = Console()


@dataclass
class ProcessResult:
    ok: bool
    src: Path
    record_id: int | None = None
    archived_path: Path | None = None
    md_path: Path | None = None
    category: str | None = None
    summary: str | None = None
    error: str | None = None
    skipped_reason: str | None = None


class _Handler(FileSystemEventHandler):
    def __init__(self, q: queue.Queue[Path]) -> None:
        self.q = q

    def on_created(self, event) -> None:
        if event.is_directory:
            return
        self.q.put(Path(event.src_path))

    def on_moved(self, event) -> None:
        if event.is_directory:
            return
        self.q.put(Path(event.dest_path))


def _wait_for_stable(path: Path, timeout: float = 30.0) -> bool:
    """Wait until file size stops changing — handles in-progress writes/copies."""
    deadline = time.monotonic() + timeout
    last_size = -1
    while time.monotonic() < deadline:
        if not path.exists():
            return False
        size = path.stat().st_size
        if size == last_size and size > 0:
            return True
        last_size = size
        time.sleep(0.5)
    return path.exists() and path.stat().st_size > 0


def process_one(
    cfg: Config, path: Path, send_notification: bool = True, move: bool = True
) -> ProcessResult:
    """Process a single file end-to-end. Used by both the watcher (mode B)
    and the `process` subcommand (mode A — Dock drop).

    `move=False` is the "note only" drop action: classify + write the note but
    leave the original file in place."""
    if path.name.startswith(".") or path.suffix == ".part":
        return ProcessResult(ok=False, src=path, skipped_reason="hidden or partial file")
    if not _wait_for_stable(path):
        console.print(f"[yellow]Skipping {path.name}: never settled[/yellow]")
        return ProcessResult(ok=False, src=path, skipped_reason="never settled")

    console.print(f"[cyan]→ {path.name}[/cyan]")
    try:
        md_text = convert.to_markdown(path, cfg=cfg)
        excerpt = convert.excerpt(md_text, cfg.max_content_chars)

        patterns = ignore.load()
        archive_listing = ignore.scan_tree(cfg.archive_root, patterns)
        md_listing = ignore.scan_tree(cfg.md_root, patterns)

        result = classify.classify(
            cfg, path.name, excerpt, archive_listing, md_listing
        )

        archived_path, md_path = archive.archive_file(
            path, cfg.archive_root, cfg.md_root, result, md_text, move=move
        )

        record_id = journal.record(
            source_path=path,
            archived_path=archived_path,
            md_path=md_path,
            category=result.category_path,
            summary=result.summary,
            moved=move,
        )

        tag = "新分类" if result.is_new_category else "已有分类"
        console.print(
            f"[green]✓ #{record_id}[/green] → {result.category_path} "
            f"[dim]({tag})[/dim]"
        )
        console.print(f"  [dim]{result.summary}[/dim]")

        if send_notification:
            notify.notify(
                title=f"DropItDown · {result.category_path}",
                message=f"{path.name} → {result.summary}",
            )
        return ProcessResult(
            ok=True,
            src=path,
            record_id=record_id,
            archived_path=archived_path,
            md_path=md_path,
            category=result.category_path,
            summary=result.summary,
        )
    except Exception as e:
        console.print(f"[red]✗ {path.name}: {type(e).__name__}: {e}[/red]")
        if send_notification:
            notify.notify(title="DropItDown failed", message=f"{path.name}: {e}")
        return ProcessResult(ok=False, src=path, error=f"{type(e).__name__}: {e}")


def _iter_folder_files(root: Path, patterns: list[str]):
    """Yield processable files anywhere under `root` (recursive), skipping
    hidden paths, `.part` temporaries, and anything an ignore pattern matches.
    Paths are yielded sorted for deterministic ordering."""
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        if any(part.startswith(".") for part in rel.parts):
            continue
        if p.suffix == ".part":
            continue
        if ignore.is_ignored(rel, patterns):
            continue
        yield p


def _prune_empty_dirs(root: Path) -> None:
    """Best-effort removal of `root` and its subdirs once their files have been
    moved out. Directories still holding hidden/ignored files are left intact."""
    for dirpath, _, _ in sorted(os.walk(root), reverse=True):
        try:
            Path(dirpath).rmdir()  # only succeeds when empty
        except OSError:
            pass


def _folder_listing_text(folder: Path, files: list[Path], max_lines: int = 200) -> str:
    """A flat, human- and LLM-readable list of the folder's processable files
    (relative paths). Clearer than a dir-count tree for both classification
    signal and the archived note."""
    rels = [str(f.relative_to(folder)) for f in files]
    lines = [f"Folder '{folder.name}' contains {len(rels)} file(s):"]
    lines += [f"- {r}" for r in rels[:max_lines]]
    if len(rels) > max_lines:
        lines.append(f"... and {len(rels) - max_lines} more")
    return "\n".join(lines)


def _sample_excerpt(
    cfg: Config, files: list[Path], max_files: int = 3, per_file_chars: int = 800
) -> str:
    """Convert the first few files to Markdown and return a labelled, trimmed
    concatenation — extra signal for whole-folder classification. A file that
    fails to convert is silently skipped."""
    parts: list[str] = []
    for f in files[:max_files]:
        try:
            md = convert.to_markdown(f, cfg=cfg)
        except Exception:
            continue
        parts.append(f"### {f.name}\n{convert.excerpt(md, per_file_chars)}")
    return "\n\n".join(parts)


def process_folder(
    cfg: Config, folder: Path, mode: str, send_notification: bool = True, move: bool = True
) -> list[ProcessResult]:
    """Handle a dropped directory.

    - mode "expand": file every contained file independently via `process_one`,
      then prune the emptied directory tree (only when files were moved).
    - mode "whole": classify and archive the folder as one unit, writing a
      single summary note. Returns a one-element list.
    """
    patterns = ignore.load()

    if mode == "expand":
        files = list(_iter_folder_files(folder, patterns))
        if not files:
            return [ProcessResult(ok=False, src=folder, skipped_reason="empty folder")]
        results = [
            process_one(cfg, f, send_notification=send_notification, move=move)
            for f in files
        ]
        if move:
            _prune_empty_dirs(folder)
        return results

    # mode == "whole"
    console.print(f"[cyan]→ {folder.name}/ (whole)[/cyan]")
    try:
        files = list(_iter_folder_files(folder, patterns))
        tree_text = _folder_listing_text(folder, files)
        sample = _sample_excerpt(cfg, files)
        excerpt = tree_text + (f"\n\nSampled file contents:\n{sample}" if sample else "")

        archive_listing = ignore.scan_tree(cfg.archive_root, patterns)
        md_listing = ignore.scan_tree(cfg.md_root, patterns)
        result = classify.classify(cfg, folder.name, excerpt, archive_listing, md_listing)

        body = f"# {folder.name}\n\n{result.summary}\n\n## Contents\n\n{tree_text}\n"
        if sample:
            body += f"\n## Sampled files\n\n{sample}\n"

        archived_path, md_path = archive.archive_folder(
            folder, cfg.archive_root, cfg.md_root, result, body, move=move
        )
        record_id = journal.record(
            source_path=folder,
            archived_path=archived_path,
            md_path=md_path,
            category=result.category_path,
            summary=result.summary,
            moved=move,
        )
        tag = "新分类" if result.is_new_category else "已有分类"
        console.print(
            f"[green]✓ #{record_id}[/green] → {result.category_path} [dim]({tag})[/dim]"
        )
        if send_notification:
            notify.notify(
                title=f"DropItDown · {result.category_path}",
                message=f"{folder.name}/ → {result.summary}",
            )
        return [ProcessResult(
            ok=True,
            src=folder,
            record_id=record_id,
            archived_path=archived_path,
            md_path=md_path,
            category=result.category_path,
            summary=result.summary,
        )]
    except Exception as e:
        console.print(f"[red]✗ {folder.name}/: {type(e).__name__}: {e}[/red]")
        if send_notification:
            notify.notify(title="DropItDown failed", message=f"{folder.name}: {e}")
        return [ProcessResult(ok=False, src=folder, error=f"{type(e).__name__}: {e}")]


def _process(cfg: Config, path: Path) -> None:
    """Back-compat shim used by the watcher's internal queue."""
    process_one(cfg, path)


def run(cfg: Config) -> None:
    cfg.inbox.mkdir(parents=True, exist_ok=True)
    q: queue.Queue[Path] = queue.Queue()

    handler = _Handler(q)
    observer = Observer()
    observer.schedule(handler, str(cfg.inbox), recursive=False)
    observer.start()

    console.print(f"[bold]Watching[/bold] {cfg.inbox}")
    console.print(f"  archive  → {cfg.archive_root}")
    console.print(f"  md       → {cfg.md_root}")
    console.print(f"  model    → {cfg.model} @ {cfg.base_url}")
    console.print("[dim]Drop files into the inbox. Ctrl+C to stop.[/dim]\n")

    # Catch up on anything already at the inbox top level (skip subdirs like
    # _review/ which holds undone files awaiting manual triage).
    for existing in cfg.inbox.iterdir():
        if existing.is_file() and not existing.name.startswith("."):
            q.put(existing)

    def worker() -> None:
        while True:
            path = q.get()
            if path is None:
                return
            try:
                _process(cfg, path)
            finally:
                q.task_done()

    t = threading.Thread(target=worker, daemon=True)
    t.start()

    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        console.print("\n[yellow]Stopping...[/yellow]")
    finally:
        observer.stop()
        observer.join()
