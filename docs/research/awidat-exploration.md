# awidat — exploration report

A descriptive read of the `awidat` codebase as of May 4, 2026. No verdicts; this is "what is here."

---

## 1. What awidat is

awidat is a from-scratch second attempt at the founder's video-editor product, framed as a "terminal-first, agent-native video editing harness." The thesis in `PLAN.md` is that long-form spoken video — podcasts, interviews, conference talks — is a domain where an LLM agent given a text-first project format and a clean tool surface can out-edit a GUI-bolted-on competitor like Descript, "because the GUI pre-defines what the agent can reach for and the terminal does not." The bet name-checks Descript Underlord as the explicit head-on competitor and Opus Clip / Submagic as features-not-products.

The architecture is split between an open Rust substrate (CLI engine, project format, MCP tool registry, Ratatui reference TUI, reference Python indexers) and a closed orchestrator/GUI/premium-AI layer to come later. PLAN.md frames it as Supabase-shaped open core, "the substrate is the open product, the consumer product is your flagship reference implementation," with a podcast episode producer skill as the v1 demo. The v1 success bar is a one-hour podcast in, a 90-second highlight clip out, with the agent making "≥3 non-mechanical editorial decisions."

The whole project draws heavily on a corpus of harness reverse-engineering notes — Codex, Goose, Aider, Crush, OpenCode, SWE-agent, Cursor multi-agent kernels, Anthropic skills. Most major design decisions in PLAN.md cite a specific harness file path as their precedent (Codex's `function_tool.rs`, Goose's eight-crate workspace, Crush's three-pane TUI). The plan reads less as "what should we build" and more as "what's the right pick from each harness for our domain." `conversation.txt` is a 414-line chat transcript between the founder and an assistant where the architecture was developed through pushback — including the assistant explicitly saying "no gaslighting to make me happy" and arguing the pure-podcast pitch is "a developer's dream product that doesn't have a clear buyer." The layered open-substrate-plus-flagship-consumer framing is the version that survived that pushback.

`docs/research/rust-port-analysis.md` is a separate research note that pre-emptively rejects ideological "rewrite everything in Rust" — going indexer by indexer through whether each Python MCP server should be ported. Its conclusion: two are free wins (audio-energy, frame-quality), `editorial-moments-mcp` should "never port" because it's pure orchestration, and `whisper-mcp` shouldn't be touched until Rust ASR + diarization is at parity with the Python stack.

---

## 2. The Rust workspace

Twelve crates (the workspace grew past PLAN.md's planned eight — `config`, `secrets`, `index`, `test-support` are extras). Total ~27k lines of Rust under `crates/*/src/`. Workspace `Cargo.toml` pins `edition = "2024"`, `rust-version = "1.95"`, and bans a long list of clippy lints (`unwrap_used = "deny"`, `expect_used = "deny"`, `await_holding_lock = "deny"`, `redundant_clone = "deny"`, etc.) at workspace level. `unsafe_code` is forbidden everywhere except in `crates/tui` where it's downgraded to `deny` so a single `terminal_probe.rs` module can call `libc::{dup, fcntl, poll, read}` for a 100ms-bounded cursor probe (the comment in `crates/tui/Cargo.toml` says the stock crossterm helper "waits two seconds and crashes the TUI on slow terminals").

Per-crate description:

- **`crates/proto/`** (~3,500 LOC) — the project format types. Hand-written pure-Rust serde models for OpenTimelineIO 1.x (Timeline, Stack, Track, Clip, Gap, ExternalReference, MissingReference, Effect, Marker, RationalTime, TimeRange) plus the `awidat` namespaced metadata extension. Includes `INDEX_SCHEMA.md` and `OTIO_NOTES.md` (covered in §4). Depends only on serde, serde_json, chrono, thiserror.
- **`crates/core/`** (~13,900 LOC, the largest crate) — the agent loop and Anthropic client. Subdirectories: `anthropic/` (hand-rolled streaming SSE Messages-API client; the comment says "no first-party Anthropic Rust SDK exists in 2026"), `edl/` (parser, anchor resolver, applier for the EDL envelope format), `tools/` (twenty tool implementations — see below), plus `session.rs`, `compact.rs`, `episode_map.rs`, `awidat_md.rs`, `mcp_host.rs`. The session implements the two-loop turn-based model copied from Codex.
- **`crates/tools/`** (20 LOC) — a stub. Contains only a `PLANNED_V1_TOOL_COUNT = 12` constant and a comment that real tools "land in Week 4." The actual tools live under `crates/core/src/tools/` (twenty of them, more on this below).
- **`crates/mcp/`** (~880 LOC) — MCP client built on the `rmcp` crate (stdio transport for child-process indexers). Has its own in-tree `awidat-mcp-test-server` binary used by integration tests so the client is exercised against a real MCP protocol, not a mock.
- **`crates/sandboxing/`** (31 LOC) — also a stub. Returns `"seatbelt"` on macOS, `"landlock+seccomp"` on Linux. Real implementation is dated to Week 7 in PLAN.md.
- **`crates/tui/`** (~4,300 LOC) — Ratatui app. Modules: `app.rs` (event loop), `chat.rs` (chat pane state), `composer.rs` (input box), `approval.rs` (modal overlay), `timeline.rs` (timeline pane), `custom_terminal.rs` (a custom inline-viewport backend ported from Codex per a recent commit), `terminal_probe.rs` (the libc cursor probe).
- **`crates/cli/`** (~1,250 LOC) — the `awidat` binary entry point. Subcommand modules: `new_cmd.rs`, `index_cmd.rs`, `chat_cmd.rs`, `tui_cmd.rs`. `clap`-based.
- **`crates/render/`** (~1,030 LOC) — ffmpeg wrapper. `ffmpeg.rs` (binary discovery + frame extraction), `job.rs` (long-running job manager for `start_render`/`poll_render`), `progress.rs` (parses `frame=`/`time=`/`speed=` lines from ffmpeg stderr).
- **`crates/index/`** (~1,030 LOC) — indexer dispatcher. Launches MCP servers, calls each one's `index_asset(asset)` tool, writes sidecars + manifest. SHA-256-keyed idempotency. Submodules: `manifest_io.rs`, `sha.rs`, `sidecar_io.rs`.
- **`crates/config/`** (~800 LOC) — TOML config loader. Reads `~/.config/awidat/config.toml` plus per-project `.awidat/config.toml`. Models `[[mcp.servers]]` entries with `kind = "indexer"`. Has an `EXAMPLE.toml` shipping reference config.
- **`crates/secrets/`** (137 LOC) — keyring wrapper. Backs the `awidat secrets-set` subcommand (commit history mentions "stash API key in OS keychain").
- **`crates/test-support/`** (86 LOC) — shared test helpers for fixtures, assertions, and MCP test harnesses. `publish = false`.

The 20 tools under `crates/core/src/tools/` go well past PLAN.md's planned 12: the planned twelve are present (`apply_edl`, `view_timeline`, `find_moment`, `inspect_clip`, `view_frame`, `list_assets`, `read_index`, `start_render`, `poll_render`, `update_plan`, `request_user_input`, `bash`), and eight more have been added — `broll_candidates`, `clip_search`, `find_beat`, `find_eye_contact`, `find_speaker_oncam`, `inspect_moment`, `shot_summary`, `view_episode`. The chat command's system prompt groups them as Discovery, Editorial index, Vision, Raw lookup, Editing, Render, Plan/collab. The largest tool by line count is `start_render.rs` (595), then `apply_edl.rs` (462), then `find_eye_contact.rs` (421).

---

## 3. The Python MCP layer

Eleven packages under `python/packages/`, organized as a `uv` workspace. Each is a small standalone MCP server speaking stdio JSON-RPC. They share a library called `awidat-mcp` that provides the sidecar header, sha256, and a `FastMCP`-based `IndexerServer` wrapper.

- **`awidat-mcp`** — the shared library. Provides `Sidecar`, `SidecarHeader`, `asset_sha256`, `IndexerServer`, `IndexAssetRequest`. Mirrors `IndexSidecarHeader` in `crates/proto/src/index.rs` so engine and indexers agree on the wire format. Pydantic-backed.
- **`whisper-mcp`** — speech-to-text + diarization. Wraps WhisperX (which itself is faster-whisper + pyannote.audio + wav2vec2 forced alignment). Outputs `words[]`, `segments[]`, `speakers[]` with word-level timestamps and speaker IDs. Defaults to `large-v3-turbo`, falls back to `small.en` (~470 MB) without `HF_TOKEN`. Diarization uses `pyannote/speaker-diarization-community-1`, gated on accepting a HuggingFace EULA.
- **`scenedetect-mcp`** — shot boundaries. Wraps PySceneDetect's ContentDetector at threshold 27.0 (the documented default). Outputs `shots[]` with `start_s`/`end_s`. Note in the comment: a TransNetV2 backend could ship as a separate `shots-transnet` indexer "without engine changes" — illustrating the shape of the index contract.
- **`shot-mcp`** — derived shot metadata. Reads scenedetect + face sidecars and labels each shot with `type` (extreme-close-up | close-up | medium | wide | no-face) from face-area-to-frame ratio and `motion` (static | slow-pan | fast-cut | handheld) from sparse optical flow. Pure derivation; no model.
- **`clip-mcp`** — CLIP frame embeddings. ViT-B-32 / OpenAI weights via open_clip. One frame per second. Embeddings packed as little-endian float16 base64 to keep sidecars <1 MB per 30-min episode.
- **`face-mcp`** — face detection + speaker-to-face mapping. dlib HOG + 128-d ResNet embeddings via `face_recognition`, DBSCAN clustering at cosine epsilon 0.4 to label face IDs, then weighted overlap with whisper diarization to map faces to speakers. Notes call out that `face_recognition_models` is GitHub-only and requires `setuptools<81` because `pkg_resources` was dropped in 81+.
- **`gaze-mcp`** — looking-at-camera vs off-camera. Heuristic on dlib's 5-point landmarks: distance from each eye center to the nose tip, normalized by face width. Score in [-1.0, +1.0]. Inherits its landmark detector from face-mcp.
- **`audio-energy-mcp`** — RMS over 100ms windows + integrated LUFS (EBU R128) + silences. Uses `pyloudnorm` and numpy. Silence threshold is relative (-30 LU below integrated), not absolute dBFS, "so it ports across podcasts/interviews/conf recordings." This is the lightest indexer (no model, no API key) and is the only one wired into `cargo test --ignored` end-to-end.
- **`topic-mcp`** — topic segmentation. Reads the whisper sibling sidecar, runs sentence-embedding boundary detection (TextTiling-with-embeddings via `all-MiniLM-L6-v2`), and labels segments via Anthropic Claude or local Ollama or a heuristic top-keyword fallback. Three optional dependency extras: `[claude]`, `[ollama]`, neither.
- **`frame-quality-mcp`** — per-second blur (Laplacian variance), brightness (mean luma), contrast (luma std-dev) via opencv-python-headless + numpy.
- **`editorial-moments-mcp`** — the "brain" indexer. Reads sibling sidecars (whisper + topic + audio-energy), runs Claude Haiku per topic-segment with a structured-output schema, and emits typed editorial beats — hooks, punchlines, CTAs, dead-air, b-roll-needs, energy levels. Calls itself out as the indexer that converts raw signals into "editorial decisions the agent can navigate." Hard fails if dependencies are missing rather than caching empty success.

Most indexers wrap an existing library; `shot-mcp`, `gaze-mcp`, `audio-energy-mcp`, `editorial-moments-mcp`, and parts of `face-mcp` (the speaker mapping) do their own work on top.

`python/SMOKE.md` is the manual-smoke playbook for indexers that are too heavy or too gated to run in CI — a copy-paste recipe to set up `uv sync`, write a per-project `.awidat/config.toml` with all nine indexer registrations, drop a real asset under `raw/`, and run `awidat init` / `awidat index` / `awidat validate`.

---

## 4. The project format and indexing

A project is a directory, not a file. PLAN.md endorses this explicitly: "the directory is a unit a user can `git init`, share, hand-edit." The layout: `project.otio.json` (source of truth), `edit-plan.json` (structured plan with status), `episode-notes.md` (agent's running editorial reasoning, append-only by convention), `index/` (sidecars), `renders/`, `.awidat/` (ephemeral session SQLite, config).

**OTIO superset.** `OTIO_NOTES.md` documents that the project format is OpenTimelineIO 1.x JSON with a single `metadata.awidat` extension namespace. The Rust types in `crates/proto/src/otio/` are a typed subset: Timeline, Stack, Track, Clip, Gap, ExternalReference, MissingReference, Effect, Marker, RationalTime, TimeRange. Skipped: SerializableCollection, LinearTimeWarp, FreezeFrame, GeneratorReference, ImageSequenceReference, SchemaDef. The doc has a worked example for adding `LinearTimeWarp.1` in v1.5 to demonstrate the additive design.

Schema versioning rules are explicit: known name + matching major → parsed; known name + unknown major → forward-compat (rewrite the schema string, deserialize as the supported major, emit a `SchemaWarning`); unknown name → hard fail with the supported list; malformed `OTIO_SCHEMA` → hard fail. The forward-compat rewrite happens in `crate::project::read_otio_timeline` before serde runs, so the typed deserializers stay pure.

The `metadata.awidat` namespace has three modeled locations: `AwidatTimelineMetadata` (project-wide source assets, anchor table, edit-plan reference), `AwidatClipMetadata` (per-clip reasoning, edit-plan back-reference, optional inline anchor), `AwidatMarkerMetadata` (per-marker category like "laugh"/"key-quote", free note). Other foreign metadata namespaces (Resolve, Premiere) are preserved verbatim through a flattened `HashMap` so round-tripping doesn't clobber them.

**INDEX_SCHEMA.md** is the contract for footage-index sidecars. The shape is `index/<indexer-name>/<asset-relative-path>.json` — one directory per indexer, one file per (indexer, asset) pair, never merged. Every sidecar has the same self-describing header (`indexer`, `indexer_version`, `schema_version`, `asset_id`, `asset_sha256`, `produced_at`) and an opaque `data` body the engine sees as `serde_json::Value`. The `index/manifest.json` is the registry the engine consults to learn what indexers have run; the engine has no hardcoded list of channel names — `read_index(channel="speaker-emotion")` is a pass-through directory lookup.

The doc spends a section on failure modes the contract guards against ("All signals share `index/<asset>.json` → adding a v1.5 channel is a breaking schema change"). It also has a worked example walking through how to add a `speaker-emotion` indexer in v1.5 with the explicit refrain "what did NOT change in the engine: no new types in `crates/proto/`, no new struct fields anywhere, no new code paths." `awidat validate` cross-checks manifest entries against disk and emits warnings rather than errors so a partially-indexed project remains usable.

**`crates/index/`** is the Rust dispatcher implementing this contract. Launches MCP servers in parallel via `tokio::spawn` + `FuturesUnordered`, calls `index_asset` on each, writes the sidecar, updates the manifest. Per-pair failure logs and continues rather than killing the run. Idempotency by `asset_sha256` — re-running on an unchanged asset is a no-op. There's no embedding index in the engine itself; vector work happens inside `clip-mcp` and `topic-mcp` and lands as opaque body data in their respective sidecars.

Beyond the index itself, two more "context" mechanisms complement it: `crates/core/src/awidat_md.rs` discovers and concatenates an `AWIDAT.md` file (the Codex AGENTS.md / Claude Code CLAUDE.md pattern, ported) walked through user → project → local scope, and `crates/core/src/episode_map.rs` produces a ~200-300 token compact textual map of the project (Aider-repomap-for-video) stuffed into the system prompt at session start.

---

## 5. The TUI

`crates/tui/` is built on Ratatui 0.29 + crossterm 0.28. The architecture comment in `lib.rs` says "single-pane chat for v1" and explicitly describes the TUI as "the developer-facing surface, not the long-term human wedge; that's the future GUI viewer." The structure mirrors the Codex TUI. Modules:

- `app.rs` — event loop. Owns the terminal, chat state, composer, modal, and merges three async sources (terminal events, agent broadcast, approval channel) into one `AppEvent` queue.
- `chat.rs` — streaming model deltas, tool spinners, tool results.
- `composer.rs` — the bottom input box with dynamic height.
- `approval.rs` — modal overlay for mutating-tool approvals (Allow / Allow for Session / Deny on a/s/d keys per the Crush pattern referenced in PLAN.md).
- `timeline.rs` — timeline pane state. `App` keeps a `pending_apply_edl_snapshot` field that captures the timeline at `apply_edl` ToolCallStart so the ToolResult can render a before/after diff crumb.
- `custom_terminal.rs` — a custom inline-viewport backend (commit history says "port from Codex").
- `terminal_probe.rs` — the libc cursor probe with the workspace-only-here-allowed unsafe code.

The flow: the caller hands the App a `Session` plus the receivers from `subscribe()` and `with_approval_channel`. The App enters the alternate screen, builds the custom full-screen terminal, drives the loop. Quit on Ctrl-C, Ctrl-D, or `:q`. Ctrl-C while a turn is in flight cancels the turn via the stored `turn_cancel` token rather than killing the app.

---

## 6. Build, run, demo

The `Makefile` exposes `check` (fmt + clippy + test), `package` (wraps `dist/package.sh`), and `install-local` (build + run the install script against the just-built tarball with `AWIDAT_RELEASE_BASE=file://...`). Workspace builds with `lto = "thin"`, single codegen unit, stripped symbols.

`dist/` is the distribution scaffold (Phase 3 per the commit log). `dist/README.md` describes the model: ship the Rust binary (~10 MB) plus a vendored `uv` plus the entire python source tree, let `uv` materialize the per-indexer venvs on the user's machine on first run (~3 GB of wheels). The reasoning: PyOxidizer fights torch/dlib/opencv native extensions, Docker breaks MCP stdio for desktop users, pre-built shiv zipapps don't handle native extensions well — "the boring/right answer" is install-time materialization, "what most ML-CLI tools land on (ollama, whisper.cpp)." A current build artifact for `aarch64-apple-darwin` exists under `dist/build/`, with the install script and tarball in place. The install URL `https://awidat.example/install.sh` is a placeholder.

CI is a single `.github/workflows/ci.yml` running `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, `cargo doc` on macOS-latest and ubuntu-latest. No Python CI step is present in the workflow file; `python/SMOKE.md` is the manual playbook.

To try it: `awidat new <project-name> --import <url-or-path>` creates the project dir, optionally pulls source via yt-dlp or copies a local file into `raw/`, then auto-runs `awidat index` and writes a starter `AWIDAT.md`. From there `awidat chat <project>` is the text REPL and `awidat tui <project>` is the Ratatui surface — both expose the same 20-tool registry. `awidat secrets-set` stashes the Anthropic API key in the OS keychain. `awidat validate` round-trips the OTIO file and cross-checks the index manifest.

Tests: nine integration test files across `crates/{cli,core,index,mcp,tui}/tests/`. Names: `live_agent.rs`, `live_advanced.rs`, `live_editorial.rs`, `editorial_workflow.rs`, `live_app_pipeline.rs`, `client_against_test_server.rs`, `cli.rs`, `end_to_end.rs`. The `live_*` naming pattern suggests they hit real APIs (Anthropic) when an API key is present. The `audio-energy` indexer is the only Python indexer wired into `cargo test --ignored` (per `python/SMOKE.md`: "the only indexer cheap enough to run on every commit").

---

## 7. Activity & state per PLAN.md

Repo creation and the bulk of the work appear to have happened in late April through early May 2026 — twenty most-recent commits range over what the messages call "Day 1" through "Day 7+" of indexing work, plus four numbered "Phase" commits. The git log reads like an active, narrated build:

- "Indexing day 1+2: AWIDAT.md hierarchy + episode-map (repomap for video)"
- "Indexing day 3+4: editorial-moments brain + navigation tools"
- "Indexing day 5: conversation compaction at 80% iteration cap"
- "Day 6 vision indexers: clip-mcp + face-mcp + shot-mcp"
- "Day 7+ specialized vision indexers: gaze-mcp + frame-quality-mcp"
- "Vision tools + McpHost: 5 new agent tools, warm Python encoder"
- "Phase 1: bundled indexer registry — zero-config default"
- "Phase 2: awidat new --import — one-command project creation"
- "Phase 3: distribution scaffold — vendored uv + python tree tarball"
- "Phase 4: Rust indexer port — research-only assessment"
- "Bugfix: dependency-aware indexer dispatcher + symlink resolution" (most recent)

Mapped against PLAN.md §15's eight-week build order: weeks 1–4 (skeleton, project format, footage index, agent loop, tool surface) appear substantively complete. Week 5 (Ratatui TUI) is in place — the diff view overlay, approval modal with a/s/d keys, and streaming spinners all match PLAN.md's spec. Week 7 (sandbox + verification tiers) is largely deferred — `crates/sandboxing` is still a 31-line stub that returns a backend name string. Week 6 (skills + the three reference skills) is not visible in the tree — there is no `skills/` directory at the repo root and no skill loader in `crates/core/`. The v1 demo (Week 8) does not appear to have been recorded; `dist/` has a built tarball but no demo recording.

The eight-crate plan grew to twelve crates: `config`, `secrets`, `index`, `test-support` are unplanned additions but described matter-of-factly in their own Cargo.toml comments. The 12-tool plan grew to 20 tools, with 8 added since "Day 6 vision indexers" started landing. PLAN.md's open question §16.2 (Architect/Editor split with Sonnet+Haiku) is not visible in the chat command — the system prompt sends to one model (defaulting to Sonnet, override via `--model`).

`docs/research/rust-port-analysis.md` (the latest non-plan doc) is dated by commit to the same period and reads as a deliberate decision to *not* port the Python indexers wholesale, with the explicit framing that "the Python+`uv` distribution model isn't a temporary hack — it's a reasonable steady state."

---

## 8. Notable bits

A few things that stood out descriptively:

**The grammar discipline on the EDL.** PLAN.md commits to a freeform Lark grammar for `apply_edl` (not JSON) on the argument that "JSON-escaping multi-line content is miserable." The current `crates/core/src/edl/parser.rs` is hand-rolled instead — a line-driven state machine, not a Lark runtime — with a comment explaining the choice: "The grammar is the documentation; the parser is line-oriented and commits at every `\n`." Same shape as Codex's `apply-patch/src/parser.rs`. The validation pipeline (parse → anchor resolve → schema check → OTIO round-trip → commit) routes failures back to the model as `FunctionCallError::RespondToModel` with anchor-miss strings that include "did you mean?" candidates.

**The "anchor" concept as the load-bearing schema extension.** Every clip change in the EDL is identified by content (transcript snippet, audio fingerprint hash, scene-change index) rather than absolute frame numbers, so edits survive upstream insertions. `metadata.awidat.anchors[clip-uuid]` carries the locator data alongside the clip itself. PLAN.md frames this as the property that lets the agent's edits be diffable and durable across restructuring.

**`editorial-moments-mcp` as "the brain indexer."** The other ten indexers extract raw signals — transcripts, shots, energy, embeddings. This one runs Claude Haiku per topic-segment with a structured-output schema and emits typed editorial beats (hook, punchline, CTA, dead-air, with energy level and b-roll-need fields). It's the only indexer that's itself an LLM call, and `rust-port-analysis.md` says it should "never port" because "porting buys literally nothing — no native code replaced, no model being run, no startup cost eliminated." The corresponding agent tools are `find_beat` and `inspect_moment`, and the system prompt tells the agent to "prefer these over `find_moment` when the user asks for editorial intent."

**The dependency-aware dispatcher.** The most recent commit ("Bugfix: dependency-aware indexer dispatcher + symlink resolution") suggests the index pipeline has implicit ordering — `topic-mcp` reads the whisper sidecar, `editorial-moments-mcp` reads whisper + topic + audio-energy, `shot-mcp` reads scenedetect + face. `python/SMOKE.md` notes this and says: "the engine doesn't model dependency order between indexers; the agent does," with `topic-mcp` returning `topics: []` plus a `note` if whisper hasn't run yet. The bugfix appears to have added some dispatcher-level dependency awareness on top of that.

**Comment density and load-bearing-doc framing.** Most files lead with a doc comment that names what they're for, what corpus pattern they're modeled on (with file paths into `harnesses/codex/codex-rs/...`), and what's deferred. INDEX_SCHEMA.md and OTIO_NOTES.md both have prominent "Status: load-bearing schema doc" headers. PLAN.md reads as a single source of truth that other docs cite by section number.

**The conversation transcript as a design artifact.** `conversation.txt` (414 lines, ~56 KB) is a chat between the founder and an assistant that produced the architecture. The assistant pushes back hard at multiple points — calling the original pitch "a developer's dream product that doesn't have a clear buyer," challenging the Cursor analogy ("none of those four cleanly apply to video"), arguing Descript will "out-execute a solo founder building from scratch." The plan's open-substrate-plus-flagship-consumer framing is the version that survived that pushback, and PLAN.md keeps referring back to specific line ranges of `conversation.txt` as primary sources for individual decisions.

**Workspace lint policy.** `Cargo.toml` enables a long list of clippy denies aimed at correctness rather than style — `unwrap_used`, `expect_used`, `await_holding_lock`, `await_holding_invalid_type`, `redundant_clone`, plus a stack of `manual_*` denies that catch missed standard-library idioms. The doc comment cites Codex's `Cargo.toml`: "we prefer enabling specific lints that catch real bugs over enabling `clippy::pedantic` wholesale, which mostly produces style noise."

**Twelve crates from a planned eight, twenty tools from a planned twelve.** Both are growth past the original plan. The four extra crates have explicit Cargo.toml justifications; the eight extra tools are mostly the vision tools added in the "Day 6/7+" commits and reflect the index growing from four channels to eleven indexers.

---

End of report.

---

## 9. June 12 addendum — short-form editing and X trend context

Follow-up read against the current `awidat` checkout on June 12, 2026, focused on
what is worth borrowing for automatic podcast/shorts editing quality and
reliability.

### Current repo-level shape

The biggest product difference remains architectural. This repo is a native
Swift editor with AI tools wired into `EditorIntent -> Command -> Execute`.
Awidat/Montage is now much more explicitly an agent-native editing environment:
Rust workspace, Tauri desktop shell, Python MCP indexers, bundled editorial
skills, and a vendored Codex runtime.

For short-form work, that means Montage has more analysis channels available to
the agent before it edits. The useful lesson is not "copy the stack"; it is
"make short selection depend on multiple inspectable signals, then verify the
rendered result."

### Short-form patterns worth porting

Awidat's short-form skills are stronger than ours in four concrete ways:

- **Candidate scoring is multi-signal.** `skills/viral-clip-extractor/scripts/score_moments.py`
  scores editorial moments with moment type, transcript hook words, audio
  energy, visual evidence, gaze/direct-address evidence, frame quality, topic
  boundary proximity, duration, and overlap suppression. This is more reliable
  than transcript-only or transcript-plus-energy selection.
- **Vertical layout is evidence-driven.** `skills/short-form/SKILL.md` and
  `skills/talking-head-vertical/` distinguish `active_speaker_fill`,
  `split_stacked`, `dynamic_switching`, and `native_vertical` instead of using
  a fixed podcast split or static crop. This maps well to our existing
  `analyze_for_shorts` / `create_short` path.
- **Review comes before mutation.** Montage's `plan_short_form_review` returns
  reviewable candidate packages and draft EDL rather than immediately applying
  edits. That fits our reliability goal: plan first, apply through editor
  commands only after approval.
- **Verification is part of the workflow.** Montage skills repeatedly require
  timeline inspection, render, and render verification before reporting success.
  For this repo, the equivalent should be `verify_playback`, export proof, and
  a clear failure if captions/audio/duration/frame checks do not pass.

Do not copy Awidat skills directly into this repo as-is. They assume Montage
tools such as `view_episode`, `read_index`, `apply_edl`, `vedit_diff`,
`start_render`, and `verify_render`. The right port is conceptual: adapt the
decision logic into this repo's tool names and mutation path.

### X trend context

Awidat has a first-class X trend read path:

- `crates/core/src/x_trends.rs`
- `fetch_x_trend_context` in `crates/core/src/montage_mcp/mod.rs`
- `skills/viral-clip-extractor/SKILL.md`

The tool takes 1-5 topic queries, uses an X bearer token to call recent search,
collects public metrics, converts recent posts into weighted trend signals, and
returns a structured `trend_context` payload for short-form planning. If
credentials are missing, it returns a setup/status payload instead of failing.
Publishing remains separate from trend reads.

The important policy in Awidat's skill is: trend alignment is only a boost.
It must not replace hook strength, standalone clarity, energy, payoff, duration,
or visual suitability.

This repo already has a weaker version inside `VideoEditor/VideoEditor/App/MCPServer.swift`:
`find_viral_moments` asks Claude to use web search 1-3 times and emit
`trending_score`. That works, but the evidence is not separately inspectable.
The model is doing trend research and clip scoring inside one large prompt.

Recommended port:

1. Add a provider-neutral `check_trend_context` tool rather than an X-only tool.
2. Start with web search because the Claude provider already supports it.
3. Return structured signals:
   - `source`
   - `label`
   - `keywords`
   - `weight`
   - `reason`
   - small evidence snippets or links when available
4. Feed those signals into `find_viral_moments`, `analyze_for_shorts`, or a new
   short-review planner.
5. Persist the selected trend evidence alongside `trending_score` so the Mac
   editor and iOS distribution app can explain why a clip is timely.
6. Add optional X bearer-token support later if direct X signal quality is worth
   the credential/setup cost.

Target scoring shape:

```text
transcript + word timings
  + audio energy / silence
  + visual quality / face / gaze when available
  + hook and payoff scoring
  + structured trend_context
  -> ranked short candidates
  -> reviewable edit plan
  -> command-based timeline edits
  -> playback/export verification
```

### Practical next step for this repo

Update `viral-clip-extractor` and `shorts-formatter` to require a structured
trend-context pass when the episode topic is timely, while keeping evergreen
moments eligible even when no current trend matches. The product promise should
be:

> "We can tell you whether a clip is good because it is evergreen, timely, or
> both, and we can show the evidence before we cut."
