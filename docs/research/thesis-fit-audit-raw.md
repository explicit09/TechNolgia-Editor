# Thesis-fit audit: agent-native, terminal-first video editor

**Date:** 2026-05-02
**Thesis under test:** Pivot toward an agent-native, terminal-first video editor with text-first project format, headless engine substrate, GUI-as-thin-viewer, composable tools (SWE-agent ACI), Architect/Editor split, long-running harness shape, Anthropic Skills, and open-core monetization.
**Audit scope:** Full read of `/Users/tadies/Projects/video-editor/`.

---

## 1. Codebase shape

The repo is a single git monorepo with three runnable surfaces and a planning corpus that's already done a chunk of the thinking the thesis is asking about.

**Code volume:**

- `VideoEditor/Packages/EditorCore/` — 124 Swift files, ~23,738 LOC. Pure Swift Package, `.macOS(.v14)` only, no UI framework imports. This is the "engine."
- `VideoEditor/Packages/AIServices/` — 30 Swift files, ~7,638 LOC. Depends on EditorCore + WhisperKit. Also no UI imports. Holds providers, planning, transcription, MCP-facing tool registry.
- `VideoEditor/VideoEditor/` — 23,591 LOC of macOS app. UI is 12,014 LOC across 52 files in `UI/`. The `App/` directory has three monsters: `MCPServer.swift` (7,158 LOC, 361KB), `AppState.swift` (2,101 LOC), `AIChatController.swift` (1,026 LOC).
- `VideoEditor/iOSApp/` — 6,978 LOC. Distribution-only, reads from Supabase, not load-bearing for the thesis.
- `VideoEditor/Tools/` — Python eval/QA harness, ~5,500 LOC including `eval_system/`. Drives the macOS app via the MCP HTTP endpoint.
- `supabase/` — 5 SQL migrations + one edge function (`regenerate-caption`) + bucket seeds. Cleanly scoped to short-form distribution.

**Test coverage:**

- EditorCore: 32 test files, 5,124 LOC. Solid coverage of models, commands, persistence, command edge cases, effect rendering, composition, action log.
- AIServices: 9 test files, 1,490 LOC. Caption drafter, context builder, topic segmenter, Supabase client (incl. resumable), pending uploads queue, transcription service.
- macOS app: 8 test files (light).
- Python harness: 1,378 LOC of tests for the eval system.
- Total ~339 Swift test files across the project (counting App + Packages + non-build dirs).

**Documentation:** `ARCHITECTURE.md` is 753 lines, opinionated and accurate (verified against code — the `EditorIntent → Command → Execute` pattern, project bundle layout, actor boundaries are all faithfully described). `docs/superpowers/` has 17,499 lines of plans + specs split into `plans/` (15 plans, mostly dated 2026-04-05 → 2026-04-12) and `specs/` (12 design docs). `docs/research/harness-learnings/` is 6,346 lines of synthesized agent-harness research — the founder has already mapped Aider Architect/Editor, Anthropic long-running harness, Skills, SWE-agent ACI, Cursor shadow workspace onto video. **This is unusual; the thesis isn't being tested cold.** `RESEARCH_REPORT.md` (336 lines) is a competitive feature-gap analysis vs. DaVinci/Premiere/CapCut/Descript/OpusClip.

**Activity signals:** 231 commits in the 30 days prior to the audit window. Last commit was 2026-04-13 (~3 weeks before today, 2026-05-02) — looks like a pause, possibly the moment this audit is being requested. Recent work was nearly all iOS distribution (LinkedIn/X/YouTube direct publish, OAuth flows). The macOS engine work largely stopped after the 2026-04-12 distribution sprint.

---

## 2. Thesis properties scorecard

### 2.1 Project format — text-first, diffable, OTIO

**Current state:** Project is a directory bundle (`*.veditor/`) with `manifest.json` + `timeline.json` + sidecar dirs (`media/`, `proxies/`, `cache/`, `analysis/`, `versions/`) + `metadata.sqlite` for the action log. Both JSON files are written via `JSONEncoder.pretty` with `[.prettyPrinted, .sortedKeys]` and `.iso8601` dates.

