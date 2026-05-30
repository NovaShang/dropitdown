/**
 * DropItDown hosted classification proxy.
 *
 * Pretends to be an OpenAI-compatible endpoint so the Python client doesn't
 * need to know it's talking to us. Validates the device_id (sent as Bearer
 * token), checks the per-device monthly quota in KV, and forwards the
 * request to DeepSeek. Adds `X-Quota-Remaining` to the response so the
 * client can show usage.
 */

export interface Env {
    QUOTA: KVNamespace;
    DEEPSEEK_API_KEY: string;
    DEFAULT_MONTHLY_QUOTA: string;
    UPSTREAM_BASE_URL: string;
}

const CORS_HEADERS: Record<string, string> = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
};

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        if (request.method === "OPTIONS") {
            return new Response(null, { headers: CORS_HEADERS });
        }

        const url = new URL(request.url);

        // Health check
        if (url.pathname === "/" || url.pathname === "/health") {
            return json({ ok: true, service: "dropitdown-proxy" });
        }

        // Quota probe endpoint — clients can poll to show remaining count.
        if (url.pathname === "/v1/quota" && request.method === "GET") {
            const deviceID = extractDeviceID(request);
            if (!deviceID) return jsonError(401, "missing device_id");
            const used = await getMonthlyCount(env, deviceID);
            const limit = parseInt(env.DEFAULT_MONTHLY_QUOTA, 10);
            return json({ used, limit, remaining: Math.max(0, limit - used) });
        }

        // OpenAI-compatible chat completions — only thing the Python client uses.
        if (url.pathname === "/v1/chat/completions" && request.method === "POST") {
            return await handleChatCompletions(request, env);
        }

        return jsonError(404, "not found");
    },
} satisfies ExportedHandler<Env>;

async function handleChatCompletions(request: Request, env: Env): Promise<Response> {
    const deviceID = extractDeviceID(request);
    if (!deviceID) return jsonError(401, "missing or malformed Authorization header (expected Bearer <device_id>)");

    // Reject body sizes that don't make sense for our use case — defends
    // against accidental large payloads inflating our DeepSeek bill.
    const contentLength = parseInt(request.headers.get("content-length") || "0", 10);
    if (contentLength > 256 * 1024) {
        return jsonError(413, "request too large");
    }

    // Check quota before forwarding.
    const used = await getMonthlyCount(env, deviceID);
    const limit = parseInt(env.DEFAULT_MONTHLY_QUOTA, 10);
    if (used >= limit) {
        return jsonError(429, `monthly quota exhausted (${used}/${limit}). Configure your own DeepSeek/OpenAI key in DropItDown settings to keep going.`);
    }

    // Forward to DeepSeek with our own API key.
    const upstreamURL = `${env.UPSTREAM_BASE_URL}/v1/chat/completions`;
    const upstreamReq = new Request(upstreamURL, {
        method: "POST",
        headers: {
            "Content-Type": request.headers.get("content-type") || "application/json",
            "Authorization": `Bearer ${env.DEEPSEEK_API_KEY}`,
        },
        body: request.body,
    });

    const upstreamResp = await fetch(upstreamReq);

    // Increment count only for successful upstream responses — failed
    // requests shouldn't burn a user's quota.
    let newUsed = used;
    if (upstreamResp.ok) {
        newUsed = await incrementMonthlyCount(env, deviceID);
    }

    // Pass through the response with extra quota headers.
    const responseHeaders = new Headers(upstreamResp.headers);
    responseHeaders.set("X-Quota-Used", String(newUsed));
    responseHeaders.set("X-Quota-Limit", String(limit));
    responseHeaders.set("X-Quota-Remaining", String(Math.max(0, limit - newUsed)));
    Object.entries(CORS_HEADERS).forEach(([k, v]) => responseHeaders.set(k, v));
    return new Response(upstreamResp.body, {
        status: upstreamResp.status,
        statusText: upstreamResp.statusText,
        headers: responseHeaders,
    });
}

function extractDeviceID(request: Request): string | null {
    const auth = request.headers.get("authorization") || "";
    const match = auth.match(/^Bearer\s+(.+)$/);
    if (!match) return null;
    const id = match[1].trim();
    // Token shape sanity-check (matches Python's `secrets.token_urlsafe(24)`).
    if (id.length < 16 || id.length > 64) return null;
    if (!/^[A-Za-z0-9_-]+$/.test(id)) return null;
    return id;
}

function monthKey(date: Date = new Date()): string {
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

async function getMonthlyCount(env: Env, deviceID: string): Promise<number> {
    const key = `device:${deviceID}:${monthKey()}`;
    const raw = await env.QUOTA.get(key);
    return raw ? parseInt(raw, 10) : 0;
}

async function incrementMonthlyCount(env: Env, deviceID: string): Promise<number> {
    const key = `device:${deviceID}:${monthKey()}`;
    const current = await getMonthlyCount(env, deviceID);
    const next = current + 1;
    // 35-day TTL — covers a full month with margin.
    await env.QUOTA.put(key, String(next), { expirationTtl: 35 * 24 * 60 * 60 });
    return next;
}

function json(obj: object, status = 200): Response {
    return new Response(JSON.stringify(obj), {
        status,
        headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
}

function jsonError(status: number, message: string): Response {
    return json({ error: { message, code: status } }, status);
}
