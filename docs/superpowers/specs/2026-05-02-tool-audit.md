# MCP Tool Correctness Audit

> **Status:** Phase 1 framework laid down 2026-05-02. Phases 2-4 fill in.
> **Companion file:** `_tool-inventory.json` — source-of-truth list of all 130 unique MCP tool names.
> **Goal:** answer the question *"where is the tool layer breaking?"* with file:line evidence per tool.

## What this document is

The MCP surface exposes ~130 unique tool names (91 in `AIToolRegistry.allTools` + 39 MCP-only handlers, after the `deduplicatedTools()` merge in [`MCPServer.swift`](../../VideoEditor/VideoEditor/App/MCPServer.swift)). We have evidence (see Phase 1 worked examples below) that some of those tools "succeed" without doing the work their `description` field promises to the model. Until we know which ones, the agent cannot trust any tool, and humans cannot trust agent reports.

This document audits **every tool** end-to-end and assigns a verdict + evidence + (when broken) a one-paragraph fix spec.

## Verdict legend

| Verdict | Meaning |
|---------|---------|
| **WORKING** | All 4 trace points connect. The tool actually does what its description claims (audible/visible/persisted). |
| **PARTIAL** | State is set and partially consumed (e.g. shown in UI preview but not in export, or applied to playback but lost on reload). |
| **STUB** | The handler returns a canned success string, OR writes state that no consumer ever reads. The tool *lies* to the agent. |
| **DEAD** | The handler exists but is unreachable — the dispatcher routes the name elsewhere first. |
| **DUPLICATE** | Two definitions for the same name. After dedupe, one schema wins; the other is misleading documentation. |
| **ORPHAN** | Implementation works fine, but no skill in `.claude/skills/*/SKILL.md` ever names the tool in `allowed-tools:`. Reachable, just unsteered. |
| **MISSING-FROM-LIST** | A tool definition exists in `AIToolRegistry.swift` but is not present in the `allTools` array, so it is not advertised via the registry path. |

## Audit method — the 4-point trace

For every tool name, walk these four points in order:

1. **Definition.** Where is the tool advertised? Registry (`AIToolRegistry.allTools`), MCP-only inline append in `MCPServer.handleRequest` (lines 187-650), `mcpOnlyAgentFallbackTools()` (line 759), or some combination? Does the `description` match the `inputSchema` and the actual handler?
2. **Dispatch.** When the agent invokes this name, who handles it? There are three lanes inside `MCPServer.executeToolCall`:
   - **Direct branch** — explicit `if name == "..."` handler that returns a string.
   - **`handleAnalysisTool`** — only for names in the gated `analysisTools = [...]` set at [`MCPServer.swift:942-946`](../../VideoEditor/VideoEditor/App/MCPServer.swift).
   - **Resolver fallthrough** — final block at [`MCPServer.swift:1162-1171`](../../VideoEditor/VideoEditor/App/MCPServer.swift) that calls `AIToolResolver.resolve(...)` → `EditorIntent` → `Command`.
3. **Handler.** Does the handler actually invoke an engine, mutate state, or just return a string? For resolver-pipeline tools, does the `Command.execute(context:)` actually mutate the timeline, or is the resolver returning `[]` (no-op)?
4. **Downstream consumer.** If the handler writes state, does playback / export / UI **read** that state? If it kicks off async work, is the result observable to the agent (via `get_state`, `get_action_log`, polling, etc.)?

A tool is only **WORKING** when all four points connect.

## Worked examples

These three concrete tools illustrate the most common verdicts. Phase 2 audits should mirror this format.

### Example A — `apply_gate` ⇒ STUB

**Trace:**

1. **Definition.** Registry-only. `AIToolRegistry.swift:882-892` — description: *"Apply a noise gate to a clip's audio. Prevents bleed by only allowing audio above the threshold through."* Schema: `clip_id` (required), `threshold_db`, `attack_ms`, `release_ms`.
2. **Dispatch.** Resolver fallthrough. `AIToolRegistry.swift:1338-1344` resolves to `[.applyGate(clipID:config:)]`.
3. **Handler.** [`AudioEffectCommands.swift`](../../VideoEditor/Packages/EditorCore/Sources/EditorCore/Commands/AudioEffectCommands.swift) → `ApplyGateCommand.execute` writes `clip.audioEffects.gate = config`. Mutation succeeds, undo is correct, the test in `AudioEffectCommandTests.swift` passes.
4. **Downstream consumer.** **None.** [`CompositionBuilder.swift:354-360`](../../VideoEditor/Packages/EditorCore/Sources/EditorCore/Playback/CompositionBuilder.swift) reads `timelineTrack.audioEffectChain` to attach `AudioEffectTap` — it never inspects `clip.audioEffects`. Grep for `audioEffects` outside the model/command/tests returns nothing in the playback or export path. So the gate config sits on the clip and is ignored at audition and at export.

**Verdict:** **STUB**. The agent receives a success snapshot and the timeline JSON contains `audioEffects.gate`, but no AVFoundation `AudioUnit` is ever built from it. The same problem hits `apply_compressor`, `apply_de_esser`, `apply_eq`, `apply_limiter`, `normalize_audio_to_lufs`.

**Fix spec (one paragraph):** Either (a) extend `CompositionBuilder` to walk `timelineTrack.clips`, collect each clip's `audioEffects`, and produce per-clip `AVMutableAudioMixInputParameters` with an `AudioEffectTap.createTap(for:)` whose `AudioEffectChain` merges per-clip and per-track configs (per-clip wins on conflict), OR (b) deprecate per-clip audio FX and have these tools resolve to `setTrackAudioEffects` on the clip's track instead — losing per-clip granularity but matching what the engine actually does today. Option (a) is the honest fix. Either way, add a regression test in `EditorCoreTests` that asserts `CompositionBuilder.build(...)` returns an `AVAudioMix` whose `inputParameters` contains a tap when only `clip.audioEffects.gate` is set.

### Example B — `split_clip` ⇒ WORKING

**Trace:**

1. **Definition.** Registry-only. `AIToolRegistry.swift:348-356` — *"Split a clip at the specified time"*. Schema: `clip_id`, `time` (both required).
2. **Dispatch.** Resolver fallthrough → `AIToolResolver` → `.splitClip(clipID:at:)`.
3. **Handler.** `EditorIntent.swift:84-85` → `SplitClipCommand` at [`ClipCommands.swift:203-205`](../../VideoEditor/Packages/EditorCore/Sources/EditorCore/Commands/ClipCommands.swift). Mutates `track.clips`, splits linked audio, supports undo.
4. **Downstream consumer.** Standard timeline mutation; `CompositionBuilder` reads `track.clips` directly. Used by `AutoCutEngine.swift:349-356`. Verified by existing tests in `EditorCoreTests`.

**Verdict:** **WORKING**.

### Example C — `apply_lut` (in `handleAnalysisTool`) ⇒ DEAD

**Trace:**

1. **Definition.** Registry-only. `AIToolRegistry.swift:654`. Real semantics: apply a `.cube` 3D LUT to the clip's color.
2. **Dispatch.** `apply_lut` is **not** in the `analysisTools` set at [`MCPServer.swift:942-946`](../../VideoEditor/VideoEditor/App/MCPServer.swift), so it never enters `handleAnalysisTool`. It falls through to the resolver, which produces an `EffectInstance.lut(...)` mutation on the clip.
3. **Handler.** Real handler is the resolver path → `AddClipEffectCommand` (via `setClipEffect`) writing `EffectInstance.typeLUT`. `Clip.swift:334` and `:365` define the type; [`EffectCompositor.swift:758`](../../VideoEditor/Packages/EditorCore/Sources/EditorCore/Playback/EffectCompositor.swift) consumes it via `LUTLoader.cachedFilter(at:)`.
4. **Downstream consumer.** Working — `EffectCompositor` applies the CIFilter at render time.

**Verdict for the `handleAnalysisTool` branch:** **DEAD** — the canned-string case in `handleAnalysisTool` for `"apply_lut"` (and the same for `"chroma_key"` and `"denoise_video"`) is unreachable. It is misleading code that survived a refactor.

**Verdict for the `apply_lut` tool overall:** **WORKING** (via the resolver path).

**Fix spec for the dead branches:** Delete the `case "apply_lut":`, `case "chroma_key":`, `case "denoise_video":` arms inside `handleAnalysisTool` ([`MCPServer.swift:2331-2372`](../../VideoEditor/VideoEditor/App/MCPServer.swift)). They are noise.

---

## Tool inventory and verdicts

The full per-tool table is filled by Phase 2. The categorization below mirrors `_tool-inventory.json`. Each subsection is owned by one Phase-2 audit subagent. **Subagent output format per tool:**

```
| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| split_clip | reg | resolver | WORKING | ClipCommands.swift:203 | — |
| apply_gate | reg | resolver | STUB | CompositionBuilder.swift:354 ignores clip.audioEffects | see §Audio FX |
```

Where:
- **def** = `reg` (registry only) / `mcp` (MCP-only) / `both` (both — duplicate)
- **dispatch** = `direct` / `analysis` / `resolver`
- **verdict** = one of the 7 from the legend
- **evidence** = the most damning file:line citation
- **fix spec** = either `—` (working) or a backref to a paragraph below the table

### §1. Timeline structure

