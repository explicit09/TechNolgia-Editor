// linkedin-token-exchange: server-side OAuth token exchange + refresh for LinkedIn.
//
// Why this exists: LinkedIn's OAuth 2.0 authorization-code flow REQUIRES the
// client_secret at the /oauth/v2/accessToken step, even when using PKCE. We
// must NOT ship the client_secret in the iOS bundle, so the iOS app calls
// this edge function which holds the secret as a Supabase secret.
//
// Environment variables (set via `supabase secrets set ...`):
//   - LINKEDIN_CLIENT_ID
//   - LINKEDIN_CLIENT_SECRET
//
// Two modes, selected by request body shape:
//   1. Authorization code exchange:
//        POST { code, redirect_uri, code_verifier? }
//      Returns LinkedIn's raw token JSON: { access_token, refresh_token?,
//      expires_in, id_token, scope, ... }.
//
//   2. Refresh token:
//        POST { refresh_token }
//      Returns LinkedIn's raw token JSON.
//
// `verify_jwt` is set to false at deploy time — this endpoint is unauthenticated
// from Supabase's perspective. The actual authentication is LinkedIn's own
// OAuth flow; the iOS app is anonymous to us.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

function requireEnv(name: string): string {
    const value = Deno.env.get(name);
    if (!value) {
        throw new Error(
            `Missing required environment variable: ${name}. ` +
            `Set it via: supabase secrets set ${name}=...`,
        );
    }
    return value;
}

interface CodeExchangeBody {
    code: string;
    redirect_uri: string;
    code_verifier?: string;
}

interface RefreshBody {
    refresh_token: string;
}

type RequestBody = Partial<CodeExchangeBody & RefreshBody>;

const LINKEDIN_TOKEN_URL = "https://www.linkedin.com/oauth/v2/accessToken";

// Hard-coded allowlist to prevent the edge function from being abused as an
// open redirector. A malicious caller knowing only the public client_id could
// otherwise substitute a phishing `redirect_uri` when exchanging a code.
// Only applied on the authorization-code branch; refresh tokens don't take a
// redirect URI.
const ALLOWED_REDIRECT_URIS = new Set([
    "com.videoeditor.shorts://linkedin-callback",
]);

const CORS_HEADERS: Record<string, string> = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(payload: unknown, status: number): Response {
    return new Response(JSON.stringify(payload), {
        status,
        headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
}

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: CORS_HEADERS });
    }
    if (req.method !== "POST") {
        return jsonResponse({ error: "Method not allowed" }, 405);
    }

    let clientId: string;
    let clientSecret: string;
    try {
        clientId = requireEnv("LINKEDIN_CLIENT_ID");
        clientSecret = requireEnv("LINKEDIN_CLIENT_SECRET");
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return jsonResponse({ error: "Server not configured", detail: message }, 500);
    }

    let body: RequestBody;
    try {
        body = (await req.json()) as RequestBody;
    } catch (_err) {
        return jsonResponse({ error: "Invalid JSON body" }, 400);
    }

    const form = new URLSearchParams();
    form.set("client_id", clientId);
    form.set("client_secret", clientSecret);

    if (body.refresh_token) {
        form.set("grant_type", "refresh_token");
        form.set("refresh_token", body.refresh_token);
    } else if (body.code && body.redirect_uri) {
        if (!ALLOWED_REDIRECT_URIS.has(body.redirect_uri)) {
            return jsonResponse({ error: "invalid_redirect_uri" }, 400);
        }
        form.set("grant_type", "authorization_code");
        form.set("code", body.code);
        form.set("redirect_uri", body.redirect_uri);
        if (body.code_verifier) {
            form.set("code_verifier", body.code_verifier);
        }
    } else {
        return jsonResponse({
            error: "Bad request",
            detail: "Provide either { code, redirect_uri } or { refresh_token }.",
        }, 400);
    }

    let liResponse: Response;
    try {
        liResponse = await fetch(LINKEDIN_TOKEN_URL, {
            method: "POST",
            headers: { "content-type": "application/x-www-form-urlencoded" },
            body: form.toString(),
        });
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return jsonResponse({ error: "LinkedIn fetch failed", detail: message }, 502);
    }

    const text = await liResponse.text();
    let parsed: unknown;
    try {
        parsed = JSON.parse(text);
    } catch (_err) {
        // Forward as-is so the client can see raw error
        return new Response(text, {
            status: liResponse.status,
            headers: { "content-type": "text/plain", ...CORS_HEADERS },
        });
    }

    return new Response(JSON.stringify(parsed), {
        status: liResponse.status,
        headers: { "content-type": "application/json", ...CORS_HEADERS },
    });
});
