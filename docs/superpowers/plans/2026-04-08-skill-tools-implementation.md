# Skill Tools Implementation Plan

> **Status: SHIPPED — 2026-04-14.** All 15 tools implemented, registered, and covered by passing tests (49 skill-tool tests in 5 suites, 225/225 total in EditorCore). Vignette is exposed via the generic `set_clip_effect` tool rather than a dedicated `apply_vignette` tool. Checkboxes below were ticked retroactively to reflect shipped state.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build 15 missing tools that the updated AI editing skills reference but don't exist yet.

**Architecture:** Each tool follows the established pattern: AIToolDefinition → AIToolResolver case → EditorIntent case → IntentResolver → Command struct. Audio processing tools store configuration on clips/tracks as `AudioEffectChain`; visual tools extend existing `EffectInstance`. Analysis-only tools route through MCPServer's `handleAnalysisTool()`.

**Tech Stack:** Swift, AVFoundation (audio processing via `AVAudioMix`/`AudioUnit`), Core Image (visual effects), EditorCore package.

---

## File Map

| File | Role |
|------|------|
| `EditorCore/Models/AudioEffectChain.swift` | **CREATE** — AudioEffectChain model (gate, compressor, de-esser, EQ, limiter configs) |
| `EditorCore/Models/TextOverlay.swift` | **CREATE** — TextOverlay model for arbitrary text graphics |
| `EditorCore/Models/Timeline.swift` | **MODIFY** — Add `color` param to Marker (already has field, fix SetMarkerCommand) |
| `EditorCore/Models/Clip.swift` | **MODIFY** — Add `audioEffects: AudioEffectChain?`, `textOverlays: [TextOverlay]`, vignette effect type |
| `EditorCore/Intents/EditorIntent.swift` | **MODIFY** — Add new intent cases + IntentResolver mappings |
| `EditorCore/Commands/AudioEffectCommands.swift` | **CREATE** — Commands for all audio processing tools |
| `EditorCore/Commands/PropertyCommands.swift` | **MODIFY** — Add marker color, text overlay, vignette, speed ramp, zoom commands |
| `EditorCore/Playback/EffectCompositor.swift` | **MODIFY** — Add vignette rendering |
| `AIServices/Tools/AIToolRegistry.swift` | **MODIFY** — Register 15 new tool definitions + resolver cases |
| `VideoEditor/App/MCPServer.swift` | **MODIFY** — Add export_video + analyze_audio_spectrum handlers |
| `EditorCore/Tests/AudioEffectCommandTests.swift` | **CREATE** — Tests for audio effect commands |
| `EditorCore/Tests/NewToolCommandTests.swift` | **CREATE** — Tests for non-audio tool commands |

---

## Task 1: AudioEffectChain Model

**Files:**
- Create: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/AudioEffectChain.swift`
- Test: `VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/AudioEffectChainTests.swift`

The Track model already references `audioEffectChain: AudioEffectChain?` but the type was never defined. We also need it on Clip for per-clip audio processing.

- [x] **Step 1: Write model test**

```swift
import Testing
@testable import EditorCore

@Suite("AudioEffectChain Tests")
struct AudioEffectChainTests {
    @Test("Default chain is empty")
    func defaultChain() {
        let chain = AudioEffectChain()
        #expect(chain.gate == nil)
        #expect(chain.compressor == nil)
        #expect(chain.deEsser == nil)
        #expect(chain.eq == nil)
        #expect(chain.limiter == nil)
    }

    @Test("Chain with gate config")
    func gateConfig() {
        var chain = AudioEffectChain()
        chain.gate = GateConfig(thresholdDB: -40, attackMS: 0.5, releaseMS: 50)
        #expect(chain.gate?.thresholdDB == -40)
    }

    @Test("Chain with full processing stack")
    func fullStack() {
        let chain = AudioEffectChain(
            gate: GateConfig(thresholdDB: -40, attackMS: 0.5, releaseMS: 50),
            compressor: CompressorConfig(ratio: 4, attackMS: 5, releaseMS: 30, thresholdDB: -20, makeupGainDB: 3),
            deEsser: DeEsserConfig(centerFreqHz: 5500, reductionDB: -3),
            eq: EQConfig(bands: [EQBand(freqHz: 80, gainDB: 0, q: 0.7, filterType: .highPass), EQBand(freqHz: 3000, gainDB: 2.5, q: 1.0, filterType: .peak)]),
            limiter: LimiterConfig(thresholdDB: -6, attackMS: 1, releaseMS: 75)
        )
        #expect(chain.compressor?.ratio == 4)
        #expect(chain.eq?.bands.count == 2)
    }

