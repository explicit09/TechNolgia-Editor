# Shorts Distribution API Comparison — Late 2025 / Early 2026

Research for publishing 9:16 ≤60s vertical video (with caption, custom thumbnail, hashtags) from a third-party iOS app to the user's own account on each major platform.

## Summary Table

| Platform | Approval required | Account tier needed | Free direct publish? | Paid tier required? | Est. iOS effort |
|---|---|---|---|---|---|
| YouTube Shorts | OAuth verification (audit if public + sensitive scope) | Any channel; phone-verified for custom thumbnails | Yes (10k units/day = ~100 uploads/day) | No | 12–16 h |
| TikTok | Yes — app audit required for public posts | Any; creator must authorize `video.publish` | Yes, but **private-only** until audited | No | 20–30 h |
| Instagram Reels | Yes — Meta App Review | Business or Creator linked to FB Page | Yes (rate-limited) | No | 25–40 h |
| Facebook Reels | Yes — Meta App Review | Facebook Page (admin) | Yes | No | 16–24 h |
| X (Twitter) | Developer signup | Any X account | Yes — pay-per-use launched Feb 6 2026 | $0.01/post + $0.005/read → **~$0.50–1/mo at 25 posts/mo** (not $200/mo) | 10–14 h |
| LinkedIn | Product access request ("Share on LinkedIn") | Any member; Company Page needs admin | Yes | No | 14–20 h |

---

## 1. YouTube Shorts (Data API v3)

**Feasibility.** Yes. Any channel can publish. A Short is just `videos.insert` with vertical aspect and ≤60s — there is no Shorts-specific endpoint. Custom thumbnails on Shorts have only been supported since Feb 2024 and **require a phone-verified channel**; otherwise `thumbnails.set` fails.

**Auth.** OAuth 2.0 Authorization Code with PKCE (native iOS uses ASWebAuthenticationSession). Scopes: `youtube.upload` for insert, plus `youtube` (or `youtube.force-ssl`) for `thumbnails.set`. Google Cloud project + OAuth client (iOS type, bundle ID). The OAuth consent screen must be published; if you request `youtube.upload` for external users, it triggers Google's **Security Assessment / brand features review**, but in practice `youtube.upload` has been treated as a standard scope — verification is still required to remove the "unverified app" warning past 100 test users. Compliance Audit is only needed if you request >10k units/day quota.

**Upload flow.** Resumable upload protocol (`uploadType=resumable`) — initial `POST` gets a session URL, then chunked `PUT`s. Metadata (title, description, tags array, categoryId) goes in the initial JSON body. Thumbnail is a **separate** `thumbnails.set` call after the video resource exists. Order: video first → thumbnail. No separate publish step — `privacyStatus` in the insert body controls draft/public.

**Content.** Max file 256 GB / 12 h (irrelevant for Shorts). Shorts require ≤60 s and vertical (≤1:1 aspect, ideally 9:16). Codec H.264 + AAC in MP4/MOV. Title ≤100 chars, description ≤5000 chars, up to 500 tags / 15 hashtags (hashtags live inline in title or description; YouTube surfaces the first 3 of the description).

**Pricing.** Free. Default quota 10,000 units/day. `videos.insert` = **1,600 units** (the previously reported value; the quota calculator page labels "100" as the display row but the actual cost assessed per upload remains 1600 — see elfsight/phyllo analyses), `thumbnails.set` = 50 units. So a free project can realistically do ~6 uploads/day before hitting quota; a Compliance Audit unlocks more.

**Gotchas.** (1) Shorts custom thumbnail support is new and still buggy — some channels lose the ability if not phone-verified. (2) Uploaded videos are private by default until Google reviews your app for `youtube.upload` — test accounts can publish public, external users cannot until verification. (3) `categoryId` is mandatory and region-sensitive.

## 2. TikTok (Content Posting API)

**Feasibility.** Yes, with asterisk. Any creator can authorize, and videos are posted. But **until the app passes TikTok's audit, every posted video is forced to `SELF_ONLY` (private)**. There is no way to direct-publish publicly from an unaudited third-party app — this is the blocker for indie teams.

