# CLAUDE.md

## What This Is

Native macOS video editor. Swift + SwiftUI + AVFoundation + Metal. Full architecture in ARCHITECTURE.md.

## Prerequisites

XcodeGen and ffmpeg must be installed: `brew install xcodegen ffmpeg`

## Build & Test

All commands from `VideoEditor/` directory:

```bash
cd VideoEditor && xcodegen generate          # Regenerate project after changes
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test
cd VideoEditor/Packages/EditorCore && swift test
cd VideoEditor/Tools && python3 -m unittest discover tests
```

The `.xcodeproj` is gitignored — generated from `project.yml` via XcodeGen.

## MCP Server

App runs at `http://localhost:8420/mcp`. Use `tools/list` to see all available tools. Use `tools/call` to invoke.

## Critical Patterns

- **All mutations:** EditorIntent → Command → Execute. Never mutate state directly.
- **Transcription is async** for files > 5 min. Poll `get_transcript` to check when ready.
- **Use `analyze_transcript` not `detect_episodes`** to find real episodes. `detect_episodes` is regex, `analyze_transcript` sends to Claude for comprehension.
- **Captions:** `set_caption_style` with `"none"` to disable. Any other value enables rendering.
- **Cuts:** use `split_clip` + `ripple_delete`. Overlay topic/chapter timestamps auto-shift after cuts.
- **Linked clips:** splitting a video clip also splits its linked audio. Only split on one track.
- **Overlay templates:** place JSON in `~/Library/Containers/com.videoeditor.app/Data/Documents/overlay_templates/`
- **Host photos:** place in app's Documents directory for sandbox access.
- **Preview:** full-res for ≤1080p, proxy only for 4K+.
- **Transcripts persist** by asset name + file size, not UUID. Survive re-imports.

## Environment Variables

API keys go in `VideoEditor/.env`. Check that file for what's needed.

**Supabase:** set `SUPABASE_URL` and `SUPABASE_SERVICE_KEY` from
the project's Settings → API page. The Mac uploader reads these for
pushing shorts to the iOS distribution backend. The iOS app must use
the `anon` key only; never ship `SUPABASE_SERVICE_KEY` in a client app.

## Skills

Skills are in `.claude/skills/`. The primary workflow is `podcast-episode-producer` — read its SKILL.md before producing episodes.

## Eval System

In `VideoEditor/Tools/`. Run `python3 mcp_visual_harness.py --help` for commands. Corpus and DBs live on external drive.