> Tools: `add_track`, `insert_clip`, `move_clip`, `delete_clips`, `split_clip`, `trim_clip`, `duplicate_clip`, `remove_section`, `ripple_delete`, `roll_trim`, `slip_clip`, `ripple_trim`, `link_clips`, `batch`, `add_to_timeline`, `clear_project`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `add_track` | reg | resolver | WORKING | — | — |
| `insert_clip` | reg | resolver | WORKING | — | — |
| `move_clip` | reg | resolver | WORKING | — | — |
| `delete_clips` | reg | resolver | WORKING | — | — |
| `split_clip` | reg | resolver | WORKING | — | — |
| `trim_clip` | reg | resolver | WORKING | — | — |
| `duplicate_clip` | reg | resolver | WORKING | — | — |
| `remove_section` | reg | direct | PARTIAL | `AIToolRegistry.swift:1694-1695` resolver throws `unknownTool`; real path is direct `MCPServer.swift:1051-1055` | §1.1 |
| `ripple_delete` | reg | direct | PARTIAL | `AIToolRegistry.swift:1694-1695`; real path `MCPServer.swift:4702-4727` | §1.2 |
| `roll_trim` | reg | resolver | WORKING | — | — |
| `slip_clip` | reg | resolver | WORKING | — | — |
| `ripple_trim` | reg | resolver | WORKING | — | — |
| `link_clips` | reg | resolver | WORKING | — | — |
| `batch` | reg | resolver | PARTIAL | Nested `resolve` `AIToolRegistry.swift:1568-1571` fails for any name without a resolver case (`remove_section`, `ripple_delete`, MCP-only direct tools) | §1.3 |
| `add_to_timeline` | mcp | direct | WORKING | — | — |
| `clear_project` | mcp | direct | WORKING | — | — |

#### §1.1 Fix spec — `remove_section`

`remove_section` is in `AIToolRegistry.allTools` and executes correctly via the MCP direct branch (`MCPServer.swift:1051-1055` → `handleRemoveSection`), but `AIToolResolver.resolve` has no `case "remove_section"`, so any path that goes through the resolver — most notably nested `batch` calls — falls into `default: throw AIToolError.unknownTool` at `AIToolRegistry.swift:1694-1695`. Smallest fix: add a resolver case that emits the same `EditorIntent` sequence the direct handler builds (split → `deleteClips` → `rippleCloseGaps` / overlay shifts), or extract one shared helper used by both MCP and resolver so the two implementations cannot drift.

#### §1.2 Fix spec — `ripple_delete`

Same root cause as §1.1: registry lists the tool and MCP handles it correctly (`MCPServer.swift:4702-4727`), but `AIToolResolver` falls through to `unknownTool`. Implement `case "ripple_delete":` in `AIToolResolver` mirroring `handleRippleDelete`, or stop advertising the tool as resolver-backed.

#### §1.3 Fix spec — `batch`

`batch` resolves its nested operations recursively by calling `resolve(toolName:arguments:assets:)` (`AIToolRegistry.swift:1568`). Any nested name without a resolver case throws `unknownTool` and the whole batch fails mid-chain. This includes MCP-only direct tools (`add_to_timeline`, `clear_project`, `import_media`, etc.) and registry tools that use the direct lane (`remove_section`, `ripple_delete`, `remove_silence`, `normalize_audio`). Smallest fix: in the `batch` resolver, when nested resolution returns `[]` or throws `unknownTool`, fall back to looking up the name in the MCP direct dispatch table — or add resolver cases for every advertised tool so every name round-trips through `resolve`. Until fixed, document in the `batch` description that only resolver-supported names are allowed.

### §2. Tracks

> Tools: `remove_track`, `lock_track`, `mute_track`, `solo_track`, `rename_track`, `reorder_track`, `set_track_volume`, `set_track_audio_effects`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `remove_track` | reg | resolver | PARTIAL | `AIToolRegistry.swift:449-451` says non-empty tracks fail; `TrackCommands.swift:83-87` removes the track with no `clips.isEmpty` check | §2.1 |
| `lock_track` | reg | resolver | WORKING | `CommandGuards.swift:14-16` enforces `isLocked` for track-scoped edits | — |
| `mute_track` | reg | resolver | WORKING | `CompositionBuilder.swift:175-176` skips muted tracks in the build loop | — |
| `solo_track` | reg | resolver | WORKING | `CompositionBuilder.swift:133-136` and `:175-176` apply solo (non-soloed tracks dropped when any track is soloed) | — |
| `rename_track` | reg | resolver | WORKING | `RenameTrackCommand` updates `track.name` (`PropertyCommands.swift:285-288`); UI reads it (e.g. `TrackHeaderRowView.swift:196-198`) | — |
| `reorder_track` | reg | resolver | PARTIAL | `AIToolRegistry.swift:1536-1538` requires `new_index` as `Int` only; JSON numeric args typically arrive as `Double`, so resolution often fails | §2.2 |
| `set_track_volume` | reg | resolver | WORKING | `CompositionBuilder.swift:295-296` / `:326` multiply `clip.volume * track.volume` into mix parameters | — |
| `set_track_audio_effects` | mcp | direct | WORKING | Handler calls `.setTrackAudioEffects` (`MCPServer.swift:1879`); `CompositionBuilder.swift:354-366` attaches taps from `timelineTrack.audioEffectChain` | — |

#### §2.1 Fix spec — `remove_track`

The tool description promises that removal fails when the track still has clips, but `RemoveTrackCommand` only consults `editableTrackIndex` (unlock check) and then removes the whole row (`TrackCommands.swift:83-87`), so MCP calls can delete tracks that still contain clips — contradicting `AIToolRegistry.swift:449-451` and the inspector behavior that only enables remove when empty (`InspectorPanel.swift:385-388`, `TrackHeaderRowView.swift:200-204`). Smallest credible fix: guard in `RemoveTrackCommand.execute` (or before emitting the intent) with `guard tracks[index].clips.isEmpty else { throw … }` so behavior matches the documented contract.

#### §2.2 Fix spec — `reorder_track`

Resolution fails whenever `new_index` is not typed exactly as `Int` in the arguments dictionary (`AIToolRegistry.swift:1536-1538`), which is fragile for JSON-derived tool args. Accept both `Int` and `Double` (and optionally `String`), normalize to `Int`, then clamp to `[0, trackCount]` before building `.reorderTrack`, mirroring how other tools coerce numeric parameters.

### §3. Clip properties

> Tools: `set_clip_volume`, `set_clip_opacity`, `set_clip_speed`, `set_clip_effect`, `set_clip_transition`, `set_clip_transform`, `set_clip_keyframes`, `set_clip_crop`, `set_clip_blend_mode`, `remove_clip_effect`, `set_clip_overlay_presentation`, `apply_pip_preset`, `rename_clip`, `normalize_audio`, `remove_silence`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `set_clip_volume` | reg | resolver | WORKING | `CompositionBuilder.swift:295-298` | — |
| `set_clip_opacity` | reg | resolver | WORKING | `EffectCompositor.swift:176-188` | — |
| `set_clip_speed` | reg | resolver | WORKING | `CompositionBuilder.swift:85-92, 290-292` | — |
| `set_clip_effect` | reg | resolver | WORKING | `EffectCompositor.swift:752-794` | — |
| `set_clip_transition` | reg | resolver | WORKING | `CompositionBuilder.swift:558-568` + `EffectCompositor.swift:620-650` | — |
| `set_clip_transform` | reg | resolver | WORKING | `EffectCompositor.swift:522-538` | — |
| `set_clip_keyframes` | reg | resolver | WORKING | `EffectCompositor.swift:540-585` | — |
| `set_clip_crop` | reg | resolver | WORKING | `CompositionBuilder.swift:580` + `EffectCompositor.swift:678-679` | — |
| `set_clip_blend_mode` | reg | resolver | WORKING | `EffectCompositor.swift:316-324` | — |
| `remove_clip_effect` | reg | resolver | WORKING | `CompositionBuilder.swift:577-582` | — |
| `set_clip_overlay_presentation` | reg | resolver | WORKING | `EffectCompositor.swift:703` | — |
| `apply_pip_preset` | reg | resolver | WORKING | `EffectCompositor.swift:703` (presentation read after `ApplyClipPiPPresetCommand`) | — |
| `rename_clip` | reg | resolver | WORKING | `PropertyCommands.swift:324-340` | — |
| `normalize_audio` | reg | direct | WORKING | `MCPServer.swift:4750-4754` + `CompositionBuilder.swift:295-298` | — |
| `remove_silence` | reg | direct | PARTIAL | `AIToolRegistry.swift:1214-1216` resolver returns `[]`; real path is direct `MCPServer.swift:1048-1049` → `SilenceRemovalExecutor` | §3.1 |

#### §3.1 Fix spec — `remove_silence`

`remove_silence` works correctly on the primary MCP/in-app path (`MCPServer.swift:1048-1049` → `handleRemoveSilence` → `SilenceRemovalExecutor.remove` in `EditorStabilizationSupport.swift:362-465`, which issues real `deleteClips` / `insertClip` work). The resolver nevertheless defines `case "remove_silence": return []` (`AIToolRegistry.swift:1214-1216`). Any execution path that resolves through `AIToolResolver` — notably `batch`, which merges sub-tool resolutions (`AIToolRegistry.swift:1552-1570`) — silently drops `remove_silence` operations instead of running the executor. Align behaviors by either removing that resolver arm and teaching `batch` to refuse `remove_silence` with a clear error, or resolving `remove_silence` into a dedicated `EditorIntent` implemented by a command that calls the same `SilenceRemovalExecutor` logic so batch and standalone share one implementation. (Same shape as `remove_section` / `ripple_delete` — see §1.1, §1.2, §1.3.)

### §4. Audio FX & analysis

