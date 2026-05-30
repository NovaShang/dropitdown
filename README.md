# DropItDown

Drop a file on the Dock icon. It gets converted, classified, and filed into your archive — original moved, Markdown note written, clipboard updated. Use-once-and-die: no background process at rest.

## Repository layout

```
.
├── src/dropitdown/        Python CLI — convert + classify + archive + journal
├── app/                   Swift .app — Dock drop handler + main window UI
│   ├── Sources/DropItDown/
│   ├── Resources/Info.plist
│   ├── build.sh             Assembles .app bundle with embedded Python
│   └── sign-and-notarize.sh Sign with Developer ID + Apple notarytool + DMG
├── worker/                Cloudflare Worker — hosted DeepSeek proxy
└── docs/prd.md            Product requirements doc
```

## Architecture

```
        ┌──────────────────────────────────┐
        │  DropItDown.app (Swift, mac14+)  │
 file ─→│  Dock drop → application(_:open:)│
        │  ┌─ subprocess (exits after job)─┴───┐
        │  │  Contents/Resources/python/        │
        │  │     bin/dropitdown process <files> │
        │  │       → MarkItDown + Azure CU      │
        │  │       → DeepSeek classify          │
        │  │       → move file, write MD note   │
        │  └─────────────────────────────────────┘
        │  Main window (only on user launch):    │
        │    History · Files · Settings tabs     │
        └────────────────────────────────────────┘
                       │
                       │  classification → hosted mode:
                       ▼
               ┌──────────────────────────────┐
               │  Cloudflare Worker (proxy)   │
               │  device_id → monthly quota   │
               │  forward to DeepSeek         │
               └──────────────────────────────┘
```

Default mode is **hosted**: the app talks to your Cloudflare Worker which checks a per-device monthly quota and forwards to DeepSeek with your key. Users who exceed the free quota can switch to **BYOK** in settings and plug in their own LLM key.

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

## Deploy the proxy

```bash
cd worker
npm install
wrangler kv:namespace create QUOTA   # paste id into wrangler.toml
wrangler secret put DEEPSEEK_API_KEY
wrangler deploy
```

Currently deployed at https://dropitdown-proxy.styleshang.workers.dev (referenced from `DEFAULT_PROXY_URL` in `src/dropitdown/config.py`).

## Use the CLI directly

```bash
uv pip install -e .
dropitdown init        # first-time setup
dropitdown process file1.pdf file2.png
dropitdown history
dropitdown fix "this is an I-94, not a bill"
dropitdown clean       # let the LLM trim ignore patterns
```

Configuration lives at `~/Library/Application Support/DropItDown/`:

| File         | Role                                                     |
|--------------|----------------------------------------------------------|
| `config.toml`| paths, model, CU endpoint                                |
| `ignore`     | gitignore-style patterns excluding noise from the tree   |
| `rules`      | hard rules the LLM has learned from `dropitdown fix`     |
| `journal.db` | SQLite — every archive action for undo / history         |
| `device_id`  | per-install token for the hosted proxy                   |

## Current build / verification status

- ✓ CLI `process` one-shot subcommand (multi-file, serial)
- ✓ Data path migration to `~/Library/Application Support/`
- ✓ hosted / BYOK classification mode
- ✓ `show` / `open-md` helpers for notification click
- ✓ Swift `.app` skeleton (AppDelegate + drop handler)
- ✓ Embedded Python via `python-build-standalone`
- ✓ Main window UI (History / Files / Settings)
- ✓ Sign + notarize + DMG pipeline (script — needs Apple Dev creds to run)
- ✓ Cloudflare Worker proxy (stub — needs `wrangler deploy`)
- ✓ End-to-end drop verified: real .app, real CU, real DeepSeek, real journal record

## Known limitations

- Bundle size ~400 MB — most is MarkItDown's tail of deps (`pandas`, `onnxruntime`, `lxml`, `pdfminer`). Trimming to a CU-only fast path would cut it to ~100 MB; trade-off is losing offline format support.
- Notification permission is requested on first launch but will be denied unless the app is signed with a Developer ID.
- macOS 14+ Sonoma only — pinned via `LSMinimumSystemVersion` and SwiftUI APIs.
