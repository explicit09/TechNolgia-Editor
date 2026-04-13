# VideoEditor

A native macOS video editor plus an iOS companion app for distributing the short-form clips it produces. Built for podcast and long-form content creators who want AI-powered editing without leaving a native app.

## Surfaces

| Surface | Where | What |
|---|---|---|
| macOS editor | `VideoEditor/VideoEditor/` | Timeline editor, AI analysis, export, uploader. Scheme `VideoEditor`. |
| iOS distribution app | `VideoEditor/iOSApp/` | Browses uploaded shorts, edits captions & thumbnails, opens platform share sheets. Scheme `ShortsDistribution`. |
| Backend | `supabase/` | Postgres + Storage + one edge function. Mac writes, iOS reads. |

## What the macOS Editor Does

Import a 3-hour podcast recording and the editor will:
- **Transcribe** the full audio (Deepgram cloud or WhisperKit local)
- **Find the real episodes** — Claude reads the transcript and identifies actual content vs pre-show chatter, rehearsals, and multiple intro takes
- **Extract cleanly** — pull the episode with the right start point
- **Apply broadcast overlays** — title cards, host name bars, chapter cards, scrolling ticker, host intro strip with photos
- **Make precise cuts** — split + ripple delete with automatic chapter timestamp adjustment
- **Export** — platform-aware presets for YouTube, TikTok, Instagram, and 8 more
- **Upload shorts** — publish clips (+ per-platform captions + thumbnails) to Supabase for the iOS app to consume

## What the iOS App Does

Consumes shorts published by the Mac uploader:
- Library view of recent shorts backed by Supabase
- Per-platform caption editor (5 platforms) with one-tap Claude regenerate
- Thumbnail editor: 10 candidate frames, configurable label text/color/position, live Core Graphics preview
- Native share sheets record a `share_intents` row so the Mac can see what actually got posted

## Stack

- **Swift + SwiftUI/AppKit** — native macOS UI
- **SwiftUI + AVKit** — iOS app
- **AVFoundation + Metal** — hardware-accelerated playback and rendering
- **VideoToolbox** — hardware encode for export
- **Core ML + WhisperKit** — on-device transcription (zero cost, works offline)
- **Deepgram** — cloud transcription with speaker diarization
- **Claude API** — content analysis, episode detection, hook optimization, caption drafting
- **Pexels API** — stock footage search and B-roll insertion
- **Supabase** — Postgres + Storage + Edge Functions for the distribution pipeline
- **supabase-swift** — iOS client; TUS resumable uploads from Mac for videos >50MB

## 117 MCP Tools

The macOS editor exposes 117 tools via MCP at `localhost:8420`, enabling any AI agent to edit video programmatically:

| Category | Tools | Examples |
|----------|-------|---------|
| Timeline editing | 14 | split, trim, move, slip, ripple trim, roll trim, speed |
| Audio processing | 9 | normalize, voice cleanup, denoise, auto-duck, loudness |
| Transcription | 6 | transcribe (cloud + local), search, timing |
| AI analysis | 7 | episode detection, content scoring, topic segmentation |
| Captions | 1 | 9 animated styles + disable |
| Short-form | 7 | face tracking, 9:16 recomposition, person mask, object tracking |
| Export | 3 | 11 platform presets |
| Broadcast overlay | 2 | template system, auto-shift timestamps |
| B-roll | 4 | Pexels search, local search, suggest, auto-insert |
| Text editing | 3 | transcript range delete, filler removal |
| Image generation | 2 | AI thumbnails, carousel graphics |
| Project management | 7 | create, open, save, close, delete, rename, list |
| Track management | 8 | add, remove, mute, solo, lock, rename, reorder, volume |
| Clip properties | 5 | volume, opacity, blend mode, crop, keyframes |
| Visual effects | 11 | LUT, chroma key, denoise video, stabilize, transitions |
| Playback control | 3 | play/pause, seek, loop |
| Publishing | 1 | upload_short_to_library (Supabase) |
| Utility | 24 | snapshots, verify, screenshots, undo/redo, action log |