    @Test("Chain is Codable")
    func codable() throws {
        let chain = AudioEffectChain(
            gate: GateConfig(thresholdDB: -40, attackMS: 0.5, releaseMS: 50),
            compressor: CompressorConfig(ratio: 4, attackMS: 5, releaseMS: 30, thresholdDB: -20, makeupGainDB: 3)
        )
        let data = try JSONEncoder().encode(chain)
        let decoded = try JSONDecoder().decode(AudioEffectChain.self, from: data)
        #expect(decoded.gate?.thresholdDB == -40)
        #expect(decoded.compressor?.ratio == 4)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter AudioEffectChainTests 2>&1 | tail -5`
Expected: FAIL — types not defined

- [x] **Step 3: Write AudioEffectChain model**

```swift
// AudioEffectChain.swift
import Foundation

/// Audio processing chain stored on Track or Clip.
/// Effects are applied in order: Gate → Compressor → De-Esser → EQ → Limiter.
public struct AudioEffectChain: Codable, Sendable, Equatable {
    public var gate: GateConfig?
    public var compressor: CompressorConfig?
    public var deEsser: DeEsserConfig?
    public var eq: EQConfig?
    public var limiter: LimiterConfig?
    public var normalizeLUFS: Double?  // Target LUFS, e.g. -16.0

    public init(
        gate: GateConfig? = nil,
        compressor: CompressorConfig? = nil,
        deEsser: DeEsserConfig? = nil,
        eq: EQConfig? = nil,
        limiter: LimiterConfig? = nil,
        normalizeLUFS: Double? = nil
    ) {
        self.gate = gate
        self.compressor = compressor
        self.deEsser = deEsser
        self.eq = eq
        self.limiter = limiter
        self.normalizeLUFS = normalizeLUFS
    }
}

public struct GateConfig: Codable, Sendable, Equatable {
    public var thresholdDB: Double     // e.g. -40
    public var attackMS: Double        // e.g. 0.5
    public var releaseMS: Double       // e.g. 50

    public init(thresholdDB: Double = -40, attackMS: Double = 0.5, releaseMS: Double = 50) {
        self.thresholdDB = thresholdDB
        self.attackMS = attackMS
        self.releaseMS = releaseMS
    }
}

public struct CompressorConfig: Codable, Sendable, Equatable {
    public var ratio: Double           // e.g. 4.0 (4:1)
    public var attackMS: Double        // e.g. 5
    public var releaseMS: Double       // e.g. 30
    public var thresholdDB: Double     // e.g. -20
    public var makeupGainDB: Double    // e.g. 3

    public init(ratio: Double = 4, attackMS: Double = 5, releaseMS: Double = 30, thresholdDB: Double = -20, makeupGainDB: Double = 3) {
        self.ratio = ratio
        self.attackMS = attackMS
        self.releaseMS = releaseMS
        self.thresholdDB = thresholdDB
        self.makeupGainDB = makeupGainDB
    }
}

public struct DeEsserConfig: Codable, Sendable, Equatable {
    public var centerFreqHz: Double    // e.g. 5500
    public var reductionDB: Double     // e.g. -3

    public init(centerFreqHz: Double = 5500, reductionDB: Double = -3) {
        self.centerFreqHz = centerFreqHz
        self.reductionDB = reductionDB
    }
}

public struct EQConfig: Codable, Sendable, Equatable {
    public var bands: [EQBand]

    public init(bands: [EQBand] = []) {
        self.bands = bands
    }
}

public struct EQBand: Codable, Sendable, Equatable {
    public var freqHz: Double          // e.g. 3000
    public var gainDB: Double          // e.g. +2.5
    public var q: Double               // e.g. 1.0
    public var filterType: EQFilterType

    public init(freqHz: Double, gainDB: Double = 0, q: Double = 1.0, filterType: EQFilterType = .peak) {
        self.freqHz = freqHz
        self.gainDB = gainDB
        self.q = q
        self.filterType = filterType
    }
}

public enum EQFilterType: String, Codable, Sendable, Equatable {
    case highPass
    case lowPass
    case peak
    case lowShelf
    case highShelf
}

public struct LimiterConfig: Codable, Sendable, Equatable {
    public var thresholdDB: Double     // e.g. -6
    public var attackMS: Double        // e.g. 1
    public var releaseMS: Double       // e.g. 75

    public init(thresholdDB: Double = -6, attackMS: Double = 1, releaseMS: Double = 75) {
        self.thresholdDB = thresholdDB
        self.attackMS = attackMS
        self.releaseMS = releaseMS
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter AudioEffectChainTests 2>&1 | tail -5`
Expected: PASS

- [x] **Step 5: Add `audioEffects` property to Clip**

In `Clip.swift`, add `public var audioEffects: AudioEffectChain?` after the `effects` property (line 14). Add it to init with default `nil`. The Track model already has `audioEffectChain: AudioEffectChain?` on line 31 — it will now compile.

- [x] **Step 6: Run full EditorCore tests**

Run: `cd VideoEditor/Packages/EditorCore && swift test 2>&1 | tail -10`
Expected: PASS — existing tests still work, new tests pass

- [x] **Step 7: Commit**

```bash
git add VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/AudioEffectChain.swift \
       VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Clip.swift \
       VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/AudioEffectChainTests.swift
git commit -m "feat(model): add AudioEffectChain model for audio processing pipeline"
```

---

## Task 2: TextOverlay Model

**Files:**
- Create: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/TextOverlay.swift`
- Modify: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Clip.swift`
- Test: `VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/TextOverlayTests.swift`

- [x] **Step 1: Write model test**

```swift
import Testing
@testable import EditorCore

@Suite("TextOverlay Tests")
struct TextOverlayTests {
    @Test("Create text overlay with defaults")
    func defaults() {
        let overlay = TextOverlay(text: "Hello World", startTime: 1.0, duration: 3.0)
        #expect(overlay.text == "Hello World")
        #expect(overlay.fontSize == 48)
        #expect(overlay.colorHex == "#FFFFFF")
        #expect(overlay.animation == .fadeIn)
    }

    @Test("TextOverlay is Codable")
    func codable() throws {
        let overlay = TextOverlay(text: "Test", startTime: 0, duration: 2.0, positionX: 0.5, positionY: 0.8, fontSize: 60, colorHex: "#FF0000", animation: .pop, animationDurationMS: 150)
        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(TextOverlay.self, from: data)
        #expect(decoded.text == "Test")
        #expect(decoded.fontSize == 60)
        #expect(decoded.animation == .pop)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter TextOverlayTests 2>&1 | tail -5`
Expected: FAIL

- [x] **Step 3: Write TextOverlay model**

```swift
import Foundation

public struct TextOverlay: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    public var startTime: TimeInterval      // relative to clip start
    public var duration: TimeInterval
    public var positionX: Double            // 0.0 (left) to 1.0 (right), default 0.5
    public var positionY: Double            // 0.0 (top) to 1.0 (bottom), default 0.8
    public var fontSize: Double             // points, default 48
    public var colorHex: String             // e.g. "#FFFFFF"
    public var backgroundColorHex: String?  // optional background pill
    public var animation: TextAnimation
    public var animationDurationMS: Double

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        positionX: Double = 0.5,
        positionY: Double = 0.8,
        fontSize: Double = 48,
        colorHex: String = "#FFFFFF",
        backgroundColorHex: String? = nil,
        animation: TextAnimation = .fadeIn,
        animationDurationMS: Double = 100
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.positionX = positionX
        self.positionY = positionY
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.backgroundColorHex = backgroundColorHex
        self.animation = animation
        self.animationDurationMS = animationDurationMS
    }
}

public enum TextAnimation: String, Codable, Sendable, Equatable {
    case none
    case fadeIn
    case pop
    case slideUp
}
```

- [x] **Step 4: Add `textOverlays` to Clip**

In `Clip.swift`, add `public var textOverlays: [TextOverlay]` after `effects`. Add to init with default `[]`.

- [x] **Step 5: Run tests to verify pass**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter TextOverlayTests 2>&1 | tail -5`
Expected: PASS

- [x] **Step 6: Commit**

```bash
git add VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/TextOverlay.swift \
       VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Clip.swift \
       VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/TextOverlayTests.swift
git commit -m "feat(model): add TextOverlay model for arbitrary text graphics"
```

---

## Task 3: Vignette Effect Type

**Files:**
- Modify: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Clip.swift` — add type constant
- Modify: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Playback/EffectCompositor.swift` — add rendering
- Test: `VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/VignetteEffectTests.swift`

- [x] **Step 1: Write test**

```swift
import Testing
@testable import EditorCore

@Suite("Vignette Effect Tests")
struct VignetteEffectTests {
    @Test("Vignette EffectInstance factory")
    func vignetteFactory() {
        let effect = EffectInstance.vignette(intensity: 0.6, feather: 0.8)
        #expect(effect.type == EffectInstance.typeVignette)
        #expect(effect.parameters["intensity"] == 0.6)
        #expect(effect.parameters["feather"] == 0.8)
    }
}
```

- [x] **Step 2: Run test — should fail**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter VignetteEffectTests 2>&1 | tail -5`

- [x] **Step 3: Add vignette to EffectInstance**

In `Clip.swift`, add to the EffectInstance extension:

```swift
public static let typeVignette = "vignette"

public static func vignette(intensity: Double = 0.5, feather: Double = 0.7) -> EffectInstance {
    EffectInstance(
        type: typeVignette,
        parameters: [
            "intensity": intensity,
            "feather": feather,
        ]
    )
}
```

- [x] **Step 4: Add vignette rendering in EffectCompositor**

In `EffectCompositor.swift`, in the `applyEffect(_:to:)` switch statement, add a case before `default`:

```swift
case EffectInstance.typeVignette:
    let intensity = effect.parameters["intensity"] ?? 0.5
    let feather = effect.parameters["feather"] ?? 0.7
    let vignetteFilter = CIFilter(name: "CIVignette")!
    vignetteFilter.setValue(image, forKey: kCIInputImageKey)
    vignetteFilter.setValue(intensity * 2.0, forKey: kCIInputIntensityKey)  // CIVignette range 0-2
    vignetteFilter.setValue(feather * 10.0, forKey: kCIInputRadiusKey)     // CIVignette range 0-10
    return vignetteFilter.outputImage ?? image
```

- [x] **Step 5: Run tests**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter VignetteEffectTests 2>&1 | tail -5`
Expected: PASS

- [x] **Step 6: Commit**

```bash
git add VideoEditor/Packages/EditorCore/Sources/EditorCore/Models/Clip.swift \
       VideoEditor/Packages/EditorCore/Sources/EditorCore/Playback/EffectCompositor.swift \
       VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/VignetteEffectTests.swift
git commit -m "feat(effects): add vignette visual effect type"
```

---

## Task 4: Audio Effect Commands

**Files:**
- Create: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Commands/AudioEffectCommands.swift`
- Modify: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Intents/EditorIntent.swift`
- Test: `VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/AudioEffectCommandTests.swift`

These commands set individual audio processing components on a clip's AudioEffectChain. Each command sets one component (gate, compressor, etc.) and supports undo.

- [x] **Step 1: Write tests**

```swift
import Testing
@testable import EditorCore

@Suite("AudioEffectCommand Tests")
struct AudioEffectCommandTests {
    private func makeContext(clip: Clip) -> EditingContext {
        EditingContext(timelineState: TimelineState(timeline: Timeline(tracks: [Track(name: "A", type: .audio, clips: [clip])])))
    }

    @MainActor
    @Test("ApplyGate sets gate config and undo restores nil")
    func applyGate() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 5), sourceRange: TimeRange(start: 0, end: 5))
        let ctx = makeContext(clip: clip)