> Tools: `apply_gate`, `apply_compressor`, `apply_de_esser`, `apply_eq`, `apply_limiter`, `normalize_audio_to_lufs`, `analyze_audio_spectrum`, `apply_spectral_noise_reduction`, `voice_cleanup`, `denoise_audio`, `auto_duck`, `measure_loudness`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `apply_gate` | reg | resolver | STUB | `CompositionBuilder.swift:354-366` reads only `track.audioEffectChain`; zero matches for `clip.audioEffects` in playback | §4.1 |
| `apply_compressor` | reg | resolver | STUB | Same — `CompositionBuilder.swift:354-366` | §4.1 |
| `apply_de_esser` | reg | resolver | STUB | Same — `CompositionBuilder.swift:354-366` | §4.1 |
| `apply_eq` | reg | resolver | STUB | Same — `CompositionBuilder.swift:354-366` | §4.1 |
| `apply_limiter` | reg | resolver | STUB | Same — `CompositionBuilder.swift:354-366` | §4.1 |
| `normalize_audio_to_lufs` | reg | resolver | STUB | `AudioEffectCommands.swift:192-195` writes `clip.audioEffects?.normalizeLUFS`; engine still only reads `track.audioEffectChain` | §4.1 |
| `analyze_audio_spectrum` | both | analysis | STUB | `MCPServer.swift:2432-2436` returns a fixed success string; no FFT path | §4.2 |
| `apply_spectral_noise_reduction` | both | analysis | STUB | `MCPServer.swift:2438-2441` success string only; no clip mutation | §4.2 |
| `voice_cleanup` | reg | analysis | STUB | `MCPServer.swift:2371-2379` calls `VoiceCleanup.describe(preset:)` and returns text; no `perform` / no DSP | §4.2 |
| `denoise_audio` | reg | analysis | STUB | `MCPServer.swift:2412-2413` returns a canned line; no processing applied | §4.2 |
| `auto_duck` | reg | analysis | STUB | `MCPServer.swift:2424-2430` string only; `AudioDucker` never referenced from `CompositionBuilder.swift` | §4.2 |
| `measure_loudness` | reg | analysis | WORKING | `MCPServer.swift:2362-2368` invokes `LoudnessMeter().measureLUFS(url:)`; reads samples in `LoudnessMeter.swift:12-60` | — |

#### §4.1 Fix spec — `apply_gate` (and similar per-clip audio FX)

`AudioEffectCommands` persist EQ / compressor / gate / limiter / de-esser / LUFS targets on `clip.audioEffects`, but `CompositionBuilder` only attaches `AudioEffectTap` when `Track.audioEffectChain` is set (`CompositionBuilder.swift:343-366`). `AudioEffectTap.createTap(for:)` (`AudioEffectTap.swift:6-14`) is therefore never driven from per-clip state. Fix by either wiring per-clip chains into the composition (build taps per clip segment, or merge into mix parameters with clip precedence over track), OR redirecting these tools to track-level `set_track_audio_effects` so the existing tap path is used (loses per-clip granularity but matches what the engine actually does today). Add an `EditorCoreTests` assertion that a composition built with only `clip.audioEffects.gate` set produces a non-nil `audioMix` with a tap on the matching composition track — that test would catch any regression.

#### §4.2 Fix spec — canned analysis / "helpers" (`analyze_audio_spectrum`, `apply_spectral_noise_reduction`, `voice_cleanup`, `denoise_audio`, `auto_duck`)

These names are gated into `handleAnalysisTool` via `analysisTools` (`MCPServer.swift:1024-1031`) and return synthetic strings (`MCPServer.swift:2371-2441`) instead of invoking analysis engines or mutating the timeline. Replace stubs with real implementations: spectrum / noise tools should run FFT (or reuse an existing analyzer) over the clip's asset URL and write clip/track state that export consumes; `voice_cleanup` should map presets to `EditorIntent`s that apply real audio settings (or document-only returns must stop claiming one-click enhancement); `auto_duck` should call the existing `AudioDucker` and persist the resulting volume keyframes on the music/secondary track. `analyze_audio_spectrum` and `apply_spectral_noise_reduction` are also duplicated across registry and MCP-only blocks (`MCPServer.swift:181-185, 628-644`); since `deduplicatedTools` keeps the **last** definition (`MCPServer.swift:1174-1187`), the MCP-only schema/description wins — merge or delete duplicates to avoid silent schema drift.

### §5. Visual FX

> Tools: `apply_lut`, `chroma_key`, `denoise_video`, `stabilize_video`, `auto_reframe`, `apply_person_mask`, `track_object`, `add_zoom_effect`, `add_text_overlay`, `apply_speed_ramp`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `apply_lut` | reg | resolver | WORKING | `EffectCompositor.swift:758-764` applies LUT. The branch in `MCPServer.swift:2452-2453` is **DEAD** — name not in `analysisTools` (`MCPServer.swift:1024-1031`) | §5.5 |
| `chroma_key` | reg | resolver | WORKING | `EffectCompositor.swift:777-782` (`ChromaKey.apply`). `MCPServer.swift:2454-2455` is **DEAD** | §5.5 |
| `denoise_video` | reg | resolver | WORKING | `EffectCompositor.swift:771-776` + `VideoDenoiser.swift:9-18` (`CINoiseReduction`). `MCPServer.swift:2414-2415` is **DEAD** | §5.5 |
| `stabilize_video` | reg | analysis | STUB | `MCPServer.swift:2416-2422` runs `VideoStabilizer.analyze` and returns a string only — no `EffectInstance`, no keyframes, no `perform` | §5.4 |
| `auto_reframe` | reg | analysis | WORKING | `MCPServer.swift:2286-2321` calls `AutoReframer`, then applies `setClipCrop`; crop is consumed at preview/export `CompositionBuilder.swift:580, 600, 729, 748` + `EffectCompositor.swift:166, 356-357` | — |
| `apply_person_mask` | reg | analysis | STUB | `MCPServer.swift:2400-2401` canned success; no Vision / `PersonMasker` invocation, no clip mutation | §5.4 |
| `track_object` | reg | analysis | WORKING | `MCPServer.swift:2406-2410` invokes `ObjectTracker`, returns position counts (matches `AIToolRegistry.swift:599-607`); no timeline write by design | — |
| `add_zoom_effect` | reg | resolver | PARTIAL | `AddZoomEffectCommand` writes `keyframes.tracks["scale"]` (`PropertyCommands.swift:933-943`); `EffectCompositor.resolvedTransform` reads `scaleX` / `scaleY` only (`EffectCompositor.swift:558-562`) — `scale` track is never read. `positionX` / `positionY` keyframes ARE interpolated (`EffectCompositor.swift:552-556`) | §5.2 |
| `add_text_overlay` | reg | resolver | STUB | `AddTextOverlayCommand` appends to `clip.textOverlays` (`PropertyCommands.swift:807`); no consumer in `CompositionBuilder.swift` / `EffectCompositor.swift` (grep returns zero hits outside Models / Commands / Tests) | §5.1 |
| `apply_speed_ramp` | reg | resolver | STUB | `ApplySpeedRampCommand` sets `clip.keyframes.tracks["speed"]` (`PropertyCommands.swift:880-885`); `CompositionBuilder` uses scalar `clip.speed` only (`CompositionBuilder.swift:199-205, 247-251`) — `keyframes.tracks["speed"]` is never sampled | §5.3 |

#### §5.1 Fix spec — `add_text_overlay`

Render `clip.textOverlays` in the same path as other per-clip visuals: extend composition building so each `VideoClipEntry` / `EffectInstruction` carries text-overlay instructions, draw them in `EffectCompositor` (or a dedicated overlay pass) for both preview AND export, and add an `EditorCore` test that fails if overlays are absent from the composed frame path. Until done, no on-screen text rendered by this tool will appear.

#### §5.2 Fix spec — `add_zoom_effect`

Either write zoom keyframes to `scaleX` AND `scaleY` (matching what `EffectCompositor.swift:558-562` reads), or teach `resolvedTransform` to treat a legacy `scale` track as uniform scale applied to both axes. Today the zoom magnitude is silently dropped while the pan keyframes (positionX/Y) may still move the layer — so the agent gets a partial pan with no zoom.

#### §5.3 Fix spec — `apply_speed_ramp`

Teach `CompositionBuilder` (and the export path) to sample the `speed` keyframe track over source time and emit corresponding `scaleTimeRange` segments — or split the clip into multiple composition slices each with their own scalar speed. Until then, only `set_clip_speed`'s scalar `clip.speed` affects AVComposition (`CompositionBuilder.swift:199-251`); the agent calling `apply_speed_ramp` will see "success" but playback runs at the original speed.

#### §5.4 Fix spec — `apply_person_mask` / `stabilize_video`

For `apply_person_mask`, call into `PersonMasker` / chroma-style masks and persist an `EffectInstance` the compositor applies, or narrow the description to match behavior. For `stabilize_video`, persist stabilization (per-frame transform metadata or a preprocessing pass) and apply it in `EffectCompositor` / export — not only `VideoStabilizer.analyze` feedback text (`MCPServer.swift:2416-2422`).

#### §5.5 Fix spec — DEAD `handleAnalysisTool` branches

Remove the unreachable string-return cases for `apply_lut`, `chroma_key`, and `denoise_video` from `handleAnalysisTool` (`MCPServer.swift:2414-2415, 2452-2455`). They are not in `analysisTools` (`MCPServer.swift:1024-1031`) and the real behavior is the resolver path → `replacePrimaryClipEffect` (`AIToolRegistry.swift:1316-1354`) → `EffectCompositor`. The dead arms only confuse maintenance.

### §6. Captions & overlays

> Tools: `set_caption_style`, `set_caption_timing`, `set_overlay_config`, `get_overlay_config`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `set_caption_style` | reg | analysis | WORKING | `MCPServer.swift:2381-2398` sets `timelineState.captionStyle` + rebuild; `EffectCompositor.swift:218-299` gates on style; export passes style to `exportEngine.export` (`MCPServer.swift:4789-4797`) | — |
| `set_caption_timing` | both | analysis | STUB | `MCPServer.swift:2443-2450` returns canned success strings; no mutation; resolver returns `[]` (`AIToolRegistry.swift:1687-1688`) | §6.1 |
| `set_overlay_config` | both | direct | DUPLICATE / WORKING | Definitions: `AIToolRegistry.swift:159-171` + `MCPServer.swift:370-386`; MCP wins after dedupe (`MCPServer.swift:655, 1174-1187`). HTTP MCP handler `MCPServer.swift:3284-3409` performs `.setBroadcastOverlay` + rebuilds. **In-app chat is reduced** — `AIChatController.swift:308-315` uses the resolver (`AIToolRegistry.swift:1434-1449`) which does not merge `template`, `topics`, `chapters`, `sponsors` | §6.2 |
| `get_overlay_config` | both | direct | DUPLICATE / WORKING | Definitions: `AIToolRegistry.swift:173-177` + `MCPServer.swift:389-391` (MCP wins); read path `MCPServer.swift:3412-3432` | §6.3 |

