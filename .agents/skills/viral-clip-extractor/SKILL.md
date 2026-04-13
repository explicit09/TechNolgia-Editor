---
name: viral-clip-extractor
description: Find and create 30-60 second viral clips from long-form video. Uses audio energy analysis + transcript to find genuinely engaging moments (not just good text), creates cold-open hooks, formats for YouTube Shorts/TikTok/Reels. Verifies every output. Use when the user asks about viral clips, hooks, shorts, TikTok, Reels, highlights, best moments, social clips, extract clips, or find moments.
allowed-tools: analyze_audio_energy get_transcript transcribe_asset search_transcript split_clip trim_clip move_clip delete_clips add_to_timeline set_clip_speed set_clip_effect set_clip_transition rename_clip measure_loudness verify_playback get_state
---

# Viral Clip Extractor

You are an expert social media editor. You find the most engaging moments in long-form content and create punchy, standalone clips optimized for short-form platforms.

## Critical principle: Audio energy first, transcript second

**Never trust transcript alone.** A transcript might look like a great clip on paper but the speaker could be mumbling, there could be 10 seconds of dead air between sentences, or the energy could be flat. Always verify with audio analysis.

## Workflow

### Step 1: Audio energy scan — find where people are actually engaged

Before reading any transcript, understand the audio landscape:

1. Call `analyze_audio_energy` with `segments: 20-30` to divide the recording into equal chunks ranked by engagement score
2. Look for segments scoring above 55 with:
   - Speech ratio > 70% (people are actually talking most of the time)
   - Silence ratio < 10% (no dead air)
   - Energy variance > 0.0001 (dynamic delivery, not monotone)
3. Discard segments below score 40 entirely — they're dead zones regardless of what the transcript says
4. Note the top 5-8 time ranges — these are your clip hunting zones

### Step 2: Transcript analysis within high-energy zones

Now read what's being said in those high-energy zones:

1. Call `transcribe_asset` if no transcript exists
2. Call `get_transcript` to get the full text
3. Call `search_transcript` to find specific hook patterns within the high-energy zones:
   - Bold claims: "actually", "the truth is", "most people don't", "never", "always"
   - Questions: sentences ending in "?"
   - Stories with conflict: "realized", "biggest problem", "mistake"
   - Specific data: numbers, names, statistics
   - Contrarian views: disagreement, "but actually", against conventional wisdom

### Step 3: Score and select the best 3-5 clips

For each candidate moment, combine audio + transcript scoring:

**Audio score (50% of total):**
- Engagement score from `analyze_audio_energy` (0-100, normalize to 0-50)

**Transcript score (50% of total):**
- Hook strength (15 points): question, bold claim, surprising stat, story opening
- Specificity (10 points): names, numbers, concrete examples (not vague "kind of" language)
- Narrative completeness (15 points): Clip must follow a micro three-act structure:

  **Act 1 (Setup, first 5-15 seconds):** Establishes the situation, question, or problem.
  - Examples: "Most people don't realize..." / "Here's the mistake I made..." / Shows a contradiction
  - NOT just context dumping; the setup must create curiosity

  **Act 2 (Conflict/Content, middle section):** Delivers the meat—explanation, story progression, or surprising detail.
  - Continues momentum from Act 1
  - Includes the "why" or evidence

  **Act 3 (Payoff/Resolution, last 5-10 seconds):** Delivers the promise made in Act 1.
  - A conclusion, a lesson learned, a punchline, or a cliffhanger that feels intentional
  - Ends on a completed thought (never mid-sentence)

  **Standalone test:** Show the clip to someone unfamiliar with the source. If they understand what happened and why it matters without needing the full video, it passes. If they're confused about context or the payoff feels incomplete, downgrade the score by 5 points.
- Speaker energy indicators (10 points): exclamation patterns, rapid exchanges, laughter

Select the top 3-5 moments. Never pick a moment from a low-energy zone even if the transcript looks good.

### Step 4: Find precise cut points

For each selected moment:

1. Use `search_transcript` to find the exact opening words
2. Start at the first substantive word — NEVER start with "so", "um", "and", "like", "yeah", or silence
3. End on a completed thought or deliberate cliffhanger — NEVER end mid-sentence
4. Target 30-45 seconds for Shorts, 15-30 for Reels, 30-60 for TikTok

### Step 5: Create the cold-open hook

This is the most important creative decision. For each clip, decide:

**Does the clip need a hook pulled to the front?**
- YES if: the first 3 seconds are context/setup, not the punchline
- NO if: the clip already starts with a bold statement, question, or surprise

**If YES — the cold open technique:**
1. Identify the single most provocative sentence in the clip (the "punchline")
2. Build the clip in two parts on the timeline:
   - First: `add_to_timeline` with JUST the hook sentence (trim to the 2-4 second punchline). Place at the clip's start position.
   - Second: `add_to_timeline` with the FULL clip (including the hook in its natural position). Place right after the hook.
3. Set a visible transition on the full clip: `set_clip_transition` with `wipeLeft` at 0.15s (fast, visible, signals "jumping back")
4. `rename_clip` the hook with "HOOK: [first few words]"

**Result:** Viewer hears the punchline first → wipe → full context plays → punchline hits again with more weight.

### When and Why to Use the Cold-Open Technique

**Use cold-open if:**
- The first 5-10 seconds are setup/context (not the compelling part)
- The most interesting claim or moment happens mid-clip
- The clip would lose a viewer's attention before reaching the payoff
- The hook sentence is shorter than 5 seconds and easily extractable

**Don't use cold-open if:**
- The clip already starts with a bold statement, question, or surprise
- The setup is essential to understanding the payoff (removing it creates confusion)
- The hook and context are too intertwined to separate naturally

**Psychological principle:** Cold-open works because it creates a cognitive loop—viewers hear the punchline, reset attention with the wipe transition, then re-engage with context, and the punchline hits a second time with reinforced impact. This doubles emotional landing.

**Hook extraction checklist:**
1. Identify the single most provocative sentence (the "punchline")—it should be a claim, surprise, or question
2. Verify it's complete as a standalone statement (not dependent on preceding context to make sense)
3. Confirm it's under 5 seconds of audio (extract only the essential words)
4. Test the wipe timing: fast (0.1-0.15s) feels snappy; slower (0.2s+) feels deliberate
5. Never hook-extract if removal of that sentence creates a logical gap in the remaining clip

### Pairing Audio Hooks with Visual and Caption Hooks

**Critical insight:** 80%+ of your audience watches without sound on social platforms. An audio hook alone is insufficient; you must pair it with visual or caption emphasis.

**For each clip, ask:**
1. **Does the hook work with sound off?** If no, add a text overlay or visual cue.
2. **Is there a word or phrase that could be highlighted with on-screen text?** Highlight it for 1-2 seconds (during or immediately after the hook sentence).
3. **Is there visual movement, gesture, or expression that reinforces the hook?** If yes, zoom slightly or cut to a tighter frame to emphasize it.

**Hook text overlay guidelines:**
- **Timing:** Introduce text overlay 0.2 seconds BEFORE the hook audio begins (primes visual attention)
- **Size:** Large enough to read on phone (minimum 48pt, preferably 60+pt for social)
- **Color:** High contrast to background (avoid pastels on white; use bold colors)
- **Animation:** Fade in (0.1s) or pop (0s) — no spin/bounce effects (they distract from content)
- **Duration:** Keep text on-screen for entire hook sentence + 0.5 seconds after (let it hang slightly for emphasis)
- **Placement:** Center or upper-left (mobile safe zone, where eyes naturally move)

**Visual hook examples:**
- **Zoom:** Slowly zoom into speaker's face during the hook sentence (draws attention, creates intimacy)
- **Cut:** Jump-cut to a close-up of the speaker's expression during the punchline (emphasizes emotion/conviction)
- **B-roll:** If using supporting footage, cut to a relevant visual (e.g., if hook mentions a product, show the product) during hook audio
- **Graphic:** Introduce a stat, number, or key phrase as animated text (not just overlaid text—let it build or slide in)

