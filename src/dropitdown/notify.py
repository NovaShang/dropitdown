from __future__ import annotations

import subprocess


def _escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def notify(title: str, message: str) -> None:
    script = (
        f'display notification "{_escape(message)}" '
        f'with title "{_escape(title)}"'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            check=False,
            capture_output=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


def copy_to_clipboard(text: str) -> bool:
    """Pipe text into the macOS pasteboard via pbcopy. Returns True on
    success, False if pbcopy isn't available or the call timed out."""
    try:
        subprocess.run(
            ["pbcopy"],
            input=text.encode("utf-8"),
            check=False,
            timeout=5,
        )
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
