from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import typer
from rich.console import Console
from rich.table import Table

# NOTE: keep module-level imports lightweight. `watcher` (→ markitdown) and
# `archive` (→ openai) pull in ~0.6s of heavy dependencies, which the Swift
# app pays on every startup when it only wants `history`/`config`. Import
# those lazily inside the commands that actually need them.
from dropitdown import ignore, journal
from dropitdown.config import (
    CONFIG_PATH,
    Config,
    write_config,
)

app = typer.Typer(
    help="Drop a file, MarkItDown + LLM file your stuff away.",
    no_args_is_help=True,
)
console = Console()


@app.command()
def init() -> None:
    """Interactive setup. Writes ~/.config/dropitdown/config.toml."""
    console.print("[bold]DropItDown setup[/bold]\n")

    inbox = typer.prompt("Inbox folder (watched)", default="~/DropItDown")
    archive_root = typer.prompt("Archive root (original files)", default="~/Documents/Archive")
    md_root = typer.prompt("Markdown root (notes)", default="~/Documents/Notes")
    base_url = typer.prompt("LLM base URL", default="https://api.deepseek.com")
    model = typer.prompt("Model name", default="deepseek-chat")
    api_key = typer.prompt(
        "API key (leave blank to use DEEPSEEK_API_KEY env)",
        default="",
        hide_input=True,
        show_default=False,
    )

    for p in (inbox, archive_root, md_root):
        Path(os.path.expanduser(p)).mkdir(parents=True, exist_ok=True)

    write_config({
        "inbox": inbox,
        "archive_root": archive_root,
        "md_root": md_root,
        "api_key": api_key,
        "base_url": base_url,
        "model": model,
        "max_content_chars": 8000,
    })
    ignore.load()  # seed ignore file with defaults
    console.print(f"\n[green]Wrote[/green] {CONFIG_PATH}")
    console.print(f"[green]Wrote[/green] {ignore.IGNORE_PATH}")
    console.print(f"[dim]Tip: drag {inbox} to the right side of your Dock for quick access.[/dim]")


@app.command()
def setup(
    archive_root: str = typer.Option(..., help="Where original files are filed."),
    md_root: str = typer.Option(..., help="Where Markdown notes are written."),
    inbox: str = typer.Option("~/DropItDown", help="Watched inbox / undo restore dir."),
    drop_action: str = typer.Option("archive", help="archive | note_only | copy_md"),
    api_key: str = typer.Option("", help="OpenAI-compatible API key (BYOK). Can be set later."),
    launch_at_login: bool = typer.Option(False, "--launch-at-login/--no-launch-at-login"),
) -> None:
    """Non-interactive first-run setup, written for the GUI onboarding wizard.
    Creates config.toml and the target folders. Idempotent — overwrites an
    existing config."""
    for p in (inbox, archive_root, md_root):
        Path(os.path.expanduser(p)).mkdir(parents=True, exist_ok=True)
    cfg: dict = {
        "inbox": inbox,
        "archive_root": archive_root,
        "md_root": md_root,
        "drop_action": drop_action,
        "launch_at_login": launch_at_login,
        "max_content_chars": 8000,
    }
    if api_key:
        cfg["api_key"] = api_key
    write_config(cfg)
    ignore.load()  # seed ignore file with defaults
    console.print(f"[green]Wrote[/green] {CONFIG_PATH}")


@app.command()
def start() -> None:
    """Run the inbox watcher (foreground)."""
    from dropitdown import watcher

    cfg = _load_config_or_die()
    if not cfg.api_key:
        console.print("[red]No API key. Set in config or DEEPSEEK_API_KEY env.[/red]")
        raise typer.Exit(1)
    watcher.run(cfg)


