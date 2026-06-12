# What the coding-harness builders learned, applied to a video harness

A distillation of two years of Anthropic, Aider, SWE-agent, OpenHands, and Cursor writing on agentic harness design — read with a single question in mind: *what transfers to building an agent that edits video?*

All citations point to files under `sources/`. Quotes under 15 words are verbatim; longer ideas are paraphrased.

## The recurring lessons

Across every source, five ideas show up in some form:

**1. The interface to the agent matters as much as the model.** SWE-agent's central claim is that "good ACI design leads to much better results when using agents" (`swe-agent-aci.md`) — they got from 3.8% to 12.47% on SWE-bench by changing nothing about the model and everything about the tool surface. The same lesson appears in Anthropic's tool design guidance: tools should be minimal, unambiguous, and prominent in the context window because they are the agent's primary execution primitives (`anthropic-context-engineering.md`).

**2. Context is a finite resource and the discipline is subtraction, not addition.** Anthropic frames it as an "attention budget" subject to "context rot" — performance degrades as you stuff more in (`anthropic-context-engineering.md`). The repeated mantra: "find the smallest set of high-signal tokens." Aider's repomap exists for this reason — instead of dumping the whole codebase, it serves a compressed tree-sitter map of class/function signatures (`aider-repomap.md`).

**3. Long-horizon work needs structured state outside the context window.** Anthropic's long-running harness post is the clearest articulation: an `init.sh`, a `claude-progress.txt`, a `feature_list.json`, and git commits, all of which let a fresh agent pick up where the last one left off (`anthropic-long-running-harnesses.md`). The Pokemon-playing agent and Claude Code's `CLAUDE.md` are the same idea: persistent notes keep the loop coherent across many context windows.

**4. Splitting reasoning from execution beats one-shot.** Aider's Architect/Editor pattern: a strong reasoning model proposes the change in prose, a cheaper editor model translates that into precise edit operations. SOTA on their bench (`aider-architect-pattern.md`). Anthropic's multi-agent research system is the same shape at larger scale: a lead agent plans, parallel sub-agents execute, lead synthesizes (`anthropic-multi-agent-research-system.md`).

**5. Verification has to be in the loop, not after.** SWE-agent runs a linter on every edit and rejects syntactically broken code at the tool layer (`swe-agent-aci.md`). Cursor's shadow workspace is the same idea — a hidden window that lets the agent see lints, run code, and iterate *before* committing (`sources/cursor-design-notes.md`). Anthropic's long-running harness mandates a Puppeteer browser test at the end of every feature, with explicit "it is unacceptable to remove or edit tests" (`anthropic-long-running-harnesses.md`).

Everything else is application of these five.

---

## Tool design — applied to video

The single most important takeaway from SWE-agent is that **the tool surface IS the product for the agent.** The model is downstream of what you let it do.

Translating to video:

A tool like `cut(clip_id, time)` works. A tool like `edit_video({operation: 'cut', target: ..., parameters: {...}})` does not — too many degrees of freedom, too easy to misuse. SWE-agent's lesson is that operations should be consolidated into as few high-level actions as possible, each with unambiguous semantics. Look at the `aider-edit-formats.md` — Aider supports five edit formats because different models prefer different shapes, and getting the format right is worth percentage points. Your video harness will have the same dynamic: there is a *correct* shape for `cut`, `trim`, `add_overlay`, `move_clip` that the model handles best, and finding it is empirical.

Three concrete mappings:

**Linter on edit.** SWE-agent rejects edits that don't parse. The video equivalent is OTIO validation — every command that mutates the timeline must produce a valid OTIO project, or it gets rejected before commit. Already true in spirit of the existing macOS app's `EditorIntent → Command → Execute` pattern (per `CLAUDE.md`). Lift this into the harness explicitly: invalid edits never land.

**Succinct, model-friendly output.** SWE-agent's grep was originally returning too much context per match and confusing the model. They simplified to a flat list. Apply this everywhere: when the agent calls `find_moment("when she laughs")`, return `[{time: 234.5, confidence: 0.82, transcript: "..."}, ...]` — not a sprawling object with audio waveforms and frame thumbnails embedded.