**Evidence:**
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Storage/ProjectStore.swift:34-63` — `save(to:timeline:)` writes pretty/sorted JSON.
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Storage/ProjectStore.swift:120-127` — the `JSONEncoder.pretty` extension. **Sorted keys + pretty-printed = genuinely diff-friendly.**
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Timeline.swift:5-17` — `Timeline` is a pure value type with `tracks: [Track]` and `markers: [Marker]`, all `Codable`.
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Clip.swift:5-112` — `Clip` is fully `Codable` with explicit `CodingKeys`, no AVFoundation references. UUIDs are stable and serialized as strings.
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/MediaAsset.swift:5-53` — `MediaAsset` is a pure `Codable` struct keyed by UUID with file URL references, no in-memory `AVAsset`.
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Storage/VersionControl.swift:5-77` — there's an in-bundle named-snapshot system (`save_snapshot`, `restore_snapshot` exposed via MCP). It encodes the Timeline as JSON Data and persists per-snapshot files plus an `index.json`. **It's not Git, but it's git-shaped: list snapshots, restore by name.**
- **OTIO grep across the repo: zero hits.** No `OpenTimelineIO`, no Python OTIO adapter, no FCPXML, no EDL, no AAF. The format is bespoke.

**Verdict:** **Aligned (with one missing piece).** The format is already JSON, already diffable, already pretty/sorted. Snapshots are first-class. The only gap vs. the thesis is OTIO — there is no adapter, and the schema is bespoke (e.g., the linked-clip pattern via `linkGroupID: UUID?`, the broadcast-overlay structure, the `OverlayPresentation` block) so it's a strict superset of what OTIO models. Mapping the engine schema → OTIO would be a real but bounded port: the field names and the layered-clip / nested-sequence story differ. There's also no Git-per-edit commit mechanism wired up, only the snapshot system.

**What would need to change:**
1. Write an OTIO adapter (Swift or Python in `Tools/`) that round-trips `Timeline` ↔ OTIO. Probably ship as a separate `EditorCoreOTIO` target with the OTIO Swift bindings or a Python bridge.
2. Decide whether the bespoke schema is the canonical and OTIO is the export, or vice versa. (Recommend: bespoke stays canonical because of the clip-link/overlay-presentation features; OTIO is the export/import format.)
3. Replace the in-bundle `versions/` snapshot store with actual Git commits scoped to the bundle (probably `git -C bundle commit timeline.json`). The current snapshot system is well-shaped to be replaced.

---

### 2.2 Engine vs. UI separation

**Current state:** Surprisingly clean. `EditorCore` and `AIServices` together are ~31k LOC and **import zero SwiftUI / AppKit / UIKit.** The UI lives entirely in `VideoEditor/VideoEditor/UI/` (12k LOC) and the `App/` directory.