**Auth.** OAuth 2.0 Authorization Code + PKCE. Required scope: `video.publish` for Direct Post (or `video.upload` for drafts into the TikTok inbox, which then needs manual user confirmation in-app). App must be registered on developers.tiktok.com, Content Posting API product added, Direct Post configured, redirect URI whitelisted. The audit checklist is strict: privacy policy, in-app disclosure copy, demo video of integration, compliance with TikTok branding, usage volume projections. Timeline: ~2–6 weeks with revisions.

**Upload flow.** Two paths: (a) `PULL_FROM_URL` where TikTok fetches from your public URL; (b) `FILE_UPLOAD` — initialize returns pre-signed chunked PUT URLs (chunk size and count derived from `video_size`). Then `POST /publish/status/fetch/` to poll. No separate thumbnail endpoint — cover is chosen by `video_cover_timestamp_ms` into a frame of the video. Single-step publish (no draft/publish split in Direct Post).

**Content.** MP4 / MOV / WebM, H.264. Direct Post max duration depends on creator's account (`max_video_post_duration_sec`, typically 180–600). No hard size limit documented; chunks are 5–64 MB. Aspect ratio free but 9:16 strongly recommended. Caption ≤2,200 UTF-16 runes (~1,000 chars practical), hashtags inline with `#`, mentions inline with `@`. TikTok auto-parses both.

**Pricing.** Free. No paid tier. Rate limits are per-app and per-user, generous for audited apps.

**Gotchas.** (1) The "all unaudited posts are private" rule is absolute and recent (2024) — you cannot ship a working product until audited. (2) `privacy_level` must match one of `privacy_level_options` returned by `/creator/info/` — you can't hard-code. (3) The "Draft" path (video.upload) lands in the creator's TikTok inbox and requires them to open TikTok and finish posting — not suitable as a seamless UX.

## 3. Instagram Reels (Graph API)

**Feasibility.** Yes, but only for **Instagram Business or Creator accounts** that are **linked to a Facebook Page**. Personal IG accounts cannot publish via API. The ≥1,000-follower rule that appeared in 2023 applied to **analytics/insights**, not publishing — publishing itself has no follower minimum as of late 2025.

**Auth.** Facebook Login (OAuth 2.0 authorization code). Scopes (new Instagram Login model, preferred 2024+): `instagram_business_basic`, `instagram_business_content_publish`. Legacy (Facebook Login for IG Business): `instagram_basic`, `instagram_content_publish`, `pages_show_list`, `pages_read_engagement`. **Meta App Review** is required for any of these scopes before non-dev test users can authorize — expect 1–3 weeks, sometimes longer, with a screencast walkthrough and business verification. The Page the IG account is linked to must have completed Page Publishing Authorization (PPA).

**Upload flow.** Two-phase container workflow: (1) `POST /{ig-user-id}/media` with `media_type=REELS`, `video_url=<your publicly reachable URL>`, `caption`, `cover_url`, `thumb_offset` → returns container ID. Meta **pulls** the video from your URL (no direct byte upload). Poll `GET /{container-id}?fields=status_code` until `FINISHED`. (2) `POST /{ig-user-id}/media_publish` with the container ID. Thumbnail is either `cover_url` (separate image URL) or `thumb_offset` (frame ms).

**Content.** MP4/MOV, H.264 + AAC. Duration 3–90 s (most accounts) up to 15 min in some rollouts; target ≤60s for Shorts parity. Recommended 9:16, 1080×1920; Meta accepts 0.01:1 to 10:1. File size up to 1 GB. Caption ≤2,200 chars, ≤30 hashtags (inline in caption). Rate limit: 100 published posts per IG account per 24 h rolling window.

**Pricing.** Free.

**Gotchas.** (1) No direct multipart file upload — you must host the file on a public HTTPS URL Meta can reach (or use Resumable Upload API). This is a real engineering cost; expect to stand up a signed-URL server or use Supabase/S3. (2) PPA on the linked Page silently blocks publishing with unhelpful errors. (3) `cover_url` must also be publicly accessible. (4) The `instagram_content_publish` scope app review rejects apps where the publishing flow isn't demonstrably user-initiated.

## 4. Facebook Reels (Graph API — Pages)

**Feasibility.** Yes, to **Pages only** (not personal profiles, not Groups). Admin access required.

**Auth.** Facebook Login OAuth 2.0. Scopes: `pages_show_list`, `pages_read_engagement`, `pages_manage_posts` (all require Meta App Review), plus page access token. Same App Review process as Instagram; reviewed bundle.

