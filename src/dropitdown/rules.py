from __future__ import annotations

from datetime import date

from dropitdown.config import CONFIG_DIR

RULES_PATH = CONFIG_DIR / "rules"


def load() -> str:
    """Return the full rules file as text (header comments and all).
    Used as a learned-corrections section in the classify system prompt."""
    if not RULES_PATH.exists():
        return ""
    return RULES_PATH.read_text()


def active_rules() -> list[str]:
    """Just the rule lines, stripped of comments and blanks."""
    text = load()
    out: list[str] = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        out.append(s.lstrip("-").strip())
    return out


def add(rule: str, context: str = "") -> None:
    """Append a learned rule. `context` is an optional one-line note about
    what triggered it (e.g. record id, user note)."""
    rule = rule.strip()
    if not rule:
        return
    RULES_PATH.parent.mkdir(parents=True, exist_ok=True)
    write_header = not RULES_PATH.exists()
    with RULES_PATH.open("a") as f:
        if write_header:
            f.write(
                "# DropItDown classification rules — appended by `dropitdown fix`.\n"
                "# These are loaded into the classify system prompt as hard rules.\n"
                "\n"
            )
        stamp = date.today().isoformat()
        ctx = f" ({context})" if context else ""
        f.write(f"# {stamp}{ctx}\n")
        f.write(f"- {rule}\n")
