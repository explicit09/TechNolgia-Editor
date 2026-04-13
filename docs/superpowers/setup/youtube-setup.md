# YouTube Shorts Direct Publish — One-Time Setup

This is a one-shot setup for the iOS Shorts Distribution app's "Publish to YouTube" button. After this, every short can be published in one tap.

Total time: ~15 minutes (most of it is Google Cloud Console + verifying both channels by phone).

Unlike the LinkedIn flow, **YouTube uses no client secret** on iOS — Google's installed-app OAuth profile is PKCE-only, so the entire token exchange runs client-side and there is no edge function to deploy.

## 1. Create (or pick) a Google Cloud Project

1. Go to <https://console.cloud.google.com/projectcreate> and create a project (or use an existing one).
2. Project name: `Shorts Distribution` (or any).

## 2. Enable the YouTube Data API v3

1. Sidebar → **APIs & Services** → **Library**.
2. Search **"YouTube Data API v3"** → **Enable**.

Without this step every API call returns `403 SERVICE_DISABLED`.

## 3. Configure the OAuth Consent Screen

1. **APIs & Services** → **OAuth consent screen**.
2. User type: **External** → Create.
3. Fill required fields:
   - **App name**: `TechNolgia Shorts`
   - **User support email**: your address
   - **Developer contact email**: your address
4. **Scopes** → **Add or Remove Scopes** → tick:
   - `https://www.googleapis.com/auth/youtube.upload`
   - `https://www.googleapis.com/auth/youtube.force-ssl`
5. **Test users** → add your Apple ID Gmail and Elvis's Gmail (the accounts that own the target YouTube channels). Without this, sign-in fails with "Access blocked: TechNolgia has not completed the Google verification process" while the consent screen is in Testing mode.
6. Save.

(Testing mode is fine for two users — no Google verification is required.)

## 4. Create the iOS OAuth Client ID