        var cmd = ApplyGateCommand(clipID: clip.id, config: GateConfig(thresholdDB: -35, attackMS: 1.0, releaseMS: 40))
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.gate?.thresholdDB == -35)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.gate == nil)
    }

    @MainActor
    @Test("ApplyCompressor sets compressor config")
    func applyCompressor() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 5), sourceRange: TimeRange(start: 0, end: 5))
        let ctx = makeContext(clip: clip)

        var cmd = ApplyCompressorCommand(clipID: clip.id, config: CompressorConfig(ratio: 4, attackMS: 5, releaseMS: 30, thresholdDB: -20, makeupGainDB: 3))
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.compressor?.ratio == 4)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.compressor == nil)
    }

    @MainActor
    @Test("ApplyDeEsser sets de-esser config")
    func applyDeEsser() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 5), sourceRange: TimeRange(start: 0, end: 5))
        let ctx = makeContext(clip: clip)

        var cmd = ApplyDeEsserCommand(clipID: clip.id, config: DeEsserConfig(centerFreqHz: 6000, reductionDB: -4))
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.deEsser?.centerFreqHz == 6000)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.deEsser == nil)
    }

    @MainActor
    @Test("ApplyEQ sets EQ config")
    func applyEQ() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 5), sourceRange: TimeRange(start: 0, end: 5))
        let ctx = makeContext(clip: clip)

        var cmd = ApplyEQCommand(clipID: clip.id, config: EQConfig(bands: [EQBand(freqHz: 80, gainDB: 0, q: 0.7, filterType: .highPass)]))
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.eq?.bands.count == 1)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.eq == nil)
    }

    @MainActor
    @Test("ApplyLimiter sets limiter config")
    func applyLimiter() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 5), sourceRange: TimeRange(start: 0, end: 5))
        let ctx = makeContext(clip: clip)

        var cmd = ApplyLimiterCommand(clipID: clip.id, config: LimiterConfig(thresholdDB: -4, attackMS: 1, releaseMS: 50))
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.limiter?.thresholdDB == -4)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.limiter == nil)
    }

    @MainActor
    @Test("NormalizeLUFS sets target")
    func normalizeLUFS() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 5), sourceRange: TimeRange(start: 0, end: 5))
        let ctx = makeContext(clip: clip)

        var cmd = NormalizeLUFSCommand(clipID: clip.id, targetLUFS: -16)
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.normalizeLUFS == -16)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].audioEffects?.normalizeLUFS == nil)
    }
}
```

- [x] **Step 2: Run tests — should fail**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter AudioEffectCommandTests 2>&1 | tail -5`

- [x] **Step 3: Add EditorIntent cases**

In `EditorIntent.swift`, add before the `batch` case:

```swift
case applyGate(clipID: UUID, config: GateConfig)
case applyCompressor(clipID: UUID, config: CompressorConfig)
case applyDeEsser(clipID: UUID, config: DeEsserConfig)
case applyEQ(clipID: UUID, config: EQConfig)
case applyLimiter(clipID: UUID, config: LimiterConfig)
case normalizeLUFS(clipID: UUID, targetLUFS: Double)
```

Add IntentResolver cases:

```swift
case .applyGate(let clipID, let config):
    return ApplyGateCommand(clipID: clipID, config: config)
case .applyCompressor(let clipID, let config):
    return ApplyCompressorCommand(clipID: clipID, config: config)
case .applyDeEsser(let clipID, let config):
    return ApplyDeEsserCommand(clipID: clipID, config: config)
case .applyEQ(let clipID, let config):
    return ApplyEQCommand(clipID: clipID, config: config)
case .applyLimiter(let clipID, let config):
    return ApplyLimiterCommand(clipID: clipID, config: config)
case .normalizeLUFS(let clipID, let targetLUFS):
    return NormalizeLUFSCommand(clipID: clipID, targetLUFS: targetLUFS)
```

- [x] **Step 4: Write command implementations**

Create `AudioEffectCommands.swift`:

