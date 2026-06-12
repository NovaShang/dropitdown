# DropItDown — Pre-launch checklist

**Audience:** English-speaking developers + technically-curious users.
**Channels:** Product Hunt (secondary) · Show HN · r/macapps · r/ClaudeAI / r/ObsidianMD.
**Positioning:** "Drop a file → clean Markdown your AI agent can read (and find later). Convert once, locally — stop burning tokens on raw PDFs." BYOK, local conversion, no account, no server.

Effort key: **S** ≤1h · **M** a few hours · **L** a day+

---

## ✅ Done

- [x] Toolbar brand: drop the Liquid Glass capsule (`daff01d`)
- [x] BYOK-only + menu-bar-only refactor; hosted/dock/worker removed; **live worker undeployed** (`f389a3e`)
- [x] Copy the written `.md` path(s) to clipboard after filing (`eda07e4`)
- [x] Notes tab: derive vault root from live config (`3805d8d`)
- [x] Onboarding: make the BYOK key requirement explicit + "Get a DeepSeek key" link (`bda9c33`)
- [x] Own DeepSeek key configured; end-to-end drop verified

---

## P0 — blockers (ship-breaking or embarrassing)

- [x] **Notarized, Developer-ID-signed DMG** — **shipped as v0.4.0** (CI release run 27448692950, 5m53s). Published GitHub Release with `DropItDown.dmg` + `DropItDown-v0.4.0.dmg` (191 MB download / ~385 MB installed); `releases/latest/download/DropItDown.dmg` returns 200. Drag-to-`/Applications` layout included. *Still verify notifications fire on the installed notarized build.*
- [x] **Summary language → configurable, default English** — `summary_language` config key (default English; user's own config set to Chinese). Editable in Settings → Classification. Verified: English summary on a fresh config.
- [x] **No-key first run isn't confusing** — `process` now emits a helpful per-file error ("add a key in Settings, or use Copy as Markdown") that reaches the macOS notification, instead of dying silently.

## P1 — makes the pitch land / avoids bad reviews

- [x] **Agent bridge, visible in-product** — `dropitdown agent-skill` writes a `CLAUDE.md` (vault path + live category snapshot + frontmatter schema) into the vault, or `--print` to the clipboard. Surfaced as a "Use with your AI agent" section in Settings (Write CLAUDE.md / Copy agent prompt). Refuses to clobber a hand-written CLAUDE.md.
- [x] **Undo truly reverts** — `undo` now restores to the original location, falling back to `_review/` only if that spot is occupied. (Move-default kept; it suits the workflow.)
- [ ] **Demo GIF (15–20s)** — **M**, *highest-leverage asset, user-driven*. Drag a file → paste the path/markdown into Claude Code → it reads it. (Blocked locally: screen-recording permission for the terminal dropped mid-session.)

## P2 — will draw comments but not blocking

- [x] **Bundle size — answer prepared** — README reframes ~400MB as the cost of a self-contained offline pipeline (nothing to install). Trimming to ~100MB stays an option, not done.
- [x] **README refreshed** — BYOK/menu-bar reality, `agent-skill`, summary-language, copy-path. *(Site screenshots still stale — see below.)*
- [x] **Site copy repositioned** — hero/how-it-works/features now lead with the token/agent hook; removed the stale "use-once-and-die / Dock / ~95MB" claims; added an "Agent-ready" feature. **Still pending: fresh screenshots** (`screenshot-main.png` is stale; blocked by the dropped screen-recording permission).
- [x] **VERSION bump** — 0.3.0 → **0.4.0**. (Tagging `v0.4.0` to trigger the CI release is the user's call — not pushed.)

## Launch day (not dev)

- [ ] PH: tagline, gallery (the GIF + screenshots), maker first comment (the design story: local, BYOK, agent-ready, why convert-once)
- [ ] Show HN post + r/macapps + r/ClaudeAI posts
- [ ] Privacy note: your key, local conversion, no server, no account (trivially true now)

---

## Decisions locked

1. **Summary language** — configurable, **default English**; user's own config set to Chinese. ✓
2. **No-key behavior** — **helpful error** surfaced in the notification (Inbox-fallback deferred). ✓
3. **Bundle** — **ship ~400MB with a ready answer** (trimming deferred). ✓

## What's left — all user-driven / external

- **Notarized DMG** — run the signing pipeline with Apple creds, or push a `v0.4.0` tag to fire the CI release. Then install the notarized build and confirm notifications fire.
- **Demo GIF** — record the drag → paste-into-Claude-Code loop (needs screen-recording permission restored).
- **Site rewrite + fresh screenshots**, then the **Product Hunt / Show HN / Reddit** posts.