**Useful errors and nudges.** SWE-agent injects "your command produced no output" as a deliberate prompt to the model. Same pattern: when `render_preview(range)` produces a black frame, the harness should *say* "render produced black frames — likely a missing media reference at clip_id X." Errors are part of the agent's training surface every turn.

---

## Context management — applied to footage

The codebase is to coding-agent as the raw footage is to video-agent. Both don't fit in context. Both need a compression step. Both need just-in-time retrieval.

**Footage is the codebase. The metadata is the repomap.** Aider builds a tree-sitter repomap because the full codebase is too large; they hand the model a compressed signature index instead. The video equivalent is what the existing app already calls the transcript + analysis pass: transcribe, diarize, detect shots, score energy, segment topics. The agent then navigates this metadata. Pixels are loaded only when the agent specifically asks ("show me frame at 4:23"). Anthropic calls this "just-in-time retrieval" and explicitly recommends it over up-front loading (`anthropic-context-engineering.md`).

**Sub-agents return distilled summaries.** The Anthropic context post recommends spawning sub-agents that explore some bounded thing and return 1-2k tokens of distillation. The video application is direct: a sub-agent watches a 5-minute segment, returns "speaker mentions Stripe at 2:34, gets visibly excited at 4:12, dead air from 1:17–1:24." The orchestrator never sees the raw segment — only the summary.

**Compaction for long sessions.** The Anthropic context post describes summarizing prior turns to keep the session viable. For a 4-hour podcast edit, the agent will burn through its window long before finishing. Compaction means: at session boundaries, summarize "what edits have been made and why" into a structured log the next session reads. This is what `claude-progress.txt` does in the long-running harness (`anthropic-long-running-harnesses.md`).

---

## Architecture patterns

Five patterns appear repeatedly. All five have video applications.

**Architect / Editor (Aider).** The reasoning model decides "we should remove the dead air from 1:17–1:24, then cut on the laugh at 2:34, then insert b-roll for the city skyline reference"; the editor model translates that to OTIO operations. Two practical wins: the architect can use a smarter, slower model without paying for it on every operation; the editor's prompts can be aggressively narrow ("here's an OTIO clip and a directive — produce the operation"). See `aider-architect-pattern.md`.

**Lead + parallel sub-agents (Anthropic Research).** When a podcast has 90 minutes of footage from three cameras, you don't process it sequentially. Spawn sub-agents per camera or per scene; each returns a summary; the lead assembles. This is the architectural answer to "how do you understand a six-hour documentary." See `anthropic-multi-agent-research-system.md`. Be careful with state — sub-agents shouldn't be able to mutate the timeline directly, only return proposals to the lead.

**Initializer + worker (Anthropic long-running).** The initializer agent runs once on a new project: ingests footage, builds the index, transcribes, identifies arc/structure, writes a `progress.json` with all the planned features ("episode 1, segments A–G, 12 cuts identified, 3 b-roll spots needed"). Subsequent workers do one feature at a time, update the progress file, and commit. This is what makes the loop survivable across many sessions. The exact same shape applies to a multi-pass video edit. See `anthropic-long-running-harnesses.md`.

**Workflow vs. agent (Anthropic effective agents).** The most important taxonomic distinction in `anthropic-building-effective-agents.md`: don't reach for an agent loop when a deterministic workflow does the job. For the "remove all dead air > 0.5s" pass, no agent needed — that's a deterministic ffmpeg invocation. The agent loop earns its keep on the editorial decisions: which 30 seconds become the trailer, which b-roll fits the moment, where the cut should land. Reserve the agent for what only judgment can do.

**Shadow workspace (Cursor).** A hidden parallel environment where the agent can render previews, sample frames, run validators — without touching the user's view. Already implicit in the macOS app's preview model; should be explicit in the harness. See `cursor-design-notes.md`.

---

## Long-horizon work — applied to episode production

Anthropic's long-running harness post is the closest direct analog to what producing an episode looks like. The shape transfers almost line-for-line:

