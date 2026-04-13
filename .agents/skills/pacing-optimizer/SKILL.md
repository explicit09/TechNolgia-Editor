---
name: pacing-optimizer
description: Optimize video pacing by removing dead zones, tightening silence, and adjusting speed. Uses audio energy analysis to find and remove low-engagement sections. Makes content feel tighter and more engaging. Use when the user asks about pacing, tighten, remove dead air, speed up, boring parts, slow sections, fix pacing, optimize, dead zones, or engagement.
allowed-tools: analyze_audio_energy get_transcript search_transcript split_clip trim_clip delete_clips move_clip set_clip_speed measure_loudness verify_playback get_state
---

# Pacing Optimizer

You optimize video pacing by removing low-energy sections and tightening content. The goal: every second earns its place.

## Workflow

### Step 1: Map the Energy Landscape with Content-Type Awareness

1. `analyze_audio_energy` with `segments: 30-40` (finer grain = better cuts)

2. **Classify each segment using content-type-specific thresholds:**

**For Short-Form Content (Shorts, Reels, TikTok):**
- **Dead** (score < 20): Cut entirely; short-form has no room for dead air
- **Weak** (score 20-35): Review transcript — cut if filler, keep if substantive
- **Active** (score 35-55): Keep, consider light speed up to 1.08x-1.10x
- **Hot** (score > 55): Keep as-is, preserve natural rhythm

**For Talking-Head Content (Solo presenter):**
- **Dead** (score < 25): Cut entirely
- **Weak** (score 25-40): Review transcript — presenter energy matters more than audio energy for this format
- **Active** (score 40-60): Keep, light speed up to 1.08x acceptable
- **Hot** (score > 60): Keep as-is

**For Interview/Dialogue Content:**
- **Dead** (score < 20): Cut entirely only if confirmed filler (side conversations, breathing, clicks)
- **Weak** (score 20-40): Keep more of these than other formats; dialogue content needs breathing room
- **Active** (score 40-65): Keep with minimal speed adjustment (1.05x if needed)
- **Hot** (score > 65): Keep as-is; preserve natural conversational rhythm

**For Podcast Content (with background music):**
- **Dead** (score < 15, no speech present): Cut only if truly empty; silence between points can be intentional
- **Weak** (score 15-35): Likely contains valuable content; background music adds perceived energy
- **Active** (score 35-60): Keep, no speed increase; music and speech together create pacing
- **Hot** (score > 60): Keep as-is

**For Educational/Tutorial Content:**
- **Dead** (score < 25): Cut if confirmed filler (stutters, false starts, technical issues)
- **Weak** (score 25-40): Review for comprehension value; slower explanation may be necessary
- **Active** (score 40-65): Keep, speed up to 1.08x if content is clear
- **Hot** (score > 65): Keep as-is; high energy usually means clarity

**Key difference:** Short-form aggressively targets dead content (< 20-25). Long-form and dialogue formats accept more weak segments because context and natural flow matter more than constant momentum.

**Default thresholds** (when content type is unknown or mixed):
- **Dead** (score < 25, speech < 20%): cut entirely
- **Weak** (score 25-40): review transcript — cut if filler, keep if substantive
- **Active** (score 40-60): keep, consider light speed up
- **Hot** (score > 60): keep as-is, this is the good stuff

### Step 2: Remove dead zones

For each dead zone:
1. `split_clip` at the zone boundaries
2. `delete_clips` the dead section
3. Close the gap by `move_clip` subsequent clips left

Target: remove 20-40% of content from a raw recording. If less than 10% is dead, the content is already tight.

### Step 3: Tighten Weak Zones with Speech-Aware Speed Adjustment

For weak zones that survived transcript review, apply differential speed adjustment based on speaker delivery rate:

**Speed Adjustment by Words-Per-Minute:**

| Delivery Rate (WPM) | Speed Multiplier | Rationale |
|---|---|---|
| Below 120 WPM | 1.15x | Slower speakers benefit from acceleration without sounding unnatural |
| 120-130 WPM | 1.08x | Moderate speaker; light acceleration maintains clarity |
| 130-160 WPM | 1.0x (no change) | Fast speaker already at natural pace; preserve rhythm |
| Above 160 WPM | 1.0x (keep native) | Maintain clarity; speed increase would sacrifice intelligibility |

**Measuring WPM:** Count the number of words spoken in a 30-second segment, multiply by 2. Compare to thresholds above.

**Application:** Instead of "speed up this weak section at 1.15x," determine the speaker's natural delivery rate first. A slow speaker accelerated to 1.15x sounds energized; a fast speaker accelerated to 1.15x becomes unintelligible.

**Internal silence handling:**
- Silence > 1.5s (outside of intentional pause moments): split and delete, keep 0.4s of pause.
- Silence 0.5-1.5s: evaluate if intentional (follows key statement, precedes transition). Keep intentional silence; delete accidental breath gaps.
- Silence < 0.5s: generally preserve for natural rhythm in dialogue content.

### Variable Pacing: Beyond Uniform Speed

Uniform speed increases (1.1x throughout) create fatigue and lose the rhythm that sustained engagement requires. Instead, deploy differential pacing:

**Speed Variation by Segment Type:**
- **Hot segments** (score > 60): Keep at 1.0x. This is the good stuff; preserve its natural rhythm.
- **Active segments** (40-60): Optional light speed at 1.05x-1.08x if the pace feels sluggish relative to surrounding hot segments.
- **Weak segments** (25-40): Candidates for 1.1x-1.15x speed, but only if transcript review confirms they contain substance worth keeping.
- **Recovered filler** (removed breaths, clicks, ums): Gaps left by filler removal often create natural rhythm without additional speed; test playback before adding speed.

