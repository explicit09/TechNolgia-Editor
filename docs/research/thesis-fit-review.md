# Thesis-fit review: what's already built, what to do next

A strategic memo, written after a deep audit of the codebase against the agent-native / terminal-first / open-substrate thesis we've been refining.

The full audit lives at `thesis-fit-audit-raw.md`. This memo is the opinionated take on what to actually do.

## The headline finding

**You're much closer to the thesis than the strategic conversation gave you credit for.** The earlier framing — "ground-up rebuild because the existing app is GUI-first" — was wrong. The existing codebase is structurally closer to an agent-native substrate than typical "should we pivot" cases.

What's actually there:

- A clean engine package (`EditorCore`, 124 files, ~24k LOC) with **zero SwiftUI/AppKit/UIKit imports** anywhere. Verified by grep.
- A project format that's already JSON, already pretty-printed with sorted keys, already diffable. `timeline.json` and `manifest.json` written via a `JSONEncoder.pretty` extension.
- Pure value-type models (`Timeline`, `Track`, `Clip`, `MediaAsset`) with no AVFoundation references — fully `Codable`, UUID-keyed, portable.
- An `EditorIntent → Command → Execute` pattern that's the exact right shape for an agent-native mutation surface.
- 94 tools in `AIToolRegistry` mapped one-to-one to intents — SWE-agent ACI granularity, not monolithic.
- A `PlanClassifier → PlanGenerator → PlanExecutor` pipeline with model-tier-per-step (Haiku for fast/property changes, Sonnet for analysis/complex). **The Architect/Editor split from Aider is already implemented.**
- Nine mature skills in `.claude/skills/` totalling ~2k LOC, in Anthropic Skill format (YAML frontmatter, `name`/`description`/`allowed-tools`). `podcast-episode-producer` is 412 lines and real.
- A snapshot-based version control system that's git-shaped (list, restore by name).
- ~5k LOC of test coverage on the engine layer, mature and meaningful.
- And — the surprise that reframes the whole thing — `docs/research/harness-learnings/synthesis.md`, which is **your own** opinionated synthesis of the harness literature, written before this conversation, mapping Aider/Anthropic/SWE-agent/Cursor onto video. The thesis we've been refining for hours wasn't new to you. You'd already mapped it.

The strategic conversation was useful for framing the *commercial* questions (audience, competition, business model) but it overshot on the architectural rebuild question. The audit corrects that.

## What I owe you, said directly

In the earlier conversation I led you toward the "ground-up rebuild" framing harder than the evidence warranted. I was reasoning about the typical case ("video editors are GUI-first, agents are bolted on") when in fact you'd already done the work to make the engine separable. That's worth saying out loud — and it changes the recommendation meaningfully. We're not deciding whether to rebuild from scratch. We're deciding how to lift what already works into the shape we want.

## The actual problem, in two files

Almost all the friction between current state and the thesis lives in two files:

**`MCPServer.swift` (7,158 LOC, 361 KB)** — a single file with a 70-case `if name == "..."` dispatch chain that handles every MCP tool call. The protocol design is fine (JSON-RPC over HTTP, loopback-only origin checks, CORS done right). The structural problem is the file itself: it's where the agent surface meets the app, and it reaches into `AppState` for things that should live in the engine. Decomposing this into per-tool files (or a tool-router pattern) is mostly mechanical. 1-2 weeks.

**`AppState.swift` (2,101 LOC, `@MainActor @Observable`)** — the actual orchestrator. Holds `EditingContext`, `CommandHistory`, `IntentResolver`, `PlaybackEngine`, `ExportEngine`, `MediaCoordinator`, `AIChatController`, `ProjectStore`, `ProjectIndexManager`, plus the MCP server. **Most of the orchestration that should be in EditorCore is in this app file.** The MCP server requires the GUI process to be running because it's instantiated here. Lifting the orchestration into an `EditorSession` actor inside EditorCore — leaving only SwiftUI-bound state in `AppState` — is the single highest-leverage refactor in the codebase.

Once those two files are decomposed, almost every other thesis property unlocks naturally. A CLI target becomes a thin shell over `EditorSession`. The MCP server moves into EditorCore (or a `Substrate` target) and is no longer GUI-tethered. The OTIO adapter is a port of the existing schema, not a rewrite. Plans persist to disk because there's a session to own them. Git-per-edit replaces the snapshot system because the bundle is now a real working directory.

## What to keep, what to refactor, what to build

### Keep (no changes needed, the thesis is already served)

