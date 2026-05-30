from __future__ import annotations

import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

from openai import OpenAI

from dropitdown import convert, ignore, journal, rules
from dropitdown.archive import _unique_path
from dropitdown.config import Config


@dataclass
class FixResult:
    new_category: str
    new_summary: str
    new_archived_path: Path
    new_md_path: Path | None
    rule_added: str | None


FIX_SYSTEM = """You are correcting a misclassified file. The user will tell you what went wrong. Decide:

1. Where the file SHOULD live in the archive tree (use existing categories when they fit, create new only when nothing fits).
2. Whether to update the Chinese summary.
3. Whether to record a HARD RULE that prevents the same mistake on future files. A rule should be a single declarative sentence anchored in document type and content cues — not a one-off ("this specific PDF goes to X"). Examples of good rules:
   - "I-20 / I-94 / EAD / visa-related immigration forms always go to Immigration/Forms, never Finance/Bills, even when they mention money or fees."
   - "Lyft/Uber ride receipts go to 票据/差旅, not Archive/Finance/Bills."

Skip the rule (empty string) when the correction is too specific to generalize.

You must call apply_correction with your decision.
"""


APPLY_CORRECTION_TOOL = {
    "type": "function",
    "function": {
        "name": "apply_correction",
        "description": "Apply the user's correction.",
        "parameters": {
            "type": "object",
            "properties": {
                "new_category_path": {
                    "type": "string",
                    "description": "Corrected archive path, forward-slash, no leading slash. Use the SAME path if only the rule or summary needs updating.",
                },
                "new_summary": {
                    "type": "string",
                    "description": "Updated Chinese one-sentence summary. Empty string keeps the current summary.",
                },
                "rule": {
                    "type": "string",
                    "description": "Hard rule to record for future classifications, single declarative sentence. Empty string to skip.",
                },
            },
            "required": ["new_category_path", "new_summary", "rule"],
        },
    },
}


def fix(cfg: Config, record_id: int, user_note: str) -> FixResult:
    rec = journal.get(record_id)
    if rec is None:
        raise ValueError(f"No record #{record_id}")
    if rec.undone:
        raise ValueError(f"Record #{record_id} was undone; nothing to correct.")

    archived = Path(rec.archived_path)
    if not archived.exists():
        raise FileNotFoundError(
            f"Archived file no longer at {archived}. Was it moved manually?"
        )

    md_text = convert.to_markdown(archived, cfg=cfg)
    excerpt_text = convert.excerpt(md_text, cfg.max_content_chars)

    patterns = ignore.load()
    archive_listing = ignore.scan_tree(cfg.archive_root, patterns)
    md_listing = ignore.scan_tree(cfg.md_root, patterns)
    arch_section = ignore.format_listing(archive_listing, "Archive root directories")
    md_section = ignore.format_listing(md_listing, "Markdown root directories")

    existing_rules = rules.active_rules()
    rules_block = ""
    if existing_rules:
        bullets = "\n".join(f"- {r}" for r in existing_rules)
        rules_block = f"\nExisting hard rules:\n{bullets}\n"

    system_msg = f"{FIX_SYSTEM}{rules_block}\n{arch_section}\n\n{md_section}\n"
    user_msg = (
        f"File: {archived.name}\n"
        f"Currently archived at: {archived}\n"
        f"Current category: {rec.category}\n"
        f"Current summary: {rec.summary}\n\n"
        f"User correction: {user_note}\n\n"
        f"Content excerpt:\n---\n{excerpt_text}\n---"
    )

    client = OpenAI(api_key=cfg.api_key, base_url=cfg.base_url)
    resp = client.chat.completions.create(
        model=cfg.model,
        messages=[
            {"role": "system", "content": system_msg},
            {"role": "user", "content": user_msg},
        ],
        tools=[APPLY_CORRECTION_TOOL],
        tool_choice={"type": "function", "function": {"name": "apply_correction"}},
        temperature=0.2,
    )
    msg = resp.choices[0].message
    if not msg.tool_calls:
        raise RuntimeError(f"LLM did not return a tool call: {msg.content}")
    args = json.loads(msg.tool_calls[0].function.arguments)

    new_category = args["new_category_path"].strip().strip("/")
    new_summary = (args.get("new_summary") or "").strip() or (rec.summary or "")
    rule_text = (args.get("rule") or "").strip()

    # Move the original file
    new_archive_dir = cfg.archive_root / new_category
    new_archive_dir.mkdir(parents=True, exist_ok=True)
    new_archived = _unique_path(new_archive_dir / archived.name)
    if archived.resolve() != new_archived.resolve():
        shutil.move(str(archived), new_archived)
    else:
        new_archived = archived

    # Move the MD note alongside, refresh its frontmatter
    new_md_path: Path | None = None
    if rec.md_path:
        old_md = Path(rec.md_path)
        if old_md.exists():
            new_md_dir = cfg.md_root / new_category
            new_md_dir.mkdir(parents=True, exist_ok=True)
            new_md_path = _unique_path(new_md_dir / old_md.name)
            if old_md.resolve() != new_md_path.resolve():
                shutil.move(str(old_md), new_md_path)
            else:
                new_md_path = old_md
            _refresh_frontmatter(
                new_md_path, new_archived, new_category, new_summary
            )

    # Persist correction in journal and rules file
    journal.update_correction(
        record_id, new_category, new_archived, new_md_path, new_summary
    )
    if rule_text:
        rules.add(rule_text, context=f"#{record_id}: {user_note[:80]}")

    return FixResult(
        new_category=new_category,
        new_summary=new_summary,
        new_archived_path=new_archived,
        new_md_path=new_md_path,
        rule_added=rule_text or None,
    )


def _refresh_frontmatter(
    md_path: Path,
    archived: Path,
    category: str,
    summary: str,
) -> None:
    """Rewrite YAML frontmatter in the MD note to point at the new archive
    location, category, and summary. Leaves body content alone."""
    text = md_path.read_text(encoding="utf-8")
    new_uri = "file://" + quote(str(archived.resolve()))
    safe_summary = summary.replace('"', '\\"')
    text = re.sub(
        r'^original_file:.*$',
        f'original_file: "{new_uri}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    text = re.sub(
        r'^category:.*$',
        f'category: "{category}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    text = re.sub(
        r'^summary:.*$',
        f'summary: "{safe_summary}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    md_path.write_text(text, encoding="utf-8")