**Upload flow.** Multi-phase resumable on `/{page-id}/video_reels`: (1) `upload_phase=start` → returns `video_id` and `upload_url`; (2) PUT binary to `upload_url` with offset headers (`Offset: 0`, `file_url` alternative); (3) `upload_phase=finish` with `title`, `description`, `video_state=PUBLISHED` (or `DRAFT` / `SCHEDULED`). Cover image via `video_preview_image_url`. Draft→publish split is supported.

**Content.** 9:16 required, minimum 540×960, duration 4–90 s (60 s if posted as a Page Story). H.264 MP4 strongly recommended (many legacy formats technically accepted). Title supports emoji; description ≤63,206 chars. Hashtags inline.

**Pricing.** Free.

**Gotchas.** (1) Shared App Review bundle with Instagram is a pro (one review) and a con (rejections block both). (2) 2024: `pages_manage_posts` denials have been common when the reviewer can't see a clear user-owned Page in the demo. (3) `video_state=SCHEDULED` requires `scheduled_publish_time` ≥10 min future and ≤75 days.

## 5. X (Twitter) API v2

**Feasibility.** Technically yes, practically **the hardest for free**. X moved to a paid tier model in 2023 and as of Feb 2026 new signups default to pay-per-use ($0.01/post write). Legacy Free tier still exists but `/2/media/upload` on Free is rate-limited to **~85 requests per 24 h** app-level and is widely reported as too constrained for a real product. Basic ($200/mo) is the realistic floor for media. v1.1 media upload was sunset June 9, 2025 — you must use the new v2 endpoints (`/2/media/upload/initialize`, `/append`, `/finalize`).

**Auth.** OAuth 2.0 Authorization Code with PKCE (for user-context tweets). Scopes: `tweet.read`, `tweet.write`, `users.read`, `media.write`, `offline.access`. App must be created at developer.x.com, attached to a paid project for media volume.

**Upload flow.** Chunked v2 flow: `POST /2/media/upload/initialize` with `media_type`, `total_bytes`, `media_category=tweet_video` → `media_id`. Then `POST /2/media/upload/:id/append` with base64 chunks (up to ~5 MB per chunk). Then `POST /2/media/upload/:id/finalize`. Poll processing status. Finally `POST /2/tweets` with `media.media_ids` and text. **No thumbnail endpoint** — X auto-generates a cover from the video first frame; no custom cover supported via API.

**Content.** MP4, H.264 + AAC. Video ≤140 s for non-verified, ≤10 min for Premium/verified. Max 512 MB. Aspect ratios 1:3 to 3:1; 9:16 accepted. Tweet body ≤280 chars (free/basic), ≤25k (Premium+). Hashtags inline, counted toward the char limit.

**Pricing (updated Feb 2026).** X launched a **pay-per-use** model on Feb 6 2026 that replaces the old "Free tier cripples media" story. Confirmed rates:
- Content: Create (posting) — **$0.01/post**
- Posts: Read — $0.005/read
- User: Read — $0.01/lookup

At a 2-user podcast posting ~25 clips/month: **~$0.50–1/month**. Legacy Free tier users get a one-time $10 voucher on transition, and every $1 spent on X API earns up to 20% back as xAI API credits. Legacy Free tier (1,500 posts/month) still exists for accounts that don't opt in. Basic $200/mo and Pro $5,000/mo tiers remain for high-volume apps but are irrelevant at this volume.

**Gotchas.** (1) No custom thumbnail — a dealbreaker if branding requires one. (2) v1.1 media endpoints **are gone** — any tutorial older than mid-2025 is wrong. (3) Rate limits on Free are per-app AND per-user combined; you cannot scale with user count on Free.

## 6. LinkedIn (Posts + Videos API)

**Feasibility.** Yes. Both personal profiles and Company Pages. Company Page posting requires the member to be an admin of that Page.

**Auth.** OAuth 2.0 Authorization Code. Scopes: `w_member_social` (personal post) or `w_organization_social` (Company Page), plus `openid profile email` (Sign In with LinkedIn via OIDC) to get the member URN. App must be created at linkedin.com/developers, then request product access for "Share on LinkedIn" and "Sign In with LinkedIn using OpenID Connect" — both are self-serve and usually auto-approve within minutes. No App Review gate like Meta.