- `EditorCore` data spine — `Models/`, `Commands/`, `Intents/`, `Storage/`, `ActionLog/`, `Cache/`. Foundation-only, portable, well-tested.
- The `EditorIntent → Command → Execute` pattern. Already exactly the agent-native mutation primitive.
- The JSON project format (`timeline.json`, `manifest.json`). Already diff-friendly. Don't replace.
- The 94-tool `AIToolRegistry`. Granularity is right; just needs to live somewhere process-agnostic.
- `PlanClassifier → PlanGenerator → PlanExecutor`. The Architect/Editor pattern is already there.
- The skills system (`SkillRegistry` + `.claude/skills/` + `.agents/skills/`). Format is Anthropic-correct; `podcast-episode-producer` is mature.
- The action log (SQLite per-command). It's the audit trail that makes diffs reviewable.
- The Supabase distribution pipeline. Orthogonal to the thesis; keeps shipping value to users.

### Refactor (the work, in priority order)

1. **Lift orchestration out of `AppState` into an `EditorSession` actor in EditorCore.** Project lifecycle, command dispatch, save scheduling, plan execution. The actor owns what the CLI would need; `AppState` retains only SwiftUI-state glue. **This is the keystone refactor; everything below is downstream of it.** ~1-2 weeks.

2. **Decompose `MCPServer.swift`.** Move the file into EditorCore (or a sibling `EditorMCP` target). Replace the 70-case dispatch with a tool router that resolves `name → handler` from a registry. Each handler in its own file, scoped to one intent. ~1-2 weeks.

3. **Add a CLI executable target.** `swift run videoeditor-cli serve --project path/to/x.veditor` boots an `EditorSession`, starts the MCP server, idles. Once #1 and #2 are done, this is a few days of work.

4. **Replace the snapshot system with Git.** The bundle is already a flat-file directory; `git init` it, commit on every command via the existing `ActionLog`. Snapshots become tags. The agent's edits become reviewable PRs. ~1 week.

5. **Persist plans to disk.** Currently in-memory in `AIChatController`. Should be `edit-plan.json` (structured, fields the agent updates) plus `episode-notes.md` (prose reasoning, append-only). Lifted directly from Anthropic's long-running harness pattern — and you've already written down the rationale in `harness-learnings/synthesis.md`. ~3-5 days.

6. **Skills: ship bundled scripts (Anthropic Skills "level 3").** Skills currently have YAML + body but no progressive-disclosure file loading. Add the convention; let `podcast-episode-producer` ship a Python script the agent calls when code is more reliable than reasoning. ~1 week.

### Build (genuinely new work)

1. **OTIO adapter.** Bidirectional Timeline ↔ OTIO converter. Either a Swift target using OTIO's C API or a Python bridge in `Tools/`. The bespoke schema stays canonical (it's a strict superset because of clip-link/overlay-presentation features); OTIO is the export/import lingua franca. Plausibly 2 weeks for round-trip with tests.

2. **The headless render backend.** Today, all rendering is AVFoundation. For Mac-first, this stays the default. For cross-platform headless, you need an `FFmpegRenderBackend` (and equivalent for transcription via WhisperKit, which already exists as a fallback). This is the cross-platform binding constraint; see next section.

3. **The "diff view" surface for the GUI.** The GUI viewer needs to show the human "here's what the agent changed since last session" — a rendering of the Git diff over the timeline JSON, made visual (added clips highlighted, modified clips marked, removed clips ghosted). This is the verification surface that closes the loop. Probably 2-3 weeks of focused UI work, but only after the substrate is solid.

4. **The flagship demo.** End-to-end: drop in raw podcast footage, agent produces a finished cut, human watches and signs off. Wire all the existing pieces together with the new orchestration. This is what makes the substrate credible — both to you and to anyone you'd pitch.

### Replace (nothing major)

Genuinely nothing big needs to be thrown away. The closest is the snapshot system → Git, but that's a swap, not a rewrite. The audit found no architectural patterns that fight the thesis.

## The real fork: Mac-first or cross-platform?

This is where the honest decision lives, and it's not the rebuild question — it's whether the substrate runs on Linux servers in v1.

**Mac-first path.** AVFoundation stays. Engine + MCP + CLI all work on macOS, headless via `swift run`. Agent runs as a process on a Mac (yours, a user's, or a Mac mini in a closet). Distribution: ship as a Homebrew formula + the GUI app for visual review. Time to a working substrate: **4-8 weeks of focused work** on the keystone refactors above. This preserves all existing engine code.

**Cross-platform path.** Add an `FFmpegRenderBackend`, decouple from AVFoundation, support Linux. Now the substrate runs on a server, on CI, in Docker. Open-source story is much cleaner ("`docker run videoeditor`"). Distribution: anywhere. Time to a working substrate: **add 2-3 months** for the render backend port, plus ongoing dual-implementation maintenance.

The right answer depends on a question you should answer before committing: **does the substrate need to run without a Mac for the business model to work?**

- For an indie shop / Mac-first power-user audience: no, Mac-first is fine. You sell to people who already have Macs. You ship faster.
- For a developer-substrate play (the layered model we discussed — sell the substrate to other builders): yes, cross-platform is required. Devs won't build production products on a Mac-only substrate.
- For a hosted SaaS where you run the agent in your cloud: yes, cross-platform is required. Mac instances on AWS exist but are economically painful.

If the layered "build for devs first, then consumer" model is the bet, cross-platform is non-optional and the FFmpeg render backend is the project that earns its keep.

If the bet is "ship a Mac-first product that beats Descript on the Mac," skip the FFmpeg work and ship faster.

I'd lean toward Mac-first for the next 8 weeks regardless, get to a working substrate, and decide on cross-platform after the demo proves the thesis (or doesn't). FFmpeg-rendering becomes a milestone you can hit *after* you have something to show, when the cost is justified by traction.

