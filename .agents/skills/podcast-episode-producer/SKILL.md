---
name: podcast-episode-producer
description: Produce edited podcast episodes from raw recordings. Handles transcription, episode detection, extraction, overlay setup, cuts, and export. Use when the user asks to produce a podcast episode, extract an episode, set up overlays or lower thirds, export a podcast, or work on Technologia Talks.
allowed-tools: import_media add_to_timeline transcribe_asset analyze_transcript extract_segment get_transcript_with_timing search_transcript set_overlay_config remove_section split_clip ripple_delete export_video save_snapshot restore_snapshot get_state set_caption_style set_zoom take_screenshot
---

# Podcast Episode Producer

You produce edited podcast episodes from raw multi-hour recordings. Your job is to find the real episodes (not rehearsals or pre-show), extract them cleanly, apply broadcast overlays, make precise cuts, and export.

## Step 0: Import and transcribe

1. `import_media` — bring the raw recording in
2. `add_to_timeline` — put it on the timeline
3. `transcribe_asset` — get the full transcript (async for files >5min, poll `get_transcript` until ready)
4. `save_snapshot` label="raw_import" — ALWAYS save before any edits

## Step 1: Analyze with Claude — NEVER SKIP THIS

1. `analyze_transcript` — sends full transcript to Claude for comprehension
2. Claude identifies:
   - Real episodes (not rehearsals, pre-show chatter, or intro takes)
   - Exact start/end timestamps for each episode
   - Topics discussed in each episode
   - Pre-show sections, post-show wrap-up, off-camera moments
3. **DO NOT use `detect_episodes`** — it's regex pattern matching ("welcome to"), not comprehension. It WILL find rehearsal intros and pre-show takes as false positives.
4. Read Claude's analysis carefully — it distinguishes pre-show from real content.

## Step 2: Extract the episode

1. Use the timestamps from `analyze_transcript` — Claude's timestamps, not keyword matching
2. `extract_segment` with `source_start` and `source_end`
3. **VERIFY** the first words match the expected episode start:
   - `get_transcript_with_timing` for the first 30 seconds
   - Watch for multiple takes — hosts often do 2-3 intro takes ("Welcome to..."). Use the LAST clean take.
   - The first take is usually incomplete or has mistakes
4. `save_snapshot` label="episode_extracted"

## Step 2.5: Post-extraction analysis — Narrative arc verification (MANDATORY)

After extracting, run `analyze_transcript` AGAIN on just the extracted episode:

1. `analyze_transcript` — Claude now reads ONLY the episode content, not the full recording
2. This second pass gives you:
   - **Exact topic transitions** within the episode (with timeline-relative timestamps)
   - **Verification** that start/end are clean (no rehearsal, no behind-scenes chatter leaked in)
   - **Chapter descriptions** tuned to the episode's actual content
   - **Narrative arc identification:**
     - Setup: What question, conflict, or promise is established? (usually first 15-20%)
     - Conflict/Content: What's the core discussion or tension? (usually middle 60%)
     - Resolution/Payoff: How does the episode resolve or deliver on the promise? (usually final 20%)
   - **Tension-payoff moments:** Where does tension build and where is it released? These moments should anchor chapter placement.
   - **Any issues** — dead sections, off-topic tangents, content that should be cut

3. Use these refined timestamps for the overlay topics/chapters — they're more accurate than the first-pass timestamps which were relative to the full 2+ hour recording

4. **Story-driven chapter strategy:** Don't just mark topic transitions. Place chapters at emotional beats, not just content shifts:
   - Place a chapter at the setup/conflict transition (where energy shifts)
   - Place chapters at tension-building moments (not between them)
   - Reserve a chapter for the payoff/resolution moment
   - This makes the chapter structure reinforce the narrative arc

5. If Claude says the start has rehearsal or the end has post-show chatter, re-extract with tighter bounds

**Why two analysis passes + narrative verification?**
- First pass (Step 1): finds episodes in 2+ hours of raw recording. Rough boundaries.
- Second pass (Step 2.5): refines the extracted episode. Exact topic structure AND narrative shape.
- Narrative verification: ensures chapters support the story, not just organize content.

## Step 2.75: Hook identification and intro strategy

Before designing overlays, identify the episode's strongest moment and decide on intro approach.

### Hook Identification

1. From the second `analyze_transcript` pass (Step 2.5), identify the **strongest moment** in the episode:
   - A surprising statement or revelation
   - A peak emotional beat (conflict or breakthrough)
   - The most compelling answer to the episode's core question
   - A moment that makes the audience say "Wait, what?"

2. Use `search_transcript` to find the exact timestamp of this moment (with surrounding context)

3. Note the moment's context: What setup is needed for viewers to understand its impact?

### Intro Strategy: Three Approaches

