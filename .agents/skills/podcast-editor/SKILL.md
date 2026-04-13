---
name: podcast-editor
description: Edit podcast and interview recordings. Uses audio energy analysis to find dead zones, removes filler words, tightens silence, speeds up slow speakers, normalizes audio. Verifies output quality. Use when the user asks to clean up a podcast, remove ums, remove filler words, tighten silence, edit an interview, or polish audio.
allowed-tools: analyze_audio_energy get_transcript transcribe_asset search_transcript split_clip trim_clip move_clip delete_clips set_clip_speed set_clip_volume set_track_volume measure_loudness verify_playback get_state
---

# Podcast Editor

You are a professional podcast editor. Your job is to make speech content sound clean, natural, and engaging without removing the speaker's personality. Every cut should be invisible to the listener.

## Step 0: Audio energy scan — understand the recording before editing

Before touching anything:

1. `analyze_audio_energy` with `segments: 20` — rank the recording by engagement
2. Identify dead zones (score < 30, speech < 20%) — these are likely:
   - Pre-recording silence
   - Technical setup ("can you hear me?")
   - Long tangents where energy drops
3. Identify hot zones (score > 55, speech > 70%) — these are the core content
4. This tells you where to focus cleaning effort and where to consider cutting entirely

## Step 1: Transcribe and analyze

1. `transcribe_asset` if no transcript exists
2. `get_transcript` — read the full transcript
3. `measure_loudness` — get baseline LUFS

## Step 1.5: Audio Processing Chain (Multi-Speaker Setup)

Before removing any filler or tightening silence, establish a clean audio foundation:

### Gate: Isolate Each Speaker
- Apply a gate to each microphone channel to prevent bleed
- Threshold: Set to just below ambient noise level, allowing only full-volume speech through
- This cuts off-camera chatter and room noise leaking into individual tracks
- Result: Cleaner, more isolated dialogue for each speaker

### Compressor: Manage Dynamics (1176 Style)
- Ratio: 4:1
- Attack: 5ms
- Release: 30-50ms
- Target: Tame peaks without losing natural breath and emphasis
- Applies AFTER gate, so it works on already-isolated audio

### De-Esser: Reduce Sibilance
- Target frequency: 5-7kHz
- Amount: -2 to -4dB depending on speaker
- Apply to all spoken content to reduce harsh "S" sounds
- More aggressive with closer-miked speakers (podcasters, hosts)

### Noise Reduction
- Apply surgical noise removal to eliminate room hum, AC buzz, or fan noise
- Use spectral analysis (iZotope RX or similar) to identify specific frequencies
- Remove only the noise, not the dialogue

### EQ: Shape Presence
- High-pass filter: 80Hz (removes low rumble and mic handling noise)
- Presence boost: +2-3dB around 3kHz (adds clarity and presence to speech)
- Gentle Q, avoid aggressive shelving

### Limiter: Protect Against Peaks
- L2 Maximizer style, threshold: -4 to -6dB
- Attack: 1ms (protect against fast transients)
- Release: 50-100ms
- Acts as final safety net for unexpected peaks

### Important: Link Tracks and Create Backups
- After syncing audio and video tracks, link them so they move as a single unit
- Create an unedited backup of original audio before any destructive cuts
- Mark each filler word or silence with colored markers for visual reference

## Step 2: Remove dead zones

Using the audio energy data from Step 0:
- Segments scoring below 25 with speech < 15% → cut entirely (these are dead air, setup, or off-topic)
- Segments scoring 25-40 → review the transcript. If it's filler ("can you hear me", small talk), cut. If it's slow-but-substantive content, keep and tighten.

## Step 3: Remove filler words

**Always remove (non-lexical):**
- "um", "uh", "er", "ah", "hmm" (standalone, not part of a word)

**Conditionally remove (lexical — check context):**
- "like" — filler when surrounded by pauses, keep when comparative
- "you know" — filler when rhetorical, keep when genuine question
- "basically", "sort of", "kind of" — remove when hedging

**Process:**
1. `search_transcript` for each filler pattern
2. `split_clip` at word boundaries to isolate — aim to include ~50ms before and after the filler word for smooth removal
3. Review each instance in context before deleting:
   - "like" in "like, you know, it was" → remove (filler)
   - "like" in "do you like this idea?" → keep (comparative, intentional)
   - "basically" in "basically, what happened..." → remove (hedging)
   - "you know" as rhetoric → remove; as genuine question → keep
4. `delete_clips` to remove only confirmed fillers
5. Never cut mid-word — always at word boundaries
6. Remember: Removing ALL filler creates robotic dialogue. Preserve speaker personality by keeping filler that reflects natural rhythm.

## Step 4: Tighten silence

- Between speakers: max 0.5s (trim anything longer)
- Within a speaker: max 0.3s
- Exception: dramatic pause before a punchline — preserve up to 0.8s
- Never remove pauses < 0.5s — that's natural breathing rhythm

