# Upload-Side Episode Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit episode metadata to the short upload path so the iOS distribution library receives pre-grouped episode bundles.

**Architecture:** Extend the existing upload metadata object and MCP tool schema rather than adding a new organizer service. Persist the same fields through Supabase and pending retry storage. Keep the phone app as the consumer of uploaded episode fields.

**Tech Stack:** Swift, Swift Testing, XcodeGen, Supabase SQL migrations.

---

### Task 1: Persistence Contract

**Files:**
- Modify: `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseUploader.swift`
- Modify: `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/PendingUploadsQueue.swift`
- Test: `VideoEditor/Packages/AIServices/Tests/AIServicesTests/PendingUploadsQueueTests.swift`
- Test: `VideoEditor/Packages/AIServices/Tests/AIServicesTests/SupabaseUploaderMetadataTests.swift`

- [ ] Add failing tests proving `PendingUpload` and uploader metadata retain `episodeName` and `episodeOrder`.
- [ ] Add the two optional properties to both structs and their initializers.
- [ ] Re-run the package tests.

### Task 2: Upload Tool Contract

**Files:**
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift`

- [ ] Add optional `episode_name` and `episode_order` to the `upload_short_to_library` input schema.
- [ ] Parse those values in `handleUploadShortToLibrary`.
- [ ] Pass them into `SupabaseUploader.UploadArtifacts.Metadata`.
- [ ] Preserve them when creating a `PendingUpload` after failure.

### Task 3: Supabase Schema

**Files:**
- Create: `supabase/migrations/20260611000000_add_episode_fields_to_shorts.sql`

- [ ] Add nullable `episode_name` and `episode_order` columns.
- [ ] Add an index for episode grouping and ordering.

### Task 4: iOS Library Surface

**Files:**
- Modify: `VideoEditor/iOSApp/Views/LibraryView.swift`

- [ ] Rename the primary library header to make episodes the visible organizing unit.
- [ ] Keep unassigned shorts visible at the bottom.
- [ ] Preserve existing card navigation and refresh behavior.

### Task 5: Verification

**Commands:**
- `cd VideoEditor/Packages/AIServices && swift test`
- `cd VideoEditor/iOSApp && xcodegen generate`
- `cd VideoEditor/iOSApp && xcodebuild -scheme ShortsDistribution -destination 'id=20B3CF5B-0E08-4F4D-B2AB-24AA01CBAA51' -configuration Debug -derivedDataPath /tmp/ShortsDistributionDerivedData build`