**Evidence:**
- `grep -rln "import SwiftUI\|import AppKit\|import UIKit" VideoEditor/Packages/{EditorCore,AIServices}/Sources/` returns nothing.
- `VideoEditor/Packages/EditorCore/Package.swift:6-8` — package targets macOS only.
- AVFoundation/Metal/Vision **are** used inside EditorCore, but concentrated in well-named subsystems: `Playback/` (13 files), `Export/` (4), `Media/` (10), `Analysis/` (15 of 23 files import AVFoundation), `Verification/` (4 of 7), `Rendering/` (1 file). 38 of 124 files import AV/Metal/Vision.
- The "data spine" — `Models/`, `Commands/`, `Intents/`, `Storage/`, `ActionLog/`, `Cache/` — is pure Foundation (plus a touch of CoreGraphics in `Project.swift:2-3` for color helpers, easily removable).
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Playback/PlaybackEngine.swift:5-22` — `PlaybackEngine` is `@MainActor @Observable` and owns `AVPlayer`. It's a service inside EditorCore, not a model. Could be left as the "macOS preview" implementation while the engine grows a non-AV "headless renderer" sibling.

**The wart:** `VideoEditor/VideoEditor/App/AppState.swift:1-35` is the actual orchestrator. It's 2,101 lines, `@Observable @MainActor`, holds `EditingContext`, `CommandHistory`, `IntentResolver`, `PlaybackEngine`, `ExportEngine`, `MediaCoordinator`, `AIChatController`, `ProjectStore`, `ProjectIndexManager`, plus the MCP server. **Most of the orchestration that should be in EditorCore is in this app file.** Routing user actions to intents, scheduling saves, glueing media coordinator to project store — all live in the app target.

**Verdict:** **Partial — strong bones, weak orchestrator placement.** The clean Package boundary and zero-UI-imports rule has actually been held. The data layer would compile on Linux today (probably) — Foundation, no AppKit. The render pipelines are AVFoundation-bound, which is the Mac OS substrate. What blocks "headless on a Linux box" is:

1. AVFoundation in the Playback/Export/Analysis paths. Replacing with FFmpeg + WhisperKit-equivalent + a software composition graph is a substantial engineering project (~5–10k LOC) but the *interface* is the timeline JSON, which is already portable.
2. `AppState` doing too much. The orchestration that a CLI would need is currently entangled with app lifecycle, SwiftUI scene phase, NSTextField prompts (`VideoEditor/VideoEditor/App/VideoEditorApp.swift:122-140`), and the MCP HTTP server.
3. The MCP server lives in the app target, not in EditorCore (see 2.3).

**What would need to change:**
1. Lift `AppState`'s orchestration logic (project lifecycle, command dispatch, save scheduling) into a `EditorSession` actor inside EditorCore. Leave SwiftUI-bound state in `AppState`.
2. Define a `RenderBackend` protocol in EditorCore. Make `AVFoundationPlaybackEngine` and `AVFoundationExportEngine` two of many possible implementations. Add `FFmpegExportBackend` for CLI/Linux.
3. Either move MCPServer into EditorCore (so it's process-attachable to any host) or create a new `Substrate` target that wraps EditorCore + MCP + a CLI.

---

### 2.3 CLI accessibility

**Current state:** Effectively zero. There is no `swift run` CLI target, no headless invocation path. The MCP server is a TCP listener instantiated by the macOS app at startup.

**Evidence:**
- `VideoEditor/VideoEditor/App/MCPServer.swift:13-22` — `MCPServer` is `@MainActor`, takes a `weak var appState: AppState?`, and is constructed by AppState.
- `VideoEditor/VideoEditor/App/AppState.swift:144-147` — MCP server `start()` is called in AppState's init, which is constructed in `VideoEditorApp.swift:8` (`@State private var appState = AppState()`). **The GUI process must be running for any agent to talk to the engine.**
- `VideoEditor/Packages/EditorCore/Package.swift:9-23` — only one product, the `EditorCore` library. No `executableTarget`.
- The Python harness `VideoEditor/Tools/mcp_visual_harness.py:36` defaults to `http://127.0.0.1:8420` — i.e., it talks to the running app, doesn't run the engine itself.

**Verdict:** **Misaligned.** This is the single biggest thesis blocker. The whole system is GUI-anchored. No headless path exists. The MCP server is well-designed in its protocol (JSON-RPC over HTTP, loopback-only origin checks at lines 56-91, CORS done correctly), but it's structurally a macOS-app feature, not a substrate.

**What would need to change:**
1. Extract `MCPServer` from the app target into EditorCore (or a sibling `EditorMCP` target). The hard work isn't the HTTP server — it's that the 70 tool handlers (`if name == "..."` chain at `MCPServer.swift:751-866+`) reach into `AppState` for things like project lifecycle, sandbox paths, and `NSAlert` flows. Those need to be extracted onto a process-agnostic session abstraction.
2. Add a `swift run videoeditor-cli` target that boots EditorCore, opens a project bundle path, starts the MCP server, and idles. This is plausibly a 1-2 week task once the orchestration is lifted out of AppState.
3. The sandbox-only file-path constraint (`MCPServer.swift:189-191`: "files must be inside the container at ~/Library/Containers/...") is a Mac App Sandbox artifact. CLI mode should drop it.

---

### 2.4 Tool surface — granularity

**Current state:** Two registries, each large, partially overlapping.

