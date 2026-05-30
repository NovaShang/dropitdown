from __future__ import annotations

from pathlib import Path

from markitdown import MarkItDown

from dropitdown.config import Config

# MarkItDown 0.1.6 hardcodes analyzer names that don't exist on real Azure
# Content Understanding resources (it uses `prebuilt-documentSearch` etc.,
# but the resource exposes `prebuilt-read`, `prebuilt-audio`, `prebuilt-video`).
# Patch the routing table at import time so auto-routing works for all
# modalities. Drop this once MarkItDown ships the fix upstream.
try:
    from markitdown.converters import _cu_converter as _cu_mod

    _cu_mod._PREBUILT_ANALYZERS = {
        "document": "prebuilt-read",
        "image": "prebuilt-read",
        "audio": "prebuilt-audio",
        "video": "prebuilt-video",
    }
except Exception:
    pass

IMAGE_EXTS = {"png", "jpg", "jpeg", "heic", "heif", "bmp", "tiff", "tif", "webp"}

# Extension aliases. When cu_file_types lists "jpeg" we also want ".jpg" to
# count, etc.
_EXT_ALIAS = {"jpg": "jpeg", "tif": "tiff", "heic": "heif"}

# Default MarkItDown instance (no cloud converters). Cached because
# `MarkItDown()` does non-trivial init.
_md_default: MarkItDown | None = None
_md_cu: MarkItDown | None = None
_md_cu_signature: tuple | None = None


def to_markdown(path: Path, cfg: Config | None = None) -> str:
    """Convert a file to markdown text.

    Routing:
    - If Azure CU is configured for this file's type → MarkItDown w/ CU.
    - Else if the file is an image → macOS Vision OCR (ocrmac).
    - Else (or as final fallback) → MarkItDown built-in local converters.
    """
    ext = path.suffix.lower().lstrip(".")

    if cfg is not None and _cu_handles(cfg, ext):
        try:
            return _get_md(cfg).convert(str(path)).text_content or ""
        except Exception as e:
            # CU failed (auth, network, quota). Fall through to local paths.
            cu_err = f"[CU failed: {type(e).__name__}: {e}]"
        else:
            cu_err = None
    else:
        cu_err = None

    if ext in IMAGE_EXTS:
        ocr_text = _macos_ocr(path)
        if ocr_text is not None:
            return ocr_text or f"[image: {path.name} — no text recognized]"

    try:
        return _get_md(None).convert(str(path)).text_content or ""
    except Exception as e:
        return cu_err or f"[MarkItDown failed: {type(e).__name__}: {e}]"


def excerpt(text: str, max_chars: int) -> str:
    """Take head + tail snippet; classification cares about both."""
    if len(text) <= max_chars:
        return text
    half = max_chars // 2
    return text[:half] + "\n\n[...truncated...]\n\n" + text[-half:]


def _cu_handles(cfg: Config, ext: str) -> bool:
    if not cfg.cu_endpoint:
        return False
    if not cfg.cu_file_types:
        return True  # CU handles all its supported types
    normalized = _EXT_ALIAS.get(ext, ext)
    allow = {_EXT_ALIAS.get(t, t) for t in cfg.cu_file_types}
    return normalized in allow


def _get_md(cfg: Config | None) -> MarkItDown:
    """Return a cached MarkItDown instance. CU variant gets rebuilt only if
    the relevant config keys change."""
    global _md_default, _md_cu, _md_cu_signature

    if cfg is None or not cfg.cu_endpoint:
        if _md_default is None:
            _md_default = MarkItDown()
        return _md_default

    sig = (
        cfg.cu_endpoint,
        cfg.cu_api_key,
        cfg.cu_analyzer_id,
        tuple(cfg.cu_file_types),
    )
    if _md_cu is None or _md_cu_signature != sig:
        kwargs: dict = {"cu_endpoint": cfg.cu_endpoint}
        if cfg.cu_api_key:
            from azure.core.credentials import AzureKeyCredential

            kwargs["cu_credential"] = AzureKeyCredential(cfg.cu_api_key)
        if cfg.cu_analyzer_id:
            kwargs["cu_analyzer_id"] = cfg.cu_analyzer_id
        if cfg.cu_file_types:
            from markitdown.converters import ContentUnderstandingFileType

            mapped = []
            for t in cfg.cu_file_types:
                norm = _EXT_ALIAS.get(t, t)
                try:
                    mapped.append(ContentUnderstandingFileType(norm))
                except ValueError:
                    pass  # silently drop unknown file types
            if mapped:
                kwargs["cu_file_types"] = mapped
        _md_cu = MarkItDown(**kwargs)
        _md_cu_signature = sig
    return _md_cu


def _macos_ocr(path: Path) -> str | None:
    """Run Apple Vision text recognition. Returns text (possibly empty if
    image has no text), or None if OCR is unavailable on this system."""
    try:
        from ocrmac import ocrmac
    except ImportError:
        return None
    try:
        annotations = ocrmac.OCR(
            str(path),
            recognition_level="accurate",
            language_preference=["zh-Hans", "en-US"],
        ).recognize()
    except Exception:
        return None
    # Annotation tuple: (text, confidence, bbox). Vision returns bbox with
    # origin at bottom-left in normalized coordinates; sort by -y to get
    # top-to-bottom reading order.
    annotations.sort(key=lambda a: -a[2][1])
    return "\n".join(a[0] for a in annotations if a[0])