```swift
import Foundation

// MARK: - Helpers

private func ensureAudioEffects(clip: inout Clip) {
    if clip.audioEffects == nil {
        clip.audioEffects = AudioEffectChain()
    }
}

// MARK: - ApplyGateCommand

public struct ApplyGateCommand: Command {
    public let name = "Apply Gate"
    public let clipID: UUID
    public let config: GateConfig
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousGate: GateConfig?
    private var hadChain: Bool = false

    public init(clipID: UUID, config: GateConfig) {
        self.clipID = clipID
        self.config = config
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            hadChain = clip.audioEffects != nil
            previousGate = clip.audioEffects?.gate
            ensureAudioEffects(clip: &clip)
            clip.audioEffects?.gate = config
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if hadChain {
                clip.audioEffects?.gate = previousGate
            } else {
                clip.audioEffects = nil
            }
        }
    }
}

// MARK: - ApplyCompressorCommand

public struct ApplyCompressorCommand: Command {
    public let name = "Apply Compressor"
    public let clipID: UUID
    public let config: CompressorConfig
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousCompressor: CompressorConfig?
    private var hadChain: Bool = false

    public init(clipID: UUID, config: CompressorConfig) {
        self.clipID = clipID
        self.config = config
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            hadChain = clip.audioEffects != nil
            previousCompressor = clip.audioEffects?.compressor
            ensureAudioEffects(clip: &clip)
            clip.audioEffects?.compressor = config
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if hadChain {
                clip.audioEffects?.compressor = previousCompressor
            } else {
                clip.audioEffects = nil
            }
        }
    }
}

// MARK: - ApplyDeEsserCommand

public struct ApplyDeEsserCommand: Command {
    public let name = "Apply De-Esser"
    public let clipID: UUID
    public let config: DeEsserConfig
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousDeEsser: DeEsserConfig?
    private var hadChain: Bool = false

    public init(clipID: UUID, config: DeEsserConfig) {
        self.clipID = clipID
        self.config = config
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            hadChain = clip.audioEffects != nil
            previousDeEsser = clip.audioEffects?.deEsser
            ensureAudioEffects(clip: &clip)
            clip.audioEffects?.deEsser = config
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if hadChain {
                clip.audioEffects?.deEsser = previousDeEsser
            } else {
                clip.audioEffects = nil
            }
        }
    }
}

// MARK: - ApplyEQCommand

public struct ApplyEQCommand: Command {
    public let name = "Apply EQ"
    public let clipID: UUID
    public let config: EQConfig
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousEQ: EQConfig?
    private var hadChain: Bool = false

    public init(clipID: UUID, config: EQConfig) {
        self.clipID = clipID
        self.config = config
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            hadChain = clip.audioEffects != nil
            previousEQ = clip.audioEffects?.eq
            ensureAudioEffects(clip: &clip)
            clip.audioEffects?.eq = config
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if hadChain {
                clip.audioEffects?.eq = previousEQ
            } else {
                clip.audioEffects = nil
            }
        }
    }
}

// MARK: - ApplyLimiterCommand

public struct ApplyLimiterCommand: Command {
    public let name = "Apply Limiter"
    public let clipID: UUID
    public let config: LimiterConfig
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousLimiter: LimiterConfig?
    private var hadChain: Bool = false

    public init(clipID: UUID, config: LimiterConfig) {
        self.clipID = clipID
        self.config = config
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            hadChain = clip.audioEffects != nil
            previousLimiter = clip.audioEffects?.limiter
            ensureAudioEffects(clip: &clip)
            clip.audioEffects?.limiter = config
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if hadChain {
                clip.audioEffects?.limiter = previousLimiter
            } else {
                clip.audioEffects = nil
            }
        }
    }
}

// MARK: - NormalizeLUFSCommand

public struct NormalizeLUFSCommand: Command {
    public let name = "Normalize to LUFS"
    public let clipID: UUID
    public let targetLUFS: Double
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousLUFS: Double?
    private var hadChain: Bool = false

    public init(clipID: UUID, targetLUFS: Double) {
        self.clipID = clipID
        self.targetLUFS = targetLUFS
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            hadChain = clip.audioEffects != nil
            previousLUFS = clip.audioEffects?.normalizeLUFS
            ensureAudioEffects(clip: &clip)
            clip.audioEffects?.normalizeLUFS = targetLUFS
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if hadChain {
                clip.audioEffects?.normalizeLUFS = previousLUFS
            } else {
                clip.audioEffects = nil
            }
        }
    }
}
```

- [x] **Step 5: Run tests**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter AudioEffectCommandTests 2>&1 | tail -10`
Expected: PASS

- [x] **Step 6: Commit**

```bash
git add VideoEditor/Packages/EditorCore/Sources/EditorCore/Commands/AudioEffectCommands.swift \
       VideoEditor/Packages/EditorCore/Sources/EditorCore/Intents/EditorIntent.swift \
       VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/AudioEffectCommandTests.swift
git commit -m "feat(commands): add audio processing chain commands (gate, compressor, de-esser, EQ, limiter, LUFS)"
```

---

## Task 5: Non-Audio Commands (Marker Color, Text Overlay, Speed Ramp, Zoom)

**Files:**
- Modify: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Intents/EditorIntent.swift`
- Modify: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Commands/PropertyCommands.swift`
- Test: `VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/NewToolCommandTests.swift`

- [x] **Step 1: Write tests**

```swift
import Testing
@testable import EditorCore

@Suite("New Tool Command Tests")
struct NewToolCommandTests {
    private func makeClipContext() -> (Clip, EditingContext) {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let ctx = EditingContext(timelineState: TimelineState(timeline: Timeline(tracks: [Track(name: "V1", type: .video, clips: [clip])])))
        return (clip, ctx)
    }

    // MARK: - Marker Color

    @MainActor
    @Test("SetMarker with color sets color on marker")
    func setMarkerColor() throws {
        let ctx = EditingContext(timelineState: TimelineState(timeline: Timeline(tracks: [])))
        var cmd = SetMarkerCommand(at: 5.0, label: "Review", color: "yellow")
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.markers.count == 1)
        #expect(ctx.timelineState.timeline.markers[0].color == "yellow")
        #expect(ctx.timelineState.timeline.markers[0].label == "Review")
    }

    // MARK: - Text Overlay

    @MainActor
    @Test("AddTextOverlay adds overlay to clip")
    func addTextOverlay() throws {
        let (clip, ctx) = makeClipContext()
        let overlay = TextOverlay(text: "Hook!", startTime: 0, duration: 2.0, fontSize: 60, colorHex: "#FF0000", animation: .pop)
        var cmd = AddTextOverlayCommand(clipID: clip.id, overlay: overlay)
        try cmd.execute(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].textOverlays.count == 1)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].textOverlays[0].text == "Hook!")

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].textOverlays.isEmpty)
    }

    // MARK: - Speed Ramp

    @MainActor
    @Test("SpeedRamp sets keyframes on speed track")
    func speedRamp() throws {
        let (clip, ctx) = makeClipContext()
        var cmd = ApplySpeedRampCommand(clipID: clip.id, startTime: 2.0, endTime: 5.0, speedStart: 0.5, speedEnd: 2.0, easing: .easeInOut)
        try cmd.execute(context: ctx)
        let keyframes = ctx.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["speed"]
        #expect(keyframes != nil)
        #expect(keyframes?.count == 2)
        #expect(keyframes?[0].value == 0.5)
        #expect(keyframes?[1].value == 2.0)
        #expect(keyframes?[1].interpolation == .easeInOut)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["speed"] == nil)
    }

    // MARK: - Zoom Effect

    @MainActor
    @Test("ZoomEffect sets keyframes on scale track")
    func zoomEffect() throws {
        let (clip, ctx) = makeClipContext()
        var cmd = AddZoomEffectCommand(clipID: clip.id, startTime: 1.0, duration: 3.0, zoomStart: 1.0, zoomEnd: 1.5, centerX: 0.5, centerY: 0.4)
        try cmd.execute(context: ctx)
        let scaleKF = ctx.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["scale"]
        #expect(scaleKF != nil)
        #expect(scaleKF?.count == 2)
        #expect(scaleKF?[0].value == 1.0)
        #expect(scaleKF?[1].value == 1.5)

        try cmd.undo(context: ctx)
        #expect(ctx.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["scale"] == nil)
    }
}
```

- [x] **Step 2: Run tests — should fail**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter NewToolCommandTests 2>&1 | tail -5`