@app.command()
def process(
    files: list[Path] = typer.Argument(..., help="One or more file paths to process."),
    json_out: bool = typer.Option(False, "--json", help="Emit one JSON line per file to stdout (for IPC)."),
    notify_native: bool = typer.Option(True, "--notify/--no-notify", help="Send macOS notification per file."),
    move: bool = typer.Option(True, "--move/--no-move", help="Move the original into the archive (--no-move = note only)."),
    folder_mode: str = typer.Option(
        "expand", "--folder-mode",
        help="How to handle dropped directories: 'expand' files each contained "
        "file separately, 'whole' archives the directory as one unit.",
    ),
) -> None:
    """Process one or more files end-to-end (serial). Used by the Mac .app
    when files are dropped on the Dock icon. Exits when done; suitable for
    'launch on demand, die on completion' lifecycle.

    Directories are handled per `--folder-mode`. Exit code: 0 if everything
    succeeded, 1 if any item failed.
    """
    from dropitdown import watcher

    cfg = _load_config_or_die()
    if not cfg.api_key:
        console.print("[red]No API key. Set in config or DEEPSEEK_API_KEY env.[/red]")
        raise typer.Exit(1)

    def emit(result: "watcher.ProcessResult") -> None:
        if not json_out:
            return
        payload = {
            "ok": result.ok,
            "src": str(result.src),
            "record_id": result.record_id,
            "archived_path": str(result.archived_path) if result.archived_path else None,
            "md_path": str(result.md_path) if result.md_path else None,
            "category": result.category,
            "summary": result.summary,
            "error": result.error,
            "skipped_reason": result.skipped_reason,
        }
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    any_failed = False
    for f in files:
        target = f.resolve()
        if target.is_dir():
            results = watcher.process_folder(
                cfg, target, mode=folder_mode, send_notification=notify_native, move=move
            )
        else:
            results = [watcher.process_one(cfg, target, send_notification=notify_native, move=move)]
        for result in results:
            emit(result)
            if not result.ok:
                any_failed = True

    if any_failed:
        raise typer.Exit(1)


@app.command(name="copy-md")
def copy_md(
    file: Path = typer.Argument(..., help="File to convert."),
) -> None:
    """Convert a file to Markdown and copy it to the clipboard. Saves nothing,
    moves nothing — the "copy Markdown" drop action."""
    from dropitdown import convert, notify

    cfg = _load_config_or_die()  # for CU routing; no LLM key needed
    md = convert.to_markdown(file.resolve(), cfg=cfg)
    if notify.copy_to_clipboard(md):
        console.print(f"[green]✓[/green] Copied {len(md)} chars to clipboard")
    else:
        # Clipboard unavailable (headless) — still emit so callers can capture.
        sys.stdout.write(md)


@app.command()
def history(
    n: int = typer.Option(20, "-n", help="How many recent records to show"),
    json_out: bool = typer.Option(False, "--json", help="Emit as JSON array (for the Swift app to consume)."),
) -> None:
    """Show recent archive records."""
    records = journal.recent(limit=n)
    if json_out:
        payload = [
            {
                "id": r.id,
                "ts": r.ts,
                "source_path": r.source_path,
                "archived_path": r.archived_path,
                "md_path": r.md_path,
                "category": r.category,
                "summary": r.summary,
                "undone": r.undone,
            }
            for r in records
        ]
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        return
    if not records:
        console.print("[dim]No history yet.[/dim]")
        return
    table = Table(show_header=True, header_style="bold")
    table.add_column("ID", justify="right")
    table.add_column("When")
    table.add_column("Category")
    table.add_column("File")
    table.add_column("Summary")
    for r in records:
        status = "[strike]" if r.undone else ""
        end = "[/strike]" if r.undone else ""
        table.add_row(
            f"{status}{r.id}{end}",
            r.ts.split("T")[0] if "T" in r.ts else r.ts,
            r.category or "-",
            f"{status}{Path(r.archived_path).name}{end}",
            (r.summary or "")[:60],
        )
    console.print(table)


@app.command()
def undo(record_id: int) -> None:
    """Reverse a record. A normal archive is restored to inbox/_review/ for
    manual triage (its MD note is left as an orphan). A "note only" record
    moved nothing, so undo just deletes the orphan note."""
    from dropitdown import archive as archive_mod

    rec = journal.get(record_id)
    if not rec:
        console.print(f"[red]No record #{record_id}[/red]")
        raise typer.Exit(1)
    if rec.undone:
        console.print(f"[yellow]Record #{record_id} already undone.[/yellow]")
        return

    # Note-only record: nothing was moved, so undo means removing the note.
    if not rec.moved:
        if rec.md_path:
            Path(rec.md_path).unlink(missing_ok=True)
        journal.mark_undone(record_id)
        console.print(f"[green]✓[/green] Removed note (original was never moved)")
        return

    cfg = _load_config_or_die()
    review_dir = cfg.inbox / "_review"
    ok, msg = archive_mod.undo(
        Path(rec.source_path), Path(rec.archived_path), restore_dir=review_dir
    )
    if ok:
        journal.mark_undone(record_id)
        console.print(f"[green]✓[/green] {msg}")
        if rec.md_path:
            console.print(f"[dim]Orphan note left at {rec.md_path}[/dim]")
    else:
        console.print(f"[red]✗ {msg}[/red]")
        raise typer.Exit(1)


