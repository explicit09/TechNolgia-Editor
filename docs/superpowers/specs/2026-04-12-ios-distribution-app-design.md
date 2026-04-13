# iOS Distribution App — Design Spec

**Date:** 2026-04-12
**Status:** Approved for planning

## Goal

An iOS companion app for the macOS video editor that lets Tadiwa and Elvis review, lightly edit, and distribute the short-form clips produced on the Mac — from anywhere, at any time, without the Mac needing to be online.

## Non-goals (v1)

- Running the video-production pipeline on iOS
- Direct API posting to social platforms (OAuth, platform API keys)
- Scheduling, analytics, push notifications
- Web version
- Multiple user workspaces, account management
- Transcription, trimming, or timeline editing on iOS

## Users

Two fixed users: Tadiwa and Elvis. Single shared Supabase account with credentials baked into the app. Both phones see the same library. No user management, no sign-in screen.

## Architecture

```
MAC (factory, online only during editing)
  ├─ Existing pipeline produces shorts (mp4 + default thumbnail)
  ├─ NEW: post-export uploader pushes to Supabase:
  │    ├─ mp4 → storage/videos/
  │    ├─ default thumbnail PNG → storage/thumbnails/
  │    ├─ 10 candidate JPG frames → storage/frames/<short_id>/
  │    ├─ metadata row → shorts table
  │    ├─ 5 caption drafts → captions table (one per platform)
  │    └─ defaults row → thumbnail_settings table
  └─ Pending-uploads queue in pending_uploads.json for retries

SUPABASE (always on, source of truth)
  ├─ Auth: single shared account, credentials in iOS app
  ├─ Storage buckets: videos, thumbnails, frames
  ├─ DB tables: shorts, captions, thumbnail_settings, share_events
  └─ Edge Function: regenerate-caption (calls Claude on behalf of iOS)

iOS APP (always works, Mac can be offline)
  ├─ Library grid (streams previews, pull-to-refresh)
  ├─ Detail screen (player + thumbnail editor + caption tabs)
  ├─ Thumbnail editor: text, color, position, frame (renders locally from settings)
  ├─ Caption tabs: 5 platforms, edit + regenerate per tab
  ├─ Share → iOS native share sheet
  └─ Aggressive cache: videos + rendered thumbnails stay until OS evicts
```

**Principle:** Supabase is source of truth. Mac is a one-way publisher. iOS is reader + editor. Mac never needs to be reachable for iOS to function.

## Data flow

### Producing a short (Mac)

1. User produces a short via existing tools (`extract_segment` → `analyze_for_shorts` → `create_short` → `export_for_platform` → `generate_short_thumbnail`).
2. After export, a new MCP tool `upload_short_to_library` is invoked. It:
   - Generates a new `short_id` (UUID)
   - Uses the existing ThumbnailScorer to pick 10 candidate frames across the source range and encodes each as JPG (quality 80)
   - Calls Claude once with the hook + transcript snippet to generate five platform-specific caption drafts
   - Uploads video + thumbnail + 10 frames to Supabase Storage (parallel, with retry)
   - Inserts rows into `shorts`, `captions` (×5), and `thumbnail_settings`
3. If any step fails, the tool writes to a local `pending_uploads.json` queue for a later retry. Rows are only inserted after all storage uploads succeed (no orphans).

### Editing + sharing (iOS)

1. Library grid loads via `select * from shorts order by created_at desc`.
2. Tap a short → Detail screen.
3. Video streams from Supabase Storage URL (HTTP range requests). First play may buffer; replays cached locally.
4. User taps "Edit thumbnail" → renders live preview from settings. Settings changes auto-save to `thumbnail_settings`.
5. User taps a platform tab → edits caption in place. Auto-save on blur. "Regenerate" calls the edge function, which calls Claude and writes the result back to the row.
6. User taps Share:
   - If video not fully cached, download it (shows progress)
   - Render final thumbnail PNG from current settings
   - Native iOS share sheet opens with video + rendered PNG + caption text
   - When sheet opens, insert a `share_events` row (assume the share happened)

## Data schemas

### Table: `shorts`

One row per produced short.

| Column          | Type       | Notes                                              |
|-----------------|------------|----------------------------------------------------|
| id              | uuid (PK)  |                                                    |
| created_at      | timestamptz | default now()                                      |
| source_asset    | text       | Source podcast episode name                        |
| hook            | text       | Original hook quote from find_viral_moments        |
| label           | text       | Mac's initial pill label (reference; not used after thumbnail_settings created) |
| duration        | numeric    | Seconds                                            |
| evergreen_score | int        | 0-10                                               |
| trending_score  | int        | 0-10                                               |
| platform_fit    | text[]     | ["youtube_shorts", "instagram_reels", ...]         |
| source_start    | numeric    | Source-time start                                  |
| source_end      | numeric    | Source-time end                                    |
| video_path      | text       | storage/videos/<id>.mp4                            |
| thumbnail_path  | text       | storage/thumbnails/<id>.png                        |
| video_size      | bigint     | Bytes                                              |
| reasoning       | text       | Why-viral text from Claude                         |

### Table: `captions`