## 9 AI Skills

Pre-built workflows following the [Agent Skills spec](https://agentskills.io). Located at `.claude/skills/` (read by Claude Code) and `.agents/skills/` (read by Codex and other agents that follow the AGENTS.md convention):

- **podcast-episode-producer** — end-to-end episode production
- **podcast-editor** — audio cleanup and polish
- **viral-clip-extractor** — find shareable moments, format for social
- **shorts-formatter** — vertical 9:16 with face tracking
- **auto-cutter** — transcript-first editing
- **rough-cut-assembler** — assemble raw footage
- **beat-sync-editor** — cut to music
- **meeting-highlights** — executive summaries
- **pacing-optimizer** — remove dead zones

## Eval System

Automated testing against a 305-video corpus:
- 18 workflow suites covering all 116 tools
- Deterministic validators (playback, audio, export, duration, black frames)
- Gemini model judge for subjective quality grading
- 5 Swift tests + 45 Python tests

## Quick Start

### Prerequisites

```bash
brew install xcodegen ffmpeg
# only if you touch backend:
brew install supabase/tap/supabase
```

### Clone and build the macOS editor

```bash
git clone <repo-url>
cd video-editor/VideoEditor
xcodegen generate
xcodebuild -scheme VideoEditor -destination 'platform=macOS' build
```

### Build the iOS app

```bash
cd video-editor/VideoEditor/iOSApp
xcodegen generate
xcodebuild -scheme ShortsDistribution \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### Configure API keys

Copy `VideoEditor/.env.example` to `VideoEditor/.env` and fill in the keys you need. `ANTHROPIC_API_KEY` and `DEEPGRAM_API_KEY` are the bare minimum for transcription + analysis. `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` are only needed if you want to upload shorts from the Mac.

The iOS app's Supabase anon key goes in `VideoEditor/iOSApp/Config/Config.swift`, not `.env`.

### (Optional) Stand up the backend

See `docs/superpowers/plans/2026-04-12-ios-distribution-01-supabase-backend.md` for step-by-step setup of the Postgres schema, storage buckets, and `regenerate-caption` edge function.

## Architecture

```
macOS editor                    Supabase                  iOS app
─────────────────               ──────────────────        ─────────────
UI (SwiftUI + AppKit)           shorts_app schema         LibraryView
Playback/Render                   shorts                  DetailView
  (AVFoundation + Metal)          captions                CaptionEditor
Media Pipeline (VideoToolbox)     thumbnail_settings      ThumbnailEditor
AI Services (Core ML + Cloud)     share_intents             (SwiftUI + AVKit)
Publishing (SupabaseUploader)   shorts-videos
                                shorts-thumbnails
                                shorts-frames
                                  (public-read buckets)
                                regenerate-caption
                                  (edge fn → Claude)
```

**Two Swift packages** under `VideoEditor/Packages/`:

- **EditorCore** — all editor logic, no UI. Models, commands, intents, timeline, playback, rendering, media, export.
- **AIServices** — AI layer. Transcription (Deepgram + WhisperKit), analysis, providers, **Publishing** (SupabaseUploader, CaptionDrafter, PendingUploadsQueue).

All state mutations in the macOS editor flow through: **EditorIntent → Command → Execute**.

See [ARCHITECTURE.md](ARCHITECTURE.md) for full detail. The distribution pipeline is documented across three plans in `docs/superpowers/plans/`:
- `2026-04-12-ios-distribution-01-supabase-backend.md`
- `2026-04-12-ios-distribution-02-mac-uploader.md`
- `2026-04-12-ios-distribution-03-ios-app.md`

## Agent Docs

- `CLAUDE.md` — Claude Code's entry point
- `AGENTS.md` — Codex (and other AGENTS.md-aware agents) entry point

Both contain the same repo facts; they differ only in the skills-directory path they point at.

## License

Proprietary. All rights reserved.
