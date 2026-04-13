---
name: rough-cut-assembler
description: Assemble raw footage into a rough cut. Uses audio energy to find active takes vs dead air, selects best takes, removes dead air, assembles in order. Verifies assembly quality. Use when the user asks about rough cut, assembly, takes, raw footage, first cut, assemble, organize, select takes, dead air, or clean up raw footage.
allowed-tools: analyze_audio_energy get_transcript transcribe_asset search_transcript split_clip trim_clip move_clip delete_clips rename_clip set_marker measure_loudness verify_playback get_state
---

# Rough Cut Assembler

You take raw footage and create a clean first assembly. The rough cut's job is story clarity and structural coherence, not technical perfection. A rough cut with clear narrative beats and authentic takes is complete. Audio balance, color, and polish come later.

## Step -1: Prepare — Understand Context & Story

Before analyzing audio, establish the narrative context for editorial decisions:

1. **Identify content type:**
   - Interview-driven (prioritizes completeness and authenticity)
   - Voiceover-driven (prioritizes clean delivery and energy)
   - B-roll with narration (prioritizes synchronization and pacing)
   - Multi-camera (prioritize coverage and angle variety)

   This affects which takes score highest and how assembly will be ordered.

2. **Review any existing script or outline:**
   - Does one exist? If yes, reference it during take selection and assembly
   - What is the intended narrative structure? (three-act flow, topical organization, chronological journey?)
   - This determines assembly order in Step 4

3. **Note the intended audience and context:**
   - What should the audience feel or understand after this assembly?
   - This guides take selection: does a take contribute to that intention?

4. **Quick assessment of raw footage:**
   - How many hours of footage? (Expect ~80% to be removed)
   - Are there obvious re-takes of the same content?
   - Any technical issues (audio inconsistency, camera drift)?

This context shapes editorial decisions downstream. Spending 2 minutes here prevents guessing later.

## Step 0: Audio energy map — find the real content

Raw footage is mostly dead air. Find where actual content lives:

1. `analyze_audio_energy` with `segments: 30-40`
2. Active zones (score > 40, speech > 50%) = actual takes
3. Dead zones (score < 25, speech < 15%) = between takes, camera rolling
4. This map replaces guessing at take boundaries

## Step 1: Identify takes

Using audio energy data + transcript:

1. `transcribe_asset` if needed
2. Takes start where speech begins after a dead zone
3. Takes end where speech stops before a dead zone
4. Search for director cues: "action", "cut", "take", "again", "from the top", "sorry"
5. `split_clip` at each take boundary
6. `rename_clip` each: "Take N: [first words]"
7. `set_marker` at each take start

**Audio energy pattern guide for different content types:**
- Interviews: Look for speech spikes above 50% speech ratio separated by dead zones (hesitations, thinking pauses)
- Voiceover: Consistent high speech ratio with clear on/off boundaries; takes are separated by complete silence or room tone reset
- Multi-camera: Each take boundary shows full silence, not just speech ending (camera roll-down or reset period)
- B-roll narration: Speech occurs in chunks; takes are separated when voiceover stops and restarts

Use content type to interpret energy data, not just numerical thresholds.

## Step 2: Select Best Take Per Scene

When the same content appears multiple times (re-takes), choose which version advances the story best.

**Understand the hierarchy for different content types:**

*For Interview/Conversational Content:*
1. Completeness (40%) — Full thought without restarts or verbal stumbles
2. Authenticity (30%) — Natural delivery, even if audio energy is lower
3. Recency (20%) — Later takes tend to be more polished
4. Audio quality (10%) — Consistent volume, minimal background noise

*For Voiceover/Narration:*
1. Audio energy (40%) — Higher engagement and delivery energy = stronger presence
2. Completeness (30%) — No stumbles, restarts, or verbal tics
3. Audio quality (20%) — Consistent with other takes in the piece
4. Recency (10%) — Earlier takes acceptable if performance is superior

**Score each take:**
- Use `analyze_audio_energy` on each take individually for precise comparison
- For interviews, manually listen to assess authenticity beyond metrics
- Flag takes where metrics conflict (high energy but incomplete speech; low energy but natural delivery)

**Make the creative choice:**
- Metrics guide but don't determine. A take with 15% lower energy but 40% better authenticity may be the right choice
- Consider what the take contributes to the narrative: Does it set up story? Provide evidence? Deliver payoff? Choose based on narrative role, not just performance metrics
- Recency matters less if an earlier take is demonstrably stronger for the story

**Three-act guidance:**
- Opening/Setup takes: Prioritize energy and hook; audience needs to engage immediately
- Middle/Conflict takes: Balance energy with authenticity; audience is invested, natural moments matter more
- Closing/Resolution takes: Prioritize completeness and emotional clarity; audience needs resolution to feel earned

**Mark rejected takes with color labels** (e.g., red for "rejected", yellow for "backup candidate") rather than deleting. You may need them if a selected take has issues during assembly.