### Silence as a Creative Tool

Not all silence is dead air. Use intentional silence to:

**Dramatic Pauses (up to 0.8s)**
- Before punchlines or big reveals
- After surprising statements to let impact land
- When a speaker takes a breath before an important point
- These pauses emphasize meaning and give listeners time to absorb

**Processing Pauses (3-5s with optional background music)**
- Between major topic shifts in longer interviews
- Allows listeners to mentally transition between subjects
- Optional: underlay with soft background music to signal a "breathing room" moment

**Turn-Taking Silence (0.2-0.5s)**
- Between speaker exchanges in dialogue
- Shorter gaps (0.2-0.3s) feel natural and conversational
- Longer gaps (0.3-0.5s) suggest contemplation or weight
- Gaps over 0.5s begin to feel awkward or like a technical error

**Energy Shift Points**
- When speaker changes volume, pacing, or emotional intensity, a natural pause often occurs
- These are ideal cut points — the silence itself signals a transition
- Never remove silence at energy shift points; it's doing creative work

## Step 5: Speed adjustment

Estimate WPM from transcript: words / (duration in minutes)
- WPM < 120: `set_clip_speed` at 1.15x
- WPM 120-130: `set_clip_speed` at 1.08x
- WPM 130-160: no change
- WPM > 160: no change — already fast

Speed propagates to linked audio clips automatically. No need to set separately.
Never exceed 1.2x for speech content.

## Step 6: Audio normalization

- Target: -16 LUFS for podcasts, -14 LUFS for social clips
- `set_clip_volume` or `set_track_volume` to adjust
- Ensure consistent levels across speakers

## Step 7: Mandatory verification

**Run after every edit session:**

1. `verify_playback` mode "quick":
   - Audio present at all checkpoints
   - No unexpected silence
   - Duration reduced 10-25% from original (typical cleanup)

2. `analyze_audio_energy` on the edited range:
   - Speech ratio should be HIGHER than the original (dead air removed)
   - Engagement score should be HIGHER (tighter content)
   - If speech ratio dropped or score decreased, something went wrong

3. `get_state`:
   - Speed shows @1.Xx on BOTH video and audio clips (linked propagation)
   - No gaps between clips
   - Volume/effects visible in properties

### Quality Markers: Speech vs. Filler

Beyond technical verification, audit for personality preservation:

1. **Speaker Voice Check:**
   - Listen for sections where you cut heavily (lots of filler removed)
   - Do they still sound natural, or do edits feel abrupt?
   - If dialogue sounds robotic, you've removed too much personality

2. **Pacing Consistency:**
   - Compare fast-paced sections to slower sections
   - Do speed adjustments feel motivated by content, not artificial?
   - Verify no speaker sounds unnaturally accelerated (max 1.2x)

3. **Silence Distribution:**
   - Visually scan timeline for dramatic pauses (they should cluster at key moments)
   - Check that silence reductions don't feel "squeezed" — breathing room should exist between exchanges

4. **Multi-Speaker Integrity:**
   - If multiple speakers: verify no one person was edited much more heavily than others
   - Unbalanced editing can make one person sound more articulate than another (changing narrative)
   - Aim for similar edit intensity across all speakers

**Never tell the user editing is done without running verification.**

## What NOT to do

**Cutting & Authenticity:**
- Never remove ALL pauses — speech becomes robotic
- Never cut mid-laugh, mid-reaction, or mid-emotional beat (these are character, not filler)
- Never edit one speaker significantly more than others — this changes power dynamics
- Never use the same filler removal pattern across all speakers; allow for individual speaking styles

**Speed & Personality:**
- Never speed up already-fast speakers (>150 WPM should stay at 1.0x)
- Never speed up emotional or dramatic content — slowing it down is often better
- Never apply speed uniformly across entire interview; adjust per speaker and context

**Audio Processing:**
- Never skip the audio energy scan — transcript alone doesn't reveal engagement patterns
- Never normalize all voices to identical levels; preserve natural personality differences in mic presence
- Never over-compress interview content; dynamic range is part of authentic speech

**Silence & Pacing:**
- Never remove intentional dramatic pauses (especially before punchlines)
- Never reduce all silences uniformly; longer pauses often mark important thinking moments
- For interviews: preserve some breathing room even if you're tightening overall — silence is part of dialogue rhythm

**Verification & Reversibility:**
- Never report success without verify_playback
- Never assume speed applied to audio — check get_state shows it on both tracks
- Never perform destructive edits on original tracks; always work on a backup copy
- Never delete a clip you're unsure about; mark it for review instead

**Creative Decision-Making:**
- Never view editing as purely technical removal; every cut is a creative choice
- Never cut based on transcript alone; audio energy analysis reveals what transcripts miss
- Never assume the user wants maximum tightness; some podcasts thrive on conversational breathing room
