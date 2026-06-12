# Local-Agent Analysis Pattern — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the editor's Anthropic API dependency for content analysis. Four MCP tools and one new tool return a "prompt-pack" (instruction + data); the driving agent (Claude Code / Codex / Cursor / in-app chat) does the reasoning in its own session.

**Architecture:** Extract every Claude-bound prompt into a new pure-Swift module `AnalysisPromptPack`. Handlers in `MCPServer.swift` shrink to: assemble inputs, call the pure builder, return the string. The new `scan_episode_chatter` tool slots in after `extract_segment` to find in-episode chatter (false starts, host coaching, abandoned takes). Skill updates make the new step explicit and direct agents to ultrathink.

**Tech Stack:** Swift 6.1, Swift Testing (`@Suite`, `@Test`, `#expect`), XcodeGen-managed `VideoEditor` target, no new dependencies. Uses the existing `TranscriptAnalysisSupport.buildTimestampedTranscript` helper for transcript formatting.

---

## Spec reference

`docs/superpowers/specs/2026-05-26-local-agent-analysis-pattern-design.md`

## File structure

| File | Purpose | Status |
|------|---------|--------|
| `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift` | Pure functions that build prompt-pack strings (one per analysis type). Single responsibility: take transcript+params, return text. Easy to unit test, no AppState dependency. | **Create** |
| `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift` | Swift Testing suite covering every prompt-builder. Verifies header + body shape. | **Create** |
| `VideoEditor/VideoEditor/App/MCPServer.swift` | Shrink 4 handlers (analyze_transcript / find_viral_moments / extract_clips / hook_optimize) to call the new pack. Add `scan_episode_chatter` tool registration + handler. Remove `ClaudeProvider` and `loadAnthropicKey()` usage from those handlers. | **Modify** |
| `.claude/skills/podcast-episode-producer/SKILL.md` | New Step 2.6 "Scan in-episode chatter" + ultrathink directives at analyze steps + Step 1/2.5 note that tools return prompts. | **Modify** |
| `.agents/skills/podcast-episode-producer/SKILL.md` | Identical mirror of above. | **Modify** |
| `CLAUDE.md` | Mark `ANTHROPIC_API_KEY` optional (in-app chat only). | **Modify** |

`ClaudeProvider` itself is NOT deleted — it's still used by `AIChatController` and by `extractBrollQueries` (B-roll search-query helper, out of scope).

---

## Task 1: Create `AnalysisPromptPack` module with `buildAnalyzeTranscriptPrompt`

**Files:**
- Create: `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift`
- Create: `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift`

- [ ] **Step 1: Write the failing test**

Create `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift`:

```swift
import Testing
import Foundation
@testable import VideoEditor

@Suite("AnalysisPromptPack")
struct AnalysisPromptPackTests {

    @Test("analyze_transcript prompt has thinking directive, prompt body, and transcript")
    func analyzeTranscriptPromptShape() {
        let transcript = "[0:00] Hello world.\n[0:05] This is a test."

        let pack = AnalysisPromptPack.buildAnalyzeTranscriptPrompt(timestampedTranscript: transcript)

        #expect(pack.contains("<EXTENDED_THINKING_REQUIRED>"))
        #expect(pack.contains("</EXTENDED_THINKING_REQUIRED>"))
        #expect(pack.contains("How many REAL episodes"))
        #expect(pack.contains("EPISODES: [number]"))
        #expect(pack.contains(transcript))
        // Thinking block must come before the prompt body
        let thinkRange = pack.range(of: "</EXTENDED_THINKING_REQUIRED>")!
        let promptRange = pack.range(of: "How many REAL episodes")!
        #expect(thinkRange.upperBound <= promptRange.lowerBound)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests 2>&1 | tail -20
```
Expected: BUILD FAILURE — `AnalysisPromptPack` is undefined.

- [ ] **Step 3: Create the module**

Create `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift`:

```swift
import Foundation

/// Builds "prompt-pack" tool outputs: an ultrathink directive, a prompt, and the data
/// the prompt needs. Returned to the calling MCP agent (Claude Code, Codex, Cursor,
/// or the in-app chat session) which then does the analysis in its own LLM turn.
///
/// All functions are pure — no AppState, no I/O, easy to unit-test.
public enum AnalysisPromptPack {

    private static let thinkingPreamble = """
    <EXTENDED_THINKING_REQUIRED>
    Think deeply before producing the analysis. Re-read every line of the transcript
    or data below. Be rigorous, not fast.
    </EXTENDED_THINKING_REQUIRED>

    """

    public static func buildAnalyzeTranscriptPrompt(timestampedTranscript: String) -> String {
        let body = """
        You are analyzing a recording transcript to identify its structure. Read the ENTIRE transcript below carefully, then tell me:
        The FULL transcript available for this task is included below. Never ask for more transcript, never say it was cut off, and never request additional context.
        If the transcript is brief, analyze only what is present and state the limitation as part of the analysis instead of refusing.

        1. How many REAL episodes are in this recording? A real episode is structured content intended for an audience — it has a topic, develops that topic, and delivers value. Casual conversation between hosts about their own channel/views/setup is NOT an episode even if it has an intro tagline.

        2. For each real episode:
           - Exact start timestamp [MM:SS]
           - Exact end timestamp [MM:SS]
           - Title (from the intro if there is one)
           - Topic summary (what is the episode actually about?)
           - Key points discussed

        3. What are the other sections? (pre-show conversation, planning, off-camera, rehearsal/re-takes, wrap-up)
           - For each non-episode section, give start/end timestamps and a brief description

        Important rules:
        - An intro tagline ("Welcome to X") does NOT make something an episode. The content after the intro must actually deliver on the promise. If they say "Welcome to Technologer" and then talk about their own YouTube views and mic setup, that's NOT an episode.
        - Multiple intro attempts close together are rehearsals, not separate episodes.
        - "Off camera" or discussing what to record next = planning, not episode content.
        - Look for topic commitment — does the conversation develop a subject for 10+ minutes in a way a viewer would find valuable?

        Format your response as:

        EPISODES: [number]

        EPISODE 1:
        Start: [MM:SS]
        End: [MM:SS]
        Title: [title]
        Topic: [what it's about]
        Key points: [bullet list]

        OTHER SECTIONS:
        [MM:SS]-[MM:SS]: [type] — [description]

        Here is the full transcript:

        \(timestampedTranscript)
        """
        return thinkingPreamble + body
    }
}
```

