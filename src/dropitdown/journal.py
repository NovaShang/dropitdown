from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from dropitdown.config import JOURNAL_PATH, ensure_data_dir

SCHEMA = """
CREATE TABLE IF NOT EXISTS archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    source_path TEXT NOT NULL,
    archived_path TEXT NOT NULL,
    md_path TEXT,
    category TEXT,
    summary TEXT,
    undone INTEGER NOT NULL DEFAULT 0,
    moved INTEGER NOT NULL DEFAULT 1
);
"""


@dataclass
class Record:
    id: int
    ts: str
    source_path: str
    archived_path: str
    md_path: str | None
    category: str | None
    summary: str | None
    undone: bool
    # False when the original file was left in place (the "note only" drop
    # action). Undo of such a record just deletes the note — there's no move
    # to reverse.
    moved: bool


def _connect() -> sqlite3.Connection:
    ensure_data_dir()
    conn = sqlite3.connect(JOURNAL_PATH)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    _migrate(conn)
    return conn


def _migrate(conn: sqlite3.Connection) -> None:
    """Add columns introduced after the initial schema. Pre-existing rows
    are all real archives (file moved), so `moved` defaults to 1."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(archives)")}
    if "moved" not in cols:
        conn.execute("ALTER TABLE archives ADD COLUMN moved INTEGER NOT NULL DEFAULT 1")


def record(
    source_path: Path,
    archived_path: Path,
    md_path: Path | None,
    category: str | None,
    summary: str | None,
    moved: bool = True,
) -> int:
    with _connect() as conn:
        cur = conn.execute(
            "INSERT INTO archives (ts, source_path, archived_path, md_path, category, summary, moved) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                datetime.now(timezone.utc).isoformat(timespec="seconds"),
                str(source_path),
                str(archived_path),
                str(md_path) if md_path else None,
                category,
                summary,
                1 if moved else 0,
            ),
        )
        return int(cur.lastrowid)


def recent(limit: int = 20) -> list[Record]:
    with _connect() as conn:
        rows = conn.execute(
            "SELECT * FROM archives ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
    return [_row_to_record(r) for r in rows]


def get(record_id: int) -> Record | None:
    with _connect() as conn:
        row = conn.execute(
            "SELECT * FROM archives WHERE id = ?", (record_id,)
        ).fetchone()
    return _row_to_record(row) if row else None


def latest() -> Record | None:
    """Most recent record that wasn't undone."""
    with _connect() as conn:
        row = conn.execute(
            "SELECT * FROM archives WHERE undone = 0 ORDER BY id DESC LIMIT 1"
        ).fetchone()
    return _row_to_record(row) if row else None


def mark_undone(record_id: int) -> None:
    with _connect() as conn:
        conn.execute("UPDATE archives SET undone = 1 WHERE id = ?", (record_id,))


def update_correction(
    record_id: int,
    category: str,
    archived_path: Path,
    md_path: Path | None,
    summary: str,
) -> None:
    """Rewrite a record after `dropitdown fix` moved the file."""
    with _connect() as conn:
        conn.execute(
            "UPDATE archives SET category = ?, archived_path = ?, "
            "md_path = ?, summary = ? WHERE id = ?",
            (
                category,
                str(archived_path),
                str(md_path) if md_path else None,
                summary,
                record_id,
            ),
        )


def _row_to_record(row: sqlite3.Row) -> Record:
    return Record(
        id=row["id"],
        ts=row["ts"],
        source_path=row["source_path"],
        archived_path=row["archived_path"],
        md_path=row["md_path"],
        category=row["category"],
        summary=row["summary"],
        undone=bool(row["undone"]),
        moved=bool(row["moved"]),
    )