1. **APIs & Services** → **Credentials** → **Create Credentials** → **OAuth client ID**.
2. **Application type**: **iOS**.
3. **Bundle ID**: `com.videoeditor.shorts` (must match `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).
4. Click Create and **copy the Client ID**, e.g.:

   ```
   1234567890-abcdefghijklmnopqrstuvwxyz123456.apps.googleusercontent.com
   ```

   You'll plug this into the app twice (config + URL scheme).

## 5. Paste the Client ID into the App

Open `VideoEditor/iOSApp/Config/YouTubeConfig.swift` and replace the placeholders:

```swift
// Before:
static let clientID = "REPLACE_WITH_CLIENT_ID.apps.googleusercontent.com"
static let redirectURI = "com.googleusercontent.apps.REPLACE_WITH_CLIENT_ID:/oauth2callback"

// After (using the example above):
static let clientID = "1234567890-abcdefghijklmnopqrstuvwxyz123456.apps.googleusercontent.com"
static let redirectURI = "com.googleusercontent.apps.1234567890-abcdefghijklmnopqrstuvwxyz123456:/oauth2callback"
```

The redirect URI's scheme is the **reverse-DNS form of the client ID**: take everything before `.apps.googleusercontent.com`, prepend `com.googleusercontent.apps.`. The path component (`/oauth2callback`) is arbitrary — don't change it.

## 6. Update the Custom URL Scheme

Open `VideoEditor/iOSApp/project.yml` and replace `REPLACE_WITH_CLIENT_ID` in the YouTube URL type:

```yaml
CFBundleURLTypes:
  - CFBundleTypeRole: Editor
    CFBundleURLName: com.videoeditor.shorts.linkedin
    CFBundleURLSchemes:
      - com.videoeditor.shorts
  - CFBundleTypeRole: Editor
    CFBundleURLName: com.videoeditor.shorts.youtube
    CFBundleURLSchemes:
      - com.googleusercontent.apps.1234567890-abcdefghijklmnopqrstuvwxyz123456  # <-- update this
```

Then regenerate the project:

```bash
cd VideoEditor/iOSApp
xcodegen generate
```

If you forget this step, `ASWebAuthenticationSession` rejects the callback URL and sign-in silently hangs.

## 7. Phone-Verify Both YouTube Channels

`thumbnails.set` requires a phone-verified channel. Without verification you'll get `400 Bad Request` on the thumbnail step. The publish flow catches this and continues with YouTube's auto-generated cover, but you almost certainly want your custom thumbnail uploaded.

For each Google account that will sign in:

1. Sign in to <https://www.youtube.com/verify>.
2. Choose the channel that owns your uploads.
3. Verify by SMS.

This is also the gate for uploads longer than 15 minutes (irrelevant for ≤60s Shorts) and for unlisted/public uploads on brand-new accounts.

## 8. Re-Archive and Push to TestFlight

Bump the build number in `project.yml` (`CURRENT_PROJECT_VERSION` — currently `"3"`, bump to `"4"`), then:

```bash
cd VideoEditor/iOSApp
xcodegen generate
# then archive in Xcode and upload to App Store Connect
```

## 9. Test the Flow

1. Open the app on a real device. (`ASWebAuthenticationSession` works in Simulator too, but Google sometimes blocks the simulator's User-Agent on first sign-in.)
2. **Settings** tab → **Sign in with YouTube**. Complete the Google consent screen for `youtube.upload` and `youtube.force-ssl`.
3. Open any Short → tap **Publish to YouTube**. Watch the progress bar (download → upload → thumbnail).
4. On success, tap **View on YouTube** to open the Shorts URL (`https://www.youtube.com/shorts/<id>`).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Access blocked: TechNolgia has not completed the Google verification process` | Account isn't a test user on the OAuth consent screen | Step 3.5 — add the Gmail address as a test user |
| Sign-in hangs / `invalid_request: redirect_uri_mismatch` | Redirect URI scheme in `project.yml` doesn't match `YouTubeConfig.redirectURI` | Step 6 |
| `403 SERVICE_DISABLED: YouTube Data API v3 has not been used in project ...` | YouTube Data API not enabled | Step 2 |
| `403 quotaExceeded` | Default daily quota is 10,000 units; an upload costs ~1,600 — so ~6 uploads/day. | In Cloud Console request a higher quota, or wait until tomorrow. |
| `400 Bad Request` from `thumbnails.set` | Channel isn't phone-verified | Step 7. The publish flow continues with the auto-generated thumbnail in the meantime. |
| `noChannel` error after sign-in | Google account has no YouTube channel | Sign in to youtube.com first and create a channel. |
| `invalid_grant` on refresh | Refresh token revoked (test-mode tokens expire after 7 days) | Sign out and sign back in. |
| Upload fails partway through | Network blip on the single-shot PUT — we don't yet support resume | Tap **Try Again**. (If this becomes a problem we can add chunked + resume support — the spec is at <https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol>.) |

## Architecture Notes (for future you)

- iOS code lives in `VideoEditor/iOSApp/Networking/YouTube{Auth,Client}.swift` and `Views/YouTube{PublishButton,SettingsSection}.swift`.
- Tokens are stored in the iOS Keychain under service `com.videoeditor.shorts.youtube`, account `youtube-tokens`. `TokenStore<YouTubeTokens>` is a generic Keychain wrapper shared with LinkedIn.
- OAuth: standard `accounts.google.com/o/oauth2/v2/auth` + `oauth2.googleapis.com/token` with PKCE (S256), `access_type=offline` + `prompt=consent` so we always get a refresh_token.
- Upload: `videos.insert` resumable init returns a `Location` session URL; we do a single-shot PUT of the full mp4 (no chunking). YouTube's resumable protocol allows multi-part uploads with `Content-Range` headers — we keep it simple for now.
- Thumbnail: `thumbnails.set?videoId=<id>&uploadType=media` with `Content-Type: image/png`. 400/403 are caught and ignored so non-verified channels still publish.
- Shorts detection is automatic when the video is ≤60s and 9:16. We append `#Shorts` to the description for extra discoverability signal.
- Default `categoryId` is `"22"` (People & Blogs). Override per-publish if needed via `publishShort(categoryID:)`.
- API quota: `videos.insert` costs 1,600 units/day. Default daily project quota is 10,000 → ~6 uploads/day before requesting an increase.
- The full per-platform comparison lives in `docs/superpowers/research/2026-04-13-shorts-distribution-api-comparison.md` §1.
