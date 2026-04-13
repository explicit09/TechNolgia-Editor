---
name: meeting-highlights
description: Create executive summaries from meeting recordings. Uses audio energy to skip dead zones, identifies decisions and action items from transcript, removes small talk and technical issues. Verifies output quality. Use when the user asks about meeting highlights, summary, executive summary, action items, decisions, minutes, key moments, recap, meeting notes, or important parts.
allowed-tools: analyze_audio_energy get_transcript transcribe_asset search_transcript split_clip trim_clip move_clip delete_clips set_marker rename_clip measure_loudness set_clip_speed set_clip_transition verify_playback get_state
---

# Meeting Highlights Editor

You create concise, actionable summaries from meeting recordings. Every second in the output earns its place.

## Understanding Your Audience: Context Before Editing

Meeting summaries compress differently depending on who receives them.

**Executive summary (C-suite, 5 minutes):**
- Decisions: 50% (tight, action-focused)
- Key risk/blocker: 20%
- Action items: 30%
- Context: minimal (assume domain knowledge)

**Team summary (direct reports, 7-8 minutes):**
- Context: 15% (why was this discussed?)
- Decisions: 40%
- Action items & ownership: 35%
- Discussions that led to decisions: 10% (credibility)

**Async summary (cross-functional teams, 10 minutes):**
- Context: 20% (new context is valuable)
- Decisions with reasoning: 40%
- Action items with impact: 30%
- Open questions/risks: 10%

Before starting analysis, confirm your audience. This determines whether you cut aggressively for brevity or preserve more discussion for context and buy-in.

## Step 0: Audio energy scan — find where real discussion happens

Meetings are mostly dead air, setup, and filler. Find the real content first:

1. `analyze_audio_energy` with `segments: 20-30`
2. Dead zones (score < 30): likely "can you hear me?", waiting for people, screen share fumbles
3. Hot zones (score > 55): active discussion, debates, decisions being made
4. This map tells you where to focus. Don't waste time cleaning dead zones — cut them entirely.

## Step 1: Transcribe and classify

1. `transcribe_asset` if needed
2. `get_transcript`
3. Search for key patterns using `search_transcript`:

**Decisions (KEEP — HIGH):**
"decided", "agreed", "going with", "approved", "consensus", "final answer", "let's go with"

**Action items (KEEP — HIGH):**
"I will", "action item", "next step", "by Friday", "deadline", "follow up", "responsible"

**Risks/blockers (KEEP — MEDIUM):**
"concern", "risk", "blocker", "worried", "issue", "problem", "delayed"

**Cut entirely:**
"can you hear me", "you're on mute", "let me share", "one second", "how's everyone", "good morning"

## Step 1.5: Map the narrative arc

Meetings have an implicit story: problem → discussion → decision → action.
Preserve this arc even in compression:

1. **Context opener:** Why are we here? (3-5 sentence context from opening)
2. **Decision cluster:** What did we agree on? (Group decisions by topic)
3. **Action cluster:** What happens next? (Who does what by when)
4. **Tension and payoff:** Lead with the decision or action that carries most weight

**Critical:** Do not jump from problem statement directly to action item—include the discussion that led to the decision. This provides reasoning and credibility. Compress the discussion, but don't erase it.

Example narrative flow:
- "We discussed three vendor options for Q2 (problem/discussion, 20 seconds)"
- "Decided to move forward with vendor B due to timeline and cost (decision, 15 seconds)"
- "Sarah owns implementation; first checkpoint Friday (action, 10 seconds)"

Intercut discussion with decision, not after. This maintains the reasoning chain.

## Step 2: Build the summary

Target: 5-minute summary from a 1-hour meeting (12:1 compression).

Budget:
- Decisions: 40% (120s)
- Action items: 30% (90s)
- Key discussions: 20% (60s)
- Opening context: 10% (30s)

Cross-reference: only keep segments that are BOTH high-energy (audio score > 45) AND contain decisions/actions (transcript search).

## Step 2.5: Strategic pacing for compressed narrative

Compression without rhythm feels rushed. Use variable pacing to guide attention:

**Speed variation strategy:**
- **Decisions:** 1.0x (normal speed, maximum clarity)
- **Action items:** 1.0x (ownership and deadlines must be clear)
- **Background discussion:** 1.05-1.1x (faster to compress while maintaining coherence)
- **Context opener:** 0.95-1.0x (slightly slower to establish setup)

**Intentional silence (0.5-1.2 seconds):**
- Insert after each decision cluster (signals topic shift)
- Insert before action items (prepares listener for specifics)
- Never remove all silence within a segment—preserve natural speaker breathing

**Transition cues:**
- Use `crossDissolve` (0.3s) between different speakers or topics within a cluster
- Use `none` (hard cut) only within a single decision or action statement
- Position transitions at energy shifts (speaker changes, topic changes)

This creates rhythm that guides the listener through the narrative without feeling rushed.

## Step 3: Edit

1. `split_clip` at each segment boundary
2. `rename_clip` with classification: "DECISION: pricing", "ACTION: John deploys Friday"
3. `delete_clips` all cut-classified segments
4. `trim_clip` each kept segment to sentence boundaries (0.3s padding)
5. Remove internal silence > 1.5s within kept segments
6. `set_marker` at each decision and action item
7. `set_clip_transition` with `crossDissolve` (0.3s) between segments from different meeting sections
8. Slight speed up if speakers are slow: `set_clip_speed` 1.05-1.1x

## Step 4: Mandatory verification

1. `verify_playback` mode "quick":
   - Audio at all checkpoints
   - Duration within 10% of target (4:30-5:30 for 5-min target)

2. `analyze_audio_energy` on the output:
   - Speech ratio should be > 80% (tight content, no dead air)
   - Engagement score should be > 60

3. **Narrative structure verification:**
   - Does the summary follow a clear arc: context → decision(s) → action(s)?
   - Is each decision preceded by at least 5-10 seconds of supporting discussion or reasoning?
   - Are action items isolated with clear ownership (name + task + deadline)?
   - Do pacing changes align with topic shifts? (Context is calm, decisions clear, actions crisp)

4. **Compression integrity check:**
   - Play back at normal speed. Does it feel coherent, not rushed?
   - Are there 0.5-1.2 second pauses between clusters? (Check with `get_state` markers)
   - Does the audience understand *why* each decision was made, not just *what* was decided?
   - Can a first-time listener identify 3-4 key action items and owners?

5. `get_state`:
   - Every decision/action item has a marker
   - Clips are named with classifications
   - Speed shows on both V+A tracks with strategic variation (decisions/actions at 1.0x)
   - Intentional pauses between clusters (0.5-1.2s)
   - No gaps between segments within clusters

If narrative arc is unclear or decisions lack supporting context, add back 10-15 seconds of discussion
rather than cutting further.

**Never tell the user the summary is ready without verification.**

## Available transitions (only these exist)

- `none` — hard cut (between consecutive segments)
- `crossDissolve` — soft blend (between segments from different meeting sections)
- `fadeToBlack` / `fadeFromBlack` — opening/closing
- `wipeLeft` / `wipeRight` — visible transition

## What NOT to do

- Never include "can you hear me?" segments
- Never cut a decision without enough context
- Never leave action items without identifying who owns them
- Never create a summary longer than 20% of the original
- Never skip audio energy scan — meetings have massive dead zones that waste editing time
- Never report done without verify_playback
