from __future__ import annotations

import os
import secrets
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

APP_SUPPORT_DIR = Path(os.path.expanduser("~/Library/Application Support/DropItDown"))
CONFIG_DIR = APP_SUPPORT_DIR
DATA_DIR = APP_SUPPORT_DIR
CONFIG_PATH = CONFIG_DIR / "config.toml"
JOURNAL_PATH = DATA_DIR / "journal.db"
DEVICE_ID_PATH = APP_SUPPORT_DIR / "device_id"

# Default hosted proxy URL — when no api_key is configured, the app talks
# here using a per-device token. The proxy is OpenAI-compatible.
DEFAULT_PROXY_URL = "https://api.dropitdown.app"

# Legacy paths from the early CLI days; migrated on first run.
_LEGACY_CONFIG_DIR = Path(os.path.expanduser("~/.config/dropitdown"))
_LEGACY_DATA_DIR = Path(os.path.expanduser("~/.local/share/dropitdown"))


def load_or_create_device_id() -> str:
    """Read the persisted device_id, generating one on first use."""
    APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    if DEVICE_ID_PATH.exists():
        existing = DEVICE_ID_PATH.read_text().strip()
        if existing:
            return existing
    new_id = secrets.token_urlsafe(24)  # ~192 bits of entropy
    DEVICE_ID_PATH.write_text(new_id)
    os.chmod(DEVICE_ID_PATH, 0o600)
    return new_id


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
    api_key: str
    base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-chat"
    max_content_chars: int = 8000
    # `hosted` (default) talks to the DropItDown proxy with a device token —
    # you get N free classifications/month, no setup. `byok` calls the
    # configured `base_url` directly with your `api_key`.
    classification_mode: str = "hosted"
    proxy_url: str = ""
    device_id: str = ""
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

        # Resolve classification mode. Hosted is the default; BYOK is
        # auto-selected when the user has set a custom api_key.
        explicit_mode = data.get("classification_mode", "").lower()
        user_api_key = data.get("api_key") or os.environ.get("DEEPSEEK_API_KEY", "")
        if explicit_mode in ("hosted", "byok"):
            mode = explicit_mode
        else:
            mode = "byok" if user_api_key else "hosted"

        if mode == "hosted":
            proxy_url = data.get("proxy_url") or DEFAULT_PROXY_URL
            device_id = data.get("device_id") or load_or_create_device_id()
            # Classify code paths use base_url + api_key uniformly — point
            # them at the proxy + device token so they're unaware of mode.
            effective_base = proxy_url
            effective_key = device_id
            effective_model = data.get("model", "deepseek-chat")
        else:
            proxy_url = ""
            device_id = ""
            effective_base = data.get("base_url", "https://api.deepseek.com")
            effective_key = user_api_key
            effective_model = data.get("model", "deepseek-chat")

        return cls(
            inbox=Path(os.path.expanduser(data["inbox"])),
            archive_root=Path(os.path.expanduser(data["archive_root"])),
            md_root=Path(os.path.expanduser(data["md_root"])),
            api_key=effective_key,
            base_url=effective_base,
            model=effective_model,
            max_content_chars=int(data.get("max_content_chars", 8000)),
            classification_mode=mode,
            proxy_url=proxy_url,
            device_id=device_id,
            cu_endpoint=data.get("cu_endpoint", ""),
            cu_api_key=data.get("cu_api_key", "") or os.environ.get("AZURE_API_KEY", ""),
            cu_analyzer_id=data.get("cu_analyzer_id", ""),
            cu_file_types=[str(t).lower().lstrip(".") for t in data.get("cu_file_types", [])],
        )


def write_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    for key in ["inbox", "archive_root", "md_root", "api_key", "base_url", "model"]:
        if key in cfg:
            lines.append(f'{key} = "{cfg[key]}"')
    if "max_content_chars" in cfg:
        lines.append(f"max_content_chars = {cfg['max_content_chars']}")
    CONFIG_PATH.write_text("\n".join(lines) + "\n")


def ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)


# scan_tree moved to dropitdown.ignore — that module owns all
# tree-filtering-with-ignore logic.