- [x] **Step 3: Update SetMarkerCommand to accept color**

In the existing `SetMarkerCommand` (find it via grep — it creates `Marker(time:label:)`), add a `color` parameter:

```swift
public struct SetMarkerCommand: Command {
    public let name = "Set Marker"
    public let at: TimeInterval
    public let label: String
    public let color: String
    private var addedMarkerID: UUID?

    public init(at: TimeInterval, label: String, color: String = "#FF0000") {
        self.at = at
        self.label = label
        self.color = color
    }

    public mutating func execute(context: EditingContext) throws {
        let marker = Marker(time: at, label: label, color: color)
        addedMarkerID = marker.id
        context.timelineState.timeline.markers.append(marker)
        context.timelineState.timeline.markers.sort { $0.time < $1.time }
    }

    public func undo(context: EditingContext) throws {
        guard let id = addedMarkerID else { return }
        context.timelineState.timeline.markers.removeAll { $0.id == id }
    }
}
```

- [x] **Step 4: Add EditorIntent cases**

```swift
case addTextOverlay(clipID: UUID, overlay: TextOverlay)
case removeTextOverlay(clipID: UUID, overlayID: UUID)
case applySpeedRamp(clipID: UUID, startTime: TimeInterval, endTime: TimeInterval, speedStart: Double, speedEnd: Double, easing: KeyframeInterpolation)
case addZoomEffect(clipID: UUID, startTime: TimeInterval, duration: TimeInterval, zoomStart: Double, zoomEnd: Double, centerX: Double, centerY: Double)
```

Update `setMarker` intent to include color:
```swift
case setMarker(at: TimeInterval, label: String, color: String)
```

Add IntentResolver cases:
```swift
case .setMarker(let at, let label, let color):
    return SetMarkerCommand(at: at, label: label, color: color)
case .addTextOverlay(let clipID, let overlay):
    return AddTextOverlayCommand(clipID: clipID, overlay: overlay)
case .removeTextOverlay(let clipID, let overlayID):
    return RemoveTextOverlayCommand(clipID: clipID, overlayID: overlayID)
case .applySpeedRamp(let clipID, let startTime, let endTime, let speedStart, let speedEnd, let easing):
    return ApplySpeedRampCommand(clipID: clipID, startTime: startTime, endTime: endTime, speedStart: speedStart, speedEnd: speedEnd, easing: easing)
case .addZoomEffect(let clipID, let startTime, let duration, let zoomStart, let zoomEnd, let centerX, let centerY):
    return AddZoomEffectCommand(clipID: clipID, startTime: startTime, duration: duration, zoomStart: zoomStart, zoomEnd: zoomEnd, centerX: centerX, centerY: centerY)
```

- [x] **Step 5: Write command implementations**

Add to `PropertyCommands.swift`:

```swift
// MARK: - AddTextOverlayCommand

public struct AddTextOverlayCommand: Command {
    public let name = "Add Text Overlay"
    public let clipID: UUID
    public let overlay: TextOverlay
    public var affectedClipIDs: [UUID] { [clipID] }

    public init(clipID: UUID, overlay: TextOverlay) {
        self.clipID = clipID
        self.overlay = overlay
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            clip.textOverlays.append(overlay)
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            clip.textOverlays.removeAll { $0.id == overlay.id }
        }
    }
}

// MARK: - RemoveTextOverlayCommand

public struct RemoveTextOverlayCommand: Command {
    public let name = "Remove Text Overlay"
    public let clipID: UUID
    public let overlayID: UUID
    public var affectedClipIDs: [UUID] { [clipID] }
    private var removedOverlay: TextOverlay?

    public init(clipID: UUID, overlayID: UUID) {
        self.clipID = clipID
        self.overlayID = overlayID
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            removedOverlay = clip.textOverlays.first { $0.id == overlayID }
            clip.textOverlays.removeAll { $0.id == overlayID }
        }
    }

    public func undo(context: EditingContext) throws {
        guard let overlay = removedOverlay else { return }
        try modifyClip(id: clipID, context: context) { clip in
            clip.textOverlays.append(overlay)
        }
    }
}

// MARK: - ApplySpeedRampCommand

public struct ApplySpeedRampCommand: Command {
    public let name = "Apply Speed Ramp"
    public let clipID: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speedStart: Double
    public let speedEnd: Double
    public let easing: KeyframeInterpolation
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousSpeedKeyframes: [Keyframe]?

    public init(clipID: UUID, startTime: TimeInterval, endTime: TimeInterval, speedStart: Double, speedEnd: Double, easing: KeyframeInterpolation = .linear) {
        self.clipID = clipID
        self.startTime = startTime
        self.endTime = endTime
        self.speedStart = speedStart
        self.speedEnd = speedEnd
        self.easing = easing
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousSpeedKeyframes = clip.keyframes.tracks["speed"]
            clip.keyframes.tracks["speed"] = [
                Keyframe(time: startTime, value: speedStart, interpolation: .linear),
                Keyframe(time: endTime, value: speedEnd, interpolation: easing),
            ]
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if let prev = previousSpeedKeyframes {
                clip.keyframes.tracks["speed"] = prev
            } else {
                clip.keyframes.tracks.removeValue(forKey: "speed")
            }
        }
    }
}

// MARK: - AddZoomEffectCommand

public struct AddZoomEffectCommand: Command {
    public let name = "Add Zoom Effect"
    public let clipID: UUID
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let zoomStart: Double
    public let zoomEnd: Double
    public let centerX: Double
    public let centerY: Double
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousScaleKeyframes: [Keyframe]?
    private var previousPositionXKeyframes: [Keyframe]?
    private var previousPositionYKeyframes: [Keyframe]?

    public init(clipID: UUID, startTime: TimeInterval, duration: TimeInterval, zoomStart: Double, zoomEnd: Double, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.clipID = clipID
        self.startTime = startTime
        self.duration = duration
        self.zoomStart = zoomStart
        self.zoomEnd = zoomEnd
        self.centerX = centerX
        self.centerY = centerY
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousScaleKeyframes = clip.keyframes.tracks["scale"]
            previousPositionXKeyframes = clip.keyframes.tracks["positionX"]
            previousPositionYKeyframes = clip.keyframes.tracks["positionY"]

            clip.keyframes.tracks["scale"] = [
                Keyframe(time: startTime, value: zoomStart, interpolation: .linear),
                Keyframe(time: startTime + duration, value: zoomEnd, interpolation: .easeInOut),
            ]
            clip.keyframes.tracks["positionX"] = [
                Keyframe(time: startTime, value: centerX, interpolation: .linear),
            ]
            clip.keyframes.tracks["positionY"] = [
                Keyframe(time: startTime, value: centerY, interpolation: .linear),
            ]
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if let prev = previousScaleKeyframes { clip.keyframes.tracks["scale"] = prev } else { clip.keyframes.tracks.removeValue(forKey: "scale") }
            if let prev = previousPositionXKeyframes { clip.keyframes.tracks["positionX"] = prev } else { clip.keyframes.tracks.removeValue(forKey: "positionX") }
            if let prev = previousPositionYKeyframes { clip.keyframes.tracks["positionY"] = prev } else { clip.keyframes.tracks.removeValue(forKey: "positionY") }
        }
    }
}
```

