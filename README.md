# DropItDown

Drop a file on the menu-bar icon. It gets converted to Markdown, classified, and filed into your archive — original moved, Markdown note written. Conversion is local; classification runs on your own LLM key (BYOK).

## Repository layout

```
.
├── src/dropitdown/        Python CLI — convert + classify + archive + journal
├── app/                   Swift .app — menu-bar drop target + main window UI
│   ├── Sources/DropItDown/
│   ├── Resources/Info.plist
│   ├── build.sh             Assembles .app bundle with embedded Python
│   └── sign-and-notarize.sh Sign with Developer ID + Apple notarytool + DMG
└── docs/prd.md            Product requirements doc
```

## Architecture

```
        ┌──────────────────────────────────┐
        │  DropItDown.app (Swift, mac14+)  │
 file ─→│  menu-bar drop (status item)     │
        │  ┌─ subprocess (exits after job)─┴───┐
        │  │  Contents/Resources/python/        │
        │  │     bin/dropitdown process <files> │
        │  │       → MarkItDown + Azure CU      │
        │  │       → LLM classify (your key)    │
        │  │       → move file, write MD note   │
        │  └─────────────────────────────────────┘
        │  Main window (opened from the icon):   │
        │    History · Notes · Settings          │
        └────────────────────────────────────────┘
```

Classification is **BYOK**: any OpenAI-compatible endpoint (DeepSeek by default) with your own API key, set during onboarding or later in Settings. Conversion itself is local and needs no key.

## Build the .app

```bash
# One-time
brew install uv

# Build
cd app
./build.sh
open .build/DropItDown.app
```

Output: `app/.build/DropItDown.app` (~400 MB self-contained, no Python install needed on the target machine).

To ship: run `sign-and-notarize.sh` after `build.sh` (requires Apple Developer credentials in env).

## Use the CLI directly

```bash
uv pip install -e .
dropitdown init        # first-time setup
dropitdown process file1.pdf file2.png
dropitdown history
dropitdown fix "this is an I-94, not a bill"
dropitdown clean        # let the LLM trim ignore patterns
dropitdown agent-skill  # write a CLAUDE.md so an agent can search the vault
```

Filing classifies with your LLM key. Converting alone needs no key:
`dropitdown copy-md <file>` puts the Markdown on the clipboard, and the
default GUI drop also copies the written note's path so you can paste it
straight into a coding agent. Summaries are written in `summary_language`
(default English; set to `Chinese`, `日本語`, … in config or Settings).

Configuration lives at `~/Library/Application Support/DropItDown/`:

| File         | Role                                                     |
|--------------|----------------------------------------------------------|
| `config.toml`| paths, model, API key, CU endpoint                       |
| `ignore`     | gitignore-style patterns excluding noise from the tree   |
| `rules`      | hard rules the LLM has learned from `dropitdown fix`     |
| `journal.db` | SQLite — every archive action for undo / history         |

## Current build / verification status

- ✓ CLI `process` one-shot subcommand (multi-file, serial)
- ✓ Data path migration to `~/Library/Application Support/`
- ✓ BYOK classification (any OpenAI-compatible endpoint)
- ✓ `show` / `open-md` helpers for notification click
- ✓ Swift `.app` skeleton (AppDelegate + drop handler)
- ✓ Embedded Python via `python-build-standalone`
- ✓ Main window UI (History / Notes / Settings)
- ✓ Sign + notarize + DMG pipeline (script — needs Apple Dev creds to run)
- ✓ End-to-end drop verified: real .app, real CU, real DeepSeek, real journal record

## Known limitations

- Bundle size ~400 MB — the cost of a self-contained, offline MarkItDown pipeline (`pandas`, `onnxruntime`, `lxml`, `pdfminer`). Nothing to install on the target machine; trimming to a CU-only fast path would cut it to ~100 MB at the cost of offline format support.
- Notification permission is requested on first launch but will be denied unless the app is signed with a Developer ID (use the notarized release, not an ad-hoc local build).
- macOS 14+ Sonoma only — pinned via `LSMinimumSystemVersion` and SwiftUI APIs.
