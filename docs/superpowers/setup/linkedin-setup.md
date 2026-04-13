# LinkedIn Direct Publish — One-Time Setup

This is a one-shot setup for the iOS Shorts Distribution app's "Post to LinkedIn" button. After this, every short can be published in one tap.

Total time: ~10 minutes.

## 1. Create the LinkedIn Developer App

1. Go to <https://www.linkedin.com/developers/apps> and click **Create app**.
2. Name: `Shorts Distribution` (or whatever you want users to see on the consent screen).
3. LinkedIn Page: pick any company page you admin (LinkedIn requires this even for personal-only apps).
4. App logo: any 100×100+ PNG.
5. Accept the legal terms and create.

## 2. Add Required Products

In the new app's **Products** tab, request:

- **Sign In with LinkedIn using OpenID Connect** — provides `openid profile email` scopes and the `/v2/userinfo` endpoint we use to resolve the member URN.
- **Share on LinkedIn** — provides the `w_member_social` scope used for posting.

Both are self-serve; you'll see them turn green within a minute.

## 3. Register the Redirect URI

In the **Auth** tab → **Authorized redirect URLs for your app**, click **Add redirect URL** and paste **exactly**:

```
com.videoeditor.shorts://linkedin-callback
```

If the value differs by even one character, the OAuth flow will fail with `redirect_uri_mismatch`.

## 4. Copy Your Credentials

Still on the **Auth** tab, copy:

- **Client ID** (public, goes in the app bundle)
- **Client Secret** (private, NEVER commit — held only as a Supabase secret)

## 5. Paste the Client ID into the App

Open `VideoEditor/iOSApp/Config/LinkedInConfig.swift` and replace the placeholder:

```swift
static let clientID = "REPLACE_WITH_CLIENT_ID"
```

…with your actual Client ID.

## 6. Set the Client Secret as a Supabase Secret

The token-exchange step requires the client secret. We hold it server-side in a Supabase Edge Function (`linkedin-token-exchange`), which is already deployed. Set the secret with:

```bash
supabase secrets set \
  LINKEDIN_CLIENT_ID=<your-client-id> \
  LINKEDIN_CLIENT_SECRET=<your-client-secret> \
  --project-ref vgkocfbtkzmpklruqmsx
```

You can verify with:

```bash
supabase secrets list --project-ref vgkocfbtkzmpklruqmsx | grep LINKEDIN
```

## 7. Re-Archive and Push to TestFlight

Bump the build number in `project.yml` (`CURRENT_PROJECT_VERSION`), then:

```bash
cd VideoEditor/iOSApp
xcodegen generate
# then archive in Xcode and upload to App Store Connect
```

## 8. Test the Flow

1. Open the app on a real device (LinkedIn OAuth will not work properly in the simulator's web auth session for callback handling).
2. Settings tab → **Sign in with LinkedIn**. Complete the LinkedIn OAuth screen.
3. Open any Short → tap **Post to LinkedIn**. Watch the progress bar.
4. On success, tap **View on LinkedIn** to see the post.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` | Redirect URI not registered exactly | Re-add `com.videoeditor.shorts://linkedin-callback` in LinkedIn dev portal |
| `Server not configured` from edge function | Secrets not set | Re-run step 6, including both `LINKEDIN_CLIENT_ID` and `LINKEDIN_CLIENT_SECRET` |
| `LinkedIn not configured` in app | Placeholder still in `LinkedInConfig.swift` | Step 5 |
| Token exchange returns `invalid_client` | Wrong secret | Re-copy the secret from LinkedIn dev portal and re-run step 6 |
| Upload chunk fails | Token expired mid-upload | Sign out & back in (Settings → LinkedIn → Sign out) |
| Sign-in works but post returns 403 | "Share on LinkedIn" product not yet provisioned | Wait a minute and retry — provisioning is usually instant but can lag |

## Architecture Notes (for future you)

- iOS code lives in `VideoEditor/iOSApp/Networking/LinkedIn{Auth,Client}.swift` and `Views/LinkedIn{PublishButton,SettingsSection}.swift`.
- Tokens are stored in the iOS Keychain under service `com.videoeditor.shorts.linkedin`, account `linkedin-tokens`. They survive uninstall on iOS by default for the same Apple ID; clearing them from Settings → LinkedIn → Sign out wipes them properly.
- LinkedIn API version is pinned via `LinkedInConfig.apiVersion` (`"202510"`). Bump it monthly — endpoints under older versions deprecate.
- Edge function source: `supabase/functions/linkedin-token-exchange/index.ts`. Re-deploy with `supabase functions deploy linkedin-token-exchange --project-ref vgkocfbtkzmpklruqmsx --no-verify-jwt` (or via the Supabase MCP `deploy_edge_function` tool).
- The 3-step Videos API + Posts API flow is documented in `docs/superpowers/research/2026-04-13-shorts-distribution-api-comparison.md` §6.