**Evidence:**
- `VideoEditor/Packages/AIServices/Sources/AIServices/Tools/AIToolRegistry.swift:8-110` — `AIToolRegistry.allTools` is an array of **94 tool definitions**. Most are 1-method tools that map directly to a single `EditorIntent` (`addTrack`, `insertClip`, `splitClip`, `setClipVolume`, etc.). Granularity is good — these are SWE-agent ACI-shaped: small, named, parameter-typed (`AIToolDefinition.ParameterSchema`), and resolve to commands via `AIToolResolver`.
- `VideoEditor/VideoEditor/App/MCPServer.swift:187-654` — the MCP server hand-codes **about 12 additional MCP-only tools** (`import_media`, `add_to_timeline`, `clear_project`, `verify_playback`, `export_video`, `save_snapshot`, `list_snapshots`, `restore_snapshot`, `take_screenshot`, `extract_clips`, `extract_segment`, `make_short`, `analyze_for_shorts`, `create_short`, `set_overlay_config`, `get_overlay_config`, `analyze_transcript`, `find_viral_moments`, `upload_short_to_library`, `detect_episodes`, `classify_audio`, `auto_cut`, `score_content`, `segment_topics`, `hook_optimize`, `export_for_platform`, `list_platforms`, `set_export_folder`, `get_export_folder`, `add_media_folder`, `list_media_folders`, `get_transcript_with_timing`, `delete_transcript_range`, `remove_filler_words`, `create_project`, `open_project`, `list_projects`, plus more).
- `MCPServer.swift:655` runs `deduplicatedTools(tools)` to merge the two lists (last-write-wins) into the JSON-RPC `tools/list` response. **Net total exposed via MCP is roughly 90-110 tools after dedup**.
- Dispatch: `MCPServer.swift:751-866+` is a flat `if name == "..." { return await handle...() }` chain with **70 cases** in a 7,158-line single file. The handlers themselves are mostly thin wrappers that call into `appState`, `appState.context`, the intent router, etc.

**Granularity assessment:** AIToolRegistry tools are **well-shaped** — `split_clip(clip_id, at)`, `set_clip_volume(clip_id, volume)`, `ripple_trim(clip_id, edge, delta)`. These are exactly SWE-agent style: small, unambiguous, resolve to one intent. The MCP-only additions are larger ("workflow tools" — `auto_cut`, `make_short`, `analyze_for_shorts`) which is appropriate for a different layer.

**Problems:**
1. **Two parallel registries with overlapping concerns.** AIToolRegistry has `delete_asset`, `get_overlay_config`, `set_overlay_config`, `analyze_transcript`, etc.; MCP server also has them. Some go through `AIToolResolver` → `IntentResolver`, some go through ad-hoc `handle*()` methods in MCPServer. There's no single source of truth for what tools exist.
2. **MCPServer.swift is the wrong shape.** 7,158 lines with a 70-case `if-elseif` chain and inline JSON-schema definitions. Tool definitions and tool handlers should be co-located in small files.
3. **Dispatch into `AppState` couples tools to the app process.** Splitting the registry from the GUI host is necessary before tools can run headlessly.

**Verdict:** **Partial.** The granularity is genuinely good — the registry already approaches the SWE-agent ACI principle. What's missing is the *organization*: the two registries should merge, MCPServer.swift should be decomposed, and tool handlers should live next to their definitions in EditorCore (or AIServices), not in a 7k-line monster in the app target.

**What would need to change:**
1. Single registry. Each tool is a `struct` conforming to a `Tool` protocol with `name`, `description`, `parameters`, and `handler(args, session) async throws -> String`.
2. Move the 70 `handle*()` methods out of MCPServer, one per file, alongside the AIToolRegistry definitions.
3. Audit overlap and remove duplicates.
4. Resulting MCPServer.swift becomes a thin transport layer (HTTP + JSON-RPC) ~500 LOC max.

---

### 2.5 Architect / Editor split

**Current state:** Already implemented, in shape if not quite in name.

**Evidence:**
- `VideoEditor/Packages/AIServices/Sources/AIServices/Planning/PlanGenerator.swift:11-89` — `PlanGenerator` calls Claude with a single `propose_plan` tool to force structured JSON output. Returns an `EditingPlan` with summary + steps, where each step has `tools`, `modelTier` (`fast`|`standard`), and `category` (`analyze`|`edit`|`property`|`verify`|`overlay`).
- `VideoEditor/Packages/AIServices/Sources/AIServices/Planning/PlanExecutor.swift:7-86` — `PlanExecutor` runs each step sequentially with the assigned tool subset and model tier, threads previous results into the next step's prompt. Haiku for fast steps, Sonnet for standard.
- `VideoEditor/Packages/AIServices/Sources/AIServices/Routing/IntentRouter.swift` and `Planning/PlanClassifier.swift` (referenced at `AIChatController.swift:115-186`) — there's even a *pre-planner* that decides whether a request needs a plan at all vs. direct execution.
- `VideoEditor/VideoEditor/App/AIChatController.swift:114-186` — the chat controller checks for pending plans, asks for user approval, then dispatches via the executor.

