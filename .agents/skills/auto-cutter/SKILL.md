---
name: auto-cutter
description: Extract and clean podcast episodes from long recordings. Transcript-first analysis, then mechanical cleanup. Handles multi-episode recordings, rehearsals, false starts. Use when the user asks about auto cut, clean up, remove fillers, tighten, one click edit, auto edit, clean edit, polish, remove ums, remove silence, clean audio, tighten pacing, extract episode, podcast editing, or make episode.
allowed-tools: analyze_transcript get_full_transcript auto_cut get_state get_transcript transcribe_asset search_transcript score_content verify_playback trim_clip add_to_timeline clear_project
---

# Auto-Cutter: Episode Extraction & Cleanup

## CRITICAL: The Correct Order

**NEVER run auto_cut on a raw recording.** Always extract the episode first.

```
1. analyze_transcript → understand what's in the recording
2. Trim to episode boundaries → extract just the episode
3. auto_cut → mechanical cleanup (silence, fillers)
4. Review the result → verify it starts clean
```

## Step 1: Understand the Content (analyze_transcript)

Call `analyze_transcript` with the asset_id. This sends the FULL transcript to Claude, which reads everything and identifies:
- How many real episodes exist
- Exact start/end timestamps for each
- What's pre-show conversation vs actual content
- Where rehearsals and false starts are

**A real episode** develops a topic for an audience over 10+ minutes. An intro tagline ("Welcome to X") does NOT make something an episode — the content after it must actually deliver value. If they say "Welcome to Technologer" and then talk about their own YouTube views, that's pre-show chat, not an episode.

## Step 2: Extract the Episode (trim_clip)

Use Claude's timestamps to trim to the FINAL good take of the intro, not the first attempt. If Claude says there are rehearsals at 112:43 and 112:50, and the clean take is at 114:32 — start at 114:32.

```
1. clear_project
2. add_to_timeline with the asset
3. trim_clip to the episode boundaries from Step 1
```

Do NOT include rehearsals and hope auto_cut catches them. It can't.

## Step 3: Clean Up (auto_cut)

Now run `auto_cut` on the extracted episode. It handles:
- Silence removal (>0.8s for standard preset)
- Filler word removal (um, uh, er, ah, hmm)
- Basic retake detection (consecutive similar sentences)

Three presets:
| Preset | Best for | Silence Threshold | Breathing Room Strategy |
|--------|----------|-------------------|------------------------|
| gentle | Interviews, tutorials, conversations | >1.0s | Preserves 0.5-1.0s pauses for contemplation; respects natural speaker rhythm |
| standard | Podcasts, vlogs, general content | >0.8s | Removes dead air while maintaining natural conversational pauses; balances tightness with authenticity |
| aggressive | Social clips, shorts, high-energy content | >0.4s | Tight pacing for momentum; removes nearly all silence except dramatic pauses (0.8s max) |

**Key principle:** Silence below the threshold is evaluated in context — if it feels intentional (after a statement, before a punchline), it may be preserved regardless of duration.

### Choosing Your Preset: Content Type Guide

- **Gentle:** Use for interviews, tutorials, conversations, and any content where natural breathing room matters. Speakers need space to think and respond. Preserves pauses that show contemplation.

- **Standard:** Default for podcasts, vlogs, and mixed-speech content. Removes obvious dead time and harsh silence while maintaining the authentic feel of conversation. Plan for ~15-20% duration reduction.

- **Aggressive:** Use for social media clips, shorts, reels, and high-energy content. Momentum is the priority. Removes nearly all silence and tightens pacing for viewer retention. Plan for ~20-30% duration reduction.

**Rule of thumb:** If you'd watch the content on Instagram or TikTok, use aggressive. If it's long-form and audience should feel heard, use gentle or standard.

### Filler Word Removal Strategy

**Always removed:** um, uh, er, ah, hmm
These contribute nothing to meaning or authenticity; removal is always better.

**Conditionally removed:** like, you know, basically
These words are tied to speaker style and natural cadence. The review pass checks whether removing them creates robotic dialogue or whether they genuinely interrupt flow. Some speakers naturally say "like" every few words; removing all instances makes them sound artificial.

**Recommendation:** Let the review pass evaluate conditional fillers in context. If the transcript reads naturally without them, they're removed. If removal makes dialogue sound choppy or unnatural, they're preserved.

auto_cut includes a Claude review pass that reads the result transcript and checks if the start is clean. If it finds remaining issues, it trims automatically.

### What the Review Pass Checks

After mechanical cleanup, Claude reviews the result transcript and checks for:

1. **Jarring silence removals** — Were natural pauses between statements preserved? Or does speech run together without breathing room?
2. **Dead air at the start** — Does the intro begin with actual content, or is there remaining silence/false start/intro fumbling?
3. **Overaggressive filler removal** — Do remaining fillers (um, uh) feel natural, or was dialogue stripped to the point of sounding robotic?
4. **Missed false starts** — Are there still obvious retakes or multiple intro attempts that should have been caught?
5. **Conditional fillers in context** — Words like "like", "you know", "basically" may remain if they're tied to the speaker's natural style; the review pass confirms they enhance rather than detract.
6. **Pacing rhythm** — Does the overall flow feel intentional and energetic (not overly compressed) or natural and conversational (not dragging)?

If issues are found, auto_cut trims automatically to fix them.

## Step 4: Verify

After auto_cut completes:
1. Check `get_state` to confirm clip count and duration
2. Use `get_full_transcript` to read the beginning — does it start with the real intro?
3. Take a screenshot to verify video renders

## What NOT to Do

- **Don't run auto_cut on a full 2-hour recording.** Extract the episode first.
- **Don't use energy analysis to find episodes.** Read the transcript. Energy analysis is for AFTER you know the boundaries.
- **Don't trust keyword matching for episode detection.** "Welcome to X" in casual conversation doesn't mean an episode started. Claude understands the difference.
- **Don't include rehearsals in the episode.** Multiple "Welcome to" attempts = rehearsal. Use the LAST one.
- **Don't skip the review pass.** auto_cut is mechanical. Claude catches what it misses.
- **Don't remove all silence in the name of pacing.** The goal is to remove *dead air*, not all pauses. Natural pauses between statements, after questions, and before key points create rhythm and let listeners absorb information. The review pass preserves these. Overly compressed content feels robotic and exhausting.

## Example: Multi-Episode Podcast Recording

A 164-minute recording contains:
- 0:00-56:00 — Pre-show conversation
- 56:23 — "Welcome to Technologer" (FALSE — just a tagline in pre-show)
- 112:43-114:32 — Rehearsal of "Technology Talks" intro (3 attempts)
- 114:32-140:42 — Episode 1: "Feedback & Customer Discovery" (REAL)
- 148:59-159:31 — Episode 2: "Is AI Making People Dumber?" (REAL)

Only `analyze_transcript` (Claude reading the full transcript) correctly identified 2 real episodes. Energy analysis found nothing. Keyword matching found 12 false episodes. Local heuristics scored pre-show chat as "episode content" because it contained tech vocabulary.

**After extraction to 114:32-140:42 (Episode 1):**
- Running time: 26m 10s
- Expected after standard preset auto_cut: ~21-23 minutes (15-20% reduction for dead time, fillers, breathing room adjustment)
- Contains natural pauses between major points (preserved); removes 2-3 second silence gaps (dead air) and filler words
- Result: Tight but authentic podcast rhythm, ready for audio processing

**If using aggressive preset instead:**
- Expected result: ~19-20 minutes
- Silence threshold drops to 0.4s; removes more breathing room
- Better for YouTube shorts/clips extracted from the episode, worse for full podcast release
