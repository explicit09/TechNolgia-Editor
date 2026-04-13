---
name: beat-sync-editor
description: Edit video to music by detecting beats and syncing cuts to the rhythm. Matches visual energy to musical energy, handles speed ramps on drops. Verifies beat alignment. Use when the user asks about beat sync, music editing, rhythm, montage, beat drop, music video, cut to beat, tempo, BPM, dance, or energy matching.
allowed-tools: detect_beats analyze_audio_energy split_clip trim_clip move_clip delete_clips set_clip_speed set_clip_effect set_clip_transition set_marker measure_loudness rename_clip verify_playback get_state
---

# Beat Sync Editor

You create visually rhythmic edits where every cut aligns precisely with the music.

## Step 1: Analyze the music

1. `detect_beats` — returns BPM, beat timestamps, strong beats
2. `analyze_audio_energy` with `segments: 10` — energy profile for song structure
3. `measure_loudness` — baseline levels
4. `set_marker` at every strong beat for visual reference

**Classify song structure by energy:**
- Intro (low energy): wide/establishing shots, cut every 4-8 beats
- Verse (medium): mix of angles, cut every 2-4 beats
- Pre-chorus (rising): accelerate cuts, every 2 beats → every beat
- Chorus (high): dynamic footage, cut every 4 beats with bold transitions
- Bridge (dip): emotional/slow footage, every 4-8 beats
- Drop: most dramatic cut on the exact beat

### Cut Selection Principles

When selecting which clips to place at each beat marker, apply these rules:

**Cut on Action (Primary):**
- Prioritize clips where movement occurs at or near the beat marker. Movement naturally masks the cut and makes timing feel seamless rather than imposed. A punch, spin, gesture, or camera movement at the beat creates invisible editing.
- Example: Place a dancing cut on the beat if the dancer's body peaks at that moment. Avoid placing a static pose on the beat—it will feel rigid.

**Cut on Energy Shifts (Secondary):**
- Music contains natural energy peaks (buildups to drops, breakdown moments). Align cuts to these peaks when possible. A drop landing on a tight action cut feels earned; a drop on a static shot feels missed.
- Use `analyze_audio_energy` not just for structure (intro/verse/chorus), but to identify micro-peaks within sections for cut placement refinement.

**Purpose in Sequence:**
- Every clip at every beat marker should serve the narrative or visual progression. Avoid placeholder footage just because the beat timing works. If a clip doesn't add energy or context, replace it.

## Step 2: Calculate clip durations and match to emotional intensity

**Duration Formula:**
```
clip_duration = (beats_per_cut × 60) / BPM

At 120 BPM:
- Every 2 beats = 1.0s per clip (very high energy)
- Every 4 beats = 2.0s per clip (high energy)
- Every 8 beats = 4.0s per clip (medium energy)
```

**Pacing Strategy — Match to Emotional Curve:**

Variable pacing creates rhythm and sustains engagement. Plan your edit to follow the song's emotional arc:

- **Building sections (pre-chorus, buildups):** Accelerate cuts progressively. Start at 4-beat intervals, move to 2-beat, then 1-beat as tension rises. This visual tightening mirrors musical tension.
- **Peak sections (chorus, drop):** Hold tight pacing (1-2 beat cuts) to maintain maximum energy and impact.
- **Release sections (bridge, breakdown):** Expand to 4-8 beat cuts to allow visual breathing and emotional reset.
- **Transitions between sections:** Use pacing shifts as mental cues. A sudden shift from 8-beat slow cuts to 1-beat fast cuts signals the drop arrival to the viewer before the audio even lands.

Do not maintain the same cut frequency throughout—monotonous pacing becomes exhausting and fails to emphasize the song's structure.

## Step 3: Align cuts to beats

1. Plan cut points based on section structure
2. `split_clip` at each beat-aligned timestamp
3. Cuts must land within ±50ms of the beat (±1.5 frames at 30fps)
4. `trim_clip` to snap precisely

## Step 4: Transitions matched to music and motivated by energy

**Transition Decision Framework:**

Every transition choice must be motivated—it should serve a musical or narrative purpose, not exist for visual novelty alone.

**Available transitions and when to use them:**

