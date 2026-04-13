# AGENTS.md

## What This Is

Two-surface product:

1. **Native macOS video editor** (`VideoEditor/VideoEditor/`) — Swift + SwiftUI + AVFoundation + Metal. Produces short-form clips and uploads them.
2. **iOS distribution app** (`VideoEditor/iOSApp/`, target `ShortsDistribution`) — SwiftUI app that browses the uploaded shorts, lets you edit captions/thumbnails, and opens platform share sheets.
3. **Supabase backend** (`supabase/`) — Postgres + Storage + one edge function. The pipe between the two apps.

Full architecture in `ARCHITECTURE.md`.

## Prerequisites

```bash
brew install xcodegen ffmpeg supabase/tap/supabase
```

(`supabase` CLI is only needed if you're touching migrations, buckets, or edge functions.)

## Build & Test

All commands from `VideoEditor/` unless noted:

```bash
# macOS editor
cd VideoEditor && xcodegen generate
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test

# iOS distribution app
cd VideoEditor/iOSApp && xcodegen generate
cd VideoEditor/iOSApp && xcodebuild -scheme ShortsDistribution \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Package tests
cd VideoEditor/Packages/EditorCore && swift test

# Python tool tests
cd VideoEditor/Tools && python3 -m unittest discover tests
```

`.xcodeproj` files are gitignored — both are regenerated from their respective `project.yml` via XcodeGen.

## MCP Server

macOS app runs at `http://localhost:8420/mcp`. Use `tools/list` to see all available tools. Use `tools/call` to invoke.

## Critical Patterns

- **All mutations:** EditorIntent → Command → Execute. Never mutate state directly.
- **Transcription is async** for files > 5 min. Poll `get_transcript` to check when ready.
- **Use `analyze_transcript` not `detect_episodes`** to find real episodes. `detect_episodes` is regex; `analyze_transcript` sends to Claude for comprehension.
- **Captions:** `set_caption_style` with `"none"` to disable. Any other value enables rendering.
- **Cuts:** use `split_clip` + `ripple_delete`. Overlay topic/chapter timestamps auto-shift after cuts.
- **Linked clips:** splitting a video clip also splits its linked audio. Only split on one track.
- **Overlay templates:** place JSON in `~/Library/Containers/com.videoeditor.app/Data/Documents/overlay_templates/`
- **Host photos:** place in app's Documents directory for sandbox access.
- **Preview:** full-res for ≤1080p, proxy only for 4K+.
- **Transcripts persist** by asset name + file size, not UUID. Survive re-imports.
- **Shorts distribution:** Mac uploads with `SUPABASE_SERVICE_KEY`; iOS reads with the `anon` key. Never put the service key in the iOS app.

## Environment Variables

API keys live in `VideoEditor/.env` (template at `VideoEditor/.env.example`).

- `ANTHROPIC_API_KEY`, `DEEPGRAM_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `BFL_API_KEY` — used by the macOS editor.
- `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` — used by the Mac uploader only. The iOS app has credentials in `VideoEditor/iOSApp/Config/Config.swift` (anon key).

The sandboxed macOS app also reads `.env` from
`~/Library/Containers/com.videoeditor.app/Data/Library/Application Support/VideoEditor/.env`.

## Skills

Skills are in `.agents/skills/` (read by Codex / agents using the AGENTS.md convention) and mirrored at `.claude/skills/` (read by Claude Code). Both trees are kept identical — edit both when changing a skill.

The primary workflow is `podcast-episode-producer` — read its SKILL.md before producing episodes.

## Eval System

In `VideoEditor/Tools/`. Run `python3 mcp_visual_harness.py --help` for commands. Corpus and DBs live on external drive.

## Plans & Specs

Feature work is planned in `docs/superpowers/`:
- `plans/` — task-by-task implementation plans (with `- [ ]` checkboxes).
- `specs/` — design docs the plans reference.

The three `2026-04-12-ios-distribution-*` plans describe the current distribution pipeline end-to-end.
