---
name: shorts-formatter
description: Format clips for vertical short-form platforms (YouTube Shorts, TikTok, Reels). Handles reframing, cold-open hooks, captions, pacing optimization. Verifies output meets platform specs. Use when the user asks about shorts, vertical video, 9:16 reframe, format for TikTok, Reels, YouTube Shorts, portrait mode, vertical video, captions, or subtitles.
allowed-tools: analyze_audio_energy get_transcript get_transcript_with_timing transcribe_asset check_trend_context find_broll_opportunities generate_broll_asset start_broll_video_job poll_broll_video_job search_local_broll search_broll import_media insert_broll extract_segment split_clip trim_clip move_clip add_to_timeline set_clip_speed set_clip_effect set_clip_transform set_clip_transition set_caption_style analyze_for_shorts create_short auto_reframe measure_loudness verify_playback get_state export_for_platform clear_project set_overlay_config
---

# Shorts Formatter

You format clips for maximum impact on vertical-first platforms.

## Hook Strategy Foundation

Shorts live or die on the hook—viewers decide within the first second whether to keep watching. Every hook must satisfy three simultaneous requirements:

1. **Grab immediately** — Bold claim, sharp question, visual surprise, or provocative statement. Never ease in.
2. **Work without sound** — 80%+ viewers watch muted. Visual hook must land without audio (captions will carry meaning).
3. **Signal value** — The hook must make clear what the viewer will gain by staying (entertainment, insight, resolution, intrigue).

Treat the hook as your primary design element, not an afterthought. All other decisions (pacing, composition, captions) serve the hook.

## Step 0: Verify the source is worth formatting

Before any formatting work:

1. `analyze_audio_energy` on the clip's source range
2. If engagement score < 40 or speech ratio < 50%, WARN the user: "This segment has low audio energy — it may not perform well as a Short"
3. Only proceed with high-energy content
4. For timely clips, call `check_trend_context` with concrete topic/person/product queries and use returned signals to sharpen the hook, caption emphasis, and posting angle. Trend fit is a boost only; never format a low-energy or unclear segment just because it matches a trend.

## Step 1: Reframe for vertical — pick the right tool based on speaker count

**DO NOT use `auto_reframe` for multi-speaker content.** `auto_reframe` averages face tracks into ONE static crop — fine for a single person, broken for podcasts/interviews where speakers move or alternate.

### 1a. Leave the broadcast overlay enabled
Do NOT call `set_overlay_config enabled=false`. `create_short` automatically switches the overlay to **short-form mode** — this renders only a minimal brand bar (show name + gold accent line at the very bottom of the frame). No chapters, sponsors, title cards, or host strips are shown. This keeps brand identity consistent across all shorts without cluttering the vertical frame.

### 1b. Route by subject count

**Check the transcript for speakers first** (via `get_transcript_with_timing` with `include_speakers=true`):

- **Multi-speaker content (podcast, interview, panel):** use `analyze_for_shorts` + `create_short`
- **Single speaker (talking head, monologue, vlog):** use `analyze_for_shorts` + `create_short` — it auto-detects monologue and applies fill layout
- **Non-human subject / single subject no face:** fall back to `auto_reframe`

### 1c. Multi-speaker pipeline (preferred for 99% of cases)

```
1. analyze_for_shorts asset_id=<id> start=<clip_start_s> end=<clip_end_s>
   → returns: faces detected, speaker-to-face mapping, layout segments
2. create_short asset_id=<id> layout=auto
   → recomposes to 1080x1920 with analyzed dynamic face tracking
```

**Picking the layout:**
- `split` — both speakers stacked vertically. Use when BOTH speakers are actively talking / reacting / visible within the clip window.
- `fill_0` — fill the frame with speaker 0 only. Use when only speaker 0 talks throughout the clip.
- `fill_1` — fill the frame with speaker 1 only.
- `auto` — preserve the dynamic layout segments from `analyze_for_shorts`; this is the default.
- **Dynamic switching:** `analyze_for_shorts` auto-detects monologue vs dialogue and may switch between focused speaker fill and split layout over time. Use `auto` unless it looks wrong in preview.

### 1d. After layout is applied — verify, don't trust

Take a screenshot (`take_screenshot`) at a middle timestamp to visually confirm:
- Face is not stretched or squashed
- Subject's eyes sit in upper third
- No dead space on sides
- For `split`: both hosts clearly visible, not overlapping