**Approach 1: Cold Open (Recommended for strong hooks)**
- Extract 15-30 seconds of the strongest moment as the intro hook
- Play it uninterrupted to grab attention immediately
- Then add a transition (music, text overlay) that signals a reset
- Return to episode start with context ("Here's how we got here...")
- Best for: Surprising statements, dramatic reveals, strong opinions
- Why: Captures the first-3-second grab; creates narrative tension

**Approach 2: Trailer-Style Intro (For multiple hooks)**
- If the episode has 2-3 strong moments, create a montage intro (max 30 seconds)
- Rapid-fire cutting between hook moments with music bridges
- Signals: "This episode has multiple payoffs"
- Then begin the episode from start
- Best for: Complex episodes with multiple discussion threads
- Why: Maintains variety; gives viewers multiple reasons to stay invested

**Approach 3: Standard Intro (For content-driven episodes)**
- Begin the episode at its natural start (no hook extraction)
- Use the title card + host intro to establish context and authority
- Best for: Educational content, interviews where the guest introduction matters
- Why: Builds credibility before diving into content; appropriate when narrative arc matters less than expert positioning

### Pre-Overlay Verification

Before moving to Step 3, decide:
- Which approach fits this episode's content and emotional arc?
- If using cold open: Is there a clean 15-30 second moment to extract?
- If using trailer: Which 2-3 moments should the montage highlight?
- If standard: Does the natural opening grab attention within 3 seconds?

**Note:** Hook strategy directly impacts chapter placement (Step 3) and YouTube metadata (Step 6). Document your choice now.

## Step 3: Set up overlay from template (pacing + emotional strategy)

1. `set_overlay_config` with `template="technologia_talks"` (loads hosts, photos, sponsors)
   - Only need to add: `episode_title`, `episode_subtitle`, `topics`, `chapters`
   - If no template system yet, set the full config with correct host info:
     - Host A (left): Tadiwa Mbuwayesango, Co-Host · Founder, LEARN-X
     - Host B (right): Elvis Kimara, Co-Host · Founder, Throwly

2. Topics and chapters: use `search_transcript` to find REAL timestamps for each topic
   - **NEVER guess timestamps** — always verify from the transcript
   - Convert source timestamps to timeline-relative (subtract episode start time)
   - **These chapters appear in THREE places — they MUST be consistent:**
     a. The overlay's chapter cards (pop up during video playback)
     b. The overlay's ticker (scrolls current topic at the bottom)
     c. The YouTube description (viewer chapter navigation)
   - Build ONE list of timestamped topics, use it for ALL three

3. **Pacing strategy: Chapter placement affects perceived energy**
   - Aim for 5-8 chapters minimum. Cover every major topic shift.
   - **Vary chapter spacing strategically:**
     - Shorter gaps (1-2 min) between chapters during high-energy/tension-building sections
     - Longer gaps (3-5 min) during lower-energy or explanatory sections
     - This variation signals emotional rhythm to viewers
   - **Place chapters at tension peaks, not between them:** A chapter at a moment of conflict or breakthrough lands harder than one before it starts
   - **Reserve the final chapter for resolution/payoff:** This is where viewers learn if the episode delivered on its promise

4. **Chapter naming strategy:**
   - Each chapter name should promise something, not just label a topic
   - Instead of "Market Research" -> "Why Most Startup Research Fails"
   - Instead of "Fundraising" -> "The Counterintuitive Pitch Strategy"
   - Promise-based naming maintains curiosity as viewers progress through chapters

5. `set_caption_style` style="none" — unless captions are explicitly requested

**Why pacing matters in chapters?**
Chapters aren't just navigation markers. They're pacing signals. Quick chapter succession feels energetic; sparse chapters feel contemplative. Match chapter spacing to the episode's emotional arc, and the overlay becomes a storytelling tool, not just an organizational one.

## Step 4: Make cuts

Use `split_clip` + `ripple_delete` — the proven manual approach:

1. Get the clip ID from `get_state`
2. `split_clip` at the start boundary of the section to remove
3. `split_clip` at the end boundary (on the NEW clip that starts at the split point)
4. `ripple_delete` the middle clip (between the two splits)
5. After EVERY cut: overlay timestamps after the cut point shift automatically (if auto-shift is enabled). If not, manually update the overlay config.
6. `save_snapshot` after cuts

**DO NOT use `remove_section`** — it has known issues with deleting entire clips instead of just the slice.

**DO NOT use `auto_cut`** on episodes longer than 5 minutes — it creates 100+ clips which can crash export. Use it only on short clips (<2 min) or in `dry_run` mode to preview what would be cut.

## Step 4.5: Audio quality baseline check

Before export, verify the episode meets audio standards for broadcast podcast distribution.

### Normalize Audio Levels

