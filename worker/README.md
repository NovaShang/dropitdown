# DropItDown classification proxy

Cloudflare Worker that fronts DeepSeek for hosted-mode clients. Each device gets a monthly quota; once exhausted, users see a 429 telling them to add their own API key.

## Deploy

```bash
cd worker
npm install
wrangler login
# 1. Create the KV namespace and paste the returned id into wrangler.toml
wrangler kv:namespace create QUOTA

# 2. Set your DeepSeek API key
wrangler secret put DEEPSEEK_API_KEY

# 3. Deploy
wrangler deploy
```

The worker is then reachable at `https://dropitdown-proxy.<your-subdomain>.workers.dev/v1/chat/completions`.

Point a domain at it (e.g. `api.dropitdown.app`) via the Cloudflare dashboard if you want — the app's `DEFAULT_PROXY_URL` constant should match.

## Tweak quota

The default is `200` calls/device/month, set as a var in `wrangler.toml`. Change it and `wrangler deploy` to apply.

## Endpoints

- `POST /v1/chat/completions` — forwarded to DeepSeek; auth via `Authorization: Bearer <device_id>`. Returns OpenAI-compatible JSON plus `X-Quota-Used`/`X-Quota-Limit`/`X-Quota-Remaining` headers.
- `GET /v1/quota` — returns `{used, limit, remaining}` for the given device.
- `GET /health` — health check.