#### §6.1 Fix spec — `set_caption_timing`

Implement real behavior: persist per-clip or project-level caption-timing intent (sync-to-transcript vs manual word timings) on the model; wire `CompositionBuilder` / `EffectInstruction` so word timings feed `captionWords` / `SubtitleRenderer` for 16:9 (`EffectCompositor.swift:206-208` flags this gap); have the handler call `appState.perform` or the same renderer code path — replacing the canned returns at `MCPServer.swift:2443-2450`. Until then, remove or clearly mark the tool as a no-op in the advertised schema so the agent is not told timing was "synced" when it wasn't.

#### §6.2 Fix spec — `set_overlay_config`

Keep a single schema source of truth: either stop appending the duplicate name in `tools/list` or align registry and MCP definitions. For behavior parity, route the in-app agent through the same `handleSetOverlayConfig` path as MCP (or call `executeToolForAgent` for this tool) so `AIChatController.swift:308-315` is not a reduced resolver-only path that omits `template`, `topics`, `chapters`, and `sponsors` from `AIToolRegistry.swift:1434-1449`. Today the same tool name does different things depending on caller.

#### §6.3 Fix spec — `get_overlay_config`

Read-path duplicate is documentation-only. If both schemas are identical, delete the registry duplicate. If they diverge, document that the MCP block is authoritative and update the registry to match — otherwise other clients reading the static registry are misled.

### §7. Transcript & content analysis

> Tools: `get_transcript`, `get_full_transcript`, `get_transcript_with_timing`, `transcribe_asset`, `search_transcript`, `analyze_transcript`, `find_viral_moments`, `auto_cut`, `classify_audio`, `score_content`, `segment_topics`, `detect_episodes`, `hook_optimize`, `analyze_audio_energy`, `delete_transcript_range`, `remove_filler_words`, `get_visual_scenes`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `get_transcript` | reg | direct | WORKING | `MCPServer.swift:2062-2077` returns real transcript text | — |
| `get_full_transcript` | both | direct | DUPLICATE (MCP wins) | Registry `AIToolRegistry.swift:240-248`; MCP overwrites at merge `MCPServer.swift:393-400`; handler chunks at sentences/pauses (`MCPServer.swift:3476-3505`), not "every 30 seconds" as MCP description claims | §7.1 |
| `get_transcript_with_timing` | mcp | direct | WORKING | `MCPServer.swift:5472-5532` — word/speaker output, `format` json/text | — |
| `transcribe_asset` | reg | direct | WORKING | `MCPServer.swift:2145-2240` — `transcriptionService.transcribe` / async path | — |
| `search_transcript` | reg | direct | WORKING | `MCPServer.swift:2244-2279` — `TranscriptSearchEngine` | — |
| `analyze_transcript` | both | direct | DUPLICATE (MCP wins) | Claude `MCPServer.swift:4057-4110`; description `MCPServer.swift:403-407`; registry `AIToolRegistry.swift:203-209` | — |
| `find_viral_moments` | both | direct | DUPLICATE (MCP wins) | Claude `MCPServer.swift:3743-4010`; default `max_duration_seconds` is **180** in handler (`MCPServer.swift:3707`) but registry advertises **60** (`AIToolRegistry.swift:217`) | §7.2 |
| `auto_cut` | both | direct | DUPLICATE (MCP wins) | Plan: `AutoCutEngine` + silence/transcript/energy `MCPServer.swift:4387-4435`; execute clips `MCPServer.swift:4465-4594`; Pass-2 Claude `reviewAndFix` `MCPServer.swift:4599-5075` | — |
| `classify_audio` | both | direct | DUPLICATE (MCP wins) | `AudioSourceClassifier` `MCPServer.swift:4306-4314` | — |
| `score_content` | both | direct | DUPLICATE (MCP wins) | `ContentScorer.rankSegments` `MCPServer.swift:5120-5125` | — |
| `segment_topics` | both | direct | DUPLICATE (MCP wins) | `TopicSegmenter` `MCPServer.swift:5182-5189` | — |
| `detect_episodes` (registry) | reg | none | MISSING-FROM-LIST | Static `AIToolRegistry.swift:271-277` is NOT in `allTools` (`AIToolRegistry.swift:8-110`); never advertised via registry path | §7.3 |
| `detect_episodes` (MCP) | mcp | direct | WORKING | Handler `MCPServer.swift:4233-4290` invokes `EpisodeBoundaryDetector().detect(...)` — uses intro phrases + energy (`EpisodeBoundaryDetector.swift:19-64, 110-120`); CLAUDE.md "regex" understates this | — |
| `hook_optimize` | mcp | direct | PARTIAL | Real Claude scoring + timeline inserts `MCPServer.swift:5293-5440`; MCP schema is empty (`MCPServer.swift:479-481, 514-516`); description claims "flash transition" but handler does no transition wiring; clip is hardcoded to first video clip (`MCPServer.swift:5230-5232`) | §7.4 |
| `analyze_audio_energy` | both | direct | DUPLICATE (MCP wins) | `SpeechEnergyAnalyzer` `MCPServer.swift:1901-1944`; registry vs MCP schemas align (`asset_id`, `start`, `end`, `segments`) | — |
| `delete_transcript_range` | mcp | direct | WORKING | `rebuildTimelineExcludingSourceRange` `MCPServer.swift:5535-5567, 5749-5830` | — |
| `remove_filler_words` | mcp | direct | WORKING | Filler scan + clip rebuild `MCPServer.swift:5571-5744` | — |
| `get_visual_scenes` | reg | direct | WORKING | On-demand `VisualSceneAnalyzer` `MCPServer.swift:2088-2108` | — |

#### §7.1 Fix spec — `get_full_transcript` description ↔ behavior drift

After `deduplicatedTools()` the MCP inline entry overwrites the registry row for the same name (`MCPServer.swift:1174-1186`), so the model sees the MCP `description` and `inputSchema`. Update the MCP block so the description matches the handler: timestamps are inserted at **sentence boundaries / long pauses** (`MCPServer.swift:3490-3492`), not "every 30 seconds" (`MCPServer.swift:393-395`). Also align the registry text (`AIToolRegistry.swift:242-243`) for consistency.

#### §7.2 Fix spec — `find_viral_moments` default mismatch