| Long-running coding | Long-running video editing |
| --- | --- |
| `init.sh` sets up environment | Initializer pass: ingest, transcribe, index, scene-detect |
| `claude-progress.txt` tracks state in prose | `episode-notes.md` — agent's running editorial reasoning |
| `feature_list.json` — JSON list of features (200+) marked failing/passing | `edit-plan.json` — list of planned cuts/inserts/transitions with status |
| Git commits per feature | Git commits per editorial decision (project format must be diffable) |
| Puppeteer browser test verifies feature | Render preview + sample-frame check + transcript-against-cut verify |
| "It is unacceptable to remove or edit tests" | "It is unacceptable to discard the editorial brief" |

Why JSON beat Markdown for the feature list (per `anthropic-long-running-harnesses.md`): the model is less likely to overwrite a JSON file with structured fields than a Markdown one with prose. Direct application to the edit plan: keep the structural state in JSON, keep the reasoning in Markdown.

The two failure modes Anthropic identifies are worth quoting because they apply to any agent-driven creative pipeline: trying to one-shot the whole thing, and prematurely declaring victory. For a video harness, both translate exactly. Don't let the agent "produce the whole episode" in one go; force it through the feature loop. Don't let it mark a feature done without producing a render and verifying.

---

## Verification — the hardest open problem for video

Coding has tests. Video has taste. This is the gap the coding-harness literature can't close for you, but it does point at the right shape:

**Make verification a first-class loop step.** The Anthropic long-running post mandates a Puppeteer test per feature. The video equivalent is a render-preview-and-check step that can't be skipped. What the agent looks at: the render produced; transcript matches expected segments; cut points are within 200ms of marked beats; no orphaned media references; OTIO validates.

**Stack cheap-to-expensive.** SWE-agent's pattern is linter (cheap) → unit test (medium) → full suite (expensive). For video: OTIO validation (cheap) → proxy render (medium) → full render (expensive) → human taste sign-off (expensive and slow). Run cheap things every operation; gate expensive things behind milestones.

**The human IS part of the verification loop.** Don't pretend it isn't. The GUI viewer is where the human signs off on taste. The harness must produce a *reviewable artifact* at the end of each session — a diff of what changed, the reasoning, a render to watch. Same loop a code reviewer runs on a PR.

---

## Skills — applied to video workflow types

Anthropic's Agent Skills format is the cleanest model for packaging editorial intent. A skill is a folder with a `SKILL.md` (YAML frontmatter `name` + `description` + body) and bundled files. The progressive disclosure design is the magic:

- Level 1: `name` and `description` go into the system prompt always (cheap)
- Level 2: full `SKILL.md` loaded only when relevant (the model decides)
- Level 3: bundled files and scripts loaded on demand

Direct video application: ship skills like `podcast-episode-producer` (already exists in the project per `CLAUDE.md`), `interview-tightener`, `trailer-cutter`, `documentary-arc`, `b-roll-suggester`. Each one is a folder with prose describing the editorial pattern + maybe a deterministic script for the mechanical bits.

Critical detail from `anthropic-agent-skills.md`: skills can ship Python code that the agent calls when code is more reliable than reasoning (the example given is PDF form extraction). The video version: the `b-roll-suggester` skill can ship a Python script that does the embedding-based search; the model uses the script's output rather than trying to do the matching in its head.

The framework also gives you a clean answer to extensibility: third parties (or your power users) write new skills, drop them in a folder, the agent discovers them. This is the open ecosystem version of "tool the agent calls."

---

## Project format and state — applied to OTIO

A few load-bearing lessons:

**The project file is the source of truth.** Cursor builds a shadow workspace because the file system is the truth. Aider's edit formats all assume the file is canonical. For video, the OTIO file (or your superset) is the source of truth — every command mutates it, every reader reads it. The GUI is a view on the OTIO; the agent's reasoning is metadata alongside it.

**Make agent reasoning a first-class artifact.** Anthropic's long-running harness writes `claude-progress.txt` deliberately so the next session can read what the previous one was thinking. The video equivalent is `episode-notes.md` (prose: "I tightened the intro by removing dead air at 0:17–0:24 because Tadiwa explicitly said keep the energy high in the first minute") alongside the structured `edit-plan.json` (machine-readable: list of operations with status).