## Step 3: Remove dead air

For each selected take:
1. `trim_clip` to start 0.3s before first spoken word
2. End 0.5s after last spoken word
3. Internal silence > 2s: `split_clip` + `delete_clips`, keep 0.4s of pause
4. Keep a mental note of pre-trim boundaries for potential restoration; mark ambiguous trim points with `set_marker` rather than assuming

## Step 4: Assemble — Build Narrative Structure

Order clips to create coherent story, not just technical sequence.

**Establish assembly hierarchy:**

1. **Story structure first** — If content has three-act structure (setup -> conflict -> resolution), arrange takes to support that shape
2. **Topic/thematic grouping second** — If content is topical (multiple interview subjects on different topics), group by topic
3. **Chronology last** — Only use chronological order if story itself is a timeline and narrative progression requires it

**Assembly pacing strategy:**

- Alternate between energy states: if a take has high energy, follow with slightly lower energy to create rhythm
- For interview content: balance speaking vs. listening moments; don't stack multiple uninterrupted speaker takes
- For voiceover-driven: ensure B-roll pacing complements audio pacing; rapid cuts match energetic narration; static shots match contemplative sections
- Watch for momentum: each take should bridge to the next naturally, not feel isolated

**Check narrative continuity:**

1. `move_clip` each take sequentially with no gaps (butt cuts)
2. After each placement, ask: Does this take naturally follow the previous one? If the answer is "technically yes but narratively no", reconsider order
3. Look for unintended repetition: Are you showing the same content twice with different takes? If both survive, you have a problem

**Measure loudness per clip:**

- `measure_loudness` for all clips
- Flag inconsistencies > 6 LUFS with `set_marker`
- Note: These may be legitimate (interview subject speaks quietly vs. loudly) but should be visible during verification

## Step 5: Narrative Verification — Does the Story Work?

Before checking technical metrics, verify the assembly tells the intended story.

1. **Play through the entire assembly without stopping:**
   - Can someone unfamiliar with the project understand what they're hearing?
   - If clarity is lost, where does it break down?
   - Mark those sections for assembly re-ordering

2. **Emotional arc check:**
   - Does the pacing support emotional beats? (Fast when energy rises, slow when contemplative)
   - Do take selections align with emotional intention at each moment?
   - Is there appropriate tension and release, or does it feel monotone?

3. **Redundancy check:**
   - Does any content appear twice unintentionally?
   - Are all included takes necessary, or is something surviving by default rather than intent?
   - Ask about each take: "If I remove this, does the story suffer?" If not, mark it for deletion

4. **Continuity check:**
   - Does flow from one take to the next feel motivated by story or arbitrary?
   - Are there places where the assembly jumps thematically without a bridge?
   - Are there orphan takes that feel isolated from surrounding context?

Mark all issues with `set_marker` for review. You may need to re-order assembly sections, re-select takes, or trim internal content.

## Step 6: Technical Verification — Audio & Workflow Integrity

After narrative verification, confirm technical execution.

1. `verify_playback` mode "quick":
   - Audio present at all checkpoints
   - No dead air > 1s at boundaries (assembly should feel continuous)
   - All clips play in order without gaps

2. `analyze_audio_energy` on the assembly:
   - Speech ratio should be > 70% (dead air removed)
   - Overall score should be higher than raw footage average
   - If not, mark sections for additional trimming or dead air removal

3. `get_state` — Confirm workflow completeness:
   - All clips named with take numbers (format: "Take N: [content]")
   - All rejected takes marked with color labels
   - Markers set at each section start or problematic boundary
   - No gaps between clips (butt cuts throughout)
   - Loudness inconsistencies marked (> 6 LUFS variance)

4. **Final checklist:**
   - Do you have a saved backup of this assembly before any further refinement?
   - Have you documented which takes were selected and why (if needed for handoff)?

Report done only after both narrative and technical verification are complete.

## What NOT to Do

**Technical mistakes:**
- Never delete a take without confirming a better version exists (archive it with color label instead)
- Never trim into spoken content — trim silence around speech, not speech itself
- Never skip audio energy analysis — it's the fastest way to find takes in raw footage
- Never assemble without checking for duplicate content

**Editorial mistakes:**
- Never select takes based solely on audio energy metrics; verify that each take serves the narrative
- Never assemble in strict chronological order if the story suggests a different arrangement
- Never trim aggressively until you understand context; mark ambiguous boundaries with markers for review
- Never report done without narrative verification; technical quality matters less than story clarity

**Workflow mistakes:**
- Never skip the preparation step; understanding content type and story intent saves time downstream
- Never forget version control; keep "pre-trim" and "before final assembly" backups
- Never assume metrics tell the whole story; listen to rejected takes if narrative questions arise during assembly

**Remember:** The rough cut's job is story clarity and structural coherence, not technical perfection. A rough cut with clear narrative beats and authentic takes is complete. Audio balance, color, and polish come later.