## Step 2: Cold-open hook structure

Every Short needs the hook in the first 3 seconds.

**Evaluate the opening for hook strength:** Does the first sentence grab attention?
- **Strong hooks** (KEEP): Bold claim ("This breaks physics"), sharp question ("What if you could...?"), visual shock, surprising statistic, provocative statement
- **Weak openers** (NEEDS COLD OPEN): Setup statements ("So..."), context ("Let me tell you..."), apologies ("This is crazy but..."), gradual build-ups

**For silent viewers:** If your hook is audio-dependent (subtle joke, unclear statement), it will fail. The visual and/or captions must make the hook land WITHOUT sound.

**For multi-hook content:** If the clip has 2-3 strong hooks available, extend the hook slightly (up to 4-5s for YouTube Shorts, 2-3s for TikTok) to showcase them. Multiple hook points give different viewers different reasons to stay.

If the opening is weak, apply cold open:

**Cold open technique:**
1. Find the most provocative sentence in the clip via `search_transcript`
2. `add_to_timeline` with JUST that sentence (2-4s), placed at the clip's start position
3. `add_to_timeline` with the FULL clip right after
4. `set_clip_transition` on the full clip: `wipeLeft` at 0.15s (visible, signals jump)
5. `rename_clip` the hook: "HOOK: [first words]"

**Do NOT use crossDissolve for hooks — it's invisible. Use wipeLeft or wipeRight.**

**Why visible transitions matter for hooks:** Invisible transitions (crossDissolve) blur the boundary between hook and content, making the hook feel like filler. Visible transitions (wipeLeft/wipeRight) create a mental reset—they signal "this was the hook, now comes the payload." This distinction helps viewers understand structure and prepares them for the body content.

## Step 3: Tighten pacing

### Pacing by Platform

**YouTube Shorts (59s max):**
- Remove silence > 0.3s (extremely tight; vertical space is premium)
- Apply speed: WPM < 140 → 1.15x, WPM 140-170 → 1.08x, WPM > 170 → no change
- Talking head runs > 6s require visual change (zoom, angle swap, graphics)
- Music: Never exceed 20-30s without visual progression

**TikTok (60s max):**
- Remove silence > 0.5s (slightly more breathing room than Shorts, still tight)
- Match visual beats to trending audio if participating in trends
- Talking heads benefit from faster cuts (switch every 3-5s) to maintain energy
- Hook window: 2 seconds (tighter than Shorts)

**Reels (30s max):**
- Remove silence > 0.3s (most constrained; every second counts)
- Pacing must be fastest of all three platforms
- Talking heads work poorly; favor B-roll heavy content with voiceover
- Hook window: 3 seconds

**General rule:** Silence can be intentional only if it emphasizes a key moment (e.g., pause after a provocative statement). Unintentional silence always reads as dead air. When in doubt, trim it.

## Step 4: Captions as Primary Information System

**Captions are not an accessibility feature—they are your primary information carrier.** 80%+ of viewers watch without sound. Captions must land just as hard as audio.

**Implementation:**
1. `set_caption_style` with style "karaoke" (word-by-word highlight)
2. Check caption timing: Each phrase should appear on-screen for at least 1.5s, with a max of 3s (faster on TikTok)
3. Verify safe area: Captions must stay > 40px from all edges (mobile notches + interface elements)
4. Color strategy: High contrast against background (white text for dark backgrounds, dark for light). Consider a subtle semi-transparent background bar for readability
5. Position captions to avoid obstructing faces or key visual elements
6. Match caption timing to audio rhythm—captions that lag behind speech feel disconnected

**Caption design principle:** Treat captions like you would motion graphics. They're visible information architecture, not boring text. Strategic color, timing, and positioning transform captions from required text into a design element that enhances the hook and maintains engagement.

## Step 5: Final polish

- `set_clip_effect` with colorCorrection: contrast 1.1 (slight boost for mobile screens)
- `measure_loudness` — target -14 LUFS
- Verify pacing alignment: Check that visual cuts and transitions sync with audio rhythm. If speech speeds up, cuts should get tighter. If speech slows, allow for more visual breathing room. Misalignment between audio and visual pacing creates cognitive dissonance.

## Step 6: Add B-roll visual polish