Five rows per short, one per platform.

| Column          | Type       | Notes                                              |
|-----------------|------------|----------------------------------------------------|
| id              | uuid (PK)  |                                                    |
| short_id        | uuid (FK)  | → shorts.id, cascade delete                        |
| platform        | text       | 'youtube_shorts' \| 'tiktok' \| 'instagram_reels' \| 'twitter' \| 'linkedin' |
| title           | text       | YouTube only (100 char max); null for others       |
| body            | text       | Main caption (up to 3000 chars)                    |
| hashtags        | text[]     | Suggested hashtags                                 |
| last_edited_by  | text       | 'mac' \| 'ios' \| 'claude_regen'                   |
| updated_at      | timestamptz | default now()                                      |

Unique constraint on (short_id, platform).

### Table: `thumbnail_settings`

One row per short, tracks current iOS thumbnail edits. Mac writes defaults at upload time; iOS edits override.

| Column          | Type       | Notes                                              |
|-----------------|------------|----------------------------------------------------|
| short_id        | uuid (PK, FK) | → shorts.id, cascade delete                     |
| label_text      | text       | Current pill text                                  |
| label_color     | text       | Hex color from brand palette                       |
| label_position  | text       | One of 9: 'top-left', 'top-center', 'top-right', 'center-left', 'center', 'center-right', 'bottom-left', 'bottom-center', 'bottom-right' |
| frame_index     | int        | 0-9, which candidate frame to use as background    |
| updated_at      | timestamptz | default now()                                      |

Brand palette (enforced client-side):
- Gold: `#C9A028`
- Dark navy: `#070D17`
- White: `#FFFFFF`
- Pink/red: `#E91E63`
- Green: `#00C853`

### Table: `share_events`

Records when a share sheet was opened for a given short + platform.

| Column       | Type       | Notes                           |
|--------------|------------|---------------------------------|
| id           | uuid (PK)  |                                 |
| short_id     | uuid (FK)  | → shorts.id, cascade delete     |
| platform     | text       | Which platform tab was active when share was tapped |
| shared_at    | timestamptz | default now()                   |

### Storage buckets

- `videos/` — object key: `<short_id>.mp4`
- `thumbnails/` — object key: `<short_id>.png` (Mac-generated default; iOS never writes here)
- `frames/` — object key: `<short_id>/frame_N.jpg` where N is 0-9

All buckets private. iOS reads via service-role key baked into the app at build time (acceptable given the closed two-user audience; see iOS credentials section).

## iOS app

### Tech choices

- **SwiftUI** — native, fastest to build for a two-screen app
- **iOS 17+** — modern SwiftUI APIs, skip backward compatibility
- **Supabase Swift SDK** — handles auth, storage, DB, realtime (if we want it later)
- **AVKit** — video playback
- **URLCache** (2GB) for video caching; in-memory `NSCache` for frames + rendered thumbnails

### Screens

**Library (home)**
- 2-column LazyVGrid
- Cell: thumbnail (renders from settings, not stored PNG) + label + duration chip + tiny platform_fit indicators
- Pull-to-refresh
- Newest first (no filtering/sorting in v1)
- Empty state: "No shorts yet. Produce some on Mac."

**Detail / Editor**
- Video player (AVKit, autoplay muted, tap to unmute, scrubbable)
- Current thumbnail preview (updates live as settings change)
- Collapsible "Edit thumbnail" section:
  - Text input
  - Color swatch row (5 colors)
  - 3x3 position picker
  - Horizontal scroll of 10 frame JPGs
  - Save button (writes thumbnail_settings)
- Caption tabs (segmented control over 5 platforms):
  - Title field (YouTube only)
  - Body textarea
  - Hashtag chips
  - Regenerate button (calls edge function)
  - Auto-save on blur
- Sticky bottom Share button

**Settings (minimal)**
- Supabase connection status
- Cache size + "Clear cache"
- (No sign-out; no auth UI)

### Rendering

Thumbnail rendering on iOS is a straight composite over a pre-cropped frame:

1. Load the selected 1080x1920 JPG frame from the candidates cache. The Mac uploader produces these frames already face-tracked and 9:16-composed — the same compositing that drives the final video. iOS does no further cropping.
2. Composite the logo top-right (loaded from the app bundle — `technolgia_logo_tight.png` is shipped with the app, not fetched).
3. Composite the pill rectangle (brand-palette color) with the label text at the chosen 3x3 grid position.
4. Render to `CGImage` → `UIImage` for display, or encode to `PNG` Data for sharing.

**Important:** Because the Mac uploads post-composition 9:16 frames, iOS never runs face tracking or re-cropping. This keeps iOS rendering code minimal.

### Caching strategy

- **Videos** — `URLCache` with 2GB disk quota. iOS evicts LRU when full.
- **Frames** — `NSCache` in memory, ~8MB total for a full library of 14 shorts × 10 frames × ~50KB. Evicts on memory pressure.
- **Rendered thumbnails** — `NSCache` keyed by `short_id + settings_hash`. Re-renders when settings change.

### Offline behavior

- Library shows cached shorts with a subtle "offline" banner
- Editing queues to Supabase and syncs on foreground
- Playback works for cached videos; others show "download when online"