1. Check that all voice levels are balanced to similar loudness across the episode
   - Use loudness metering (LUFS) to verify consistency
   - Target loudness: **-16 LUFS for podcast distribution**
   - This ensures consistent volume across all playback systems
   - **Why:** Normalized levels prevent listeners from adjusting volume constantly

2. If available in your editing environment:
   - Apply a light gate to any multi-speaker sections to reduce microphone bleed
   - This is critical if recording with multiple mics in the same room (hosts + guest)
   - Gate lets only full-volume speech through, cutting low-level ambient noise

### Remove Non-Essential Audio

3. Remove filler sounds that distract from content:
   - **Always remove:** um, uh, er, ah, hmm (these are unintentional verbal tics)
   - **Conditionally remove:** like, you know, basically (tie these to speaker style; light use is OK)
   - **Preserve:** Natural pauses and breaths (removing ALL pauses makes dialogue robotic)
   - **Rule of thumb:** Silence between speakers should not exceed 0.5 seconds; within a speaker, not more than 0.3 seconds (except for intentional dramatic pauses up to 0.8 seconds)

4. Use `search_transcript` to identify these moments precisely
   - Never rely on audio visualization alone; cross-reference with transcript
   - Mark each filler word before removing (use colored markers if available) to ensure precision

### Verify Sonic Clarity

5. For multi-speaker episodes (host + guest), verify:
   - Host A and Host B have consistent tone and presence
   - Any guest voice isn't buried or too bright compared to hosts
   - Background noise is minimal (fan hum, room echo, etc.)

6. If the original recording has significant background noise:
   - Note it but do not over-process; light noise is acceptable in casual podcasts
   - Heavy processing can make dialogue sound artificial

### Why This Matters

Audio quality affects listener retention as much as story. Professional-sounding audio signals credibility. Episodes with unbalanced levels, excessive filler words, or harsh audio create listener fatigue and drop-off, even if the content is strong.

**Before moving to Step 5 (export), confirm:**
- All voices are normalized to similar loudness
- Filler words are removed
- Silence is intentional (not dead air)
- No obvious background noise dominates

## Step 5: Verify and export

1. `get_state` — verify timeline duration is correct (original minus sum of all cuts)
2. `set_zoom` level="fit" then `take_screenshot` — verify overlay rendering looks correct
3. `export_video` preset="high" filename="EpisodeN_Title"
4. Verify export file exists and has reasonable size

## Step 6: Generate YouTube metadata (hook-driven strategy)

After export, create metadata that hooks viewers immediately. Your title, description, and chapter list are marketing tools, not just organization.

### Title: Hook + Context Formula

Use the strongest moment from your hook identification (Step 2.75) as the title anchor:

**Formula: [Strong Claim/Question] | [Show Name]**

Examples:
- "Most Startup Feedback Is Useless" | Technologia Talks (strong claim)
- "Why You're Building The Wrong MVP" | Technologia Talks (provocative claim)
- "The Unfair Advantage Nobody Talks About" | Technologia Talks (intrigue + promise)

**Title Rules:**
- Lead with the hook, not with names or episode number
- Keep it under 60 characters for full display on mobile
- Include your show name (Technologia Talks) for brand recognition
- Avoid clickbait that contradicts the episode content (breaks trust)
- Test the title on people unfamiliar with the episode — does it make them curious?

### Description: Hook + Context + Chapters

Structure your description in three layers:

**Layer 1: The Hook (2-3 sentences max)**
- Start with the most compelling insight or question from the episode
- Don't over-explain; make viewers curious enough to watch
- Example: "What if the problem with your startup isn't your idea — it's how you're validating it? This week, we break down why 80% of startup feedback is worthless, and what questions actually matter."

**Layer 2: Episode Context (1-2 sentences)**
- Who is this episode for? What will they learn?
- Example: "Perfect for founders, product managers, or anyone building something new."

**Layer 3: Chapters (Formatted for navigation)**
- Use the chapters from your overlay, formatted as: `M:SS - Topic Name`
- **YouTube requires `0:00` as the first chapter (always)**
- Match these timestamps exactly to your overlay chapters

Format:
```
⏱️ CHAPTERS:
0:00 - Intro
0:46 - Topic One
3:48 - Topic Two
...
[Continue for all chapters]
```

**Layer 4: Host Info (Optional but Recommended)**
- Include guest or guest expert info if relevant
```
🎙️ HOSTS:
Tadiwa Mbuwayesango — Co-Host · Founder, LEARN-X
Elvis Kimara — Co-Host · Founder, Throwly
```

### Tags & Hashtags

Add 5-8 relevant tags/hashtags for discoverability:
- Show name: #technologiatalks
- Topic keywords: #startups, #entrepreneurship, #productmanagement
- Episode-specific: #feedback, #validation, #MVP
- Platform signals: #podcast, #entrepreneurpodcast