@app.command()
def fix(
    note: str = typer.Argument(..., help="One-sentence correction — what went wrong / where it should go."),
    record_id: int = typer.Option(None, "--id", "-i", help="Record to fix. Defaults to the latest."),
) -> None:
    """Send a natural-language correction to the LLM and apply the fix.
    Moves the original file + MD note, updates the journal, and records a
    rule so the same mistake doesn't recur."""
    from dropitdown.correction import fix as do_fix

    cfg = _load_config_or_die()
    if not cfg.api_key:
        console.print("[red]No API key. Set in config or DEEPSEEK_API_KEY env.[/red]")
        raise typer.Exit(1)

    if record_id is None:
        rec = journal.latest()
        if rec is None:
            console.print("[red]No records yet — nothing to fix.[/red]")
            raise typer.Exit(1)
        record_id = rec.id
        console.print(f"[dim]Defaulting to latest: #{record_id} ({Path(rec.archived_path).name})[/dim]")

    try:
        result = do_fix(cfg, record_id, note)
    except (ValueError, FileNotFoundError) as e:
        console.print(f"[red]{e}[/red]")
        raise typer.Exit(1)
    console.print(
        f"[green]✓ #{record_id}[/green] → {result.new_category}"
    )
    console.print(f"  [dim]{result.new_summary}[/dim]")
    if result.rule_added:
        console.print(f"  [yellow]+rule[/yellow] [dim]{result.rule_added}[/dim]")


@app.command()
def clean() -> None:
    """Ask the LLM to review the directory tree and add ignore patterns for noise."""
    from dropitdown.classify import review_tree

    cfg = _load_config_or_die()
    if not cfg.api_key:
        console.print("[red]No API key. Set in config or DEEPSEEK_API_KEY env.[/red]")
        raise typer.Exit(1)
    patterns_before = ignore.load()
    arch = ignore.scan_tree(cfg.archive_root, patterns_before, max_depth=4)
    md = ignore.scan_tree(cfg.md_root, patterns_before, max_depth=4)
    arch_paths = [e.path for e in arch.entries]
    md_paths = [e.path for e in md.entries]
    console.print(
        f"[bold]Reviewing[/bold] {len(arch_paths)} archive dirs, "
        f"{len(md_paths)} md dirs, with {len(patterns_before)} patterns active..."
    )
    added = review_tree(cfg, arch_paths, md_paths)
    if not added:
        console.print("[dim]LLM found nothing to add.[/dim]")
        return
    console.print(f"[green]Added {len(added)} pattern(s):[/green]")
    for p in added:
        console.print(f"  + {p}")
    arch_after = ignore.scan_tree(cfg.archive_root, ignore.load(), max_depth=4)
    console.print(
        f"[dim]Archive tree: {len(arch_paths)} → {len(arch_after.entries)} dirs[/dim]"
    )


@app.command(name="ignore")
def ignore_cmd() -> None:
    """Show current ignore patterns."""
    patterns = ignore.load()
    console.print(f"[bold]Ignore file[/bold]  {ignore.IGNORE_PATH}")
    if not patterns:
        console.print("[dim](no patterns)[/dim]")
        return
    for p in patterns:
        console.print(f"  {p}")


@app.command(name="rules")
def rules_cmd() -> None:
    """Show classification rules learned from corrections."""
    from dropitdown import rules as rules_mod
    active = rules_mod.active_rules()
    console.print(f"[bold]Rules file[/bold]  {rules_mod.RULES_PATH}")
    if not active:
        console.print("[dim](no rules yet — use `dropitdown fix` to add)[/dim]")
        return
    for r in active:
        console.print(f"  • {r}")


@app.command()
def show(record_id: int) -> None:
    """Reveal the archived file in Finder. Used by notification clicks."""
    import subprocess

    rec = journal.get(record_id)
    if rec is None:
        console.print(f"[red]No record #{record_id}[/red]")
        raise typer.Exit(1)
    path = Path(rec.archived_path)
    if not path.exists():
        console.print(f"[yellow]File no longer at {path}[/yellow]")
        raise typer.Exit(1)
    subprocess.run(["open", "-R", str(path)], check=False)


