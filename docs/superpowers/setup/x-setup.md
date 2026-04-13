# X (Twitter) Direct Publish — One-Time Setup

This is a one-shot setup for the iOS Shorts Distribution app's "Publish to X" button. After this, every short can be published in one tap.

Total time: ~15 minutes (most of it waiting for developer portal + token provisioning).

Like YouTube (and unlike LinkedIn), **X uses no client secret** on iOS — X's OAuth 2.0 flow for **Public clients** is PKCE-only, so the entire token exchange runs client-side and there is no edge function to deploy.

## 1. Create an X Developer Account + Project

1. Go to <https://developer.x.com> → sign in with the X account that will publish.
2. Sign up for the **Free** tier. As of Feb 6 2026 X switched to a pay-per-use model for media upload, but the Free tier still supports ≤25 posts/month of media upload — well within our needs.
3. After approval, go to the **Developer Portal** → **Projects & Apps** → **+ Add Project**.
4. Project name: `Shorts Distribution` (or any).
5. Inside the Project, click **+ Add App** and give it any name (e.g. `shorts-ios`). Free tier includes one project + one app.

> **Pay-per-use note.** If you expect >25 posts/month (or need higher media-upload throughput), enable pay-per-use billing on the project from the project settings page. Costs are per-API-call; for our Shorts volume this is negligible.

## 2. Configure User Authentication

1. In the app, click **Settings** → **User authentication settings** → **Set up**.
2. **App permissions**: **Read and write and Direct Messages** — or at minimum **Read + Write + Media**.
3. **Type of App**: **Native App** (Public client). This is critical — it's what enables PKCE-only token exchange with no client secret.
4. **App info**:
   - **Callback URI / Redirect URL**: `com.videoeditor.shorts://x-callback`
     Must match **exactly**. Whitespace or trailing-slash mismatches cause `invalid_request: redirect_uri`.
   - **Website URL**: anything — required by X but not validated. Put your Linktree / portfolio / `https://example.com`.
5. Save.

## 3. Copy the OAuth 2.0 Client ID

1. App → **Keys and Tokens** → scroll to **OAuth 2.0 Client ID and Client Secret**.
2. Copy the **Client ID**. It's a base64url-ish string ~30 chars long, e.g. `cmZweEpjcTZXVXFfM1cycGJXMXQ6MTpjaQ`.
3. **IGNORE** the API Key / API Key Secret / Bearer Token — those are v1.1 legacy credentials and are not used here.
4. **IGNORE** the Client Secret — for Native Apps it exists in the UI but MUST NOT be shipped in the app. Our flow is pure PKCE and never sends it.

## 4. Paste the Client ID into the App

Open `VideoEditor/iOSApp/Config/XConfig.swift` and replace the placeholder:

```swift
// Before:
static let clientID = "REPLACE_WITH_CLIENT_ID"

// After:
static let clientID = "cmZweEpjcTZXVXFfM1cycGJXMXQ6MTpjaQ"  // your copied Client ID
```

No other changes needed — `redirectURI`, scopes, and endpoints are all preconfigured.

## 5. URL Scheme — Already Registered

The custom URL scheme `com.videoeditor.shorts` is already registered in `project.yml` via the LinkedIn entry. X reuses the same scheme but with a different host (`x-callback` vs `linkedin-callback`). No `project.yml` changes required.

Both auth flows rely on `ASWebAuthenticationSession`, which delivers the callback URL directly to the running session's completion handler — there's no AppDelegate scheme routing involved. The two sessions never run simultaneously so the shared scheme is safe.

If you ever need to regenerate the project, just run:

```bash
cd VideoEditor/iOSApp
xcodegen generate
```

## 6. Re-Archive and Push to TestFlight

Bump the build number in `project.yml` (`CURRENT_PROJECT_VERSION`), then archive + upload as usual.

```bash
cd VideoEditor/iOSApp
xcodegen generate
# then archive in Xcode and upload to App Store Connect
```

## 7. Test the Flow

1. Open the app on a real device or simulator.
2. **Settings** tab → **Sign in with X**. Complete the X consent screen (scopes: `tweet.read`, `tweet.write`, `users.read`, `media.write`, `offline.access`).
3. Open any Short → tap **Publish to X**. Watch the progress bar (download → init → chunked append → finalize + poll → tweet).
4. On success, tap **View on X** to open the tweet URL.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `invalid_request: redirect_uri mismatch` | Callback URI in developer portal doesn't match `XConfig.redirectURI` | Step 2.4 — set it to `com.videoeditor.shorts://x-callback` exactly |
| Sign-in completes but token exchange returns `401 invalid_client` | App is NOT set to "Native App" / "Public client" | Step 2.3 — change type to Native App |
| `403 Forbidden` on `/2/tweets` | App permissions set to Read-only | Step 2.2 — set to Read + Write + Media, then re-authorize |
| `403 Forbidden` on `/2/media/upload/initialize` | Missing `media.write` scope, or Free tier monthly quota hit | Re-authorize (we request the scope), or enable pay-per-use |
| `media.finalize` returns `processing_info.state=failed` | Video codec/format not accepted by X | Confirm mp4 is H.264 + AAC. Our pipeline produces this by default. |
| Upload stalls at ~50% for minutes | Network blip on a chunk — we don't yet retry chunks | Tap **Try Again**. If this becomes a pattern we can add per-chunk retry. |
| `X media processing timed out` | Processing took >3 min (hard ceiling) | Retry. X's processing latency is usually <30s for Shorts-length videos. |
| `invalid_grant` on refresh | Refresh token revoked or rotated incorrectly | Sign out and sign back in. |
| No cover / wrong frame used | **Expected.** X API does not support custom video thumbnails. | X auto-generates a cover from the video — there's nothing to configure. |

## Architecture Notes (for future you)

- iOS code lives in `VideoEditor/iOSApp/Networking/X{Auth,Client}.swift` and `Views/X{PublishButton,SettingsSection}.swift`.
- Tokens are stored in the iOS Keychain under service `com.videoeditor.shorts.x`, account `x-tokens`. `TokenStore<XTokens>` is a generic Keychain wrapper shared with LinkedIn + YouTube.
- OAuth: `twitter.com/i/oauth2/authorize` + `api.twitter.com/2/oauth2/token` with PKCE (S256). Public client — no client secret sent.
- Media upload: v2 chunked flow (`initialize` → `append` × N → `finalize` → optionally `STATUS` poll). Chunk size is 4 MB. Legacy v1.1 endpoints were sunset June 9 2025 so we only use v2.
- Tweet create: `POST /2/tweets` with `{ text, media: { media_ids: [...] } }`.
- **Tweet text is capped at 280 chars** (`XConfig.maxTweetTextLength`). `XClient.buildTweetText(body:hashtags:)` does smart truncation: trims the body to the last full word that fits, appends `" …"` if cut, then keeps as many full hashtags as will fit. Hashtags are all-or-nothing — we never cut mid-hashtag. If the body alone doesn't fit, we drop hashtags from the end.
- **No custom thumbnail.** X auto-generates the cover. The publish button surfaces this in a sub-caption on the success card so users aren't surprised.
- Duration limits: ≤140s for unverified accounts, ≤10 min for verified. Our Shorts are ≤60s so this is a non-issue.
- Auto-refresh: every authenticated request catches a single 401 → calls `XAuth.refresh` → retries with the new token. If there's no refresh token or refresh itself fails, the caller sees `notAuthorized` and is prompted to re-sign-in.
- The full per-platform comparison lives in `docs/superpowers/research/2026-04-13-shorts-distribution-api-comparison.md` §5.