**This is the Aider Architect/Editor pattern, video-flavored:** Sonnet plans the structural decisions, Haiku executes the mechanical steps, with model tier baked into each step.

**Verdict:** **Aligned.** Better than the thesis asked for — there's also a `PlanClassifier` that gates whether to plan at all, and a `SkillRegistry` that enriches the planner system prompt with workflow-specific rules. The shape is correct.

**Gaps relative to the thesis:**
1. The plan executor lives in AIServices but the `executeToolCall` closure at `AIChatController.swift:138-142` hops through `appState.mcpServer?.executeToolForAgent` — i.e., the executor is wired through the app process. CLI mode would require lifting this.
2. There is no parallel sub-agent ("Lead + parallel sub-agents" from the harness research). The plan is sequential, which is fine for short clips but expensive for "process this 4-hour podcast with 90 minutes from each of 3 cameras."
3. The `editorState` re-fetch between steps is a JSON dump — unbounded, no compression. For long sessions this will eat tokens. The harness research file (`docs/research/harness-learnings/synthesis.md`) explicitly calls this out as the discipline the founder hasn't yet imposed.

---

### 2.6 Long-running harness shape

**Current state:** Mixed. Some pieces are real, others are missing.

**Evidence — what exists:**
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/ActionLog/ActionLog.swift:43-78` — every command is logged to SQLite with timestamp, command name, affected clip/track IDs, parameters dict, and an `ActionSource` enum (`user|ai|macro|undo|redo`). **This is structured-state-outside-context, exactly the pattern.**
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Storage/VersionControl.swift:28-41` — named-snapshot save/restore. Used by skills like `podcast-episode-producer` (the first instruction is `save_snapshot label="raw_import"`).
- `VideoEditor/Packages/EditorCore/Sources/EditorCore/Storage/CrashRecovery.swift:5-43` — lock-file mechanism detects unclean shutdown.
- Transcription is async and stateful (per `CLAUDE.md` and `VideoEditor/Packages/AIServices/Sources/AIServices/Transcription/TranscriptionService.swift`). `transcribe_asset` returns a job ID; `get_transcript` polls.

**Evidence — what's missing:**
- No `episode-notes.md` equivalent — the agent's running editorial reasoning is not captured anywhere, only the structured action log.
- No `edit-plan.json` artifact persisted between sessions. Plans live in `AIChatController.pendingPlan` (in-memory), get executed, then evaporate.
- No initializer/worker split. There's no "ingest pass" that runs once and writes a structured plan a worker picks up later. The `auto_cut` and `analyze_transcript` tools are the closest, but they're per-call, not persistent harness state.
- No git-commit-per-editorial-decision. The snapshot system is the closest analog but is named-only (no auto-commit on intent execution).
- No agent-resume semantics. If a session ends mid-plan, there's no way to pick up from step N.

**Verdict:** **Partial.** The substrate exists — SQLite action log, snapshot system, async transcription — but the harness shape on top of it is not built. Plans aren't persisted, agent reasoning isn't captured to disk, there's no two-phase initializer/worker.

**What would need to change:**
1. Persist plans. `EditingPlan` is already `Codable`-shaped; save it to `<bundle>/plans/<plan-id>.json` with status fields.
2. Add an `episode-notes.md` artifact in the bundle that the agent appends to as it makes editorial decisions.
3. Auto-commit Git per intent (if/when Git replaces the snapshot system). Snapshot commits per `EditorIntent` execution from `.ai` source.
4. Extract `transcribe + analyze + index` into a one-shot initializer skill that writes its output to a known location for subsequent sessions.

---

### 2.7 Skills — Anthropic Agent Skills format

**Current state:** Already implemented, mostly correctly.