Three places disagree on `max_duration_seconds`: registry default 60 (`AIToolRegistry.swift:217`), MCP default 180 (`MCPServer.swift:416`), handler default 180 (`MCPServer.swift:3707`). Pick one default (and decide whether it's a hard cap or a soft target), update the losing definitions so agents are not told 60s while the server runs 180s.

#### §7.3 Fix spec — `detect_episodes` (registry orphan)

Either append `detectEpisodes` to `AIToolRegistry.allTools` (`AIToolRegistry.swift:8-110`) so the registry and MCP catalog agree, or delete the unused static (`AIToolRegistry.swift:271-277`) to avoid drift. The live MCP tool is the MCP-only definition (`MCPServer.swift:437-441`); decide which surface owns the canonical schema.

#### §7.4 Fix spec — `hook_optimize`

Replace the empty `inputSchema` (`MCPServer.swift:514-516`) with parameters matching what the handler should support — at minimum `clip_id` or `asset_id` so the agent can target a specific clip instead of the hardcoded "first video clip" (`MCPServer.swift:5230-5232`). Update the description to match behavior (duplicate hook segment at t=0 + optional short-form caption shift at `MCPServer.swift:5412-5436`) and either implement "flash transition" or drop it from the description.

### §8. Assets & projects

> Tools: `import_media`, `delete_asset`, `fix_av_links`, `create_project`, `open_project`, `save_project`, `list_projects`, `close_project`, `delete_project`, `rename_project`, `save_snapshot`, `list_snapshots`, `restore_snapshot`, `set_export_folder`, `get_export_folder`, `add_media_folder`, `list_media_folders`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `import_media` | mcp | direct | WORKING | `MCPServer.swift:1191-1229` blocks until readable or returns clear error at `:1220-1221`; `AppState.swift:1822-1825` copies into bundle unless bookmarked | — |
| `delete_asset` | both | direct | DUPLICATE / PARTIAL | Registry `AIToolRegistry.swift:151-157`; MCP duplicate `MCPServer.swift:305-310` (MCP wins after dedupe `MCPServer.swift:1174-1186`). Handler `MCPServer.swift:1309-1313` returns BEFORE `MediaManager.remove` / `refreshAssets` finish; `MediaManager.swift:61-64` drops in-memory only (no bundle file delete) | §8.1 |
| `fix_av_links` | mcp | direct | WORKING | `MCPServer.swift:1947-1979` — matches same `assetID`/range, sets `linkGroupID`, `rebuildComposition()` + `flushPendingState()` | — |
| `create_project` | mcp | direct | PARTIAL | `AppState.swift:1624-1645` + `switchToBundle` `:1805-1810` — `Task` loads project AFTER handler returns success | §8.2 |
| `open_project` | mcp | direct | PARTIAL | Same race — `AppState.swift:1666-1669, 1805-1810` | §8.2 |
| `save_project` | mcp | direct | WORKING | `AppState.swift:1673-1676` `persistProjectState` | — |
| `list_projects` | mcp | direct | WORKING | `MCPServer.swift:1274-1289` + `AppState.listProjects()` `AppState.swift:1753-1778` | — |
| `close_project` | mcp | direct | PARTIAL | `AppState.swift:1689-1694` + async `switchToBundle` `:1805-1810` | §8.2 |
| `delete_project` | mcp | direct | WORKING | `AppState.swift:1698-1712` removes bundle + index | — |
| `rename_project` | mcp | direct | PARTIAL | `AppState.swift:1747` calls `loadProject()` whose body schedules `Task` `:1543-1609` after sync return | §8.2 |
| `save_snapshot` | mcp | direct | WORKING | `VersionControl.swift:28-40` persists under bundle `versions/`; MCP `MCPServer.swift:985-994` | — |
| `list_snapshots` | mcp | direct | WORKING | `MCPServer.swift:996-1001`, `VersionControl.swift:44-46` | — |
| `restore_snapshot` | mcp | direct | PARTIAL | `MCPServer.swift:1010-1012` sets `context.timelineState.timeline` only — no `rebuildComposition()` / `scheduleSave()` (contrast `fix_av_links` `:1977-1978` and command paths `AppState.swift:1170-1172`) | §8.3 |
| `set_export_folder` | mcp | direct | WORKING | `MCPServer.swift:4886-4890`, `ExportFolderManager.swift:21-30, 127-132` UserDefaults bookmark | — |
| `get_export_folder` | mcp | direct | WORKING | `MCPServer.swift:4893-4897`, `ExportFolderManager.swift:15-17` | — |
| `add_media_folder` | mcp | direct | WORKING | `MCPServer.swift:1075-1079`, `ExportFolderManager.swift:146-156` persists `[Data]` | — |
| `list_media_folders` | mcp | direct | WORKING | `MCPServer.swift:1081-1086`, `ExportFolderManager.swift:69-78` | — |

#### §8.1 Fix spec — `delete_asset`

Keep a single schema for HTTP `tools/list` by either dropping the duplicate MCP dictionary entry (`MCPServer.swift:305-310`) so the registry definition wins, or merging descriptions intentionally. In the handler (`MCPServer.swift:1292-1314`), `await media.mediaManager.remove` and `refreshAssets()` BEFORE building the `stateSnapshot` so the returned text matches `appState.assets`. Extend removal so copied bundle files under `media/` are deleted when safe (today `MediaManager.remove` only trims the in-memory array `MediaManager.swift:61-64` — disk leaks). Optionally route through an `EditorIntent` so undo stays consistent.

#### §8.2 Fix spec — project lifecycle async race (`create_project`, `open_project`, `close_project`, `rename_project`)

`switchToBundle` (`AppState.swift:1785-1810`) and `loadProject()` (`AppState.swift:1539-1609`) schedule async `Task` work AFTER the MCP handler already returned success. The agent's next `get_state` call can briefly observe an empty timeline or stale assets. Fix: have these handlers `await` the bundle load (e.g. await a completion handed through `switchToBundle`, or make `loadProject` async and await it on the main actor). Apply the same pattern for `renameProject` after `loadProject()` (`AppState.swift:1747`).

#### §8.3 Fix spec — `restore_snapshot`

After `vc.restoreSnapshot` (`MCPServer.swift:1010`), mirror other timeline replacements: call `normalizeSelection()` if needed, `rebuildComposition()` (or `rebuildCompositionNow()`), and `scheduleSave()` / `flushPendingState()` so `timeline.json` matches memory and the playback engine matches the returned `stateSnapshot` (`MCPServer.swift:1982-2028`). This matches the pipeline used when loading a project (`AppState.swift:1600-1602`).

### §9. Export & distribution

> Tools: `export_video`, `export_for_platform`, `list_platforms`, `upload_short_to_library`, `generate_thumbnail`, `generate_short_thumbnail`, `generate_carousel`, `make_short`, `create_short`, `extract_clips`, `extract_segment`, `analyze_for_shorts`, `generate_title`, `search_broll`, `search_local_broll`, `auto_insert_broll`, `suggest_broll`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `export_video` | both | direct | WORKING / DUPLICATE | `handleExportVideo` calls `appState.exportEngine.export(...)` (`MCPServer.swift:4789-4798`). MCP schema wins for HTTP (presets include `4k`); registry lists `proxy` (`AIToolRegistry.swift:1027-1032`). In-app `buildToolList` only adds `mcpOnlyAgentFallbackTools()` (`MCPServer.swift:742-753`), which does NOT redefine `export_video`, so the in-app agent still sees the registry definition only — schema split | §9.1 |
| `export_for_platform` | mcp | direct | WORKING | `handleExportForPlatform` uses `exportEngine.export` with `PlatformPreset` (`MCPServer.swift:4818-4856`) | — |
| `list_platforms` | mcp | direct | WORKING | `handleListPlatforms` iterates `PlatformPreset.all` (`MCPServer.swift:4877-4883`) | — |
| `upload_short_to_library` | both | direct | WORKING / DUPLICATE | Supabase guard returns explicit message if unset (`MCPServer.swift:3577-3584`); `SupabaseUploader.upload` (`MCPServer.swift:3676-3679`). MCP schema wins on merge (`MCPServer.swift:420-434` vs `AIToolRegistry.swift:222-237`) | §9.1 |
| `generate_thumbnail` | both | direct | WORKING / DUPLICATE | Real `ThumbnailRenderer` / `FluxImageProvider`+`GeminiImageProvider` (`MCPServer.swift:5835-6116`). MCP definition wins on merge (`MCPServer.swift:586-600`). Registry description references OpenAI/Gemini only (`AIToolRegistry.swift:1037-1050`) — drift vs handler (BFL flux + Gemini + local) | §9.1 |
| `generate_short_thumbnail` | mcp | direct | WORKING | Vision scoring + `ShortFormLayoutRenderer` + file write (`MCPServer.swift:6771-6965`); also in `mcpOnlyAgentFallbackTools` (`MCPServer.swift:821-830`) | — |
| `generate_carousel` | both | direct | WORKING / DUPLICATE | `generateCarouselSlidePrompt` uses Anthropic HTTP (`MCPServer.swift:6540-6552`); images via BFL/Gemini (`MCPServer.swift:6416-6437`). MCP merge wins for HTTP (`MCPServer.swift:617-626`). Registry text says "GPT Image / Nano Banana" (`AIToolRegistry.swift:1053-1063`) — not what the handler calls | §9.1 |
| `make_short` | mcp | direct | WORKING | Orchestrates `handleExtractSegment`, `MultiFaceTracker`, optional `decideLayoutWithClaude`, sets `shortFormConfig` (`MCPServer.swift:2690-2783`) | §9.2 |
| `create_short` | mcp | direct | WORKING | Applies cached/configured `ShortFormConfig`, overlay (`MCPServer.swift:3218-3279`) | §9.2 |
| `extract_clips` | mcp | direct | WORKING | Claude transcript analysis (`MCPServer.swift:2961-3011`); returns text candidates only — does NOT edit timeline | §9.2 |
| `extract_segment` | mcp | direct | WORKING | Deletes clips, inserts linked A/V at timeline 0 (`MCPServer.swift:3033-3087`) | §9.2 |
| `analyze_for_shorts` | mcp | direct | WORKING | Face tracking, speaker mapping, caches `shortFormConfigs` (`MCPServer.swift:3095-3215`) | §9.2 |
| `generate_title` | mcp | direct | PARTIAL | Description promises transcript-driven ranked titles (`MCPServer.swift:271-275`); handler uses local `titleFocus`/`titleSuggestions` templates only (`MCPServer.swift:1358-1397, 1744-1811`) — NO Claude/OpenAI call | §9.3 |
| `search_broll` | mcp | direct | WORKING | Pexels path requires key or returns clear error (`MCPServer.swift:1459-1461`); optional download + `insertClip` when `insert_at` set (`MCPServer.swift:1548-1579`) | — |
| `search_local_broll` | mcp | direct | PARTIAL | SQLite query only (`MCPServer.swift:1591-1663`). Description claims fallback to `search_broll` (`MCPServer.swift:296-297`) but handler returns static guidance instead (`MCPServer.swift:1616-1617, 1641-1642`) | §9.4 |
| `auto_insert_broll` | mcp | direct | STUB | Name + description promise automatic insertion (`MCPServer.swift:278-283`); handler only prints suggestions and instructs manual `add_to_timeline` (`MCPServer.swift:1400-1437`) | §9.5 |
| `suggest_broll` | reg | analysis | STUB | `BRollMatcher().suggest(...)` builds real suggestions (`BRollMatcher.swift:26-79`), but handler discards details and returns only a count string (`MCPServer.swift:2355-2360`) | §9.6 |

#### §9.1 Fix spec — duplicate MCP vs registry (`export_video`, `upload_short_to_library`, `generate_thumbnail`, `generate_carousel`)

For each duplicated name, `deduplicatedTools` overwrites by last occurrence (`MCPServer.swift:1174-1186`), so HTTP MCP clients always see the MCP `inputSchema` and description. Either remove the duplicate registry entries for these four names and treat them as MCP-owned, or stop appending shadowing definitions and enrich the registry so one source defines presets (`4k` vs `proxy`), providers (local / flux / gemini vs "OpenAI"), and upload fields. Without a fix, models reading the static registry JSON (e.g. for static docs, the in-app agent fallback path) will send parameters the winning MCP schema does not describe — and vice versa.

#### §9.2 Fix spec — shorts pipeline overlap (`make_short`, `create_short`, `extract_clips`, `extract_segment`, `analyze_for_shorts`)

Five overlapping tools without clear documentation. Roles in practice: **`extract_segment`** replaces the timeline with one source range at 0. **`analyze_for_shorts`** computes face/layout data and stores in `shortFormConfigs` for `create_short`. **`create_short`** applies a cached/configured `shortFormConfig` to playback/export. **`make_short`** is the one-shot path — calls `extract_segment` internally, runs its own face pass + optional Claude layout when `layout` is auto, writes `shortFormConfig` directly (does NOT populate `shortFormConfigs` the same way as `analyze_for_shorts`). **`extract_clips`** is analysis-only (Claude returns candidate ranges as text). Document this split in tool descriptions so agents choose `make_short` for one-call vertical prep, `extract_segment` + `analyze_for_shorts` + `create_short` for separate-step or cached analysis, and `extract_clips` only for ideation without timeline cuts.

#### §9.3 Fix spec — `generate_title`

Either wire `handleGenerateTitle` to an LLM (e.g. Claude on condensed transcript) with clear failure when `ANTHROPIC_API_KEY` is missing, OR rewrite the description (`MCPServer.swift:271-275`) to state that titles are template-based heuristics from transcript keywords — not "ranked by engagement potential."

#### §9.4 Fix spec — `search_local_broll`

Either remove the "falls back to `search_broll`" claim from the description (`MCPServer.swift:296-297`), or implement an optional chained call to `handleSearchBroll` when the local DB returns no rows (`MCPServer.swift:1641-1642`).

#### §9.5 Fix spec — `auto_insert_broll`

Implement real inserts: resolve assets (from `BRollMatcher` or user library), compute timeline times, and issue `EditorIntent` / `appState.perform` the same way `search_broll` does when `insert_at` is provided (`MCPServer.swift:1554-1574`). Or rename the tool and description to "suggest_broll_placements" if insertion stays out of scope. Today the name lies.

#### §9.6 Fix spec — `suggest_broll`

Return the structured output from `BRollMatcher.suggest` (asset id, start time, duration, reason) as human-readable or JSON text instead of replacing it with `"\(suggestions.count) B-roll suggestions."` (`MCPServer.swift:2355-2360`), so the analysis lane matches the registry promise (`AIToolRegistry.swift:584-587`). Currently the agent gets a count and no actionable data.

### §10. App, playback, state

> Tools: `undo`, `redo`, `play_pause`, `seek`, `toggle_loop`, `set_zoom`, `take_screenshot`, `get_state`, `get_action_log`, `verify_playback`, `test_feature`, `activate_skill`, `set_marker`, `delete_marker`, `score_thumbnails`, `detect_beats`

| name | def | dispatch | verdict | evidence | fix spec |
|------|-----|----------|---------|----------|----------|
| `undo` | reg | direct | WORKING | `MCPServer.swift:1089-1096` `appState.undo()` | — |
| `redo` | reg | direct | WORKING | `MCPServer.swift:1099-1105` `appState.redo()` | — |
| `play_pause` | reg | direct | WORKING | `MCPServer.swift:1108-1118` `playbackEngine.togglePlayPause()` | — |
| `seek` | reg | direct | WORKING | `MCPServer.swift:1121-1136` `playbackEngine.seek(to:)` | — |
| `toggle_loop` | reg | direct | WORKING | `MCPServer.swift:1139-1141` `playbackEngine.loopEnabled` | — |
| `set_zoom` | mcp | direct | WORKING | `MCPServer.swift:845-856` `timelineViewState.zoomToFit` / `setZoom` | — |
| `take_screenshot` | mcp | direct | WORKING | `MCPServer.swift:1316-1352` writes PNG to `FileManager.default.temporaryDirectory`, returns path | — |
| `get_state` | both | direct | DUPLICATE | MCP overwrites registry on merge `MCPServer.swift:240-242` vs `AIToolRegistry.swift:187-191`. Single handler `MCPServer.swift:1982-2028` | §10.1 |
| `get_action_log` | reg | direct | WORKING | `MCPServer.swift:1144-1148` `appState.context.actionLog.recentActions` | — |
| `verify_playback` | both | direct | DUPLICATE | MCP overwrites registry on merge `MCPServer.swift:210-213` vs `AIToolRegistry.swift:298-304`. Handler `MCPServer.swift:2033-2056` `ContentVerifier` | §10.1 |
| `test_feature` | mcp | direct | WORKING | `MCPServer.swift:2463-2652` named feature tests; `default` returns "unknown feature" | — |
| `activate_skill` | reg | resolver | STUB | `AIToolRegistry.swift:1691-1692` returns `[]`; `MCPServer.swift:1162-1168` only emits `stateSnapshot` — no skill load. Real implementation lives only in `AIChatController.swift:374-388` for in-app chat | §10.2 |
| `set_marker` | reg | resolver | PARTIAL | Model + command store color (`AIToolRegistry.swift:1206-1212` → `SetMarkerCommand` `ClipCommands.swift:282-288`); UI ignores `marker.color` and uses theme only (`MarkerView.swift:19-38`) | §10.3 |
| `delete_marker` | reg | resolver | WORKING | `AIToolRegistry.swift:1428-1432` → `DeleteMarkerCommand` `EditorIntent.swift:182-188` mutates `timeline.markers` | — |
| `score_thumbnails` | reg | analysis | WORKING | `MCPServer.swift:1025-1031` + `:2338-2353` `ThumbnailScorer` | — |
| `detect_beats` | reg | analysis | WORKING | `MCPServer.swift:1025-1031` + `:2329-2335` `BeatDetector` | — |

#### §10.1 Fix spec — `get_state` and `verify_playback` duplicates

`deduplicatedTools` (`MCPServer.swift:1174-1184`) overwrites the stored entry per name, so the later MCP-only dictionary blocks (`MCPServer.swift:186-654`) override the registry's `inputSchema` and `description` for these duplicate names. Pick a single source of truth: either remove the redundant MCP duplicates so registry text wins, or delete from `AIToolRegistry.allTools` and document MCP-only — then align the surviving description with `handleGetState` / `handleVerifyPlayback` so the model is not trained on shadowed schemas.

#### §10.2 Fix spec — `activate_skill`

Expose the same behavior as `AIChatController.swift:374-388` over MCP: before the resolver fallthrough, add a direct `executeToolCall` branch that looks up `SkillRegistry`, sets active-skill state if needed, and returns skill markdown. Alternatively resolve `activate_skill` to a dedicated `EditorIntent` carrying skill payload — today `AIToolRegistry.swift:1691-1692` forces empty intents so MCP callers only get an incidental `stateSnapshot` (`MCPServer.swift:1162-1168`), which is not skill activation. The agent never knows the skill failed to activate.

#### §10.3 Fix spec — `set_marker` color

Persisted color is correct in the model (`Timeline.swift:69-84`, tests in `NewToolCommandTests.swift`). Update `MarkersOverlay` in `MarkerView.swift:19-38` to parse `marker.color` (hex or named color) for the diamond, stroke, and/or flag background instead of hardcoded `CinematicTheme.primary`. Otherwise the parameter advertised in `AIToolRegistry.swift:366-373` has no visual effect.

---

## Cross-cutting findings

### §X1. Duplicate-name audit

20 tool names appear in BOTH `AIToolRegistry.allTools` AND the MCP-only inline append at `MCPServer.swift:187-650`. After `deduplicatedTools()` (`MCPServer.swift:1174-1187`), entries are merged by name with the **last writer winning** — and the MCP-only block is appended after the registry list (`MCPServer.swift:181-655`), so **the MCP-only schema and description always win** for HTTP MCP clients. The registry definition becomes shadowed documentation that no agent ever sees through `tools/list`.

The 20 duplicated names:

| name | registry source | MCP-only source | schema drift? | wins |
|------|-----------------|-----------------|----------------|------|
| `verify_playback` | `AIToolRegistry.swift:298-304` | `MCPServer.swift:210-213` | minor | MCP |
| `export_video` | `AIToolRegistry.swift:1027-1032` | `MCPServer.swift:215-218` | **YES** — registry has `proxy` preset, MCP has `4k` (see §9.1) | MCP |
| `get_state` | `AIToolRegistry.swift:187-191` | `MCPServer.swift:240-242` | minor | MCP |
| `analyze_audio_energy` | `AIToolRegistry.swift:251-260` | `MCPServer.swift:261-269` | aligned | MCP |
| `delete_asset` | `AIToolRegistry.swift:151-157` | `MCPServer.swift:305-310` | minor | MCP |
| `set_overlay_config` | `AIToolRegistry.swift:159-171` | `MCPServer.swift:370-386` | **YES** — MCP adds `template`, `topics`, `chapters`, `sponsors` (see §6.2) | MCP |
| `get_overlay_config` | `AIToolRegistry.swift:173-177` | `MCPServer.swift:389-391` | minor | MCP |
| `get_full_transcript` | `AIToolRegistry.swift:240-248` | `MCPServer.swift:393-400` | **YES** — description drift "every 30s" vs sentence boundaries (see §7.1) | MCP |
| `analyze_transcript` | `AIToolRegistry.swift:203-209` | `MCPServer.swift:403-407` | minor | MCP |
| `find_viral_moments` | `AIToolRegistry.swift:212-220` | `MCPServer.swift:410-418` | **YES** — `max_duration_seconds` default 60 vs 180 (see §7.2) | MCP |
| `upload_short_to_library` | `AIToolRegistry.swift:222-237` | `MCPServer.swift:420-434` | aligned | MCP |
| `classify_audio` | `AIToolRegistry.swift:262-269` | `MCPServer.swift:444-451` | aligned | MCP |
| `auto_cut` | `AIToolRegistry.swift:194-201` | `MCPServer.swift:453-460` | aligned | MCP |
| `segment_topics` | `AIToolRegistry.swift:290-296` | `MCPServer.swift:462-468` | aligned | MCP |
| `score_content` | `AIToolRegistry.swift:280-288` | `MCPServer.swift:470-477` | aligned | MCP |
| `generate_thumbnail` | `AIToolRegistry.swift:1037-1050` | `MCPServer.swift:586-600` | **YES** — registry says OpenAI/Gemini, MCP+handler use BFL flux + Gemini + local (see §9.1) | MCP |
| `generate_carousel` | `AIToolRegistry.swift:1053-1063` | `MCPServer.swift:617-626` | **YES** — registry says "GPT Image / Nano Banana", handler uses Anthropic + BFL/Gemini (see §9.1) | MCP |
| `analyze_audio_spectrum` | `AIToolRegistry.swift:945-953` | `MCPServer.swift:629-636` | aligned (both stubs anyway) | MCP |
| `apply_spectral_noise_reduction` | `AIToolRegistry.swift:955-963` | `MCPServer.swift:638-644` | aligned (both stubs anyway) | MCP |
| `set_caption_timing` | `AIToolRegistry.swift:1015-1025` | `MCPServer.swift:646-651` | aligned (both stubs anyway) | MCP |

**Aggravating factor:** `mcpOnlyAgentFallbackTools()` (`MCPServer.swift:759`) is used by the IN-APP `buildToolList` path (`MCPServer.swift:742-753`) and contains a smaller subset that does NOT include `export_video`, `set_overlay_config`, etc. So the in-app agent sees the registry definition for these names, while HTTP MCP clients see the MCP-only definition. **Same tool name, two different schemas, two different code surfaces.** The most likely consequence: agent-authored tool calls that work over HTTP MCP fail when issued from in-app chat (or vice versa).

### §X2. Skill orphan check

Union of `allowed-tools:` across all 9 `.claude/skills/*/SKILL.md` files (~42 distinct names):

```
add_to_timeline, analyze_audio_energy, analyze_for_shorts, analyze_transcript,
auto_cut, auto_reframe, clear_project, create_short, delete_clips,
detect_beats, export_for_platform, export_video, extract_segment,
get_full_transcript, get_state, get_transcript, get_transcript_with_timing,
import_media, measure_loudness, move_clip, remove_section, rename_clip,
restore_snapshot, ripple_delete, save_snapshot, score_content,
search_transcript, set_caption_style, set_clip_effect, set_clip_speed,
set_clip_transform, set_clip_transition, set_clip_volume, set_marker,
set_overlay_config, set_track_volume, set_zoom, split_clip, take_screenshot,
transcribe_asset, trim_clip, verify_playback
```

**Skills exist but the tool surface is ~3× larger** (~130 vs 42). Cross-referencing skill-use × verdict yields the priority signal for Phase 4:

- **STUB × skill-used = nothing.** No skill in the repo references `apply_gate`, `apply_compressor`, `apply_de_esser`, `apply_eq`, `apply_limiter`, `normalize_audio_to_lufs`, `voice_cleanup`, `denoise_audio`, `auto_duck`, `analyze_audio_spectrum`, `apply_spectral_noise_reduction`, `set_caption_timing`, `add_text_overlay`, `apply_speed_ramp`, `apply_person_mask`, `stabilize_video`, `auto_insert_broll`, `suggest_broll`. **All 18 STUBs are skill-orphans.** Good news for impact: no skill is silently broken because of these. Bad news for trust: the model still picks them autonomously when interpreting natural-language requests like "remove the background noise" or "add a hook overlay", and the agent confidently reports success.
- **PARTIAL × skill-used = critical.** These ARE used by skills and DO have correctness gaps:
  - `remove_section` — used by `podcast-episode-producer`. Resolver gap (§1.1).
  - `ripple_delete` — used by `podcast-episode-producer`. Resolver gap (§1.2).
  - `set_overlay_config` — used by `podcast-episode-producer` + `shorts-formatter`. In-app vs MCP schema split (§6.2).
  - `set_marker` — used by `beat-sync-editor`, `meeting-highlights`, `rough-cut-assembler`. Color is silently ignored at render (§10.3).
  - `restore_snapshot` — used by `podcast-episode-producer`. Composition not rebuilt (§8.3).
  - `get_full_transcript` — used by `auto-cutter`. Description drift (§7.1).
- **DUPLICATE × skill-used.** Many — `verify_playback`, `export_video`, `get_state`, `analyze_audio_energy`, `set_overlay_config`, `analyze_transcript`, `auto_cut`, `score_content`, `get_full_transcript`. Mostly cosmetic, but the in-app vs HTTP schema split (§X1 aggravating factor) is real.
- **WORKING × skill-orphan.** Plenty — `insert_clip`, `duplicate_clip`, `link_clips`, `batch` (PARTIAL), `roll_trim`, `slip_clip`, `ripple_trim`, `lock_track`, `mute_track`, `solo_track`, `rename_track`, `reorder_track`, `set_clip_opacity`, `set_clip_keyframes`, `set_clip_crop`, `set_clip_blend_mode`, `remove_clip_effect`, `set_clip_overlay_presentation`, `apply_pip_preset`, `normalize_audio`, `remove_silence` (PARTIAL), most project lifecycle tools (`create_project`, `open_project`, `save_project`, `list_projects`, `close_project`, `delete_project`, `rename_project`, `list_snapshots`), folder tools (`set_export_folder`, `get_export_folder`, `add_media_folder`, `list_media_folders`, `list_platforms`), `fix_av_links`, `play_pause`, `seek`, `toggle_loop`, `undo`, `redo`, `get_action_log`, `delete_marker`, `score_thumbnails`, `track_object`, `apply_lut`, `chroma_key`, `denoise_video`, `set_track_audio_effects`, `set_track_volume` (used in podcast-editor only), `make_short`, `extract_clips`, `delete_transcript_range`, `remove_filler_words`, `get_visual_scenes`, `transcribe_asset` (used), `search_transcript` (used), `search_broll`, `generate_thumbnail`, `generate_short_thumbnail`, `generate_carousel`, `upload_short_to_library`, `detect_episodes` (MCP), `classify_audio`, `segment_topics`, `find_viral_moments`, `test_feature`. Most of these are reasonable — the agent can still discover them via `tools/list` — but the more orphans there are, the larger the "tools never deliberately tested by a workflow" surface.
- **DEAD × skill-used.** N/A — DEAD branches are inside `handleAnalysisTool` for `apply_lut`/`chroma_key`/`denoise_video`; the actual tools are WORKING via the resolver path.

### §X3. Description ↔ behavior drift

Surfaced during Phase 2 — collected here for Phase 4 prioritization:

| tool | drift | severity |
|------|-------|----------|
| `get_full_transcript` | description: "every 30 seconds" / handler: sentence + pause boundaries (§7.1) | low |
| `find_viral_moments` | default `max_duration_seconds`: registry 60 / MCP 180 / handler 180 (§7.2) | medium — agent will plan for 60s clips and get 180s |
| `generate_thumbnail` | registry description: "OpenAI/Gemini" / handler: BFL flux + Gemini + local (§9.1) | medium |
| `generate_carousel` | registry description: "GPT Image / Nano Banana" / handler: Anthropic + BFL/Gemini (§9.1) | medium |
| `generate_title` | description: "ranked by engagement potential" / handler: template heuristics (§9.3) | high |
| `search_local_broll` | description: "falls back to `search_broll`" / handler: returns static guidance (§9.4) | medium |
| `auto_insert_broll` | name + description: "auto-insert" / handler: prints suggestions only (§9.5) | high |
| `suggest_broll` | description: returns ranked suggestions / handler: returns count only (§9.6) | high |
| `voice_cleanup` | description: removes noise/de-esses / handler: returns text describing the preset (§4.2) | high |
| `denoise_audio` | description: removes background noise / handler: canned line (§4.2) | high |
| `auto_duck` | description: ducks music under speech / handler: canned line (§4.2) | high |
| `analyze_audio_spectrum` | description: returns frequency peaks / handler: canned text (§4.2) | high |
| `apply_spectral_noise_reduction` | description: removes specific frequencies / handler: canned text (§4.2) | high |
| `set_caption_timing` | description: enables word-level captions / handler: canned text (§6.1) | high |
| `apply_gate`/`compressor`/`de_esser`/`eq`/`limiter`/`normalize_audio_to_lufs` | description: applies the effect / handler: writes config that engine ignores (§4.1) | high |
| `add_text_overlay` | description: adds on-screen text / handler: writes data nothing renders (§5.1) | high |
| `apply_speed_ramp` | description: animated speed change / handler: writes keyframe track engine ignores (§5.3) | high |
| `add_zoom_effect` | description: zoom + pan / handler: pan keyframes work, zoom keyframes ignored (§5.2) | medium |
| `apply_person_mask` | description: applies a mask / handler: canned success (§5.4) | high |
| `stabilize_video` | description: removes shake / handler: only analyzes (§5.4) | high |
| `remove_track` | description: "fails if non-empty" / handler: removes anyway (§2.1) | medium |
| `hook_optimize` | description: "flash transition" / handler: no transition wired (§7.4) | medium |
| `auto_reframe` | description: "Returns crop regions" / handler: ALSO mutates `cropRect` when `apply: true` (default!) (`MCPServer.swift:2306-2321`) | low — undocumented side effect |

### §X4. Schema sanity

Issues found across categories:

- **`reorder_track`** — schema requires `new_index`, resolver only accepts Swift `Int`, JSON typically arrives as `Double` → resolution fails for any caller passing a JSON number (§2.2).
- **`hook_optimize`** — `inputSchema` is empty (`MCPServer.swift:514-516`) so the agent cannot pass any parameter; handler hardcodes the first video clip (§7.4).
- **`set_caption_timing`** — `word_timings` parameter accepts an array but the handler does nothing with it (§6.1).
- **`export_video`** — registry preset enum includes `proxy` which the handler does not map; MCP preset enum includes `4k` which the registry does not document (§9.1).
- **`set_marker`** — `color` parameter is plumbed through model + command, but UI never reads `marker.color` (§10.3).
- **`activate_skill`** — registered as a resolver-route tool, but the resolver returns `[]` → MCP callers never trigger skill activation (§10.2).
- **`detect_episodes`** — defined in `AIToolRegistry.swift:271-277` but missing from `allTools` array (`AIToolRegistry.swift:8-110`). Only reachable via the MCP-only definition (§7.3).
- **Duplicate-name schemas** — see §X1 table; mostly minor but four pairs (`export_video`, `set_overlay_config`, `get_full_transcript`, `find_viral_moments`) have semantically meaningful drift.

---

## Prioritized fix backlog

The audit found **0 STUB tools currently referenced by any skill** — but it found **6 PARTIAL tools that ARE skill-used and DO break workflows**. P0 has been redefined accordingly: "skill-used and broken or misleading enough to actually fail a workflow today." STUB tools that no skill uses still rank above pure cleanup because the agent will autonomously call them when interpreting natural-language requests, and those calls report success without doing the work.

Effort key: **S** = under a day, **M** = 1-3 days, **L** = a week+.

### P0 — Skill-used PARTIALs (real workflows fail today)

| # | tool | symptom | fix spec | effort |
|---|------|---------|----------|--------|
| P0.1 | `remove_section` | `podcast-episode-producer` calls this; if invoked through `batch` it throws `unknownTool` | §1.1 | S |
| P0.2 | `ripple_delete` | Same — used by `podcast-episode-producer`; also nested-batch broken | §1.2 | S |
| P0.3 | `restore_snapshot` | `podcast-episode-producer` restores snapshots; composition not rebuilt and changes not persisted to disk after restore | §8.3 | S |
| P0.4 | `set_overlay_config` | `podcast-episode-producer` + `shorts-formatter` set overlays; in-app chat gets a reduced schema (no `template`/`topics`/`chapters`/`sponsors`) so agent calls silently drop those fields when executed in-app | §6.2 + §X1 | M |
| P0.5 | `set_marker` (color) | 4 skills set marker color; UI ignores `marker.color` and renders theme color regardless | §10.3 | S |
| P0.6 | `get_full_transcript` | `auto-cutter` plans on the description's "every 30 seconds" claim; handler chunks at sentence boundaries instead — the agent's mental model of timestamp density is wrong | §7.1 | S (description fix) |
| P0.7 | `find_viral_moments` | Models that read `tools/list` get `max_duration_seconds` default 180 (MCP); models that read static registry get 60. Same tool, two contracts. | §7.2 | S |
| P0.8 | `create_project` / `open_project` / `close_project` / `rename_project` | Async load races the response — `get_state` immediately after the handler can return an empty timeline. Reachable from `podcast-episode-producer` and any multi-project workflow. | §8.2 | M |
| P0.9 | `batch` | Cannot compose `remove_section`, `ripple_delete`, `remove_silence`, or any MCP-only direct tool because nested resolver throws `unknownTool` | §1.3 | M |

**P0 fix-order recommendation:** P0.1 + P0.2 + P0.9 + §3.1 (`remove_silence`) share one root cause — the resolver/direct dispatch split. Fix them together by giving each direct-handler tool a resolver case (or having `batch` fall back to MCP direct dispatch on `unknownTool`). One PR, ~half a day. P0.6/P0.7 are description edits, ~1 hour each. P0.5 is a single SwiftUI change in `MarkerView.swift`. P0.3 + P0.8 + P0.4 are the meatier fixes (a day or two each).

### P1 — STUB × skill-orphan (agent will pick these autonomously and lie to user)

The agent picks tools based on description text, not skill membership. Every tool below has a confident-sounding description that matches common user requests like "denoise this", "add a hook overlay", "find the bass frequencies". When the agent picks them, it gets a success snapshot back. It cannot tell anything is wrong.

| # | tool(s) | severity | fix spec | effort |
|---|---------|----------|----------|--------|
| P1.1 | `apply_gate` / `apply_compressor` / `apply_de_esser` / `apply_eq` / `apply_limiter` / `normalize_audio_to_lufs` | per-clip audio FX engine missing | §4.1 | L (real fix is composition rework) or S (redirect to track-level) |
| P1.2 | `voice_cleanup` / `denoise_audio` / `auto_duck` / `analyze_audio_spectrum` / `apply_spectral_noise_reduction` | canned-string audio analysis/processing | §4.2 | M-L |
| P1.3 | `add_text_overlay` | text overlay model + command exist but no renderer | §5.1 | M |
| P1.4 | `apply_speed_ramp` | speed keyframes written but ignored at composition | §5.3 | M |
| P1.5 | `add_zoom_effect` | scale keyframes ignored (writes wrong track), pan works | §5.2 | S |
| P1.6 | `set_caption_timing` | canned text; word-level captions need `SubtitleRenderer` work | §6.1 | M |
| P1.7 | `apply_person_mask` / `stabilize_video` | analysis exists but never persisted as effect | §5.4 | M |
| P1.8 | `auto_insert_broll` | lies about inserting; only suggests | §9.5 | M |
| P1.9 | `suggest_broll` | returns count only; throws away `BRollMatcher` data | §9.6 | S |
| P1.10 | `generate_title` | no LLM despite description claim | §9.3 | S (description fix) or M (wire LLM) |
| P1.11 | `search_local_broll` | false claim about chained fallback to `search_broll` | §9.4 | S |
| P1.12 | `activate_skill` | resolver returns `[]` — MCP callers never activate the skill, only `AIChatController` does | §10.2 | M |
| P1.13 | `hook_optimize` | empty input schema; clip hardcoded to first | §7.4 | S |

**P1 fix-order recommendation:** Start with the cheapest description-correction fixes (P1.10, P1.11, P1.5, P1.13) — these stop the lie without changing engine behavior, and the agent immediately gets honest tool descriptions. Then tackle P1.1 / P1.3 / P1.4 since they are the most-likely natural-language hits ("apply EQ", "add text", "speed ramp"). P1.12 is special: until it's fixed, `activate_skill` over MCP is useless — agents using HTTP MCP cannot bootstrap into skills the way the in-app chat can.

### P2 — DEAD branches and DUPLICATEs (cleanup, not correctness)

| # | item | fix | effort |
|---|------|-----|--------|
| P2.1 | DEAD branches in `handleAnalysisTool` for `apply_lut`, `chroma_key`, `denoise_video` (`MCPServer.swift:2414-2415, 2452-2455`) | Delete the three case arms | S (15 min) |
| P2.2 | 20 DUPLICATE names — 16 with cosmetic drift, 4 with semantic drift (handled in P0.4, P0.6, P0.7, §9.1) | Pick a single source per tool: either (a) delete the registry duplicate and treat as MCP-owned, or (b) align both definitions byte-for-byte. Add a unit test that fails when a name is registered twice. | M |
| P2.3 | `delete_asset` race + duplicate | §8.1 — `await` removal before snapshot; resolve duplicate as part of P2.2 | S |
| P2.4 | `remove_track` no clip check | §2.1 — guard in `RemoveTrackCommand.execute` | S |
| P2.5 | `reorder_track` `Int`-only argument coercion | §2.2 — accept `Int` and `Double` | S |
| P2.6 | `auto_reframe` undocumented `apply: true` side effect | Update description to mention it mutates `cropRect` | S (5 min) |

### P3 — ORPHAN WORKING (decide: delete, expose, or leave)

These tools work correctly but no skill steers the agent toward them. Three buckets:

- **Leave as-is** (infrastructure that's reachable but doesn't need a skill): `undo`, `redo`, `play_pause`, `seek`, `toggle_loop`, `get_action_log`, `set_zoom`, `take_screenshot`, `delete_marker`, `get_visual_scenes`, all folder/project lifecycle tools, `score_thumbnails`, `track_object`, `test_feature`, `fix_av_links`.
- **Consider exposing in a skill** (genuinely useful workflow building blocks the agent doesn't know to reach for):
  - `insert_clip`, `duplicate_clip`, `link_clips` — timeline construction
  - `set_clip_keyframes`, `set_clip_crop`, `set_clip_blend_mode`, `set_clip_overlay_presentation`, `apply_pip_preset`, `set_clip_opacity` — advanced clip work
  - `roll_trim`, `slip_clip`, `ripple_trim` — advanced trim modes
  - `lock_track`, `mute_track`, `solo_track` — track audition
  - `set_track_audio_effects` — only working audio FX path; should replace per-clip audio FX in any skill that needs gate/EQ/etc.
  - `extract_clips`, `make_short`, `delete_transcript_range`, `remove_filler_words` — content workflow
  - `search_broll`, `generate_thumbnail`, `generate_short_thumbnail`, `generate_carousel`, `upload_short_to_library` — distribution-adjacent
- **Consider deletion** (no consumer + ambiguous role): `apply_lut` if no skill ever surfaces LUTs to the user; `chroma_key` if green-screen is out of scope; `detect_episodes` if `analyze_transcript` covers the use case (and the registry orphan is removed — see Missing-from-list below).

This bucket is product strategy, not engineering, and should be settled before the follow-up implementation plan is sized.

### MISSING-FROM-LIST

| # | item | fix |
|---|------|-----|
| M1 | `detect_episodes` — defined in `AIToolRegistry.swift:271-277`, missing from `allTools` (`AIToolRegistry.swift:8-110`); MCP-only definition (`MCPServer.swift:437-441`) is the canonical one | §7.3 — either append to `allTools` or delete the registry static |

### Recommended sequencing for the follow-up implementation plan

A single follow-up plan should ship in this order:

1. **Quick wins (1 day total).** P2.1 (delete dead branches), P2.6 (auto_reframe description), P0.6 (`get_full_transcript` description), P0.7 (`find_viral_moments` default), P1.10/P1.11/P1.5/P1.13 (description-honesty fixes), P0.5 (`set_marker` color UI), P2.4/P2.5 (track guards). All small, all fix a lie or a footgun.
2. **Resolver/direct unification (half day).** P0.1 + P0.2 + P0.9 + §3.1 — one PR.
3. **Project lifecycle async (1-2 days).** P0.8 + P0.3 — `await` the bundle load, add a rebuild after restore.
4. **Schema and overlay parity (1-2 days).** P2.2 (resolve duplicates) + P0.4 (in-app vs MCP overlay parity).
5. **Audio FX engine fix (the big one, 3-5 days).** P1.1 — wire per-clip `audioEffects` into `CompositionBuilder`. Then P1.2 — replace canned audio analysis stubs with real FFT / ducker / cleanup.
6. **Visual rendering gaps (3-5 days).** P1.3 (text overlay renderer), P1.4 (speed keyframes), P1.7 (person mask + stabilize persistence).
7. **Caption + skill activation + hook polish (2-3 days).** P1.6 + P1.12 + remaining P1 items.
8. **P3 product call.** Decide which orphans get skill exposure vs deletion. Update `.claude/skills/*/SKILL.md` `allowed-tools:` accordingly. Mirror to `.agents/skills/`.

Total estimated effort: ~3 weeks of focused work to take the tool surface from "trust nothing" to "trust everything." After that, build the harness coverage to make sure it stays trustworthy (separate plan).