**Diffability is the unfair advantage.** Code review works because diffs work. Video review usually doesn't work because there's no diff. If your project format is text and Git-friendly, every edit pass becomes a reviewable PR. The human can see "the agent removed clip 7, shortened clip 12 by 8 frames, inserted b-roll at 2:34" — exactly the way they'd review code. This is something Descript and Resound structurally cannot do because their state isn't text.

**JSON for state Claude shouldn't overwrite. Markdown for state Claude updates.** Direct translation of Anthropic's lesson. `edit-plan.json` is the edit plan; the agent updates status fields. `episode-notes.md` is the reasoning; the agent appends. Don't mix them.

---

## What the coding harnesses got wrong (so we don't repeat)

Reading between the lines:

**Tool surfaces sprawl.** Every harness eventually accumulates 30+ tools because each new use case feels like it needs one. Cursor, Aider, Claude Code, OpenHands all show some version of this. Discipline early: every tool should justify its existence by being un-substitutable in the agent loop. New use case? First ask if existing tools compose. SWE-agent is the cautionary tale in the other direction — they kept tools small and got SOTA results from it.

**Shadow workspaces are expensive to maintain.** Cursor's shadow workspace was a clever idea that turned into a CPU hog and got partly rolled back as their retrieval improved (`cursor-design-notes.md`). Lesson: hidden parallel environments are right when verification is local and fast (lints), wrong when verification is expensive (renders). Don't try to render-in-shadow on every edit; render at milestones.

**The "framework" trap.** From `anthropic-building-effective-agents.md`: "the most successful implementations weren't using complex frameworks." Translation: don't build LangChain-for-video. Build the smallest set of primitives that compose. The harness is glue, not infrastructure.

**Tests-as-cargo-cult.** The long-running harness explicitly warns against agents that delete tests to make CI pass. The video version: don't let the agent achieve "good cuts metric" by lowering the bar for what counts as a cut. Verification must be adversarial; the agent shouldn't be allowed to grade its own homework. This is hard for video specifically because "did this cut land well" doesn't have a clean test, which makes it doubly important.

---

## Open questions specific to video that the coding literature doesn't answer

1. **Verification of taste.** Coding has unambiguous truth conditions. Video has taste. The literature gives us the loop shape but not the metric. We will have to invent it — probably some combination of transcript-against-cut checks, beat detection, energy curves, and a critic-LLM that watches the render.

2. **Render economics.** Compilation is fast; renders are slow. The harness loop has to assume verification is expensive and design for it (proxies, milestone-based renders, render caching keyed by command hash).

3. **The medium isn't text.** Code is in the model's native medium; video isn't. Transcripts and metadata are the bridge — the agent navigates through descriptions of pixels, not pixels themselves. This is fine but means the metadata index quality is the rate-limiting step on agent quality. Investing there is investing in the agent's IQ.

4. **Sub-agent boundaries are different.** A coding sub-agent can run an entire test suite in seconds. A video sub-agent watching a 5-minute segment is a meaningful chunk of compute. The right granularity for "spawn a sub-agent" is empirically different — probably scene-level or topic-segment-level, not clip-level.

5. **Skills for editorial style.** A skill can teach the agent "this is how to refactor a React component." Can a skill teach "this is how to edit like Joe Rogan's editor vs. like Lex Fridman's editor"? The Skills format is right; the content is the open research question.

---

## Reading order

If you're in a hurry, the highest-leverage four:

1. `sources/anthropic-context-engineering.md` — the foundational frame
2. `sources/anthropic-long-running-harnesses.md` — the closest direct shape match for episode production
3. `sources/aider-architect-pattern.md` — the cleanest two-model split
4. `sources/swe-agent-aci.md` — short, sharp, makes the case that interface > model

Then `sources/anthropic-agent-skills.md` for the extensibility model and `sources/anthropic-building-effective-agents.md` for the workflow-vs-agent taxonomy.

Cursor and OpenHands are useful for context but less directly applicable.