**Evidence:**
- `.claude/skills/` has 9 skills; `.agents/skills/` mirrors them. All 9 are present in both: `auto-cutter`, `beat-sync-editor`, `meeting-highlights`, `pacing-optimizer`, `podcast-editor`, `podcast-episode-producer`, `rough-cut-assembler`, `shorts-formatter`, `viral-clip-extractor`. Total 1,945 lines across 9 SKILL.md files, the largest being `podcast-episode-producer/SKILL.md` (412 lines).
- Each skill uses YAML frontmatter with `name`, `description`, `allowed-tools` (space-separated tool list). The `podcast-episode-producer/SKILL.md:1-5` frontmatter declares 19 allowed tools. **This is the Anthropic Skills format faithfully implemented.**
- `VideoEditor/Packages/AIServices/Sources/AIServices/Skills/SkillRegistry.swift:36-146` — loader walks a `skillsDir`, parses frontmatter (simple key:value with list support), exposes `match()` (keyword-based scoring) and `skillCatalog()` (system-prompt fragment).
- `AIChatController.swift:166-186` — when a request needs a plan, the controller calls `skillRegistry.match(message)` and threads the matching skill's body into `PlanGenerator`'s system prompt.
- `AIToolRegistry` includes `activate_skill` as a tool — agent can opt in to a skill on its own.

**Gaps:**
1. The skills don't yet carry **bundled scripts** (Anthropic's "level 3" progressive disclosure). It's prose-only. The `podcast-editor` skill has guidelines but no Python helper to e.g. run the deterministic filler-word matcher.
2. The `keywords` field in the frontmatter is the matcher's input — but the skills don't all declare it. The `description` is what gets matched-against in many cases. Inconsistent.
3. No skill versioning, no skill dependencies.

**Verdict:** **Aligned (mostly).** The format is right, the loader is right, the integration into the planner is right. The progressive-disclosure level-3 (bundled scripts) is the missing piece.

**What would need to change:**
1. Add support for bundled Python scripts in skill folders. `SkillRegistry` already exposes `skill.content`; extend with `skill.scripts: [URL]` and a way for the agent to request execution.
2. Standardize on either `description`-based or `keywords`-based matching (recommend description-based with embeddings, not keyword scoring — the current `matchScore` is a substring count, which is fragile).
3. Audit `allowed-tools` lists against the actual `AIToolRegistry` for typos / drift.

---

### 2.8 Open core readiness

**Current state:** Not posture-ready as-is, but cleanly separable.

**Evidence — licensing:**
- **No LICENSE file at the repo root.** No `SPDX-License-Identifier` headers in any source file. This is a private repo by default — there is no open-source posture established.