- [ ] **Step 4: Register the new file with XcodeGen and regenerate**

```bash
cd VideoEditor && xcodegen generate 2>&1 | tail -5
```
Expected: `Generated project successfully` (the new `.swift` file is auto-picked up under the `App/` folder).

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests 2>&1 | tail -20
```
Expected: PASS — 1/1 tests.

- [ ] **Step 6: Commit**

```bash
git add VideoEditor/VideoEditor/App/AnalysisPromptPack.swift \
        VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift \
        VideoEditor/VideoEditor/project.yml VideoEditor/VideoEditor.xcodeproj 2>/dev/null || true
git add VideoEditor/VideoEditor/App/AnalysisPromptPack.swift VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift
git commit -m "feat(mcp): introduce AnalysisPromptPack with analyze_transcript builder"
```

---

## Task 2: Refactor `handleAnalyzeTranscript` to return a prompt-pack

**Files:**
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift:3932-4140` (approximately — the entire `handleAnalyzeTranscript` body, including the second-pass refinement loop)

- [ ] **Step 1: Read current handler bounds to know what to replace**

```bash
sed -n '3932,4140p' /Users/explicit/Projects/video-editor/VideoEditor/VideoEditor/App/MCPServer.swift | head -220
```
Note the exact end of `handleAnalyzeTranscript` (look for the `}` that closes the function — should be near line 4135).

- [ ] **Step 2: Replace the handler body**