## Mac-side upload

### New MCP tool: `upload_short_to_library`

Registered in AIToolRegistry. Parameters:

| Param           | Type    | Required | Notes                                                   |
|-----------------|---------|----------|---------------------------------------------------------|
| asset_id        | string  | yes      | Source asset UUID                                        |
| source_start    | number  | yes      | Clip start in source seconds                             |
| source_end      | number  | yes      | Clip end in source seconds                               |
| video_path      | string  | yes      | Local path to exported MP4                               |
| label           | string  | yes      | Pill label text                                          |
| hook            | string  | yes      | Hook quote                                               |
| evergreen_score | number  | no       | Default 0                                                |
| trending_score  | number  | no       | Default 0                                                |
| platform_fit    | array   | no       | Default []                                               |
| reasoning       | string  | no       | Why-viral explanation                                    |
| source_asset_name | string | no      | Display name (e.g. "2026-03-14 14-12-22")               |

Behavior:
1. Reuse `ShortFormLayoutRenderer` to produce 10 candidate thumbnail frames across the source range, using the same face-tracked 9:16 composition already used in the final video. Encode as JPG quality 80.
2. Generate default thumbnail PNG (existing `generate_short_thumbnail` output).
3. Call Claude once via `ClaudeProvider` with the hook + transcript excerpt. Ask for 5 platform captions in a single JSON response. Parse.
4. Upload to Supabase:
   - `videos/<short_id>.mp4`
   - `thumbnails/<short_id>.png`
   - `frames/<short_id>/frame_0.jpg` through `frame_9.jpg`
5. Insert DB rows (transactional where possible): `shorts` → `thumbnail_settings` → `captions` (×5).
6. If any step fails, append the full request payload to `pending_uploads.json` in the app support directory. On next invocation, drain the queue first.

### Supabase credentials on Mac

Two new env vars in `.env`:
- `SUPABASE_URL`
- `SUPABASE_SERVICE_KEY`

Loaded by existing `loadEnvKeys` mechanism.

### Error handling

- Each storage upload wrapped in 3 retries with exponential backoff (1s, 2s, 4s)
- If any upload fails after retries, rollback by deleting uploaded objects before writing to pending_uploads
- If DB insert fails, delete already-uploaded objects before queuing
- Partial failures never leave orphan rows or orphan objects

## Edge Function: `regenerate-caption`

Supabase Edge Function (Deno/TypeScript). Invoked from iOS when user taps "Regenerate" in the caption editor.

Request body:
```json
{
  "short_id": "<uuid>",
  "platform": "youtube_shorts" | "tiktok" | ... ,
  "tone": "default" | "spicier" | "more_professional"
}
```

Behavior:
1. Fetch the short's hook + existing caption for context
2. Call Claude with a platform-appropriate prompt
3. Write the result back to the caption row (updates `body`, `hashtags`, `title`, `last_edited_by='claude_regen'`)
4. Return the new caption

Anthropic API key held in Supabase secret, not exposed to iOS.

## iOS app — Supabase credentials

- Baked into the app at build time via `Config.swift` (service-role key).
- Caveat: anyone with the built IPA can read/write. Acceptable for two-user personal tool. Document as "lock your phone."

## Error handling (iOS)

- **Thumbnail save fails:** optimistic local update + toast "saved locally, will sync." Retry on foreground.
- **Caption regenerate fails:** toast error, keep existing caption.
- **Video playback 404:** "Video no longer available" card.
- **Share sheet dismissed without sharing:** no share_events row (we can't tell which platform was actually chosen from the iOS share sheet API anyway, so we record based on the active caption tab when user tapped Share — acknowledged limitation).

## Out of scope

Explicit non-features for v1:

- Sign-in / user management
- Push notifications for new uploads
- Post scheduling
- Direct API posting
- View-count analytics
- Trimming / re-editing video on iOS
- Captions translated into other languages
- Web version
- Android version
- Multiple brand templates (TechNolgia only)

## Testing

- **Mac upload tool**: unit tests for payload shape, retry logic, rollback on failure. Integration test against a Supabase staging project.
- **iOS app**: SwiftUI previews for each screen. Manual end-to-end test against production Supabase.
- **No broad test suite for v1** — ship, use, harden.

## Dependencies + costs

- **Supabase** — free tier fine initially. At ~14 shorts × 10 episodes = 140 shorts ≈ 20-30GB video. Paid tier (~$25/mo base + $0.021/GB/mo storage) is ~$26/mo at that volume.
- **Apple Developer Program** — $99/year (required to run on physical devices + distribute via TestFlight)
- **Xcode 15+**, macOS 14+ for building

## Implementation order

(Plan doc will detail each task. High-level order:)

1. Supabase project + schema + storage buckets + edge function
2. Mac `upload_short_to_library` tool + retry + pending queue
3. iOS project scaffold + Supabase SDK + Config
4. iOS library grid + streaming video player
5. iOS caption editor (read/write + regenerate)
6. iOS thumbnail editor (live render + save)
7. iOS share sheet + cache + share_events
8. End-to-end test with real shorts + polish