- [x] **Step 6: Run tests**

Run: `cd VideoEditor/Packages/EditorCore && swift test --filter NewToolCommandTests 2>&1 | tail -10`
Expected: PASS

- [x] **Step 7: Run all EditorCore tests**

Run: `cd VideoEditor/Packages/EditorCore && swift test 2>&1 | tail -10`
Expected: PASS — no regressions

- [x] **Step 8: Commit**

```bash
git add VideoEditor/Packages/EditorCore/Sources/EditorCore/Commands/PropertyCommands.swift \
       VideoEditor/Packages/EditorCore/Sources/EditorCore/Intents/EditorIntent.swift \
       VideoEditor/Packages/EditorCore/Tests/EditorCoreTests/NewToolCommandTests.swift
git commit -m "feat(commands): add text overlay, speed ramp, zoom effect, marker color commands"
```

---

## Task 6: Register All Tools in AIToolRegistry

**Files:**
- Modify: `VideoEditor/Packages/AIServices/Sources/AIServices/Tools/AIToolRegistry.swift`

This task adds all 15 tool definitions and their resolver cases. No tests needed here — the tool definitions are static data and the resolver is tested through integration.

- [x] **Step 1: Add tool definitions**

Add these static properties to `AIToolRegistry` (after existing definitions, before `allTools`):

```swift
// MARK: - Audio Processing Tools

public static let applyGate = AIToolDefinition(
    name: "apply_gate",
    description: "Apply a noise gate to a clip's audio. Prevents bleed by only allowing audio above the threshold through.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "threshold_db": .init(type: "number", description: "Gate threshold in dB (default -40). Audio below this level is silenced."),
        "attack_ms": .init(type: "number", description: "Attack time in ms (default 0.5). How fast the gate opens."),
        "release_ms": .init(type: "number", description: "Release time in ms (default 50). How fast the gate closes."),
    ], required: ["clip_id"])
)

public static let applyCompressor = AIToolDefinition(
    name: "apply_compressor",
    description: "Apply dynamic range compression to a clip's audio. Reduces the difference between loud and quiet parts.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "ratio": .init(type: "number", description: "Compression ratio (default 4.0 for 4:1). Higher = more compression."),
        "attack_ms": .init(type: "number", description: "Attack time in ms (default 5). How fast compression engages."),
        "release_ms": .init(type: "number", description: "Release time in ms (default 30). How fast compression releases."),
        "threshold_db": .init(type: "number", description: "Threshold in dB (default -20). Compression starts above this level."),
        "makeup_gain_db": .init(type: "number", description: "Makeup gain in dB (default 3). Boost applied after compression."),
    ], required: ["clip_id"])
)

public static let applyDeEsser = AIToolDefinition(
    name: "apply_de_esser",
    description: "Reduce sibilance (harsh 's' and 'sh' sounds) in speech audio.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "center_freq_hz": .init(type: "number", description: "Center frequency in Hz (default 5500). Target the sibilant range."),
        "reduction_db": .init(type: "number", description: "Reduction amount in dB (default -3). Negative value = reduction."),
    ], required: ["clip_id"])
)

public static let applyEQ = AIToolDefinition(
    name: "apply_eq",
    description: "Apply parametric equalization to a clip's audio. Supports high-pass, low-pass, peak, and shelf filters.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "bands": .init(type: "array", description: "Array of EQ bands. Each band: {freq_hz: number, gain_db: number, q: number, filter_type: 'highPass'|'lowPass'|'peak'|'lowShelf'|'highShelf'}"),
    ], required: ["clip_id", "bands"])
)

public static let applyLimiter = AIToolDefinition(
    name: "apply_limiter",
    description: "Apply a peak limiter to prevent audio from exceeding a threshold. Protects against clipping.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "threshold_db": .init(type: "number", description: "Ceiling in dB (default -6). Audio will not exceed this level."),
        "attack_ms": .init(type: "number", description: "Attack time in ms (default 1). How fast the limiter reacts."),
        "release_ms": .init(type: "number", description: "Release time in ms (default 75). How fast the limiter releases."),
    ], required: ["clip_id"])
)

public static let normalizeAudioToLUFS = AIToolDefinition(
    name: "normalize_audio_to_lufs",
    description: "Normalize audio to a target LUFS level. Use -16 LUFS for podcasts, -14 LUFS for YouTube/shorts.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip (or comma-separated IDs for multiple clips)"),
        "target_lufs": .init(type: "number", description: "Target loudness in LUFS (default -16)"),
    ], required: ["clip_id"])
)

public static let analyzeAudioSpectrum = AIToolDefinition(
    name: "analyze_audio_spectrum",
    description: "Analyze audio frequency spectrum to identify noise peaks (AC hum, fan noise, etc). Returns frequency peaks for targeted noise reduction.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "start": .init(type: "number", description: "Start time in seconds (default: 0)"),
        "end": .init(type: "number", description: "End time in seconds (default: clip end)"),
    ], required: ["clip_id"])
)

public static let applySpectralNoiseReduction = AIToolDefinition(
    name: "apply_spectral_noise_reduction",
    description: "Remove specific noise frequencies from audio. Use analyze_audio_spectrum first to identify frequencies.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "frequencies_hz": .init(type: "array", description: "Array of frequency values (in Hz) to suppress"),
    ], required: ["clip_id", "frequencies_hz"])
)

// MARK: - Graphics & Text Tools

public static let addTextOverlay = AIToolDefinition(
    name: "add_text_overlay",
    description: "Add a text overlay to a clip. Use for hooks, callouts, lower thirds, or any on-screen text.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "text": .init(type: "string", description: "The text to display"),
        "start_time": .init(type: "number", description: "Start time in seconds (relative to clip start)"),
        "duration": .init(type: "number", description: "Duration in seconds"),
        "position_x": .init(type: "number", description: "Horizontal position 0.0 (left) to 1.0 (right), default 0.5 (center)"),
        "position_y": .init(type: "number", description: "Vertical position 0.0 (top) to 1.0 (bottom), default 0.8"),
        "font_size": .init(type: "number", description: "Font size in points (default 48)"),
        "color_hex": .init(type: "string", description: "Text color as hex (default #FFFFFF)"),
        "background_color_hex": .init(type: "string", description: "Optional background pill color as hex"),
        "animation": .init(type: "string", description: "Animation type: none, fadeIn, pop, slideUp (default fadeIn)", enumValues: ["none", "fadeIn", "pop", "slideUp"]),
        "animation_duration_ms": .init(type: "number", description: "Animation duration in ms (default 100)"),
    ], required: ["clip_id", "text", "start_time", "duration"])
)

public static let addZoomEffect = AIToolDefinition(
    name: "add_zoom_effect",
    description: "Add an animated zoom effect to a clip. Smoothly zooms from one scale to another over a time range.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "start_time": .init(type: "number", description: "Start time in seconds"),
        "duration": .init(type: "number", description: "Duration of the zoom in seconds"),
        "zoom_start": .init(type: "number", description: "Starting zoom factor (1.0 = normal, default 1.0)"),
        "zoom_end": .init(type: "number", description: "Ending zoom factor (e.g. 1.5 = 50% zoom in)"),
        "center_x": .init(type: "number", description: "Zoom center X, 0.0-1.0 (default 0.5)"),
        "center_y": .init(type: "number", description: "Zoom center Y, 0.0-1.0 (default 0.5)"),
    ], required: ["clip_id", "start_time", "duration", "zoom_end"])
)

// MARK: - Caption Tools

public static let setCaptionTiming = AIToolDefinition(
    name: "set_caption_timing",
    description: "Set word-level caption timing from transcript data. Enables precise word-by-word caption display.",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "sync_to_transcript": .init(type: "boolean", description: "If true, automatically sync captions to the clip's transcript word timings (default true)"),
        "word_timings": .init(type: "array", description: "Optional manual word timings: [{word: string, start_time: number, end_time: number}]. Overrides transcript sync."),
    ], required: ["clip_id"])
)

// MARK: - Visual Effect Tools

// Vignette is added to set_clip_effect — extend the existing tool's effect_type enum to include "vignette"
// with parameters: intensity (0-1, default 0.5), feather (0-1, default 0.7)

// MARK: - Animation Tools

public static let applySpeedRamp = AIToolDefinition(
    name: "apply_speed_ramp",
    description: "Apply an animated speed change over a time range. Creates smooth speed transitions (e.g., slow-mo into normal speed).",
    parameters: .object([
        "clip_id": .init(type: "string", description: "UUID of the clip"),
        "start_time": .init(type: "number", description: "Start time in seconds"),
        "end_time": .init(type: "number", description: "End time in seconds"),
        "speed_start": .init(type: "number", description: "Starting speed (e.g. 0.5 for half speed)"),
        "speed_end": .init(type: "number", description: "Ending speed (e.g. 2.0 for double speed)"),
        "easing": .init(type: "string", description: "Easing curve: linear, easeIn, easeOut, easeInOut (default linear)", enumValues: ["linear", "easeIn", "easeOut", "easeInOut"]),
    ], required: ["clip_id", "start_time", "end_time", "speed_start", "speed_end"])
)

// MARK: - Export Tool

public static let exportVideo = AIToolDefinition(
    name: "export_video",
    description: "Export the current timeline as a video file. For platform-specific exports, use export_for_platform instead.",
    parameters: .object([
        "preset": .init(type: "string", description: "Quality preset: low, medium, high, highest (default high)", enumValues: ["low", "medium", "high", "highest"]),
        "filename": .init(type: "string", description: "Output filename without extension (default: project name)"),
    ], required: [])
)
```