**Evidence — closed-API dependencies:**
- `ANTHROPIC_API_KEY`, `DEEPGRAM_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `BFL_API_KEY` are all read from `.env`.
- `AIServices/Providers/ClaudeProvider.swift`, `AIServices/Transcription/DeepgramProvider.swift`, `AIServices/ImageGen/{FluxImageProvider, OpenAIImageProvider, GeminiImageProvider}.swift` — direct API clients.
- `AIServices/Transcription/WhisperKitProvider.swift` — local fallback for transcription, free.
- `AIServices/Publishing/SupabaseUploader.swift`, `SupabaseClient.swift` — uses TUS resumable upload to Supabase. The Supabase URL+key live in `.env`.

**Evidence — boundary:**
- The `AIProvider` and `TranscriptionProvider` protocols (`AIServices/Protocols/AIProvider.swift`, `AIServices/Transcription/TranscriptionProvider.swift`) are abstractions over the closed APIs. **Cleanly drawable boundary.** A user with their own keys could substitute providers.
- The MCP-only tools that hard-bind to commercial APIs: `generate_thumbnail` (FLUX/Gemini), `generate_carousel` (FLUX/Gemini), `generate_title` (Claude), `analyze_transcript` (Claude), `find_viral_moments` (Claude), `auto_insert_broll` (Pexels API), `upload_short_to_library` (Supabase).

**Verdict:** **Partial.** The technical boundary is fine — providers are protocol-shaped, local fallbacks exist for transcription, the engine is provider-agnostic. The legal posture isn't established. There's also no obvious "free tier" story: the editor depends on at minimum the Claude API for any content-aware editing.

**What would need to change:**
1. Choose a license. Apache 2.0 + commercial cloud add-on is the typical open-core shape. Add headers.
2. Make every closed-API call optional. WhisperKit is already the local fallback for Deepgram; do the same for image gen (e.g., local Stable Diffusion for thumbnails) and document the degradation.
3. Decide what's open vs. closed:
   - **Open candidates:** EditorCore, AIServices/Tools (registry + resolver), AIServices/Skills, AIServices/Planning, MCPServer (lifted out of app), CLI substrate, OTIO adapter.
   - **Closed candidates:** Hosted agent (running the planner against hosted Claude), Supabase distribution backend, the proprietary `BroadcastOverlay` template assets, the iOS app + share-intent flows.
4. The macOS GUI itself could go either way — open as a reference viewer, or closed as the paid hosted experience. The thesis's "GUI as one of many possible clients" suggests open + reference.

---

## 3. Surprises

**1. The harness research already exists.** `docs/research/harness-learnings/synthesis.md` is 171 lines + 18 source documents (6,346 LOC total). The founder has read Aider's Architect/Editor paper, Anthropic's long-running harness post, SWE-agent ACI, Cursor design notes, OpenHands overview, and synthesized them with explicit application to video. The thesis is not a surprise to this codebase — it is the direction the author has already mapped. The document explicitly notes "OTIO file (or your superset) is the source of truth", "Make agent reasoning a first-class artifact", "JSON for state Claude shouldn't overwrite. Markdown for state Claude updates" — these are the thesis bullet points, paraphrased. **The codebase isn't a coding harness, it's a codebase whose author has already concluded it should become one.**

**2. The two-tier plan/execute system is real.** I expected to find a single agent loop; instead found `PlanClassifier → PlanGenerator → user approval → PlanExecutor`, with model-tier-per-step (`fast`/`standard`) baked in. This is more sophisticated than typical "Claude with tools" agent setups.

**3. Skills are wired into the planner system prompt.** When a user request matches a skill's keywords, the entire SKILL.md body gets included in the planner's prompt at `PlanGenerator.swift:84-86`. This means skills aren't just documentation — they're load-bearing in the planner's reasoning. That's how the thesis says it should work; it's already built.

**4. `MCPServer.swift` is the architectural bug.** A 7,158-line, 361KB single file with a 70-case if/else chain is a giant smell. It's the seam where the thesis-aligned engine work (clean Packages, intent/command, action log) collides with macOS-app-specific stuff (sandbox paths, `NSAlert`, `WindowGroup`). Refactoring this file unlocks most of the thesis.

**5. The "shorts distribution" pivot looks like the actual recent activity.** 60+ of the last 70 commits are iOS distribution / OAuth / direct-publish work (LinkedIn, X, YouTube). The macOS engine and harness research went quiet around 2026-04-12. The codebase's thesis-fit is strong but the thesis isn't where the recent investment has gone — that may itself be useful signal for the founder conversation (i.e., they ran the experiment of "build the iOS distribution moat" and may now be deciding whether to swing back).

**6. The action log is more complete than the GUI surfaces.** Every command logs `clipIDs`, `trackIDs`, `parameters`, `source` to SQLite with timestamps. The MCP `get_action_log` tool exposes it. This is the Git-log-of-edits the thesis wants — it just isn't surfaced as Git commits. Replacing the snapshot system with `git -C bundle commit -m "<intent>"` per edit is a multi-day project, not a multi-month one.

**7. The plan/spec discipline is unusually high.** 17,499 lines of dated, structured plans in `docs/superpowers/`. Each plan has `- [ ]` checkboxes and a referenced design doc. Recent ones go down to per-task granularity ("Step 1.3: Add `WhisperKitProvider.transcribe(audio:options:)`"). This is engineering hygiene that suggests pivoting cost is lower than it would be in a typical codebase — the team already plans before coding.

**8. Tests are heavier in EditorCore than I expected.** 5,124 LOC across 32 test files for the engine alone. `CommandEdgeCaseTests`, `ActionLogTests`, `ProjectPersistenceTests`, `ContentVerifierTests` — these are non-trivial. EditorCore is *test-covered enough to refactor confidently*.

---

## 4. Bottom line

**Keep:**
- `EditorCore` — the engine package is genuinely thesis-aligned. JSON project format, command/intent pattern, action log, no UI imports. ~24k LOC of well-tested Swift that already does most of what a "headless substrate" would need to do at the data-and-mutation layer.
- `AIServices/Planning/` — the Architect/Editor split (`PlanClassifier → PlanGenerator → PlanExecutor` with model tiering) is the thesis pattern, already shipped.
- `AIServices/Skills/` + `.claude/skills/` — Anthropic Skills format adopted correctly, planner integration wired up, 9 mature skills.
- `AIServices/Tools/AIToolRegistry.swift` — the 94-tool registry is SWE-agent ACI-shaped; the granularity is good even if the organization needs work.
- `docs/research/harness-learnings/` and `docs/superpowers/` — the planning corpus and synthesis are unusually mature; pivoting won't require re-reading the literature.
- The action log + version control + crash recovery primitives. They're the substrate for the "long-running harness" piece of the thesis.

**Refactor:**
- `VideoEditor/VideoEditor/App/MCPServer.swift` (7,158 LOC) — decompose into per-tool files alongside `AIToolRegistry`. Extract HTTP transport (~300 LOC). This is the highest-leverage single refactor in the codebase.
- Merge `AIToolRegistry` and the MCP-only tool list. Single source of truth.
- `VideoEditor/VideoEditor/App/AppState.swift` (2,101 LOC) — lift orchestration (project lifecycle, save scheduling, command dispatch routing) into an `EditorSession` actor in EditorCore. Leave SwiftUI-bound state in `AppState`.
- Replace the in-bundle `versions/` snapshot system with Git commits scoped to the bundle. Auto-commit per `.ai`-source intent.
- Decompose `Playback/`, `Export/` so they implement a `RenderBackend` protocol; make AVFoundation one of N backends.

**Replace / Add:**
- OTIO adapter — write one. The bespoke Timeline JSON is a strict superset, so the adapter is a port, not a redesign.
- CLI entry point — add a `swift run videoeditor` executable target that boots the engine + MCP without the GUI.
- Persistent agent state — `<bundle>/plans/*.json`, `<bundle>/episode-notes.md` for the harness reasoning artifact.
- Open-source license + provider-optionality audit.

**Honest read on starting fresh vs. evolving:**

Starting from this codebase is **substantially faster than ground-up**, but with the caveat that the savings are concentrated in the engine package and the planning corpus, not in the macOS app shell.

The engine, command system, intent pattern, action log, project format, planning system, and skills loader are ~30-40k LOC of work that would take 4-6 months to rebuild from scratch and test to current quality. The skills are domain knowledge worth weeks more. The harness research is itself a moat — most teams pivoting to "agent-native video editing" would spend a month reading the same papers this team has already synthesized. None of that gets thrown away in the pivot.

What you'd be cutting: the SwiftUI timeline UI (12k LOC), the iOS distribution app (7k LOC plus the recent OAuth work), parts of `MCPServer.swift` and `AppState.swift` (a thousand LOC of MacOS-specific glue between them, post-refactor). Probably 20-25k LOC of macOS-app-shell work becomes vestigial or downgraded to "reference viewer" status.

The single biggest risk: this is a Swift+macOS codebase. If the thesis means "should run on Linux servers headlessly," then the AVFoundation-bound Playback/Export/Analysis modules are a 2-3 month port to FFmpeg + on-Linux-equivalent libraries. That's the load-bearing engineering question. If the thesis allows "headless on macOS only" (i.e., the substrate is `swift run` on a Mac, the GUI is one of many clients on the same Mac), the pivot is much cheaper — probably 4-8 weeks of focused work to lift orchestration out of AppState, decompose MCPServer, add OTIO + CLI + plan persistence + Git-per-edit, and ship a public release.

Recommendation framing for the founder: this codebase is closer to thesis-aligned than 90% of what an audit like this typically reveals. The work isn't fundamental redesign — it's structural cleanup of `MCPServer.swift` + `AppState.swift`, plus four targeted additions (CLI target, OTIO adapter, persistent plan state, Git-per-edit). The math is "evolve from here" unless the cross-platform requirement is hard, in which case the AVFoundation coupling becomes the binding constraint and a Rust/FFmpeg substrate-only rewrite is worth pricing as an alternative.