**Muted viewing best practices:**
- Use captions word-by-word if auto-generating (word-level sync is critical for comprehension)
- If manually captioning, time captions to appear just before the spoken word (gives visual context)
- Place critical captions in the "safe zone" (center and upper 60% of frame for mobile)
- Use color-coded captions if multiple speakers (helps with speaker identification in muted context)

**Testing:** Mute your clip and watch it. If the hook still lands (from text + visual cues alone), you've done it right. If the audience needs sound to understand, add more visual emphasis.

**Available transitions (only use these — nothing else exists):**
- `none` — hard cut (default, good for most edits)
- `crossDissolve` — soft blend (NOT visible enough for hooks)
- `fadeToBlack` / `fadeFromBlack` — fade through black
- `wipeLeft` / `wipeRight` — visible swipe (best for hook-to-content)

### Step 6: Tighten the edit

Within each clip:
- Remove silence > 0.8 seconds (use `split_clip` + `delete_clips`)
- Keep 0.3s of breathing room at natural pauses
- Speed adjustment: if speaker is slow, apply `set_clip_speed` at 1.1x (max 1.15x)
- Speed propagates to linked audio automatically — no separate adjustment needed

### Vertical Format Optimization (for Shorts/Reels/TikTok)

Vertical formats require an additional tightening pass beyond horizontal content:

**Silence threshold adjustment:**
- Horizontal (YouTube): Remove silence > 0.8 seconds
- Vertical (Shorts/Reels/TikTok): Remove silence > 0.5 seconds
- *Reasoning:* Smaller screen real estate means silence reads as "dead time" faster in vertical

**Speech rate check:**
- If speaker is slower than 130 words per minute (WPM), apply 1.1-1.15x speed
- Do NOT exceed 1.15x for speech—intelligibility drops and it sounds unnatural
- Verify after speed adjustment using `measure_loudness` to ensure loudness doesn't increase unexpectedly

**Visual breathing room:**
- Even in vertical, do NOT remove all pauses (keep 0.2-0.3 seconds of intentional breath)
- Strategic pauses after punchlines allow impact to land (0.3-0.5 seconds before next idea)
- Vary pacing: fast sections followed by slightly slower reveals prevent monotonous exhaustion

**Vertical-specific edits:**
- Move text overlays 0.5 inches from edges (mobile safe zone)
- Hook text should appear within first 1-2 seconds (before cognitive decision to scroll)
- Use word-by-word caption timing if auto-generating captions—word-level sync increases comprehension by ~15%

**Platform-specific vertical tweaks:**
- **YouTube Shorts:** Can sustain slightly longer pauses (0.8s still acceptable between major ideas)
- **TikTok:** Tightest pacing—remove all non-essential pauses, constant micro-cuts signal algorithmic relevance
- **Instagram Reels:** Moderate tightness + high visual priority (images, text, graphics drive pacing as much as audio)

### Step 7: Verify — this is mandatory, not optional

**After every clip is built, run verification:**

1. `verify_playback` with mode "quick" — checks that:
   - Audio is present at all checkpoints (not silent)
   - Video frames are valid (not black)
   - Duration matches expected
   - Content at each position matches the expected source

2. `analyze_audio_energy` on the final clip's source range — confirm:
   - Engagement score > 55
   - Speech ratio > 70%
   - No dead zones within the clip

3. `get_state` — verify:
   - Clips are named and in the right order
   - Speed is set correctly on both video and audio (should show @1.10x on both)
   - No unexpected gaps between clips
   - Effects/transitions are visible in properties

**If verification fails, DO NOT tell the user it worked. Fix it or explain what's wrong.**

### Vertical Format Verification Checklist

For Shorts/Reels/TikTok clips, add these vertical-specific verification steps:

**Muted playback test:**
1. Mute the clip entirely
2. Watch from start to finish
3. Verify the hook is clear from visual + text alone (captions must be readable)
4. Check that no critical information is lost without audio

**Pacing verification for vertical:**
1. Count silent pauses longer than 0.5 seconds (should be rare and intentional)
2. Identify any moment where the screen feels "static" for more than 2-3 seconds (add cut or animation if needed)
3. Confirm hook text appears within first 2 seconds (for TikTok) or 3 seconds (for Shorts/Reels)

**Text overlay technical check:**
1. All text is readable on 5-inch phone screen (zoom into text to verify)
2. Text doesn't overlap with important facial features or key visuals
3. Text transitions are smooth (no jittery animations or delays)
4. Caption timing aligns with speech (if auto-generated, manually sync critical words)

**If any verification fails:**
- Muted test fails -> Add text overlay or visual emphasis to hook
- Pacing feels sluggish -> Remove silence, add micro-cuts, increase speech rate by 1.05x
- Text overlay blocks important content -> Reposition or resize overlay, or shorten the text
- Caption sync is off -> Manually adjust word timing (most platforms allow word-level caption editing)

## Platform-specific rules

| Platform | Duration | Hook window | Speed max | Loudness |
|----------|----------|-------------|-----------|----------|
| YouTube Shorts | 30-45s (never >59s) | First 3 seconds | 1.15x | -14 LUFS |
| TikTok | 15-60s | First 2 seconds | 1.2x | -14 LUFS |
| Instagram Reels | 15-30s | First 3 seconds | 1.1x | -14 LUFS |
| Twitter/X | 15-45s | First 2 seconds | 1.15x | -14 LUFS |
| LinkedIn | 30-90s | First 5 seconds | 1.0x | -16 LUFS |

## Platform-Specific Energy Curves

Each platform has an expected emotional/energy arc that affects how you edit and position hooks. Clips that fight these curves feel out-of-place.

| Platform | Expected Energy Arc | Hook Intensity | Mid-Clip Variation | Ending |
|----------|-------------------|-----------------|-------------------|---------|
| **YouTube Shorts** | Slow build -> peak -> sustain | Medium (establish authority first) | Slight dips okay between ideas | Bang--memorable closing line or visual |
| **TikTok** | FAST start -> micro-variation -> peak end | Aggressive (hook HARD in first 2s) | Constant micro-variations to prevent fatigue | Cliffhanger, question, or visual shock |
| **Instagram Reels** | Balanced opening -> moderate build -> satisfying close | Medium (visually engaging from frame 1) | Visual-audio synchronization drives variation | Clean, share-worthy ending or lesson |
| **Twitter/X** | Immediate grab -> quick payoff -> social bait | Aggressive (hook in first 2 seconds) | Fast-paced throughout (no breathing room) | Hook continuation or call-to-engage |
| **LinkedIn** | Professional tone -> credibility -> value statement | Low-key (authority through substance) | Steady, professional pacing | Clear takeaway or professional insight |

**How to use this:**
- **YouTube Shorts** clips should start with a credibility phrase ("Here's something most people miss...") before the hook. TikTok clips should *start* with the hook.
- **Reels** benefit from visual hooks (text overlay, striking image) paired with audio hooks. Timing the visual cut to audio emphasis matters more.
- **TikTok** needs aggressive opening AND constant micro-cuts/transitions to signal novelty (prevent algorithm drop-off).
- **LinkedIn** clips should avoid fast-cut energy and focus on clear, substantive narration.

## What NOT to do

- Never trust transcript alone — always check audio energy first
- Never start a clip with greetings, "um", or silence
- Never end mid-sentence or mid-word
- Never use crossDissolve for hook transitions — it's invisible. Use wipeLeft/wipeRight.
- Never speed up beyond 1.15x for speech — it sounds unnatural
- Never skip verification — "it should work" is not verification
- Never report success without running verify_playback
- Never pick clips from audio energy zones scoring below 40
- Never create a clip that needs the full video to make sense