Open `VideoEditor/VideoEditor/App/MCPServer.swift`. Replace the body of `handleAnalyzeTranscript` (everything between the function's `{` on line 3932 and its closing `}`) with:

```swift
    private func handleAnalyzeTranscript(_ args: [String: Any], appState: AppState) async -> String {
        guard let assetIDStr = args["asset_id"] as? String,
              let assetID = UUID(uuidString: assetIDStr),
              let asset = appState.assets.first(where: { $0.id == assetID }) else {
            return "Error: Invalid asset_id"
        }

        guard let result = await appState.media.transcriptionService.getTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) else {
            return "Error: No transcript. Run transcribe_asset first."
        }

        let words = result.words
        let transcript = TranscriptAnalysisSupport.buildTimestampedTranscript(from: words)
        let coverage = TranscriptAnalysisSupport.assessCoverage(
            words: words,
            assetDuration: asset.duration
        )

        if coverage.isSparseForStructuralAnalysis {
            let startText = TranscriptAnalysisSupport.formatTimestamp(coverage.firstStart ?? 0)
            let endText = TranscriptAnalysisSupport.formatTimestamp(coverage.lastEnd ?? 0)
            let assetDurationText = String(format: "%.1f", asset.duration)
            let spanText = String(format: "%.1f", coverage.speakingSpan)

            return """
            === TRANSCRIPT ANALYSIS ===

            EPISODES: 0

            OTHER SECTIONS:
            [\(startText)]-[\(endText)]: incomplete captured excerpt — only \(coverage.wordCount) transcript words are available for structural analysis.

            LIMITATION:
            Transcript coverage is sparse for this asset: \(coverage.wordCount) words spanning \(spanText)s of speech within a \(assetDurationText)s recording. That is not enough material to identify real episodes, full sections, or reliable topic development.

            Transcript excerpt:
            \(transcript.isEmpty ? "[no transcript text available]" : transcript)
            """
        }

        return AnalysisPromptPack.buildAnalyzeTranscriptPrompt(timestampedTranscript: transcript)
    }
```

This deletes ~170 lines (the Claude API call + two-pass refinement). The sparse-transcript early-return is preserved verbatim.

- [ ] **Step 3: Build to verify nothing else referenced the removed code**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`. If anything errors (e.g. an unused `parseEpisodeStarts` helper), check whether that helper is used elsewhere and delete if not.

- [ ] **Step 4: Manual integration test**

In a separate terminal, with a transcribed asset already on the timeline:

```bash
python3 -c "
import json, urllib.request
asset_id = 'YOUR-ASSET-UUID'
payload = {'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'analyze_transcript','arguments':{'asset_id':asset_id}}}
req = urllib.request.Request('http://localhost:8420/mcp', data=json.dumps(payload).encode(),
  headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
print(urllib.request.urlopen(req, timeout=30).read().decode()[:2000])
"
```
Expected: result text starts with `<EXTENDED_THINKING_REQUIRED>`, contains the prompt body and the full timestamped transcript. No `Error: ANTHROPIC_API_KEY`.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "refactor(mcp): analyze_transcript returns prompt-pack instead of calling Claude API"
```

---

## Task 3: Add `scan_episode_chatter` tool

**Files:**
- Modify: `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift` — add `buildScanEpisodeChatterPrompt`
- Modify: `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift` — add test
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift` — register tool + dispatch + handler

- [ ] **Step 1: Add the failing test**

In `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift`, add inside the `@Suite`:

```swift
    @Test("scan_episode_chatter prompt covers all 6 chatter categories and uses timeline-relative timestamps")
    func scanEpisodeChatterPromptShape() {
        let transcript = "[0:00] Welcome.\n[0:15] So um, scratch that. Let's start over."
        let pack = AnalysisPromptPack.buildScanEpisodeChatterPrompt(
            timelineRelativeTranscript: transcript,
            durationSeconds: 60
        )

        #expect(pack.contains("<EXTENDED_THINKING_REQUIRED>"))
        #expect(pack.contains("ABANDONED TAKES"))
        #expect(pack.contains("HOST COACHING"))
        #expect(pack.contains("PRODUCTION CHATTER"))
        #expect(pack.contains("FALSE STARTS"))
        #expect(pack.contains("AGE / FACT CORRECTIONS"))
        #expect(pack.contains("HOST-TO-HOST ASIDES"))
        #expect(pack.contains("CUT [MM:SS]-[MM:SS]"))
        #expect(pack.contains("TOTAL CUT TIME"))
        #expect(pack.contains("60 seconds"))   // duration interpolated
        #expect(pack.contains(transcript))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests/scanEpisodeChatterPromptShape 2>&1 | tail -10
```
Expected: BUILD FAILURE — `buildScanEpisodeChatterPrompt` undefined.

- [ ] **Step 3: Add the builder to `AnalysisPromptPack`**

Append to `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift` (inside the `enum AnalysisPromptPack { ... }`):

```swift
    /// Builds the in-episode chatter scan prompt. Called AFTER `extract_segment` —
    /// transcript should already be windowed to the episode and timestamps should
    /// be timeline-relative (t=0 at the start of the episode clip).
    public static func buildScanEpisodeChatterPrompt(
        timelineRelativeTranscript: String,
        durationSeconds: Double
    ) -> String {
        let durText = String(format: "%.0f", durationSeconds)
        let body = """
        You are scanning an already-extracted podcast episode for in-episode chatter
        that must be cut. The transcript below is the EPISODE ONLY — timestamps are
        timeline-relative (t=0 is the start of the episode clip). Episode length is
        \(durText) seconds.

        Look for:

        1. ABANDONED TAKES — a speaker starts an answer, stops, then restarts.
           Cut from start-of-abandoned to start-of-clean.

        2. HOST COACHING — one host coaching the guest mid-flow ("you can say…",
           "we don't have to…"). Cut the coaching, not the surrounding content.

        3. PRODUCTION CHATTER — asides about technical issues, "we might need to
           scratch that", "can we redo that", camera switches, mic checks.

        4. FALSE STARTS that are NOT followed by a clean version — keep these
           (they're part of natural speech). Only cut a false start if a clean
           retake exists.

        5. AGE / FACT CORRECTIONS that interrupt the answer ("wait, how old were
           you again?", "actually I started at 23, not 25").

        6. HOST-TO-HOST ASIDES while the guest is silent ("Elvis, you want to take
           this?", "no, you go").

        For EACH cut, output exactly:
          CUT [MM:SS]-[MM:SS]: <one-line reason>

        Be conservative — only cut things clearly chatter. A 1-second laugh, a brief
        "yeah", or a natural pause should stay. Do not cut content that, while
        imperfect, is part of the conversational beat.

        After listing all cuts, output:
          TOTAL CUT TIME: <seconds>
          EXPECTED FINAL DURATION: <\(durText) - total_cut>

        Here is the timestamped episode transcript:

        \(timelineRelativeTranscript)
        """
        return thinkingPreamble + body
    }
```

- [ ] **Step 4: Run prompt-pack tests, expect pass**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests 2>&1 | tail -10
```
Expected: PASS — 2/2 tests.

- [ ] **Step 5: Register the tool in `MCPServer.swift`**

In `VideoEditor/VideoEditor/App/MCPServer.swift`, find the `analyze_transcript` registration block (around line 401) and insert a new entry directly after it:

```swift
                [
                    "name": "scan_episode_chatter",
                    "description": "Scan an already-extracted episode clip for in-episode chatter (abandoned takes, host coaching, production asides, false starts with clean retakes, age/fact corrections, host-to-host asides). Returns a prompt for the agent to ultrathink and produce a CUT list. Run AFTER extract_segment, BEFORE making cuts.",
                    "inputSchema": ["type": "object", "properties": [
                        "asset_id": ["type": "string", "description": "UUID of the asset to scan"],
                        "start": ["type": "number", "description": "Source start time in seconds (defaults to 0)"],
                        "end": ["type": "number", "description": "Source end time in seconds (defaults to asset duration)"],
                    ], "required": ["asset_id"]],
                ],
```

- [ ] **Step 6: Dispatch the tool in the handler switch**

Find the dispatch block where `analyze_transcript` is routed (around line 825):

```swift
        if name == "analyze_transcript" {
            return await handleAnalyzeTranscript(arguments, appState: appState)
        }
```

Insert directly after it:

```swift
        if name == "scan_episode_chatter" {
            return await handleScanEpisodeChatter(arguments, appState: appState)
        }
```

- [ ] **Step 7: Implement the handler**

Add a new method to the `MCPServer` class, immediately AFTER `handleAnalyzeTranscript` (so the analysis-related handlers stay grouped). Approximate insertion: just after the closing `}` of `handleAnalyzeTranscript`.

```swift
    private func handleScanEpisodeChatter(_ args: [String: Any], appState: AppState) async -> String {
        guard let assetIDStr = args["asset_id"] as? String,
              let assetID = UUID(uuidString: assetIDStr),
              let asset = appState.assets.first(where: { $0.id == assetID }) else {
            return "Error: Invalid asset_id"
        }

        let rangeStart = (args["start"] as? Double) ?? 0
        let rangeEnd = (args["end"] as? Double) ?? asset.duration
        guard rangeEnd > rangeStart else {
            return "Error: end must be greater than start"
        }

        guard let result = await appState.media.transcriptionService.getTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) else {
            return "Error: No transcript. Run transcribe_asset first."
        }

        // Window the transcript to [start, end] and shift timestamps so t=0 is `start`.
        let windowed = result.words
            .filter { $0.start >= rangeStart && $0.end <= rangeEnd }
            .map { word -> TranscriptWord in
                TranscriptWord(
                    word: word.word,
                    start: word.start - rangeStart,
                    end: word.end - rangeStart,
                    confidence: word.confidence
                )
            }

        guard !windowed.isEmpty else {
            return "Error: No transcript words in [\(rangeStart), \(rangeEnd)]. Check the range."
        }

        let transcript = TranscriptAnalysisSupport.buildTimestampedTranscript(from: windowed)
        return AnalysisPromptPack.buildScanEpisodeChatterPrompt(
            timelineRelativeTranscript: transcript,
            durationSeconds: rangeEnd - rangeStart
        )
    }
```

Note: `TranscriptWord` is the type used by `result.words`; check its initializer in `EditorCore` if the exact init label differs (the current model uses `word/start/end/confidence`).

- [ ] **Step 8: Build to verify**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`. If `TranscriptWord` init differs, adjust the windowing map.

- [ ] **Step 9: Integration test**

Relaunch the editor, restore an extracted-episode snapshot, then:

```bash
python3 -c "
import json, urllib.request
payload = {'jsonrpc':'2.0','id':1,'method':'tools/call',
  'params':{'name':'scan_episode_chatter','arguments':{'asset_id':'YOUR-ASSET','start':1463,'end':4517}}}
req = urllib.request.Request('http://localhost:8420/mcp', data=json.dumps(payload).encode(),
  headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
print(urllib.request.urlopen(req, timeout=30).read().decode()[:3000])
"
```
Expected: prompt-pack with `<EXTENDED_THINKING_REQUIRED>`, the 6 chatter categories, and a timeline-relative transcript starting at `[0:00]`.

- [ ] **Step 10: Commit**

```bash
git add VideoEditor/VideoEditor/App/AnalysisPromptPack.swift \
        VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift \
        VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "feat(mcp): add scan_episode_chatter tool for in-episode cut detection"
```

---

## Task 4: Refactor `handleFindViralMoments` to prompt-pack

**Files:**
- Modify: `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift` — add `buildFindViralMomentsPrompt`
- Modify: `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift` — add test
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift:3612-3920` — shrink handler

- [ ] **Step 1: Add the failing test**

In `AnalysisPromptPackTests.swift`:

```swift
    @Test("find_viral_moments prompt has duration constraints, JSON instruction, and word data")
    func findViralMomentsPromptShape() {
        let wordJSON = #"[{"w":"hello","s":0.1,"e":0.5,"sp":"0"}]"#
        let pack = AnalysisPromptPack.buildFindViralMomentsPrompt(
            wordEntriesJSON: wordJSON,
            minDuration: 15,
            maxDuration: 90,
            maxMoments: 40
        )

        #expect(pack.contains("<EXTENDED_THINKING_REQUIRED>"))
        #expect(pack.contains("15-90 second"))
        #expect(pack.contains("up to 40"))
        #expect(pack.contains(wordJSON))
    }
```

- [ ] **Step 2: Run test, verify it fails**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests/findViralMomentsPromptShape 2>&1 | tail -10
```
Expected: BUILD FAILURE — `buildFindViralMomentsPrompt` undefined.

- [ ] **Step 3: Add the builder**

In `AnalysisPromptPack.swift`, copy the prompt body verbatim from `MCPServer.swift` lines 3680-3790 (the existing `let prompt = """ ... """` in `handleFindViralMoments`). Wrap as:

```swift
    public static func buildFindViralMomentsPrompt(
        wordEntriesJSON: String,
        minDuration: Double,
        maxDuration: Double,
        maxMoments: Int
    ) -> String {
        let body = """
        You are a social-media expert finding EVERY genuinely viral \(Int(minDuration))-\(Int(maxDuration)) second clip in a podcast/interview transcript. Reviewers will curate afterward — your job is to surface all the good ones, not a short top-N.

        [...COPY ENTIRE EXISTING PROMPT FROM MCPServer.swift handleFindViralMoments...]

        Return up to \(maxMoments) moments. Be thorough but honest — if there are only 8 genuinely viral moments, return 8, not 40.

        WORD ENTRIES (JSON):
        \(wordEntriesJSON)
        """
        return thinkingPreamble + body
    }
```

The exact existing prompt text spans roughly MCPServer.swift:3680-3790. Read those lines and paste them inline — do not summarize. Verbatim preservation matters: the analysis quality depends on the prompt content.

- [ ] **Step 4: Run test, verify it passes**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests 2>&1 | tail -10
```
Expected: PASS — 3/3 tests.

- [ ] **Step 5: Replace handler body**

In `MCPServer.swift`, replace `handleFindViralMoments` (lines 3612 to its closing `}`, ~3925) with:

```swift
    private func handleFindViralMoments(_ args: [String: Any], appState: AppState) async -> String {
        guard let assetIDStr = args["asset_id"] as? String,
              let assetID = UUID(uuidString: assetIDStr),
              let asset = appState.assets.first(where: { $0.id == assetID }) else {
            return "Error: Invalid asset_id"
        }

        let maxMoments = args["max_moments"] as? Int ?? (args["max_moments"] as? Double).map({ Int($0) }) ?? 40
        let minDuration = args["min_duration_seconds"] as? Double ?? 15.0
        let maxDuration = args["max_duration_seconds"] as? Double ?? 180.0

        guard let result = await appState.media.transcriptionService.getTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) else {
            return "Error: No transcript found. Run transcribe_asset first."
        }

        guard let speakers = result.speakers, !speakers.isEmpty else {
            return "Error: No speaker diarization found. Re-transcribe with transcribe_asset using the Deepgram provider (default), which supports speaker diarization."
        }

        let words = result.words
        guard !words.isEmpty else { return "Error: Transcript is empty." }

        let coverage = TranscriptAnalysisSupport.assessCoverage(words: words, assetDuration: asset.duration)
        if coverage.isSparseForStructuralAnalysis {
            let startText = TranscriptAnalysisSupport.formatTimestamp(coverage.firstStart ?? 0)
            let endText = TranscriptAnalysisSupport.formatTimestamp(coverage.lastEnd ?? 0)
            return """
            === VIRAL MOMENTS ===
            Asset: \(asset.name)

            Result: no viral moments found.
            Reason: transcript coverage is too sparse (\(coverage.wordCount) words from [\(startText)]-[\(endText)]) — not enough material to identify \(Int(minDuration))-\(Int(maxDuration))s viral clips.
            """
        }

        let wordEntries: [[String: Any]] = words.map { w in
            let speakerID = speakers.first(where: { $0.range.contains(w.start) })?.speakerID ?? "0"
            return ["w": w.word, "s": w.start, "e": w.end, "sp": speakerID]
        }
        guard let wordData = try? JSONSerialization.data(withJSONObject: wordEntries, options: []),
              let wordJSON = String(data: wordData, encoding: .utf8) else {
            return "Error: Failed to serialize transcript words."
        }

        return AnalysisPromptPack.buildFindViralMomentsPrompt(
            wordEntriesJSON: wordJSON,
            minDuration: minDuration,
            maxDuration: maxDuration,
            maxMoments: maxMoments
        )
    }
```

- [ ] **Step 6: Build and integration-test**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | tail -10
```
Then call the tool against a transcribed asset and verify the result starts with `<EXTENDED_THINKING_REQUIRED>` and contains the viral-moments prompt.

- [ ] **Step 7: Commit**

```bash
git add VideoEditor/VideoEditor/App/AnalysisPromptPack.swift \
        VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift \
        VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "refactor(mcp): find_viral_moments returns prompt-pack instead of calling Claude API"
```

---

## Task 5: Refactor `handleExtractClips` to prompt-pack

**Files:**
- Modify: `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift` — add `buildExtractClipsPrompt`
- Modify: `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift` — add test
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift:2821-~3070` — shrink handler

- [ ] **Step 1: Add the failing test**

```swift
    @Test("extract_clips prompt embeds count, duration constraints, and transcript")
    func extractClipsPromptShape() {
        let transcript = "[0:00] Hello.\n[0:05] World."
        let pack = AnalysisPromptPack.buildExtractClipsPrompt(
            timestampedTranscript: transcript,
            count: 5,
            minDuration: 30,
            maxDuration: 90
        )

        #expect(pack.contains("<EXTENDED_THINKING_REQUIRED>"))
        #expect(pack.contains("5 best moments"))
        #expect(pack.contains("30-90 seconds"))
        #expect(pack.contains(transcript))
    }
```

- [ ] **Step 2: Run test, verify fail**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests/extractClipsPromptShape 2>&1 | tail -10
```

- [ ] **Step 3: Add the builder**

In `AnalysisPromptPack.swift`, copy the existing extract-clips prompt verbatim from `MCPServer.swift` lines 2885-2935. Wrap as:

```swift
    public static func buildExtractClipsPrompt(
        timestampedTranscript: String,
        count: Int,
        minDuration: Double,
        maxDuration: Double
    ) -> String {
        let body = """
        You are finding the best short-form clip candidates from a podcast transcript.
        The FULL transcript available for this task is included below. Never ask for more transcript, never say it was cut off, and never emit tool calls.
        If the transcript is short or imperfect, still return the best candidates you can from the provided material.
        Find the \(count) best moments that would make great 30-90 second TikTok/Shorts/Reels clips.

        [...COPY remainder of existing prompt from MCPServer.swift lines 2891-2935 verbatim — items 1-8, ranges, format example...]

        Constraint: each clip must be \(Int(minDuration))-\(Int(maxDuration)) seconds.

        Here is the full transcript:

        \(timestampedTranscript)
        """
        return thinkingPreamble + body
    }
```

- [ ] **Step 4: Run test, expect pass**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests 2>&1 | tail -10
```

- [ ] **Step 5: Replace handler body**

In `MCPServer.swift`, shrink `handleExtractClips` to:

```swift
    private func handleExtractClips(_ args: [String: Any], appState: AppState) async -> String {
        guard let assetIDStr = args["asset_id"] as? String,
              let assetID = UUID(uuidString: assetIDStr),
              let asset = appState.assets.first(where: { $0.id == assetID }) else {
            return "Error: Invalid asset_id"
        }

        let count = args["count"] as? Int ?? (args["count"] as? Double).map({ Int($0) }) ?? 5
        let minDur = args["min_duration"] as? Double ?? 30
        let maxDur = args["max_duration"] as? Double ?? 90

        guard let result = await appState.media.transcriptionService.getTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) else {
            return "Error: No transcript. Run transcribe_asset first."
        }

        let words = result.words
        let transcript = TranscriptAnalysisSupport.buildTimestampedTranscript(from: words)
        let coverage = TranscriptAnalysisSupport.assessCoverage(words: words, assetDuration: asset.duration)

        if coverage.isSparseForStructuralAnalysis {
            // [Preserve the existing sparse-coverage early-return block verbatim from
            // current MCPServer.swift:2846-2876 — same text, same format.]
            let startText = TranscriptAnalysisSupport.formatTimestamp(coverage.firstStart ?? 0)
            let endText = TranscriptAnalysisSupport.formatTimestamp(coverage.lastEnd ?? 0)
            let hook = words.prefix(12).map(\.word).joined(separator: " ")
            let durationText = String(format: "%.1f", coverage.speakingSpan)
            let assetDurationText = String(format: "%.1f", asset.duration)
            let excerpt = transcript.isEmpty ? "[no transcript text available]" : transcript
            return """
            === CLIP CANDIDATES ===
            Asset: \(asset.name)
            Requested: \(count) clips (\(Int(minDur))-\(Int(maxDur))s)

            Result: no complete clip candidates found.
            Reason: transcript coverage is too sparse for ranked short-form extraction.
            Coverage: \(coverage.wordCount) words from [\(startText)]-[\(endText)] across \(durationText)s of spoken material in a \(assetDurationText)s asset.

            Best available excerpt:
            Start: [\(startText)]
            End: [\(endText)]
            Duration: \(durationText)s
            Hook: "\(hook)"
            Topic: incomplete excerpt
            Score: n/a
            Layout: unknown
            Why: the available transcript does not contain enough complete material to produce a \(Int(minDur))-\(Int(maxDur)) second ranked clip.

            Transcript excerpt:
            \(excerpt)
            """
        }

        return AnalysisPromptPack.buildExtractClipsPrompt(
            timestampedTranscript: transcript,
            count: count,
            minDuration: minDur,
            maxDuration: maxDur
        )
    }
```

- [ ] **Step 6: Build + integration test + commit**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | tail -10
# Integration test via MCP call to extract_clips on a transcribed asset
git add VideoEditor/VideoEditor/App/AnalysisPromptPack.swift \
        VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift \
        VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "refactor(mcp): extract_clips returns prompt-pack instead of calling Claude API"
```

---

## Task 6: Refactor `handleHookOptimize` to prompt-pack

**Files:**
- Modify: `VideoEditor/VideoEditor/App/AnalysisPromptPack.swift` — add `buildHookOptimizePrompt`
- Modify: `VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift` — add test
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift:5145-~5340` — shrink handler

`hook_optimize` is different from the others: today it returns a JSON-parsed best-index after Claude scoring. After refactor, it returns a prompt-pack — the agent does the scoring and the agent calls subsequent tools (`split_clip`, `move_clip`) to rearrange the clip. The output format documented in the prompt should make that workflow explicit.

- [ ] **Step 1: Add the failing test**

```swift
    @Test("hook_optimize prompt asks for JSON scoring with index and reason")
    func hookOptimizePromptShape() {
        let sentenceList = "[0] \"Hello.\"\n[1] \"What if...\"\n[2] \"Today we...\""
        let pack = AnalysisPromptPack.buildHookOptimizePrompt(sentenceList: sentenceList)

        #expect(pack.contains("<EXTENDED_THINKING_REQUIRED>"))
        #expect(pack.contains("Rate each sentence"))
        #expect(pack.contains(#""index": 0, "score": 8, "reason": "..."#))
        #expect(pack.contains(sentenceList))
    }
```

- [ ] **Step 2: Run test, verify fail**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests/hookOptimizePromptShape 2>&1 | tail -10
```

- [ ] **Step 3: Add the builder**

```swift
    public static func buildHookOptimizePrompt(sentenceList: String) -> String {
        let body = """
        Rate each sentence as a short-form video hook (1-10). Consider: curiosity gap, bold claim, question, emotional language, specificity. Return JSON: [{"index": 0, "score": 8, "reason": "..."}]
        After producing the JSON, the calling agent will rearrange the clip so the highest-scoring sentence opens the video (via split_clip + move_clip).
        SENTENCES:
        \(sentenceList)
        """
        return thinkingPreamble + body
    }
```

- [ ] **Step 4: Run test, expect pass**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test \
  -only-testing:VideoEditorTests/AnalysisPromptPackTests 2>&1 | tail -10
```

- [ ] **Step 5: Replace handler body**

In `MCPServer.swift`, the entire `handleHookOptimize` (lines 5145 to its closing `}`) needs to shrink. The sentence-grouping logic (lines 5170-5210) stays; everything from "Send to Claude" onwards is replaced with a `return AnalysisPromptPack.buildHookOptimizePrompt(...)` call.

Replace `handleHookOptimize` with:

```swift
    private func handleHookOptimize(_ args: [String: Any], appState: AppState) async -> String {
        guard let videoTrack = appState.timeline.tracks.first(where: { $0.type == .video }),
              let clip = videoTrack.clips.first else {
            return "Error: No video clip on timeline"
        }

        guard let asset = appState.assets.first(where: { $0.id == clip.assetID }) else {
            return "Error: Asset not found for clip"
        }

        guard let transcript = await appState.media.transcriptionService.getTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) else {
            return "Error: No transcript available. Run transcribe_asset first."
        }

        let sourceRange = clip.sourceRange
        let words = transcript.words.filter { $0.start >= sourceRange.start && $0.end <= sourceRange.end }
        guard !words.isEmpty else {
            return "Hook skipped: no transcript words in clip source range. " + stateSnapshot(appState)
        }

        // Group words into sentences (split on punctuation or pauses > 0.8s).
        struct Sentence {
            let text: String
            let startTime: TimeInterval
            let endTime: TimeInterval
            let wordRange: Range<Int>
        }

        var sentences: [Sentence] = []
        var currentWords: [String] = []
        var sentenceStartIdx = 0
        var sentenceStartTime = words[0].start

        for (i, word) in words.enumerated() {
            if currentWords.isEmpty {
                sentenceStartTime = word.start
                sentenceStartIdx = i
            }
            currentWords.append(word.word)

            let isPunctEnd = word.word.hasSuffix(".") || word.word.hasSuffix("?") || word.word.hasSuffix("!")
            let hasPause = i + 1 < words.count && (words[i + 1].start - word.end) > 0.8
            let isLast = i == words.count - 1

            if isPunctEnd || hasPause || isLast {
                sentences.append(Sentence(
                    text: currentWords.joined(separator: " "),
                    startTime: sentenceStartTime,
                    endTime: word.end,
                    wordRange: sentenceStartIdx..<(i + 1)
                ))
                currentWords = []
            }
        }

        guard sentences.count >= 2 else {
            return "Hook is already at the start (only 1 sentence in clip)"
        }

        var sentenceList = ""
        for (i, s) in sentences.enumerated() {
            sentenceList += "[\(i)] \"\(s.text)\" (start=\(String(format: "%.2f", s.startTime))s, end=\(String(format: "%.2f", s.endTime))s)\n"
        }

        return AnalysisPromptPack.buildHookOptimizePrompt(sentenceList: sentenceList)
    }
```

Note: the existing handler used to act on Claude's response by calling split/move itself. After refactor, the AGENT does that — they get the prompt-pack, score the sentences, then call `split_clip` and `move_clip` to put the winning sentence first. Document this in the skill update (Task 7 covers `podcast-episode-producer`; if `viral-clip-extractor` references `hook_optimize`, update that skill too — out of scope here unless found).

- [ ] **Step 6: Build + integration test + commit**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | tail -10
# Integration test via MCP call to hook_optimize on a clip
git add VideoEditor/VideoEditor/App/AnalysisPromptPack.swift \
        VideoEditor/VideoEditorTests/AnalysisPromptPackTests.swift \
        VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "refactor(mcp): hook_optimize returns prompt-pack; agent now drives rearrangement"
```

---

## Task 7: Update `podcast-episode-producer` skill (both copies)

**Files:**
- Modify: `.claude/skills/podcast-episode-producer/SKILL.md`
- Modify: `.agents/skills/podcast-episode-producer/SKILL.md` (must stay byte-identical to the `.claude/` copy)

- [ ] **Step 1: Update Step 1 wording for prompt-pack behavior**

In `.claude/skills/podcast-episode-producer/SKILL.md`, find Step 1 (`## Step 1: Analyze with Claude`). Replace the block content with:

```markdown
## Step 1: Analyze the transcript — NEVER SKIP THIS

1. Call `analyze_transcript` with the asset_id.
2. The tool returns a prompt-pack: an `<EXTENDED_THINKING_REQUIRED>` directive, the analysis prompt, and the full timestamped transcript. The tool does NOT call any cloud API — YOU do the analysis in your own turn.
3. **Ultrathink before responding.** Re-read every line of the transcript. Identify:
   - Real episodes (not rehearsals, pre-show chatter, or intro takes)
   - Exact start/end timestamps for each episode
   - Topics discussed in each episode
   - Pre-show sections, post-show wrap-up, off-camera moments
4. **DO NOT use `detect_episodes`** — it's regex pattern matching ("welcome to"), not comprehension. It WILL find rehearsal intros and pre-show takes as false positives.
5. Output your analysis in the EPISODES/OTHER SECTIONS format the prompt asks for. This becomes the input for Step 2.
```

- [ ] **Step 2: Update Step 2.5 wording the same way**

Find `## Step 2.5: Post-extraction analysis`. Update the first sentence to:

```markdown
After extracting, call `analyze_transcript` AGAIN on the extracted episode (pass the same asset_id; the tool returns a prompt-pack you analyze in your own turn — ultrathink first):
```

- [ ] **Step 3: Insert new Step 2.6 (Mid-episode chatter scan)**

Insert between the existing Step 2.5 and Step 2.75:

```markdown
## Step 2.6: Mid-episode chatter scan — NEVER SKIP THIS

In-episode chatter (host coaching mid-take, abandoned answers, "we might need to scratch that") is invisible to Step 2.5 because the second `analyze_transcript` pass focuses on topic structure. This step scans for cuttable chatter inside the already-extracted episode.

1. Call `scan_episode_chatter` with the asset_id, `start` and `end` matching the source range you passed to `extract_segment`.
2. The tool returns a prompt-pack with the timeline-relative transcript and 6 chatter categories: abandoned takes, host coaching, production chatter, false starts (with clean retake), age/fact corrections, host-to-host asides.
3. **Ultrathink before responding.** Be conservative — only cut things clearly chatter.
4. Produce a CUT list in this exact format:
   ```
   CUT [MM:SS]-[MM:SS]: <reason>
   ```
5. Translate each CUT to `split_clip` + `ripple_delete` (work LATEST → EARLIEST in timeline order so earlier cut positions don't shift).
6. `save_snapshot` after cuts.

**Why this step matters:** Without it, you'll miss 5-15 minutes of in-episode production chatter that should have been cut. The first session that produced an episode without this step shipped with ~10 minutes of fixable chatter.
```

- [ ] **Step 4: Mirror to `.agents/`**

```bash
cp .claude/skills/podcast-episode-producer/SKILL.md .agents/skills/podcast-episode-producer/SKILL.md
diff -q .claude/skills/podcast-episode-producer/SKILL.md .agents/skills/podcast-episode-producer/SKILL.md
```
Expected: no diff output (files identical).

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/podcast-episode-producer/SKILL.md .agents/skills/podcast-episode-producer/SKILL.md
git commit -m "docs(skill): podcast-episode-producer adds Step 2.6 chatter scan + prompt-pack wording"
```

---

## Task 8: Mark `ANTHROPIC_API_KEY` optional in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (root) — the `## Environment Variables` section

- [ ] **Step 1: Update the env var description**

In `CLAUDE.md`, find:
```
- `ANTHROPIC_API_KEY`, `DEEPGRAM_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `BFL_API_KEY` — used by the macOS editor.
```

Replace with:
```
- `DEEPGRAM_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `BFL_API_KEY` — used by the macOS editor.
- `ANTHROPIC_API_KEY` — required ONLY when the in-app chat panel (`AIChatController`) is used. The chat panel itself is a Claude API session, so it needs the key for its own completions. The legacy B-roll search-query helper also uses it.

  When `ANTHROPIC_API_KEY` is needed:

  | User setup | Editor needs the key? | Where analysis runs |
  |---|---|---|
  | External agent (Claude Code / Codex / Cursor) drives the editor via MCP | No | External agent's seat |
  | In-app chat panel drives the editor | **Yes** | In-app chat's Claude turn |
  | No agent — user hand-drives the editor | No | No AI analysis at all |

  MCP tools that previously called Claude directly (`analyze_transcript`, `find_viral_moments`, `extract_clips`, `hook_optimize`, plus the new `scan_episode_chatter`) now return a prompt-pack for whichever agent is driving — they never call Anthropic themselves in any scenario.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: mark ANTHROPIC_API_KEY optional now that MCP tools return prompt-packs"
```

---

## Self-review

**Spec coverage:**
- Prompt-pack pattern → Tasks 1-2, 4-6 ✓
- New `scan_episode_chatter` tool → Task 3 ✓
- Skill update with new Step 2.6 → Task 7 ✓
- CLAUDE.md update → Task 8 ✓
- Refactor of out-of-scope tools (`score_content`, `generate_title`) → spec updated to remove these; no plan task needed ✓

**Placeholder scan:** All steps contain actual file paths and code. The two `[...COPY ENTIRE EXISTING PROMPT...]` markers in Tasks 4-5 are intentional — the engineer reads the live source file and pastes verbatim, because the prompt text is hundreds of lines and reproducing it inline here would just go stale. The plan tells them exactly which line ranges to copy.

**Type consistency:** `buildAnalyzeTranscriptPrompt`, `buildFindViralMomentsPrompt`, `buildExtractClipsPrompt`, `buildScanEpisodeChatterPrompt`, `buildHookOptimizePrompt` all live in `enum AnalysisPromptPack` with `thinkingPreamble` as the shared private constant. All return `String`. `TranscriptWord` init in Task 3 may need a tweak if the EditorCore signature differs — flagged in Step 8 of that task.

**Risk:** `hook_optimize` changes semantics (was: tool acts on Claude's response; becomes: tool returns prompt and the agent acts). Any caller scripting against the old JSON-of-score format breaks. Acceptable per spec ("Anyone with automation that *parsed* the structured Claude output will need updating").