### Complete Metadata Example

```
TITLE:
Most Startup Feedback Is Useless | Technologia Talks

DESCRIPTION:
What if the problem with your startup isn't your idea — it's how you're validating it? This week, we break down why 80% of startup feedback is useless, and what questions actually matter.

For founders and product builders working on early-stage ideas.

⏱️ CHAPTERS:
0:00 - Intro
0:46 - Why Most Founders Ask Wrong Questions
3:12 - The Difference Between Feedback and Validation
6:44 - How To Run A Real Validation Interview
11:22 - Common Mistakes That Kill Your Learning
15:08 - Building Your Feedback System
19:30 - Outro

🎙️ HOSTS:
Tadiwa Mbuwayesango — Co-Host · Founder, LEARN-X
Elvis Kimara — Co-Host · Founder, Throwly

#startups #entrepreneurship #productmanagement #validation #technologiatalks
```

### Why This Matters

YouTube's algorithm prioritizes watch time and click-through rate. A compelling title and hook-driven description increase both. Chapters improve viewer experience AND signal to YouTube that your content is well-structured (algorithm bonus). Metadata isn't an afterthought — it's part of the production.

**Before publishing, verify:**
- Title hooks within the first few words
- Description answers "Why should I watch this?"
- Chapters are accurate and promise-driven
- All timestamps match your overlay

**Present this to the user after export. Do not skip this step.**

## Step 7: Generate Thumbnail

After export, generate a branded thumbnail using `generate_thumbnail`. The default provider is `"local"` — a programmatic renderer that uses real host photos with background removal, perfect text, and brand colors. No AI API calls needed.

### Brand Identity (Technolgia)

The brand theme is defined in the overlay template (`technologia_talks.json`) under the `brand` key. The renderer loads it automatically:

- **Background:** Dark black (#000000) base with dark emerald green (#0A3D2A) gradient panels
- **Accents:** Gold (#C8A84E) corner lines and emphasis text
- **Text:** Title in white, subtitle in gold — rendered programmatically (no AI misspellings)
- **Logo:** Technolgia logo composited from file
- **Host photos:** Real photos with background removed (Vision framework) and feathered edges

### Layouts

- `split_panel` (default) — Two hosts side by side, title at bottom
- `centered` — Hosts angled inward at bottom, title at top (debate/versus energy)
- `text_heavy` — Small circular host photos, massive title dominates

### How to Generate

**Recommended (AI background + real photos):**
```
generate_thumbnail(
  title="<short punchy title, 3-5 words>",
  subtitle="<subtitle line>",
  template="technologia_talks",
  description="<topic description — drives the visual background>",
  provider="hybrid"
)
```

The `hybrid` provider generates a topic-relevant background with AI (Gemini), then composites real host cutout photos on top with programmatic text and brand badge. The `description` field is critical — it drives what appears in the background. Be specific about companies, technologies, people, or concepts.

**Quick/instant (no AI, gradient background):**
```
generate_thumbnail(
  title="<episode title>",
  subtitle="<subtitle line>",
  template="technologia_talks",
  layout="split_panel"
)
```

**Full AI generation (experimental — faces may be altered):**
Pass `provider="flux"` or `provider="gemini"` for fully AI-generated thumbnails.

### Title Strategy

- First line (title): the hook — strong claim or question
- Second line (subtitle): the payoff — context or promise
- Keep both lines short for readability at small YouTube sizes

## What NOT to do

- **Never** use `detect_episodes` for finding real episodes — use `analyze_transcript`
- **Never** guess topic/chapter timestamps — search the transcript
- **Never** use `auto_cut` on long episodes (100+ clips crashes export)
- **Never** forget to `save_snapshot` before destructive operations
- **Never** set captions unless explicitly asked
- **Never** assume the first "Welcome to..." is the real intro — check for multiple takes
- **Never** use `remove_section` — use split_clip + ripple_delete instead
- **Never** export without verifying timeline duration matches expected
- **Never** place chapters purely on topic shifts — consider emotional pacing and tension points
- **Never** use generic metadata — hook-driven titles and descriptions drive YouTube performance

## Overlay Reference (Technologia Talks)

Timing at 30fps:
- Title card: 0-30s (fade in, hold, fade out)
- Host intro strip: 38s-1:32 (gold bar with photos, slides up from bottom)
- Name bars: always visible (bottom, above ticker)
- Smart ticker: bottom bar with sponsors cycling with current topic
- Chapter cards: pop in at chapter timestamps (centered, 6s display)

Host photos are at:
- `/Users/explicit/Library/Containers/com.videoeditor.app/Data/Documents/tadiwa.jpg`
- `/Users/explicit/Library/Containers/com.videoeditor.app/Data/Documents/elvis.jpg`
