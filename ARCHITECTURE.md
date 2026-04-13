# Native macOS AI-Ready Video Editor — Architecture Plan

This doc describes the macOS editor — the original surface and still the bulk of the system. Since the original plan, two companion surfaces have been added:

- **iOS distribution app** (`VideoEditor/iOSApp/`) — consumes shorts produced by the Mac.
- **Supabase backend** (`supabase/`) — the pipe between the two apps.

See the [Distribution Pipeline](#distribution-pipeline) section below for how they fit together.

## Philosophy

This is a real-time media system with AI attached to it.
Build the editor like a game engine, not a CRUD app.
Editor core first. AI-ready foundation underneath. AI features layered progressively.

---

## Stack

| Layer | Stack | Responsibility |
|-------|-------|---------------|
| UI | SwiftUI + AppKit | Timeline, inspector, media browser, preview, panels |
| Playback/Render | AVFoundation + Metal | Frame scheduling, compositing, caching, effects preview |
| Media Pipeline | VideoToolbox + AVAssetReader/Writer | Decode, transcode, proxy generation, export |
| Ingestion AI | Core ML + local models | Transcript, silence, shot boundaries, diarization |
| Assistive AI | Core ML + cloud APIs | Search, suggestions, chaptering, rough cuts |
| Generative AI | Cloud APIs | Titles, reframing, visual variations, heavy tasks |
| Publishing | Supabase (Postgres + Storage) | Upload shorts + captions + thumbnails; TUS resumable for large videos |
| Companion app | SwiftUI + AVKit (iOS 17+) | Browse published shorts, edit captions/thumbnails, share |

---

## Project Structure

```
VideoEditor/
├── VideoEditor/                         # macOS app target
│   ├── App/
│   │   ├── VideoEditorApp.swift         # App entry point
│   │   └── AppState.swift              # Top-level app state / DI container
│   ├── UI/
│   │   ├── Timeline/                   # Timeline panel (tracks, clips, ruler, playhead)
│   │   ├── Preview/                    # Video preview + Metal layer
│   │   ├── Inspector/                  # Property inspector for selected clip
│   │   ├── MediaBrowser/               # Import, browse, search media assets
│   │   ├── Layout/                     # Panel layout, split views, window chrome
│   │   └── Shared/                     # Reusable UI components
│   └── Resources/
│
├── Packages/
│   ├── EditorCore/                     # Swift Package — editor logic (no UI)
│   │   └── Sources/EditorCore/
│   │       ├── Models/                 # Project, Timeline, Track, Clip, Asset
│   │       ├── Commands/               # Command pattern + undo/redo history
│   │       ├── Intents/                # Editor Intent layer (human/AI/automation)
│   │       ├── Timeline/               # Timeline operations, snap, zoom, overlap
│   │       ├── Composition/            # Render graph compiled from timeline
│   │       ├── Playback/               # AVFoundation playback engine
│   │       ├── Rendering/              # Metal preview renderer
│   │       ├── Media/                  # Asset management, proxy gen, cache
│   │       ├── Export/                 # Export pipeline (VideoToolbox)
│   │       ├── Storage/                # Project bundle + SQLite metadata
│   │       ├── Cache/                  # Cache policies per artifact type
│   │       ├── Actions/                # Action definitions + keybinding dispatch
│   │       └── ActionLog/              # Structured edit history (AI-ready)
│   │
│   └── AIServices/                     # Swift Package — AI layer (protocols + providers)
│       └── Sources/AIServices/
│           ├── Protocols/              # AIProvider, AITool, AnalysisTask
│           ├── Context/                # Editor state → AI-consumable context
│           ├── Providers/              # ClaudeProvider, PexelsClient
│           ├── Transcription/          # Deepgram + WhisperKit transcription
│           ├── Analysis/               # Transcript analysis, silence, shots
│           ├── Search/                 # Semantic + keyword search over analyses
│           ├── Planning/               # PlanGenerator (turns prompts into intents)
│           ├── Routing/                # Model/cost routing between providers
│           ├── Skills/                 # Skill-activation + workflow wiring
│           ├── Tools/                  # AIToolRegistry — MCP-facing tool defs
│           ├── ImageGen/               # Thumbnail + carousel image generation
│           └── Publishing/             # SupabaseUploader, CaptionDrafter,
│                                       # PendingUploadsQueue, SupabaseClient (TUS)
│
├── iOSApp/                             # ShortsDistribution iOS target (SwiftUI)
│   ├── App/                            # App entry + navigation
│   ├── Views/                          # Library, Detail, Caption editor, Thumbnail editor
│   ├── Models/                         # Short, Caption, ThumbnailSettings, Platform
│   ├── Networking/                     # SupabaseShortsClient (anon key)
│   ├── Cache/                          # VideoCache, FrameCache
│   ├── Rendering/                      # ThumbnailCompositor (Core Graphics preview)
│   ├── AppIntents/                     # Share-sheet intents
│   ├── Config/                         # Config.swift (anon key + brand palette)
│   ├── Resources/
│   └── project.yml                     # Separate XcodeGen spec from the macOS app
│
├── Tools/                              # Python eval harness + MCP visual tests
│
└── Tests/
    ├── EditorCoreTests/
    └── AIServicesTests/
```

The backend lives alongside `VideoEditor/` at the repo root:

```
supabase/
├── migrations/         # Schema: shorts, captions, thumbnail_settings, share_intents
├── functions/
│   └── regenerate-caption/   # Edge function: Claude-powered caption rewrites
└── seeds/              # Storage bucket creation (videos, thumbnails, frames)
```

---

## Core Data Models

The timeline is the heart. It holds **references + instructions**, never video data.

### Project Bundle (on disk)

Projects are stored as bundle directories, not monolithic JSON.
JSON is fine for early dev. Migrate to this structure before complexity grows.

```
MyProject.veditor/
├── manifest.json                    # Project metadata, settings, version
├── timeline.json                    # Timeline state (tracks, clips, markers)
├── media/                           # Original source files (immutable)
│   ├── {uuid}.mp4
│   └── {uuid}.wav
├── proxies/                         # Editing proxies (derived, rebuildable)
│   └── {uuid}_proxy.mp4
├── cache/                           # Thumbnails, waveforms, render cache
│   ├── thumbnails/
│   ├── waveforms/
│   └── render/
├── analysis/                        # AI-generated artifacts (derived)
│   ├── transcripts/
│   ├── embeddings/
│   └── segments/
└── metadata.sqlite                  # Action log, indexes, search, analysis refs
```

### Project Model

```swift
struct Project: Codable, Identifiable {
    let id: UUID
    var name: String
    var settings: ProjectSettings
    var timeline: Timeline
    var createdAt: Date
    var modifiedAt: Date
}

struct ProjectSettings: Codable {
    var resolution: CGSize           // 1920x1080, 3840x2160, etc.
    var frameRate: Double            // 24, 30, 60
    var sampleRate: Int              // 44100, 48000
    var backgroundColor: CodableColor
}
```

### Timeline → Tracks → Clips

```swift
struct Timeline: Codable {
    var tracks: [Track]
    var markers: [Marker]

    var duration: TimeInterval {
        tracks.flatMap(\.clips).map { $0.timelineRange.end }.max() ?? 0
    }
}

struct Track: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: TrackType
    var clips: [Clip]
    var isMuted: Bool
    var isLocked: Bool
    var volume: Double               // audio tracks
    var opacity: Double              // video tracks
}

enum TrackType: String, Codable {
    case video, audio, text, effect
}
```

### Clip = Reference + Instructions

```swift
struct Clip: Codable, Identifiable {
    let id: UUID
    var assetID: UUID                // pointer to source — NOT the source itself
    var timelineRange: TimeRange     // where this sits on the timeline
    var sourceRange: TimeRange       // in/out within the source media
    var transform: Transform2D       // position, scale, rotation
    var opacity: Double
    var volume: Double
    var effects: [EffectInstance]
    var keyframes: KeyframeStore
    var metadata: ClipMetadata       // AI-enrichable
}

struct TimeRange: Codable {
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval { end - start }
}

struct Transform2D: Codable {
    var position: CGPoint
    var scale: CGSize
    var rotation: Double             // degrees
    var anchor: CGPoint
}

// AI-ready: structured metadata per clip
struct ClipMetadata: Codable {
    var label: String?
    var tags: [String]
    var transcriptSegment: TranscriptSegment?
    var sceneType: String?           // e.g., "talking-head", "b-roll", "title"
}
```

### Media Assets — Immutable Sources

```swift
struct MediaAsset: Codable, Identifiable {
    let id: UUID
    var name: String
    var sourceURL: URL               // original — never modified
    var proxyURL: URL?               // lower-res for editing
    var thumbnailURL: URL?
    var type: MediaType
    var duration: TimeInterval
    var resolution: CGSize?
    var codec: String?
    var fileSize: Int64
    var importedAt: Date

    // AI-enriched (populated by background analysis)
    var analysis: MediaAnalysis?
}

enum MediaType: String, Codable {
    case video, audio, image
}

struct MediaAnalysis: Codable {
    var transcript: [TranscriptWord]?
    var shotBoundaries: [TimeInterval]?
    var silenceRanges: [TimeRange]?
    var speakerSegments: [SpeakerSegment]?
    var sceneDescriptions: [SceneSegment]?
    var loudnessProfile: [Float]?
}
```

---

## Concurrency Architecture

Media tools get ugly fast without explicit concurrency boundaries.
Every domain with mutable state or heavy I/O is an actor.

```swift
// Each actor owns its domain — no shared mutable state across boundaries
actor ProjectStore     { ... }      // Save/load, migration, bundle I/O
actor PlaybackEngine   { ... }      // AVPlayer, composition building, seek
actor RenderCache      { ... }      // Frame cache, thumbnail cache
actor AnalysisQueue    { ... }      // Background AI/analysis jobs
actor ThumbnailService { ... }      // Thumbnail generation + eviction
actor ProxyService     { ... }      // Proxy generation + lifecycle
actor ExportEngine     { ... }      // Export pipeline, progress
```

**Why actors, not just queues:**
- Analysis jobs must not mutate project state without going through ProjectStore
- Timeline edits must not race preview invalidation
- Exports must read consistent asset state, not stale references
- Background waveform/transcript jobs must not flood memory

---

## Editor Intent Layer

The bridge between human editing, keyboard shortcuts, AI actions, and automation.
One operational language for the entire editor.

```swift
// Intents are the shared vocabulary — humans, AI, and macros all speak this
enum EditorIntent {
    case trimClip(clipID: UUID, newSourceRange: TimeRange)
    case splitClip(clipID: UUID, at: TimeInterval)
    case moveClip(clipID: UUID, to: TimeRange, trackID: UUID)
    case deleteClips(clipIDs: [UUID])
    case insertClip(assetID: UUID, at: TimeInterval, trackID: UUID)
    case removeSilence(clipID: UUID, ranges: [TimeRange])
    case createSelectsSequence(clipIDs: [UUID])
    case groupBySpeaker(clipIDs: [UUID])
    case insertTitleCard(text: String, at: TimeInterval)
    case applyReframePlan(plan: ReframePlan)
    case setMarker(at: TimeInterval, label: String)
}

// Intent resolver turns intents into commands
final class IntentResolver {
    func resolve(_ intent: EditorIntent, context: EditingContext) throws -> Command {
        switch intent {
        case .trimClip(let id, let range):
            return TrimClipCommand(clipID: id, newSourceRange: range)
        case .removeSilence(let id, let ranges):
            return BatchCommand(ranges.map { DeleteRangeCommand(clipID: id, range: $0) })
        // ...
        }
    }
}
```

**Who triggers intents:**
- User actions (mouse, keyboard) → Intent
- Keyboard shortcuts → Intent
- AI suggestions (accepted by user) → Intent
- Batch tools / macros → Intent
- Future: agentic workflows (plan → intents → verify → refine)

---

## Command System

All mutations go through commands. DI — no singletons.
Intents resolve to commands. Commands execute on EditingContext.

```swift
protocol Command {
    var name: String { get }
    mutating func execute(context: EditingContext) throws
    func undo(context: EditingContext) throws
}

// DI container — passed to every command
final class EditingContext {
    let timeline: TimelineManager
    let media: MediaManager
    let playback: PlaybackEngine
    let actionLog: ActionLog
}

final class CommandHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [Command] = []
    private var redoStack: [Command] = []

    func execute(_ command: inout Command, context: EditingContext) throws {
        try command.execute(context: context)
        undoStack.append(command)
        redoStack.removeAll()
        context.actionLog.record(command)   // AI-ready audit trail
        updateState()
    }

    func undo(context: EditingContext) throws { ... }
    func redo(context: EditingContext) throws { ... }
}
```

**Example commands:** TrimClip, SplitClip, MoveClip, DeleteClips, InsertClip, AddTrack, RemoveTrack, ApplyEffect, SetKeyframe, BatchCommand (groups multiple)

---

## Composition Graph

The user-facing timeline model and the internal render graph are separate.

```
Timeline (user model)         Composition Graph (render model)
┌─────────────────┐          ┌──────────────────────┐
│ Tracks + Clips   │  ──────▶ │ Source Nodes          │
│ Effects          │  compile │ Transform Nodes       │
│ Keyframes        │          │ Effect Nodes          │
│ Transitions      │          │ Blend/Composite Nodes │
└─────────────────┘          │ Output Node           │
                              └──────────────────────┘
```

**Why separate:**
- Effects, transitions, nested sequences, adjustment layers, and AI overlays are cleaner when the engine compiles timeline state into a render graph
- The render graph can be optimized (node merging, caching intermediate results) without touching the user model
- Future: AI-generated overlays insert into the graph without polluting the timeline

Both pipelines (preview + export) consume the same composition graph, just with different quality settings.

---

## Two Rendering Pipelines

### Interactive (Preview)

```
Timeline → Compile → Composition Graph → Metal Preview Layer → Display
                                              ↑
                                        AVPlayer (proxy media)
```

- Uses proxy media for responsive scrubbing
- Metal layer composites video tracks + effects in real-time
- Frame cache (ring buffer) for smooth playback
- Coarse effects (good enough for preview, not final quality)

**Frame budget discipline:**
- Hard target FPS (match project frame rate)
- Bounded GPU work per frame — no unbounded effect chains
- No synchronous analysis on the render path
- No silent CPU fallback on the hot path — if Metal can't do it, skip or degrade
- Explicit degraded-preview modes when effects stack too heavy:
  - Level 0: full quality preview
  - Level 1: reduce effect quality (lower-res blur, skip secondary effects)
  - Level 2: proxy-only, skip custom effects entirely
  - Level 3: thumbnail strip scrubbing (last resort)

### Export (Offline)

```
Timeline → Compile → Composition Graph → AVAssetReader (per source)
                                              ↓
                                        Frame-by-frame decode (VideoToolbox hardware)
                                              ↓
                                        Metal compute pipeline (full quality effects)
                                              ↓
                                        AVAssetWriter (VideoToolbox hardware encode)
                                              ↓
                                        Output file (.mp4 / .mov)
```

- Full resolution, no proxies
- Multi-pass capable (future: color grading, denoising)
- Background queue with progress reporting
- Cancellable

---

## Proxy Strategy

Proxies are not just "lower-res." They are the editing media layer.

| Decision | Choice |
|----------|--------|
| Codec | ProRes Proxy or H.264 intraframe (all-I) |
| Resolution | 1/4 source (e.g., 960x540 for 4K source) |
| Frame structure | Intraframe preferred (fast random access for scrubbing) |
| Scope | Per-project (proxies live in project bundle) |
| Generation | On import, background, cancellable |
| Analysis target | Analysis runs on proxy (cheaper), full-res only when needed |
| Rebuild | Proxies are derived — can be deleted and regenerated |

**Why intraframe:** Interframe codecs (H.264 long-GOP) require decoding from the nearest keyframe to seek. Intraframe means every frame is a keyframe — instant scrub response.

---

## Cache Policies

Each cache type has explicit size limits, eviction rules, and invalidation triggers.

| Cache | Storage | Max Size | Eviction | Invalidated By |
|-------|---------|----------|----------|----------------|
| Frame cache | Memory (ring buffer) | ~200 frames | LRU, drop on seek | Playhead jump, timeline edit |
| Thumbnail strip | Disk (project cache/) | Unlimited | Per-asset, rebuild on proxy change | Source re-import, proxy regen |
| Waveform | Disk (project cache/) | Unlimited | Per-asset | Source re-import |
| Transcript | SQLite + disk | Unlimited | Per-asset, versioned | Re-transcription, model change |
| Embeddings | SQLite | Unlimited | Per-asset | Re-analysis, model change |
| Render cache | Disk (project cache/) | Configurable (default 2GB) | LRU by last access | Timeline edit affecting cached region |
| Proxy media | Disk (project proxies/) | Per-project | Manual or on project close | Source re-import |

**Cold-start rebuild:** On project open, validate cache checksums. Missing/stale caches are rebuilt in background via AnalysisQueue. Editor is usable immediately with degraded preview.

**Memory pressure response:**
1. Evict frame cache to minimum (current frame + 2 ahead)
2. Drop render cache from memory (keep on disk)
3. Force proxy-only preview
4. Pause background analysis jobs
5. Log memory event for diagnostics

---

## Degradation Rules

Explicit behavior when things go wrong. The editor must never feel broken — it degrades gracefully.

| Failure | Behavior |
|---------|----------|
| Proxy generation fails | Edit with full-res source (slower scrubbing). Show indicator. |
| Hardware decode unsupported (codec) | Fall back to software decode via AVAssetReader. Force proxy generation for that asset. |
| Cloud AI times out | Keep human workflow uninterrupted. Show "AI unavailable" in suggestion panel. Retry in background. |
| Local transcript fails / partial | Show partial transcript. Mark gaps. Allow manual retry per segment. |
| Memory pressure rises | Activate memory pressure response (see Cache Policies). Reduce preview quality. |
| Export interrupted | Save progress checkpoint. Offer resume on next attempt. |
| Analysis artifacts stale | Mark as stale, re-queue in background. Don't serve stale data to AI without marking confidence. |
| Project file corruption | SQLite WAL recovery for metadata. Timeline JSON has last-known-good backup (written before each save). |
| Metal unavailable | Software-only preview path (rare on modern Mac, but handle it). |

**Principle:** AI failures must never block human editing. The editor works without AI. AI enhances it.

---

## AI-Ready Infrastructure (Phase 1 — interfaces only)

### Action Log — Every edit is structured data

```swift
struct ActionEvent: Codable {
    let timestamp: Date
    let commandName: String
    let intent: EditorIntent?          // what triggered this
    let clipIDs: [UUID]
    let trackIDs: [UUID]
    let parameters: [String: String]
    let source: ActionSource           // .user, .ai, .macro, .undo
}

enum ActionSource: String, Codable {
    case user, ai, macro, undo, redo
}

// Persisted to SQLite in project bundle
actor ActionLog {
    func record(_ command: Command, source: ActionSource) { ... }
    func recentActions(count: Int) -> [ActionEvent] { ... }
    func actionsFor(clip: UUID) -> [ActionEvent] { ... }
    func actionsSince(_ date: Date) -> [ActionEvent] { ... }
}
```

### Three AI Buckets

AI is not one service. It's three with different cost/latency/quality profiles.

```
┌─────────────────────────────────────────────────────┐
│                    AI Services                       │
├──────────────┬──────────────┬───────────────────────┤
│ Ingestion    │ Assistive    │ Generative            │
│ (local)      │ (local+cloud)│ (cloud)               │
├──────────────┼──────────────┼───────────────────────┤
│ Transcript   │ Search       │ Title generation      │
│ Silence det  │ Suggestions  │ Reframing plans       │
│ Shot bounds  │ Chaptering   │ Visual variations     │
│ Diarization  │ Rough cuts   │ Complex edit planning │
│ Scene labels │ Highlight    │ Narrative restructure │
│ Loudness     │ ranking      │                       │
├──────────────┼──────────────┼───────────────────────┤
│ Runs on      │ Local first, │ Cloud only            │
│ import,      │ cloud for    │ User-initiated        │
│ background   │ quality      │ Cost-aware            │
│ Core ML      │              │                       │
└──────────────┴──────────────┴───────────────────────┘
```

**Cost tiers:**
- **Cheap/local:** silence detection, audio segmentation, transcript alignment, scene boundaries, keyword extraction. Run automatically on import.
- **Frequent cloud:** chapter suggestions, semantic search, selects ranking, caption generation, rough-cut proposals. Run on user request, cached aggressively.
- **Rare expensive:** full multimodal edit planning, generative transforms, cross-scene narrative restructuring. Explicit user action, progress bar, cost estimate shown.

### Background Analysis Pipeline

```swift
protocol AnalysisTask: Sendable {
    var type: AnalysisType { get }
    var costTier: CostTier { get }
    func run(asset: MediaAsset, progress: @escaping (Double) -> Void) async throws -> AnalysisResult
}

enum AnalysisType: String, Codable {
    case transcription, shotDetection, silenceDetection
    case speakerDiarization, sceneDescription, loudnessProfile
}

enum CostTier: String, Codable {
    case local       // free, runs on device
    case frequent    // cheap cloud, cached
    case expensive   // user must explicitly trigger
}

// Actor-based job queue
actor AnalysisPipeline {
    func enqueue(_ task: AnalysisTask, for asset: MediaAsset) async { ... }
    func cancel(asset: UUID) { ... }
    func pauseAll() { ... }           // memory pressure response
    func resumeAll() { ... }
}
```

### AI Provider Protocol — provider-agnostic

```swift
protocol AIProvider: Sendable {
    var name: String { get }
    func complete(messages: [AIMessage], tools: [AIToolDefinition]) async throws -> AIResponse
}

protocol AITool {
    var definition: AIToolDefinition { get }
    // AI tools resolve to EditorIntents, not raw commands
    func resolve(arguments: [String: Any], context: EditingContext) async throws -> [EditorIntent]
}
```

**AI tools resolve to EditorIntents** — same operational language as human actions. AI never bypasses the intent layer.

These are **empty shells** in Phase 1. The interfaces exist so Phase 2 (AI features) plugs in without redesigning the editor.

---

## Phase 1 Implementation Steps

### Step 1: Project Scaffold
- Create Xcode project (macOS app, SwiftUI lifecycle)
- Create `EditorCore` and `AIServices` as local Swift packages
- Define actor boundaries (ProjectStore, PlaybackEngine, RenderCache, etc.)
- Set up basic panel layout (SwiftUI): timeline, preview, media browser, inspector
- Wire up DI container (`EditingContext`)

### Step 2: Core Models + Persistence
- Implement all data models (Project, Timeline, Track, Clip, MediaAsset, etc.)
- Implement project bundle structure (directories + manifest)
- Start with JSON for timeline/manifest, add SQLite for action log + indexes
- Implement Command protocol + CommandHistory
- Implement EditorIntent enum + IntentResolver
- Unit tests for models, commands, intent resolution

### Step 3: Media Import + Proxy Pipeline
- File picker for video/audio/image import
- Copy source to project bundle media/ folder
- Thumbnail generation (AVAssetImageGenerator)
- Proxy generation: ProRes Proxy or H.264 all-I, 1/4 resolution
- Proxy generation runs in ProxyService actor, cancellable, with progress
- Fallback: if proxy fails, edit with full-res source (slower but works)
- Media browser UI with thumbnails

### Step 4: Timeline UI
- Track lanes (SwiftUI + AppKit for custom drawing if needed)
- Clip blocks on tracks (positioned by timelineRange)
- Playhead
- Ruler with timecode
- Zoom/scroll
- Drag to rearrange clips — all drags resolve through EditorIntent
- Snap to edges, playhead, markers
- Selection (single, multi)

### Step 5: Playback Engine
- Build AVComposition from Timeline model
- Implement composition graph compiler (Timeline → render graph)
- AVPlayer with preview in Metal-backed view
- Play/pause, seek, scrub
- Frame budget discipline: target project FPS, bounded GPU work
- Preview degradation levels (full → reduced effects → proxy-only → thumbnail)
- Audio waveform extraction + display
- Use proxy media for scrubbing, full-res for stationary preview

### Step 6: Editing Operations (via Intents → Commands)
- All user actions go through: User Action → EditorIntent → Command → Execute
- TrimClip, SplitClip, MoveClip, DeleteClips, InsertClip
- Undo/redo via CommandHistory
- ActionLog records every command with source (.user) to SQLite
- Keyboard shortcuts dispatch EditorIntents via Actions system

### Step 7: Export
- Build export pipeline: composition graph → AVAssetReader → Metal → AVAssetWriter
- Hardware encode via VideoToolbox, software fallback if unsupported codec
- Export settings UI (resolution, codec, quality)
- Progress bar + cancel
- Export interruption checkpoint (offer resume)
- Save to file

### Step 8: AI Rails (infrastructure only, no AI features)
- AnalysisPipeline actor (job queue shell, pause/resume for memory pressure)
- Three AI bucket protocols: Ingestion, Assistive, Generative
- AIProvider + AITool protocols (tools resolve to EditorIntents)
- MediaAnalysis model on assets (empty fields, ready to populate)
- Cache policies implemented per artifact type
- Memory pressure observer (NSProcessInfo) triggers degradation chain

---

## Phase 2 Preview (not built yet, but architecture supports it)

Once Phase 1 is solid, AI features plug in:
- **Transcription**: AnalysisTask implementation using Whisper / Cloud API
- **Silence detection**: Local audio analysis → marks silent ranges
- **AI chat**: AIProvider (Claude) with tools mapped to editor Commands
- **Smart rough-cut**: AI reads transcript + shot boundaries → proposes timeline
- **Semantic search**: "Find where I mention pricing" → transcript + embedding search

None of this requires redesigning the editor. It all operates on the structured data model.

---

## Distribution Pipeline

The editor's short-form output flows to Supabase, and an iOS app consumes it. The Mac is the sole writer; the iOS app is read-plus-edit-captions-only.

```
┌──────────────────┐      service-role key       ┌──────────────────┐      anon key      ┌────────────────┐
│ macOS editor     │  ────────────────────────▶  │ Supabase         │  ◀──────────────── │ iOS app        │
│                  │    upload_short_to_library  │                  │    read + edit     │ ShortsDistrib. │
│ SupabaseUploader │                             │ shorts_app schema│                    │                │
│ CaptionDrafter   │  TUS resumable for >50MB    │ • shorts         │                    │ LibraryView    │
│ ThumbnailCandi-  │                             │ • captions       │                    │ DetailView     │
│ dates            │                             │ • thumbnail_     │                    │ CaptionEditor  │
│ PendingUploads-  │                             │   settings       │                    │ ThumbnailEditor│
│ Queue (retry)    │                             │ • share_intents  │                    │                │
└──────────────────┘                             │ shorts-videos/   │                    └────────────────┘
                                                 │ shorts-thumbnails│
                                                 │ shorts-frames    │
                                                 │   (public-read)  │
                                                 │ • regenerate-    │                              │
                                                 │   caption fn     │  ◀───── POST ────────────────┘
                                                 │   (→ Claude)     │
                                                 └──────────────────┘
```

**Key constraints:**

- **Key separation.** Mac uses `SUPABASE_SERVICE_KEY`. iOS ships with the **anon key only** (`VideoEditor/iOSApp/Config/Config.swift`). The service key must never reach the client.
- **Public-read buckets.** `shorts-videos`, `shorts-thumbnails`, `shorts-frames` are public-read so iOS can stream without signed-URL infrastructure. Access is gated by the anon RLS policies on the tables, not the buckets.
- **Schema isolation.** All tables live in the `shorts_app` schema (not `public`); buckets are prefixed `shorts-*`. Keeps this product isolated from other tables in the same Supabase project.
- **Resumable uploads.** `SupabaseUploader` uses TUS for videos > 50 MB. Partial failures roll back the `shorts` row via typed errors and a logged rollback.
- **Retry queue.** `PendingUploadsQueue` persists pending uploads so a network blip doesn't lose work.
- **Caption regeneration.** The iOS app never calls Claude directly. It POSTs to the `regenerate-caption` edge function, which holds the `ANTHROPIC_API_KEY` as a Supabase secret and writes the result back to the `captions` table with `last_edited_by = 'claude_regen'`.
- **Share intents.** After the native share sheet completes (the user actually handed off to a platform app), iOS writes a `share_intents` row with a best-effort platform mapping from the `UIActivity.ActivityType`. If the user cancels, nothing is written. This gives the Mac feedback on what got posted without requiring OAuth to every platform.

Full task-by-task construction of this pipeline is in `docs/superpowers/plans/2026-04-12-ios-distribution-{01,02,03}-*.md`.

---

## Key Architectural Rules

1. **Timeline = references + instructions.** Never holds video data.
2. **All mutations through Intents → Commands.** One operational language for human, AI, and automation.
3. **DI everywhere.** No singletons. EditingContext is the root container.
4. **Actors own state.** Each domain actor is the single writer for its state. No shared mutable data.
5. **Two pipelines, one composition graph.** Preview and export share the same render graph, different quality settings.
6. **Frame budget is sacred.** Preview never exceeds target FPS budget. Degrade gracefully, never drop frames silently.
7. **AI operates on representations.** Transcript, metadata, embeddings — not raw pixels.
8. **AI failures never block editing.** The editor works without AI. AI enhances it.
9. **Immutable sources.** Original media is never modified. Proxies + cache are derived and rebuildable.
10. **Explicit cache policies.** Every cache type has size limits, eviction rules, and invalidation triggers.
11. **Incremental.** Only process what changed. Cache aggressively. Invalidate precisely.
