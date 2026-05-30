# DropItDown landing page

Static site for Cloudflare Pages.

## Files

| File | Purpose |
|---|---|
| `index.html` | Single-page landing copy + structure |
| `styles.css` | Brand-aligned stylesheet (dark navy + mint green from app icon) |
| `favicon.svg` | App icon (same SVG the macOS bundle ships) |
| `apple-touch-icon.png` | 512×512 PNG render of the icon |
| `og.png` | 1200×630 social preview card |
| `screenshot-main.png` | Main window screenshot used in the “Browse” section |
| `_headers` | Cloudflare Pages cache + security headers |

## Local preview

```sh
cd site
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy to Cloudflare Pages

One-shot, no project config needed:

```sh
cd site
npx wrangler pages deploy . --project-name=dropitdown
```

First run prompts to create the project; subsequent deploys reuse it. After the
first successful deploy, custom domain (e.g. `dropitdown.app`) can be attached
in the Pages dashboard.

For CI deploys, store a Cloudflare API token with `Pages:Edit` permission in
GitHub Actions and use the same command with `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` env vars set.

## Regenerating assets

Source-of-truth for the icon is `../app/Resources/AppIcon.svg`. To refresh:

```sh
cp ../app/Resources/AppIcon.svg favicon.svg
rsvg-convert -w 512 -h 512 favicon.svg -o apple-touch-icon.png
```

To refresh the screenshot, grab the current main window from a built app and
shrink it:

```sh
sips -s format png -Z 1600 ~/Desktop/main.png --out screenshot-main.png
```

The OG card is rendered from a hand-tuned SVG (not checked in — it’s simple
enough to keep inline if it needs editing later).