| Transition | Duration | Purpose | Musical Moment |
|---|---|---|---|
| `none` (hard cut) | instant | Default choice; cuts are invisible and feel natural. Uses the beat itself as punctuation. | Strong beats, action moments, high-energy continuous sections |
| `wipeLeft` / `wipeRight` | 0.1-0.15s | Visible transition that signals intentionality; draws attention to a moment. Reserve for earned, important beats. | Dramatic accents, pre-chorus → chorus transitions, hook signaling |
| `fadeToBlack` | 1.0s | Creates a pause and reset; tells the audience "something is about to change." Provides visual breathing room. | Breakdowns, mood shifts, intentional pause moments within the song |
| `fadeFromBlack` | 0.1s | Announces the return of energy with visual impact; works with drops and dynamic re-entries. | Drops after breakdowns, sudden energy increases, surprise impact moments |
| `crossDissolve` | 0.5-1.0s | Signals time passage or topic shift; creates a bridge between contrasting sections. Keep brief to avoid breaking pacing. | Verse → verse transitions, sustained notes, emotional moment shifts |

**Transition Rules:**

1. **Cuts are default.** Use hard cuts on strong beats and action moments. They feel natural and don't slow pacing.
2. **Transitions must be motivated.** If a transition doesn't serve the music's energy shift, it's decorative. Remove it.
3. **No arbitrary surprises.** A wipe on a random beat will feel jarring. Reserve visible transitions for moments the audience anticipates (a known drop, an obvious structural shift).
4. **Never use transitions that don't exist** (no spin, zoom, flash, etc.)

**Anti-Pattern:** Do not use `crossDissolve` on a strong beat or drop moment—hard cuts land better on peaks. Save dissolves for sustained notes or moment shifts where pacing can expand.

## Step 4.5: Verify energy motivation

Before applying effects and speed ramps, review your transition and cut decisions:

1. **For each hard cut on a strong beat:** Does the clip have movement or action at that beat? If static, consider moving to an action-based moment nearby (within +/-1 beat) or replacing the clip entirely. Static shots on strong beats feel rigid.

2. **For each visible transition (wipe, fade, dissolve):** Does it correspond to a clear energy shift in the music? If not, change it to a hard cut. Motivated transitions feel earned; unmotivated ones distract.

3. **For pacing consistency within sections:** Are cut frequencies matching the song's emotional moment? Review your cut intervals against the energy curve. A slow section should not have 1-beat cuts; a drop should not have 8-beat cuts.

4. **Orphaned clips:** Does every clip serve the visual or emotional narrative? Placeholder footage inserted just to fill beat markers will feel out of place. Replace with more appropriate content if available.

This review prevents the trap of "it fits the beat" while missing "it fits the story."

## Step 5: Speed effects

- Breakdown: `set_clip_speed` 0.5x (slow motion)
- Drop ramp: 0.5x → 1.0x → 2.0x across 4 beats
- Freeze frame: very low speed for 1 beat on a dramatic accent

Speed propagates to linked audio automatically.

## Step 6: Energy-matched color

- Chorus: `set_clip_effect` colorCorrection: saturation 1.2, contrast 1.15
- Bridge: saturation 0.8 (desaturated for emotion)

## Step 7: Mandatory verification

1. **Technical verification** — `verify_playback` mode "quick":
   - Audio present throughout
   - Video frames valid
   - Total duration matches music

2. **Structural verification** — `get_state`:
   - Markers at every strong beat
   - Clips named by section
   - Speed/effects visible in properties
   - No gaps

3. **Editorial verification** — Watch playback and ask:
   - Does every cut land on action or movement (not static moments)?
   - Does every visible transition (wipe, fade) correspond to a clear energy shift?
   - Do pacing speeds match emotional intensity (tight cuts on high energy, slow cuts on low)?
   - Do all clips serve the narrative or visual arc, or are any placeholder shots?

4. **Final playback** — Watch the entire edit at intended viewing size/platform. Does the rhythm feel intentional and motivated, or does it feel like beats were hit arbitrarily?

## What NOT to do

- Never cut between beats — off-beat cuts feel amateur
- Never use the same clip twice until all footage is used
- Never have more than 3 flash effects per second (epilepsy concern)
- Never use crossDissolve on a strong beat — hard cuts are better
- Never mismatch energy — no slow footage on drops
- Never skip verification
- Never use transitions that don't exist in the editor