@app.command()
def open_md(record_id: int) -> None:
    """Open the MD note for a record in its default editor."""
    import subprocess

    rec = journal.get(record_id)
    if rec is None or not rec.md_path:
        console.print(f"[red]No MD note for record #{record_id}[/red]")
        raise typer.Exit(1)
    path = Path(rec.md_path)
    if not path.exists():
        console.print(f"[yellow]MD note no longer at {path}[/yellow]")
        raise typer.Exit(1)
    subprocess.run(["open", str(path)], check=False)


config_app = typer.Typer(help="Inspect / edit configuration.")
app.add_typer(config_app, name="config")


@config_app.command("show")
def config_show(
    json_out: bool = typer.Option(False, "--json", help="Emit as JSON (for the Swift UI)."),
) -> None:
    """Print current resolved config."""
    cfg = _load_config_or_die()
    if json_out:
        payload = {
            "inbox": str(cfg.inbox),
            "archive_root": str(cfg.archive_root),
            "md_root": str(cfg.md_root),
            "drop_action": cfg.drop_action,
            "launch_at_login": cfg.launch_at_login,
            "model": cfg.model,
            "base_url": cfg.base_url,
            "has_api_key": bool(cfg.api_key),
            "max_content_chars": cfg.max_content_chars,
            "cu_endpoint": cfg.cu_endpoint,
            "cu_analyzer_id": cfg.cu_analyzer_id,
            "cu_file_types": cfg.cu_file_types,
            "has_cu_key": bool(cfg.cu_api_key),
        }
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        return
    console.print(f"  inbox        {cfg.inbox}")
    console.print(f"  archive      {cfg.archive_root}")
    console.print(f"  md           {cfg.md_root}")
    console.print(f"  model        {cfg.model} @ {cfg.base_url}")


@config_app.command("set")
def config_set(
    key: str = typer.Argument(..., help="Top-level config key (e.g. archive_root, model)."),
    value: str = typer.Argument(..., help="New value."),
) -> None:
    """Set a single config value. Writes config.toml in place."""
    import tomllib

    if not CONFIG_PATH.exists():
        console.print(f"[red]No config at {CONFIG_PATH}[/red]")
        raise typer.Exit(1)
    with CONFIG_PATH.open("rb") as f:
        data = tomllib.load(f)

    # Coerce the incoming string to the right TOML type for known keys, so
    # the Swift settings UI can set list/int values without corrupting them.
    list_keys = {"cu_file_types"}
    int_keys = {"max_content_chars"}
    bool_keys = {"launch_at_login"}
    if key in list_keys:
        data[key] = [
            part.strip().lstrip(".").lower()
            for part in value.split(",")
            if part.strip()
        ]
    elif key in bool_keys:
        data[key] = value.strip().lower() in ("1", "true", "yes", "on")
    elif key in int_keys:
        try:
            data[key] = int(value)
        except ValueError:
            console.print(f"[red]{key} must be an integer[/red]")
            raise typer.Exit(1)
    elif value == "" and key in data:
        # Empty string clears the key entirely (used to unset api keys).
        del data[key]
    else:
        data[key] = value
    # Re-emit as TOML (simple key=value layout, ASCII-safe escaping for strings).
    lines: list[str] = []
    for k, v in data.items():
        if isinstance(v, str):
            escaped = v.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'{k} = "{escaped}"')
        elif isinstance(v, bool):
            lines.append(f"{k} = {str(v).lower()}")
        elif isinstance(v, (int, float)):
            lines.append(f"{k} = {v}")
        elif isinstance(v, list):
            items = ", ".join(f'"{x}"' for x in v)
            lines.append(f"{k} = [{items}]")
    CONFIG_PATH.write_text("\n".join(lines) + "\n")
    console.print(f"[green]✓[/green] {key} = {value}")


@app.command()
def status() -> None:
    """Show config and recent activity."""
    try:
        cfg = Config.load()
    except FileNotFoundError as e:
        console.print(f"[red]{e}[/red]")
        raise typer.Exit(1)
    console.print(f"[bold]Config[/bold]  {CONFIG_PATH}")
    console.print(f"  inbox        {cfg.inbox}")
    console.print(f"  archive      {cfg.archive_root}")
    console.print(f"  md           {cfg.md_root}")
    console.print(f"  model        {cfg.model} @ {cfg.base_url}")
    console.print(f"  api_key      {'set' if cfg.api_key else '[red]missing[/red]'}")
    console.print()
    history(n=10, json_out=False)


def _load_config_or_die() -> Config:
    try:
        return Config.load()
    except FileNotFoundError as e:
        console.print(f"[red]{e}[/red]")
        raise typer.Exit(1)