## Concrete sequence (Mac-first, 8 weeks)

A plausible week-by-week shape. This is one ordering, not the only one.

- **Week 1-2:** `EditorSession` actor in EditorCore. Lift orchestration from `AppState`. The keystone refactor.
- **Week 3-4:** Decompose `MCPServer.swift`. Move into EditorCore / `EditorMCP`. Tool router pattern.
- **Week 4:** CLI executable target. `videoeditor-cli serve`.
- **Week 5:** Replace snapshot system with Git. Wire `ActionLog` to commit on every command.
- **Week 6:** Persist plans to disk (`edit-plan.json` + `episode-notes.md`). Initializer agent writes the plan; worker agents update it.
- **Week 7:** OTIO adapter (round-trip with tests).
- **Week 8:** End-to-end demo. Hour of raw podcast footage → finished cut → human reviews diff → ships.

This sequence assumes one focused person (you) and no hard blockers. Realistically it's 10-12 weeks with normal interruptions. Either way, by the end you have a working agent-native substrate that's a real product, not a prototype, and you've thrown away approximately none of the existing engine code.

## What this changes in the strategic conversation

A few things land differently now:

**The "build dev-substrate first, then consumer" framing gets stronger.** Because you already have an opinionated, well-tested engine, you're closer to "we have an SDK, let's package it" than to "we need to build the SDK." The substrate-as-product play is more reachable than I thought.

**Competing with Descript on output quality is more reachable too.** The skills system is mature. The Architect/Editor split is implemented. The action log makes every decision reviewable. What's missing for "agent edits my podcast end-to-end and the output is great" is mostly orchestration plumbing (the keystone refactor) and the editorial polish loop (the skills + the verification step).

**Your earlier hesitation about pivoting was sound.** When you said you'd already advertised the previous direction, that wasn't just a marketing concern — it was correct architectural conservatism. The audit confirms there's no fundamental misalignment to throw away. The pivot is "expose what you've built more directly," not "start over."

**The synthesis you wrote in `harness-learnings/synthesis.md` is doing real work in this codebase.** Not just intellectually — it's actually informing decisions you've already made (the JSON-pretty-sorted format, the Architect/Editor split, the Skills format). Keep using it as a design constraint. Reread it when you start the keystone refactor.

## Risks worth flagging

**The keystone refactor is non-trivial.** Lifting orchestration out of `AppState` is the kind of work that looks small in a memo and takes longer than expected once you're in the file. Budget for it; don't get demoralized week three.

**Cross-platform timing matters more than this memo suggests.** If you commit to Mac-first now and decide six months in that you need Linux, the FFmpeg port is much more painful with three more months of accumulated AVFoundation coupling. Make that decision deliberately, not by drift.

**Distribution-side work has been eating engine work.** The audit shows the last six weeks of commits were almost entirely iOS distribution. That's fine if shipping was the priority, but the engine pivot needs sustained engineering time. Decide whether the next two months are "ship the substrate" or "keep shipping distribution features."

**The opportunity cost of the demo is real.** Eight weeks of refactoring without a visible deliverable is hard to sustain alone. Consider doing the keystone refactor in week 1-2 *plus* a hacky end-to-end agent demo in week 1, even if the demo is duct-tape, so you have a continuous artifact of progress and a thing to look at when motivation flags.

## Bottom line

The codebase is a real asset. The thesis is well-served by it. The strategic conversation should pivot from "rebuild or refactor" to "what order do we lift this into the shape we already know we want." Eight focused weeks of concentrated work — keystone refactor, MCP decomposition, CLI target, Git-as-version-control, plans-on-disk, OTIO adapter, end-to-end demo — and you have an agent-native substrate with a Mac-first GUI viewer that's a meaningfully different product from Descript. After that, the open question is cross-platform, which you'll be in a much better position to answer with a working thing to point at.

The conversation we've been having stays correct in its commercial conclusions (open core, layered, possibly developer-first, narrow consumer wedge). The architectural conclusion needs updating: you don't need to start over. You need to finish what you started.