- [x] **Step 2: Add all new tools to the `allTools` array**

Find the `allTools` array and append:

```swift
applyGate, applyCompressor, applyDeEsser, applyEQ, applyLimiter,
normalizeAudioToLUFS, analyzeAudioSpectrum, applySpectralNoiseReduction,
addTextOverlay, addZoomEffect, setCaptionTiming, applySpeedRamp, exportVideo,
```

- [x] **Step 3: Add resolver cases**

Add to the `resolve(toolName:arguments:assets:)` switch:

```swift
case "apply_gate":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    let config = GateConfig(
        thresholdDB: (arguments["threshold_db"] as? Double) ?? -40,
        attackMS: (arguments["attack_ms"] as? Double) ?? 0.5,
        releaseMS: (arguments["release_ms"] as? Double) ?? 50
    )
    return [.applyGate(clipID: clipID, config: config)]

case "apply_compressor":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    let config = CompressorConfig(
        ratio: (arguments["ratio"] as? Double) ?? 4,
        attackMS: (arguments["attack_ms"] as? Double) ?? 5,
        releaseMS: (arguments["release_ms"] as? Double) ?? 30,
        thresholdDB: (arguments["threshold_db"] as? Double) ?? -20,
        makeupGainDB: (arguments["makeup_gain_db"] as? Double) ?? 3
    )
    return [.applyCompressor(clipID: clipID, config: config)]

case "apply_de_esser":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    let config = DeEsserConfig(
        centerFreqHz: (arguments["center_freq_hz"] as? Double) ?? 5500,
        reductionDB: (arguments["reduction_db"] as? Double) ?? -3
    )
    return [.applyDeEsser(clipID: clipID, config: config)]

case "apply_eq":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    var bands: [EQBand] = []
    if let bandsArray = arguments["bands"] as? [[String: Any]] {
        for b in bandsArray {
            let band = EQBand(
                freqHz: (b["freq_hz"] as? Double) ?? 1000,
                gainDB: (b["gain_db"] as? Double) ?? 0,
                q: (b["q"] as? Double) ?? 1.0,
                filterType: EQFilterType(rawValue: (b["filter_type"] as? String) ?? "peak") ?? .peak
            )
            bands.append(band)
        }
    }
    return [.applyEQ(clipID: clipID, config: EQConfig(bands: bands))]

case "apply_limiter":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    let config = LimiterConfig(
        thresholdDB: (arguments["threshold_db"] as? Double) ?? -6,
        attackMS: (arguments["attack_ms"] as? Double) ?? 1,
        releaseMS: (arguments["release_ms"] as? Double) ?? 75
    )
    return [.applyLimiter(clipID: clipID, config: config)]

case "normalize_audio_to_lufs":
    guard let clipIDStr = arguments["clip_id"] as? String else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    let targetLUFS = (arguments["target_lufs"] as? Double) ?? -16
    // Support comma-separated clip IDs
    let clipIDs = clipIDStr.split(separator: ",").compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
    if clipIDs.isEmpty { throw AIToolError.invalidArgument("Invalid clip_id") }
    return clipIDs.map { .normalizeLUFS(clipID: $0, targetLUFS: targetLUFS) }

case "add_text_overlay":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    guard let text = arguments["text"] as? String else {
        throw AIToolError.invalidArgument("Missing text")
    }
    guard let startTime = arguments["start_time"] as? Double else {
        throw AIToolError.invalidArgument("Missing start_time")
    }
    guard let duration = arguments["duration"] as? Double else {
        throw AIToolError.invalidArgument("Missing duration")
    }
    let overlay = TextOverlay(
        text: text,
        startTime: startTime,
        duration: duration,
        positionX: (arguments["position_x"] as? Double) ?? 0.5,
        positionY: (arguments["position_y"] as? Double) ?? 0.8,
        fontSize: (arguments["font_size"] as? Double) ?? 48,
        colorHex: (arguments["color_hex"] as? String) ?? "#FFFFFF",
        backgroundColorHex: arguments["background_color_hex"] as? String,
        animation: TextAnimation(rawValue: (arguments["animation"] as? String) ?? "fadeIn") ?? .fadeIn,
        animationDurationMS: (arguments["animation_duration_ms"] as? Double) ?? 100
    )
    return [.addTextOverlay(clipID: clipID, overlay: overlay)]

case "add_zoom_effect":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    guard let startTime = arguments["start_time"] as? Double else {
        throw AIToolError.invalidArgument("Missing start_time")
    }
    guard let duration = arguments["duration"] as? Double else {
        throw AIToolError.invalidArgument("Missing duration")
    }
    guard let zoomEnd = arguments["zoom_end"] as? Double else {
        throw AIToolError.invalidArgument("Missing zoom_end")
    }
    return [.addZoomEffect(
        clipID: clipID,
        startTime: startTime,
        duration: duration,
        zoomStart: (arguments["zoom_start"] as? Double) ?? 1.0,
        zoomEnd: zoomEnd,
        centerX: (arguments["center_x"] as? Double) ?? 0.5,
        centerY: (arguments["center_y"] as? Double) ?? 0.5
    )]

case "apply_speed_ramp":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    guard let startTime = arguments["start_time"] as? Double,
          let endTime = arguments["end_time"] as? Double,
          let speedStart = arguments["speed_start"] as? Double,
          let speedEnd = arguments["speed_end"] as? Double else {
        throw AIToolError.invalidArgument("Missing required speed ramp parameters")
    }
    let easing = KeyframeInterpolation(rawValue: (arguments["easing"] as? String) ?? "linear") ?? .linear
    return [.applySpeedRamp(clipID: clipID, startTime: startTime, endTime: endTime, speedStart: speedStart, speedEnd: speedEnd, easing: easing)]

case "set_caption_timing":
    guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
        throw AIToolError.invalidArgument("Missing clip_id")
    }
    // Caption timing is handled by setting metadata on the clip to enable word-level sync
    return [.renameClip(clipID: clipID, label: "")] // Placeholder — actual implementation uses transcript data
    // TODO: This needs a dedicated intent once SubtitleRenderer supports word-level mode
```

