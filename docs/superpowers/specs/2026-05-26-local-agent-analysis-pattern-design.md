# Local-Agent Analysis Pattern + Mid-Podcast Chatter Tool

**Date:** 2026-05-26
**Author:** Claude Code (with Explicit)
**Status:** Approved, ready for implementation plan

## Problem

Today, several MCP tools in the editor call the Anthropic Cloud API directly to do content analysis:

- `analyze_transcript` — sends transcript to Claude for episode/structure comprehension
- `find_viral_moments` — sends diarized transcript to Claude for moment ranking
- `extract_clips` — sends transcript to Claude for clip candidates
- `score_content` — Claude scoring
- `hook_optimize` — Claude hook generation
- `generate_title` — Claude title suggestions

This has three problems:

1. **Hard dependency on a working `ANTHROPIC_API_KEY` inside the editor.** When the key expires or rotates, the entire podcast workflow silently breaks (we hit this today with a 401).
2. **Double billing.** The user is already running Claude Code, Codex, Cursor, or the editor's in-app chat — they're paying for an LLM session. Having the editor pay Anthropic for *additional* completions is wasteful.
3. **The editor decides the prompt and reasoning depth.** The driving agent (which knows the user's intent, history, and project context) has no leverage to think harder, retry, or refine. A single-shot Claude completion inside the tool is a black box.

Separately, the `podcast-episode-producer` skill has a real gap: it identifies pre-show chatter and rehearsals well, but doesn't have an explicit step for *in-episode* chatter — host coaching mid-take, abandoned answers, "we might need to scratch that" moments. We discovered this today: the first pass missed ~10 minutes of in-episode chatter that needed cutting.

## Goals

1. Remove the editor's Anthropic API dependency for content analysis. The driving agent does all reasoning.
2. Make mid-episode chatter detection a first-class step in the podcast workflow.
3. Force agents to use extended thinking (ultrathink) before producing analysis.
4. Preserve the in-app chat experience — the in-app agent's Claude session naturally handles the new pattern as a tool result.

## Non-goals

- Refactoring the in-app `AIChatController`'s own Claude binding. It stays cloud-Claude-backed; it just consumes the new tool format like any other agent.
- Removing `ClaudeProvider` entirely. Some tools (e.g., AI thumbnail generation via Gemini/Flux) still need outbound calls and aren't in scope.

## Design

### Pattern: Tools return a "prompt-pack"

A prompt-pack is a structured tool result with three parts:

```
<EXTENDED_THINKING_REQUIRED>
[directive: think deeply before producing the analysis]
</EXTENDED_THINKING_REQUIRED>

[the analysis prompt — the same prompt the editor used to send to Claude]

[data the prompt needs — timestamped transcript, candidate ranges, etc.]
```

The driving agent reads this as a tool result, ultrathinks, produces the analysis, and decides the next action. There is no callback to the editor — analysis happens entirely in the agent's session.

Agent compatibility: `<EXTENDED_THINKING_REQUIRED>` is a documentation convention, not a magic token. Each agent treats it according to its own thinking mechanism — Claude Code uses extended thinking, Codex respects the directive, Cursor reads it as instruction. The directive is opt-in: agents that don't extend-think will still produce a passable answer, just less rigorous.

### Affected tools (refactor)

Verified scope after reading the handlers: only the tools below actually call Claude API. `score_content` uses a local `ContentScorer` (heuristic). `generate_title` uses template strings via `titleSuggestions`. Both are already local and out of scope.

| Tool | Current | After |
|------|---------|-------|
| `analyze_transcript` | Calls Claude API with episode-structure prompt | Returns prompt-pack with same prompt + timestamped transcript |
| `find_viral_moments` | Calls Claude API with diarized transcript | Returns prompt-pack with same prompt + diarized transcript |
| `extract_clips` | Calls Claude API for clip candidates | Returns prompt-pack |
| `hook_optimize` | Calls Claude API for hooks | Returns prompt-pack |

The two-pass refinement in current `analyze_transcript` (which zooms in on each episode start to find the clean take) is REMOVED. The driving agent can re-call `get_transcript_with_timing` on a narrow window if it wants to refine.

`ANTHROPIC_API_KEY` becomes optional in the editor — only needed if the in-app chat is in use.

### New tool: `scan_episode_chatter`

Called AFTER `extract_segment`, on the already-extracted episode clip. Operates on a narrow transcript window, returning a focused prompt-pack for chatter-only detection.

**Input schema:**
```
{
  "clip_id": "string (optional, defaults to first video clip on timeline)",
  "start": "number (optional, default 0)",
  "end": "number (optional, default clip duration)"
}
```

**Output:**
```
<EXTENDED_THINKING_REQUIRED>
Think deeply. Re-read every line of the transcript before producing the cut plan.
</EXTENDED_THINKING_REQUIRED>

You are scanning an already-extracted podcast episode for in-episode chatter that must be cut.
Look for:

1. ABANDONED TAKES — a speaker starts an answer, stops, then restarts.
   Cut from start-of-abandoned to start-of-clean.

2. HOST COACHING — one host coaching the guest mid-flow ("you can say…", "we don't have
   to…"). Cut the coaching, not the surrounding content.

3. PRODUCTION CHATTER — asides about technical issues, "we might need to scratch that",
   "can we redo that", camera switches, mic checks.

4. FALSE STARTS that are NOT followed by a clean version — keep these (they're part of
   natural speech). Only cut a false start if a clean retake exists.

5. AGE / FACT CORRECTIONS that interrupt the answer ("wait, how old were you again?",
   "actually I started at 23, not 25").

6. HOST-TO-HOST ASIDES while the guest is silent ("Elvis, you want to take this?",
   "no, you go").

For EACH cut, output exactly:
  CUT [MM:SS]-[MM:SS]: <one-line reason>

Timestamps are timeline-relative (matching the transcript below).

Be conservative — only cut things clearly chatter. A 1-second laugh, a brief "yeah",
or a natural pause should stay. Do not cut content that, while imperfect, is part of
the conversational beat.

After listing all cuts, output:
  TOTAL CUT TIME: <seconds>
  EXPECTED FINAL DURATION: <original_duration - total_cut>

Here is the timestamped transcript:

[transcript content, sentence-grouped]
```

The agent reads this, ultrathinks, returns a list of CUT lines, then translates them to
`split_clip` + `ripple_delete` calls.

### Skill update: `podcast-episode-producer`

Updated steps:

- **Step 1 — Analyze transcript:** "Call `analyze_transcript`. It returns a prompt for you to analyze. Ultrathink, then output the episode boundaries."
- **Step 2 — Extract:** unchanged
- **Step 2.5 — Second pass:** "Call `analyze_transcript` again on the extracted clip's transcript via `get_transcript_with_timing`. Refines topic + narrative arc."
- **NEW Step 2.6 — Mid-episode chatter scan:** "Call `scan_episode_chatter` on the extracted episode. Ultrathink through the returned prompt. Produce a cut list. Apply via split_clip + ripple_delete in latest-to-earliest order."
- **Step 2.75 — Hook strategy:** unchanged
- **Step 3-7:** unchanged

Mirror to `.agents/skills/podcast-episode-producer/SKILL.md`.

### In-app agent

No code change. The in-app `AIChatController`'s Claude session reads the prompt-pack as a tool result and produces the analysis within its existing API session.

#### When `ANTHROPIC_API_KEY` is required

| User setup | Editor needs `ANTHROPIC_API_KEY`? | Where analysis runs |
|---|---|---|
| **External agent** (Claude Code, Codex, Cursor) drives the editor via MCP | No | External agent's seat |
| **In-app chat panel** drives the editor | **Yes** — the chat panel itself is a Claude API session | In-app chat's Claude turn |
| No agent — user hand-drives the editor | No | No AI analysis at all; only mechanical tools (cuts, exports, overlays) |

The key only stops being required when there's no in-app chat session in play. The MCP tools themselves never call Anthropic in any scenario after this refactor.

### Migration / compatibility

- Existing callers that read tool output as text still work (output is still text — just a prompt-pack now instead of a finished analysis).
- Anyone with automation that *parsed* the structured Claude output (e.g., regex `EPISODE 1: Start: [MM:SS]`) will need updating. The structure is preserved — the agent still produces output in the same format, just in its own turn rather than embedded in the tool result. Downstream tools that the agent calls (e.g., `extract_segment`) take raw numbers, not Claude output, so they're unaffected.
- The two-pass refinement in `analyze_transcript` is removed. Agents wanting refined timestamps call `get_transcript_with_timing` with a narrow window.

## Implementation order

1. Add `scan_episode_chatter` (new tool, no risk to existing flows). Wire it into the skill.
2. Refactor `analyze_transcript` to return a prompt-pack. Verify the skill flow works end-to-end with Claude Code.
3. Refactor the other 5 tools.
4. Remove `ClaudeProvider` calls from MCPServer.swift for those tools (keep `ClaudeProvider` itself; AIChatController still uses it).
5. Update CLAUDE.md to mark `ANTHROPIC_API_KEY` as optional (in-app chat only).

Each step is independently shippable.

## Open questions

None.
