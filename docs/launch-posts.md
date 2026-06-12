# Launch posts — paste-ready drafts

Positioning: **"Drop a file → clean Markdown your AI agent can read (and find later). Convert once, locally — stop burning tokens on raw PDFs."** Free, BYOK, local conversion, no account, native macOS, open source.

Replace `LINK` with the site (e.g. `https://novashang.com/dropitdown`) and `REPO` with the GitHub URL once live. Don't post before the notarized DMG is up and a demo GIF exists.

---

## Product Hunt

**Name:** DropItDown
**Tagline (≤60):** Drop a file → Markdown your AI agent can read
**Topics:** Mac · Developer Tools · Artificial Intelligence · Productivity

**Description (≤260):**
> Drag any file onto the menu-bar icon. DropItDown converts it to clean Markdown locally, files it into your vault, and drops the note's path on your clipboard — paste it into Claude Code or Cursor. Convert once; stop feeding raw PDFs to your AI. Free, BYOK, no account.

**Maker's first comment:**
> Hey PH 👋 I live in the terminal with Claude Code. All day I get files — WeChat/Slack downloads, screenshots, PDFs — that I want to hand to my agent. But making an agent parse a docx or PDF directly burns a pile of tokens and is clumsy.
>
> So I built DropItDown: drag a file onto the menu-bar icon → it's converted to clean Markdown **on your Mac** (no upload), filed into a folder in your vault, and the note's path is on your clipboard. I paste that into Claude Code and it reads plain text — a fraction of the tokens. Later I can ask the agent to grep the vault and it finds anything (every note has a one-line summary as the index). One click drops a `CLAUDE.md` in the vault so any agent opened there knows how to search it.
>
> It's **BYOK** — classification runs on your own key (DeepSeek, OpenAI, Claude, any OpenAI-compatible endpoint). No account, no server, your files stay on your Mac. Native SwiftUI, open source.
>
> Honest caveats: macOS 14+ / Apple Silicon, and it's a ~190MB download (bundles a full offline MarkItDown pipeline so there's nothing to install). Would love feedback on what file types you'd throw at it. — Nova

---

## Show HN

**Title:** Show HN: DropItDown – Drop a file, get Markdown your AI agent can read (macOS)

**Body:**
> I kept wanting to hand real-world files (PDFs, docx, screenshots from chat apps) to Claude Code, but having the agent parse a binary directly is expensive and awkward. DropItDown is a tiny menu-bar app for that loop: drag a file onto the icon →
>
> - converted to clean Markdown locally (MarkItDown, no upload, no key needed)
> - filed into the right folder in a plain-Markdown vault, with a one-line summary in YAML frontmatter
> - the written note's **path** lands on the clipboard, so I paste it into Claude Code / Cursor and the agent reads text, not a binary — far fewer tokens
> - `dropitdown agent-skill` writes a `CLAUDE.md` into the vault so any agent opened there knows to grep `summary:` lines to find things
>
> Classification (the "which folder + summary" step) is BYOK — any OpenAI-compatible endpoint with your own key. Conversion itself is local and free. No account, no server. The vault is just Markdown, so zero lock-in (works with Obsidian, or nothing).
>
> Stack: native SwiftUI front end + an embedded python-build-standalone runtime for the MarkItDown/classify pipeline, Developer-ID signed + notarized.
>
> Caveats I already know: macOS 14+ / Apple Silicon only, and the bundle is ~400MB (the price of shipping the whole offline pipeline — nothing to install). Source: REPO. Happy to answer anything.

---

## Reddit

**r/macapps** — Title: `DropItDown – drag any file to the menu bar, get clean Markdown for your AI (free, BYOK, open source)`
> Native menu-bar app: drop a file → it's converted to Markdown locally and filed into a vault, and the note path goes on your clipboard to paste into Claude Code/Cursor. Free, bring-your-own-key, no account, files stay local. Open source. macOS 14+/Apple Silicon. Feedback welcome — LINK

**r/ClaudeAI** — Title: `Made a Mac tool so I stop burning tokens feeding raw PDFs to Claude Code`
> Drop any file on the menu-bar icon → clean Markdown on your Mac → the note's path on your clipboard → paste into Claude Code and it reads text instead of a binary. It also drops a CLAUDE.md in the vault so the agent can grep your archived files later. BYOK, local, open source. LINK

**r/ObsidianMD** (optional) — angle: "auto-ingest real-world files into your vault as Markdown from anywhere on the Mac (works even when Obsidian is closed)."

---

## X / Mastodon

> Drop a file on your menu bar → clean Markdown your AI agent can read, filed in your vault, path on your clipboard.
> Stop feeding raw PDFs to Claude Code and burning tokens. Convert once, locally. Free, BYOK, open source. 🧵 LINK
> [attach the demo GIF]

---

## Comment-section FAQ prep

- **"Why not just upload the file to ChatGPT?"** Many agents/contexts only take text (Cursor, the terminal, web forms). Local conversion is instant, private, offline, and you keep a reusable Markdown copy your agent can re-read and search — you don't re-upload each time.
- **"That's a big download?"** ~190MB (compressed DMG; ~385MB installed). It bundles a full offline MarkItDown pipeline (pandas/onnxruntime/…) so there's nothing to install and it works offline. A leaner OCR-only path could shrink it; on the roadmap.
- **"DeepSeek?"** It's BYOK — DeepSeek is just the default `base_url`. Point it at OpenAI, Anthropic, or any OpenAI-compatible endpoint. Conversion never calls a model; only the folder/summary step does, on your key.
- **"Privacy?"** Originals and notes stay in your folders. Only a short text excerpt is sent for classification, to your own provider. No account, no server, no telemetry.