**Why variable pacing works:** Fast sections emphasize key moments when surrounded by normal-speed content; uniform acceleration flattens engagement. Think of pacing as an energy curve, not a volume dial.

**Practical application:** Analyze speed changes in the context of the full edit. A 1.15x section following natural 1.0x content feels energized; the same section in a uniformly sped-up piece feels like metadata, not storytelling.

### Step 3.5: Apply Content-Type Silence Thresholds

Before finalizing silence cuts, verify that silence removal matches content type. The 1.5s rule does not apply equally to all formats.

**Silence Thresholds by Content Type:**

| Content Type | Max Dead Silence | Rationale |
|---|---|---|
| Short-form (Shorts, Reels, TikTok) | 1.5 seconds | Continuous momentum expected; extended silence breaks engagement before retention is established |
| Talking-head (Solo presenter) | 1.2 seconds | Without visual activity or audio change, viewers disengage quickly |
| Interview/Dialogue | 0.5 seconds (normal) / 0.8 seconds (dramatic pause) | Natural conversational breathing; complete silence feels unnatural |
| Podcast (with background music) | 3-5 seconds (intentional breaks) | Deliberate silence with music allows information processing and signals transitions |
| Podcast (no music) | 1.5 seconds | Breathing room needed but silence without audio context reads as dead air |
| Educational/Tutorial | 0.8-1.2 seconds | Pacing matches learning absorption; too-tight feels rushed |

**Intentional vs. Dead Silence:**
- **Dead silence** = No content context, no speaker intent, no tonal purpose. Remove it.
- **Intentional silence** = Follows a key statement (emphasis pause), precedes a shift (transition buffer), or creates dramatic weight. Preserve minimum 0.3-0.5 seconds.

**Application:** Before deleting any silence longer than 1.5 seconds, classify it as dead or intentional using this matrix. Short-form content can be more aggressive; long-form content needs breathing room.

### Step 4: Verify improvement

1. `analyze_audio_energy` on the result:
   - Average engagement score should be HIGHER than the original
   - Speech ratio should be HIGHER (dead air removed)
   - If scores decreased, the cuts were wrong — undo

2. **Verify Emotional Arc (Post-Cutting):**

   After cutting and speed adjustments, confirm that the emotional journey remains intact:

   **Emotional Arc Checklist:**
   - [ ] **Tension building exists** — Does the content build momentum toward payoff moments? Or does it feel flat throughout?
   - [ ] **Key moments are emphasized** — Silence before and after high-energy statements should feel intentional, not accidental.
   - [ ] **Pacing variation is perceivable** — When you listen to the full piece, do you notice rhythm changes (fast sections feel distinct from normal sections)? Or does it feel uniformly compressed?
   - [ ] **Conversational breathing present** — For dialogue/interview content, do speaker transitions feel natural? Or does the rapid cutting feel robotic?
   - [ ] **No over-compensation** — Did you cut so aggressively that you removed context-setting moments? Listeners should understand the narrative, not feel whiplash.

   **Red flags that indicate over-cutting:**
   - "That section feels rushed even though the speaker wasn't talking fast"
   - "I lost track of who was talking / what the topic was"
   - "The pacing feels relentless, not engaging"
   - "Key points don't land anymore because there's no pause before them"

   If three or more flags appear, undo recent cuts and re-evaluate. The goal is tighter pacing, not compressed exhaustion.

3. `verify_playback`:
   - Audio at all checkpoints
   - No unexpected gaps
   - Duration reduced by target percentage

## Quality Rules

- **Never cut mid-sentence** — Always cut at silence gaps or natural energy transitions, not during speech.
- **Identify intentional silence before cutting** — Silence following key statements, preceding transitions, or creating dramatic emphasis should be preserved at minimum 0.3-0.5 seconds. Ask: "Does this pause serve the message?" If yes, keep it.
- **Never remove content where the score is > 55** — That's the good stuff, and good stuff often includes intentional pacing.
- **Never speed up beyond 1.15x** — Beyond this threshold, voice loses natural character.
- **Always verify after cutting** — The result should score HIGHER than the input, with speech ratio elevated and emotional arc intact.
- **Never report done without verify_playback** — Always listen for unintended gaps, lost emphasis moments, or flattened emotional progression.
- **Preserve breathing room in dialogue** — Interview and conversation content requires natural pauses between speakers. Never compress below 0.3 seconds between speaker changes.

## Anti-patterns

- **Don't remove all silence** — Some pauses are dramatic, some signal transitions, some allow comprehension. Silence is content, not just dead space.
- **Don't speed up everything uniformly** — Variable pacing is better. Fast-paced sections emphasize key moments when surrounded by normal speed; uniform acceleration is exhausting.
- **Don't ignore content type** — Short-form can tolerate tighter silence (1.5s max dead air). Interviews need breathing room (1.2s max dead air). Podcasts with music can use 3-5s intentional breaks.
- **Don't trust transcript alone for pacing decisions** — Use audio energy as primary signal; transcript confirms whether weak energy sections contain substance worth keeping.
- **Don't flatten the emotional arc** — Pacing choices should maintain or enhance the emotional progression of content, not reduce everything to uniform rhythm.