Before final verification, add B-roll where the vertical frame would otherwise stay static:

1. Call `find_broll_opportunities` with `platform="shorts"` for the transcribed asset/clip.
2. For the top 1-3 opportunities, use actual video B-roll: call `start_broll_video_job`, then `poll_broll_video_job` until it returns an imported MP4 `asset_id`.
3. If OpenRouter credentials are missing, call `search_local_broll` with the opportunity's `search_query`; import a selected local file and call `insert_broll`.
4. If local search has no match, call `search_broll` with `query=search_query`, `download=true`, `insert_at=timeline_start`, and `duration=1.5-3.0`.
5. Call `insert_broll` with `placement="overlay"`, `insert_at=timeline_start`, and `duration=1.5-3.0` when the fallback did not already insert the clip.
6. Use `generate_broll_asset` only as a still visual-support fallback. If you insert a still, pass `allow_still_visual_support=true` and do not describe it as actual video B-roll.
7. Do not cover the first face/hook frame unless the B-roll itself is the hook. Keep B-roll short and rhythmic.

### B-roll video prompt pattern

When writing or editing a B-roll generation prompt, keep it structured and concrete:

- Start with the video style and intent: "Editorial documentary B-roll video" and what spoken idea it supports.
- Specify subject, scene, one clear action, camera movement, composition, lighting/tone, format, and duration.
- For shorts, require portrait-safe framing and no important detail near the bottom brand bar.
- For 1.5-4s cutaways, ask for a single continuous shot with slow push-in or lateral slide. Avoid multi-scene stories unless the B-roll duration is long enough.
- Ask for silent video only; the podcast audio stays underneath.
- Add constraints: no captions, no readable text, no real logos, no famous likeness, unidentifiable people if present.

## Step 7: Mandatory verification

1. `verify_playback` mode "quick":
   - Duration 30-59s (YouTube penalizes 60+)
   - Audio present everywhere
   - Frames valid

2. `get_state`:
   - Hook clip is first, labeled "HOOK:"
   - Speed on both V+A
   - Transition visible on the content clip (wipeLeft/wipeRight, not crossDissolve)
   - Total duration within platform limits

3. `analyze_audio_energy` on final:
   - Speech ratio > 80%
   - No dead zones

## Why These Steps Matter for Vertical

Vertical short-form content is fundamentally different from horizontal video:

- **Framing is tighter:** Side-to-side movement wastes space. Face, hands, and emotional expression dominate. Auto-reframe is a starting point; manual refinement is mandatory.
- **Silent viewing is the norm:** Design for muted playback first, then add audio as enhancement. Captions aren't optional—they're your primary narrative layer.
- **Hooks are survival:** The first 3 seconds determine everything. Weak hooks lose viewers before the content begins.
- **Pacing drives perception:** Tighter pacing isn't just aesthetic—it's required for the narrow vertical frame. Long shots, slow cuts, and extended silence feel like dead air in vertical.
- **Captions are design:** Done right, they're typography, rhythm, and information architecture combined. Done wrong, they're invisible clutter.

Every decision—composition, pacing, captions, transitions—must be intentional for the vertical medium. Shortcuts show immediately on mobile screens.

## Available transitions (only these exist)

- `none`, `crossDissolve`, `fadeToBlack`, `fadeFromBlack`, `wipeLeft`, `wipeRight`
- For hooks: use `wipeLeft` or `wipeRight` (visible)
- For endings: use `fadeToBlack`
- Never use transitions that don't exist (no spin, zoom, flash, etc.)

## Platform Specifications

| Platform | Max Duration | Loudness | Hook Window | Silence Threshold | Primary Medium |
|----------|-------------|----------|-------------|-------------------|----------------|
| YouTube Shorts | 59s | -14 LUFS | 3 seconds | > 0.3s (remove) | Captions (80%+ muted) |
| TikTok | 60s | -14 LUFS | 2 seconds | > 0.5s (remove) | Captions + audio trends |
| Reels | 30s | -14 LUFS | 3 seconds | > 0.3s (remove) | Captions (most muted) |

## What NOT to do

- Never exceed 59 seconds for YouTube Shorts
- Never start with black, logos, or intros
- Never use crossDissolve for hooks — it's invisible
- Never use transitions that don't exist in the editor
- Never skip verification
- Never format a low-energy segment — check audio first
