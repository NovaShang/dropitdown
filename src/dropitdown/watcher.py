from __future__ import annotations

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


def process_one(cfg: Config, path: Path, send_notification: bool = True) -> ProcessResult:
    """Process a single file end-to-end. Used by both the watcher (mode B)
    and the `process` subcommand (mode A — Dock drop)."""
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
            path, cfg.archive_root, cfg.md_root, result, md_text
        )

        record_id = journal.record(
            source_path=path,
            archived_path=archived_path,
            md_path=md_path,
            category=result.category_path,
            summary=result.summary,
        )

        tag = "新分类" if result.is_new_category else "已有分类"
        console.print(
            f"[green]✓ #{record_id}[/green] → {result.category_path} "
            f"[dim]({tag})[/dim]"
        )
        console.print(f"  [dim]{result.summary}[/dim]")

        try:
            md_body = md_path.read_text(encoding="utf-8")
            if notify.copy_to_clipboard(md_body):
                console.print("  [dim]📋 copied to clipboard[/dim]")
        except OSError:
            pass

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