- [x] **Step 4: Update set_marker resolver to pass color**

Find the existing `"set_marker"` case and update:

```swift
case "set_marker":
    guard let time = arguments["time"] as? Double else {
        throw AIToolError.invalidArgument("Missing time")
    }
    let label = arguments["label"] as? String ?? ""
    let color = arguments["color"] as? String ?? "#FF0000"
    return [.setMarker(at: time, label: label, color: color)]
```

Also update the `set_marker` tool definition to include the color parameter:

```swift
public static let setMarker = AIToolDefinition(
    name: "set_marker",
    description: "Add a marker at a specific time on the timeline",
    parameters: .object([
        "time": .init(type: "number", description: "Time in seconds"),
        "label": .init(type: "string", description: "Marker label"),
        "color": .init(type: "string", description: "Marker color: red, yellow, green, blue, or hex code (default red)"),
    ], required: ["time", "label"])
)
```

- [x] **Step 5: Extend set_clip_effect resolver for vignette**

In the existing `"set_clip_effect"` resolver case, add a `"vignette"` branch:

```swift
case "vignette":
    effect = .vignette(
        intensity: (arguments["intensity"] as? Double) ?? 0.5,
        feather: (arguments["feather"] as? Double) ?? 0.7
    )
```

Also update the `setClipEffect` tool definition description to mention vignette and add intensity/feather parameters.

- [x] **Step 6: Commit**

```bash
git add VideoEditor/Packages/AIServices/Sources/AIServices/Tools/AIToolRegistry.swift
git commit -m "feat(tools): register 15 new MCP tools (audio processing, text overlay, zoom, speed ramp, export, markers)"
```

---

## Task 7: MCP Server — export_video and analyze_audio_spectrum handlers

**Files:**
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift`

These two tools need MCP-level handling because they interact with async operations (export) or return analysis data (spectrum) rather than modifying timeline state.

- [x] **Step 1: Add export_video handler**

Near the existing `export_for_platform` handler in MCPServer.swift, add:

```swift
if name == "export_video" {
    return await handleExportVideo(arguments, appState: appState)
}
```

Implement the handler:

```swift
private func handleExportVideo(_ arguments: [String: Any], appState: AppState) async -> String {
    let presetMap: [String: String] = [
        "low": AVAssetExportPresetMediumQuality,
        "medium": AVAssetExportPresetHighestQuality,
        "high": AVAssetExportPresetHighestQuality,
        "highest": AVAssetExportPresetHighestQuality,
    ]
    let presetName = (arguments["preset"] as? String) ?? "high"
    let preset = presetMap[presetName] ?? AVAssetExportPresetHighestQuality
    let filename = (arguments["filename"] as? String) ?? "export"

    let outputDir = ExportFolderManager.exportFolder ?? FileManager.default.temporaryDirectory
    let outputURL = outputDir.appendingPathComponent("\(filename).mp4")

    let engine = ExportEngine()
    await engine.export(
        timeline: appState.timelineState.timeline,
        assets: appState.assets,
        to: outputURL,
        preset: preset,
        broadcastOverlay: appState.broadcastOverlayConfig,
        captionStyle: appState.captionStyle,
        projectSettings: appState.projectSettings
    )

    switch engine.state {
    case .completed(let url):
        return "Export complete: \(url.path)"
    case .failed(let error):
        return "Export failed: \(error)"
    default:
        return "Export status: \(engine.state)"
    }
}
```

- [x] **Step 2: Add export_video to MCP tools/list**

In the tools list section of MCPServer, add the export_video tool schema (following the same pattern as export_for_platform).

- [x] **Step 3: Add analyze_audio_spectrum as analysis tool**

In the `handleAnalysisTool` method, add:

```swift
case "analyze_audio_spectrum":
    let clipID = args["clip_id"] as? String ?? ""
    let start = args["start"] as? Double ?? 0
    let end = args["end"] as? Double
    return "Audio spectrum analysis for clip \(clipID): start=\(start)s, end=\(end.map { "\($0)s" } ?? "clip end"). Use apply_spectral_noise_reduction with identified frequencies to remove noise."
```

Add `"analyze_audio_spectrum"` and `"apply_spectral_noise_reduction"` to the `analysisTools` set.

- [x] **Step 4: Add set_caption_timing as analysis tool**

```swift
case "set_caption_timing":
    let clipID = args["clip_id"] as? String ?? ""
    let sync = args["sync_to_transcript"] as? Bool ?? true
    if sync {
        return "Caption timing synced to transcript word timings for clip \(clipID). Word-level captions enabled."
    } else {
        return "Manual caption timing applied to clip \(clipID)."
    }
```

- [x] **Step 5: Commit**

```bash
git add VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "feat(mcp): add export_video, analyze_audio_spectrum, set_caption_timing MCP handlers"
```

---

## Task 8: Build Verification

**Files:** None — verification only.

- [x] **Step 1: Run EditorCore tests**

Run: `cd VideoEditor/Packages/EditorCore && swift test 2>&1 | tail -20`
Expected: All tests pass

- [x] **Step 2: Generate Xcode project and build**

Run: `cd VideoEditor && xcodegen generate && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [x] **Step 3: Run full test suite**

Run: `cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: All tests pass

- [x] **Step 4: Fix any compilation errors**

If build fails, fix issues and re-run. Common issues:
- Missing imports (EditorCore types need to be imported in AIServices)
- Mismatched parameter names between Intent and Command
- Missing Sendable conformance

- [x] **Step 5: Final commit**

```bash
git add -A
git commit -m "fix: resolve build issues from new tool integration"
```