**Upload flow.** Three steps on the Videos API: (1) `POST /rest/videos?action=initializeUpload` with `owner` URN, `fileSizeBytes`, `uploadThumbnail=true` → returns chunked upload URLs (4 MB parts) plus a separate `thumbnailUploadUrl`. (2) `PUT` each 4 MB chunk, collect ETags; `PUT` thumbnail JPEG to the thumbnail URL. (3) `POST /rest/videos?action=finalizeUpload` with ETags. Then `POST /rest/posts` with the video URN, `commentary` text, and visibility. Separate thumbnail endpoint — **yes**, supported natively.

**Content.** MP4 only. Video 3 s – 30 min, 75 KB – 5 GB. Aspect ratio 9:16 supported. Commentary/text ≤3,000 chars. Hashtags inline — LinkedIn parses `#Word`. All requests need `LinkedIn-Version: YYYYMM` and `X-Restli-Protocol-Version: 2.0.0` headers.

**Pricing.** Free.

**Gotchas.** (1) Rest.li protocol quirks (URN-encoded paths, colon escaping) trip up most first integrations. (2) Monthly API version pinning via `LinkedIn-Version` header — must be kept current or endpoints deprecate. (3) Company Page posts must use `w_organization_social` AND the member must have ADMIN/DSC role on that specific Page, which LinkedIn validates server-side.

---

## Recommendation Ranking (Easiest → Hardest for a 2-User Indie)

1. **LinkedIn — easiest.** Self-serve product access, no app review, native thumbnail support, clean chunked upload. Clean B2B surface. ~14–20 h.
2. **YouTube Shorts.** OAuth is standard; upload is well-documented; only real gate is OAuth verification for external users (paperwork, not a real review). Quota ceiling matters at scale. ~12–16 h.
3. **Facebook Reels.** Meta App Review adds 1–3 weeks but is a one-time cost; API itself is straightforward chunked upload with draft/publish control. ~16–24 h.
4. **Instagram Reels.** Same review gate as FB, plus the "you must host the file on a public URL" requirement forces infra work (Supabase signed URLs). Highest recurring engineering tax. ~25–40 h.
5. **TikTok.** Audit is the steepest qualitative bar — until you pass, every post is private, so the product literally doesn't work for users. Expect 2–6 weeks from first demo to audit approval. ~20–30 h dev plus audit cycle.
6. **X — now viable.** Feb 2026 pay-per-use shifts X from "$200/mo floor" to "~$1/month at our volume". Remaining blockers are cosmetic (no custom thumbnail — X auto-generates from frame 1) and a migration cost (v1.1 sunset so pre-mid-2025 tutorials are dead). Worth ~10–14 h of work.

**Advised rollout order for this project:** LinkedIn → YouTube → X → Facebook → Instagram → TikTok.

---

## Sources

- YouTube Data API quota calculator — developers.google.com/youtube/v3/determine_quota_cost
- YouTube `thumbnails.set` reference — developers.google.com/youtube/v3/docs/thumbnails/set
- YouTube Quota & Compliance Audits — developers.google.com/youtube/v3/guides/quota_and_compliance_audits
- Elfsight YouTube API v3 guide 2025; Phyllo "YouTube API Quota Limit 2026"
- Google Support: custom thumbnails require phone-verified channel
- TikTok Content Posting API Get Started + Direct Post reference — developers.tiktok.com/doc/content-posting-api-get-started, /content-posting-api-reference-direct-post
- Mixpost TikTok Direct Post audit guide; echotik "TikTok API Public 2025"
- Meta Instagram Content Publishing — developers.facebook.com/docs/instagram-platform/content-publishing/
- Meta Page Video Reels — developers.facebook.com/docs/graph-api/reference/page/video_reels/
- Phyllo Instagram Reels API guide 2026; Ayrshare Facebook Reels API
- LinkedIn Videos API — learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/videos-api (version li-lms-2026-03)
- LinkedIn Posts API — learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api
- X API pricing 2026 — postproxy.dev/blog/x-api-pricing-2026/; twitterapi.io/blog/twitter-api-pricing-2025
- X devcommunity posts on v2 /media/upload rate limits and v1.1 sunset June 9 2025
