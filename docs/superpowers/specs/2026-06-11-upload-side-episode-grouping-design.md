# Upload-Side Episode Grouping Design

## Goal

Shorts uploaded by an agent should arrive in the phone distribution app already grouped by podcast episode, so the user can open one episode bundle and post or download only those shorts.

## Decision

Use explicit upload-side episode metadata. The `upload_short_to_library` MCP tool accepts `episode_name` and `episode_order`. Agents posting shorts for one episode pass the same `episode_name` for every short and assign `episode_order` to preserve the intended publishing sequence.

## Data Model

The `shorts_app.shorts` table stores:

- `episode_name text`
- `episode_order int`

`episode_name` is the grouping key. `episode_order` sorts shorts within a group before falling back to creation time.

## Upload Flow

The Mac uploader includes episode fields in the inserted `shorts` row. Failed uploads persist those same fields in `PendingUpload` so retries do not lose grouping.

If an upload omits `episode_name`, the uploader leaves it unset. The phone app will show that short under an unassigned section instead of guessing incorrectly.

## Phone App

The library stays backed by live Supabase shorts but presents episodes as the primary surface. Each episode section shows its count and ordered shorts. Unassigned shorts remain visible at the bottom.

## Tests

Package tests cover:

- `PendingUpload` round-trips `episodeName` and `episodeOrder`.
- Upload metadata exposes `episodeName` and `episodeOrder` for the row builder.

Manual verification covers:

- `xcodegen generate`
- iOS app build on a simulator
- package tests for `AIServices`
