from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

APP_SUPPORT_DIR = Path(os.path.expanduser("~/Library/Application Support/DropItDown"))
CONFIG_DIR = APP_SUPPORT_DIR
DATA_DIR = APP_SUPPORT_DIR
CONFIG_PATH = CONFIG_DIR / "config.toml"
JOURNAL_PATH = DATA_DIR / "journal.db"

# Legacy paths from the early CLI days; migrated on first run.
_LEGACY_CONFIG_DIR = Path(os.path.expanduser("~/.config/dropitdown"))
_LEGACY_DATA_DIR = Path(os.path.expanduser("~/.local/share/dropitdown"))


def migrate_from_legacy() -> list[str]:
    """Move config/ignore/rules/journal from the early XDG-style paths to
    the macOS Application Support dir. Idempotent — returns the list of
    files moved (empty if nothing to migrate)."""
    moved: list[str] = []
    APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    legacy_pairs = [
        (_LEGACY_CONFIG_DIR / "config.toml", APP_SUPPORT_DIR / "config.toml"),
        (_LEGACY_CONFIG_DIR / "ignore", APP_SUPPORT_DIR / "ignore"),
        (_LEGACY_CONFIG_DIR / "rules", APP_SUPPORT_DIR / "rules"),
        (_LEGACY_DATA_DIR / "journal.db", APP_SUPPORT_DIR / "journal.db"),
    ]
    for old, new in legacy_pairs:
        if old.exists() and not new.exists():
            old.replace(new)
            moved.append(str(old.name))
    return moved

DEFAULT_IGNORE_DIRS = [
    "node_modules",
    "venv",
    ".venv",
    ".git",
    ".next",
    "dist",
    "build",
    "target",
    "__pycache__",
    ".cache",
    ".DS_Store",
]


@dataclass
class Config:
    inbox: Path
    archive_root: Path
    md_root: Path
    # BYOK: any OpenAI-compatible endpoint. Key comes from config.toml or the
    # DEEPSEEK_API_KEY env var.
    api_key: str
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-chat"
    max_content_chars: int = 8000
    # Language the one-sentence summaries are written in. Free-form (passed
    # to the model verbatim): "English", "Chinese", "日本語", …
    summary_language: str = "English"
    # Behavior / UX. `drop_action` is what a plain drop does (and the default
    # action of the menu-bar panel): archive | note_only | copy_md.
    # `launch_at_login` mirrors the macOS login-item registration for the
    # settings UI.
    drop_action: str = "archive"
    launch_at_login: bool = False
    # Azure Content Understanding (optional). Auth resolves in this order:
    #   AZURE_API_KEY env var → DefaultAzureCredential (az login).
    cu_endpoint: str = ""
    cu_api_key: str = ""
    cu_analyzer_id: str = ""
    # Restrict which file extensions route to CU. Empty = all CU-supported
    # types. Lowercase extensions without dot, e.g. ["pdf", "png", "wav"].
    cu_file_types: list[str] = field(default_factory=list)

    @classmethod
    def load(cls) -> "Config":
        # Idempotent migration from the early XDG-style paths. Cheap on
        # subsequent runs (just checks that old files don't exist).
        migrate_from_legacy()
        if not CONFIG_PATH.exists():
            raise FileNotFoundError(
                f"No config at {CONFIG_PATH}. Run `dropitdown init` first."
            )
        with CONFIG_PATH.open("rb") as f:
            data = tomllib.load(f)

        return cls(
            inbox=Path(os.path.expanduser(data["inbox"])),
            archive_root=Path(os.path.expanduser(data["archive_root"])),
            md_root=Path(os.path.expanduser(data["md_root"])),
            api_key=data.get("api_key") or os.environ.get("DEEPSEEK_API_KEY", ""),
            base_url=data.get("base_url", "https://api.deepseek.com"),
            model=data.get("model", "deepseek-chat"),
            max_content_chars=int(data.get("max_content_chars", 8000)),
            summary_language=str(data.get("summary_language", "English")),
            cu_endpoint=data.get("cu_endpoint", ""),
            cu_api_key=data.get("cu_api_key", "") or os.environ.get("AZURE_API_KEY", ""),
            cu_analyzer_id=data.get("cu_analyzer_id", ""),
            cu_file_types=[str(t).lower().lstrip(".") for t in data.get("cu_file_types", [])],
            drop_action=str(data.get("drop_action", "archive")),
            launch_at_login=bool(data.get("launch_at_login", False)),
        )


def write_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    str_keys = ["inbox", "archive_root", "md_root", "api_key", "base_url", "model", "drop_action", "summary_language"]
    for key in str_keys:
        if key in cfg:
            lines.append(f'{key} = "{cfg[key]}"')
    if "launch_at_login" in cfg:
        lines.append(f"launch_at_login = {str(bool(cfg['launch_at_login'])).lower()}")
    if "max_content_chars" in cfg:
        lines.append(f"max_content_chars = {cfg['max_content_chars']}")
    CONFIG_PATH.write_text("\n".join(lines) + "\n")


def ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)


# scan_tree moved to dropitdown.ignore — that module owns all
# tree-filtering-with-ignore logic.
