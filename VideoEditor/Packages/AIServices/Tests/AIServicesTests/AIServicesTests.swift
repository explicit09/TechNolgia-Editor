import Testing
import Foundation
@testable import AIServices
@testable import EditorCore

@Suite("AI Services Tests")
struct AIServicesTests {

    @Test("AIMessage round-trips all encoded fields")
    func messageEncoding() throws {
        let message = AIMessage(
            role: "user",
            content: "Hello",
            toolResultID: "tool-use-123",
            isToolResult: true
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AIMessage.self, from: data)
        #expect(decoded.role == "user")
        #expect(decoded.content == "Hello")
        #expect(decoded.toolResultID == "tool-use-123")
        #expect(decoded.isToolResult == true)
    }

    @Test("CostTier values are correct")
    func costTiers() {
        #expect(CostTier.local.rawValue == "local")
        #expect(CostTier.frequent.rawValue == "frequent")
        #expect(CostTier.expensive.rawValue == "expensive")
    }

    @MainActor
    @Test("Visual effect tools resolve to clip-mutating intents")
    func visualEffectToolResolution() throws {
        let resolver = AIToolResolver()

        let effectIntents = try resolver.resolve(toolName: "set_clip_effect", arguments: [
            "clip_id": UUID().uuidString,
            "effect_type": "blur",
            "radius": 12.0,
        ])
        #expect(effectIntents.count == 1)
        if case .replacePrimaryClipEffect(_, let effect) = effectIntents[0] {
            #expect(effect.type == EffectInstance.typeBlur)
            #expect(effect.parameters["radius"] == 12.0)
        } else {
            Issue.record("set_clip_effect should resolve to replacePrimaryClipEffect")
        }

        let denoiseIntents = try resolver.resolve(toolName: "denoise_video", arguments: [
            "clip_id": UUID().uuidString,
            "level": 0.45,
        ])
        if case .replacePrimaryClipEffect(_, let effect) = denoiseIntents[0] {
            #expect(effect.type == EffectInstance.typeVideoDenoise)
            #expect(effect.parameters["level"] == 0.45)
        } else {
            Issue.record("denoise_video should resolve to replacePrimaryClipEffect")
        }

        let lutPath = "/tmp/test.cube"
        let lutIntents = try resolver.resolve(toolName: "apply_lut", arguments: [
            "clip_id": UUID().uuidString,
            "lut_path": lutPath,
        ])
        if case .replacePrimaryClipEffect(_, let effect) = lutIntents[0] {
            #expect(effect.type == EffectInstance.typeLUT)
            #expect(effect.stringParameters["path"] == lutPath)
        } else {
            Issue.record("apply_lut should resolve to replacePrimaryClipEffect")
        }

        let chromaIntents = try resolver.resolve(toolName: "chroma_key", arguments: [
            "clip_id": UUID().uuidString,
            "target_hue": 0.33,
            "tolerance": 0.12,
        ])
        if case .replacePrimaryClipEffect(_, let effect) = chromaIntents[0] {
            #expect(effect.type == EffectInstance.typeChromaKey)
            #expect(effect.parameters["targetHue"] == 0.33)
            #expect(effect.parameters["tolerance"] == 0.12)
        } else {
            Issue.record("chroma_key should resolve to replacePrimaryClipEffect")
        }
    }
    @MainActor
    @Test("Clip property tools resolve to correct intents")
    func clipPropertyToolResolution() throws {
        let resolver = AIToolResolver()
        let clipID = UUID()

        // set_clip_crop
        let cropIntents = try resolver.resolve(toolName: "set_clip_crop", arguments: [
            "clip_id": clipID.uuidString,
            "x": 0.1,
            "y": 0.2,
            "width": 0.5,
            "height": 0.6,
        ])
        #expect(cropIntents.count == 1)
        if case .setClipCrop(let id, let crop) = cropIntents[0] {
            #expect(id == clipID)
            #expect(crop.x == 0.1)
            #expect(crop.y == 0.2)
            #expect(crop.width == 0.5)
            #expect(crop.height == 0.6)
        } else {
            Issue.record("set_clip_crop should resolve to setClipCrop")
        }

        // set_clip_blend_mode
        let blendIntents = try resolver.resolve(toolName: "set_clip_blend_mode", arguments: [
            "clip_id": clipID.uuidString,
            "blend_mode": "multiply",
        ])
        #expect(blendIntents.count == 1)
        if case .setClipBlendMode(let id, let mode) = blendIntents[0] {
            #expect(id == clipID)
            #expect(mode == .multiply)
        } else {
            Issue.record("set_clip_blend_mode should resolve to setClipBlendMode")
        }

        // remove_clip_effect
        let effectID = UUID()
        let removeIntents = try resolver.resolve(toolName: "remove_clip_effect", arguments: [
            "clip_id": clipID.uuidString,
            "effect_id": effectID.uuidString,
        ])
        #expect(removeIntents.count == 1)
        if case .removeClipEffect(let cid, let eid) = removeIntents[0] {
            #expect(cid == clipID)
            #expect(eid == effectID)
        } else {
            Issue.record("remove_clip_effect should resolve to removeClipEffect")
        }
    }

    @MainActor
    @Test("Track management tools resolve correctly")
    func trackManagementToolResolution() throws {
        let resolver = AIToolResolver()
        let trackID = UUID()

        let soloIntents = try resolver.resolve(toolName: "solo_track", arguments: [
            "track_id": trackID.uuidString,
            "soloed": true,
        ])
        #expect(soloIntents.count == 1)
        if case .soloTrack(let id, let soloed) = soloIntents[0] {
            #expect(id == trackID)
            #expect(soloed == true)
        } else {
            Issue.record("solo_track should resolve to soloTrack")
        }

        let renameIntents = try resolver.resolve(toolName: "rename_track", arguments: [
            "track_id": trackID.uuidString,
            "name": "Main Audio",
        ])
        #expect(renameIntents.count == 1)
        if case .renameTrack(let id, let name) = renameIntents[0] {
            #expect(id == trackID)
            #expect(name == "Main Audio")
        } else {
            Issue.record("rename_track should resolve to renameTrack")
        }

        let reorderIntents = try resolver.resolve(toolName: "reorder_track", arguments: [
            "track_id": trackID.uuidString,
            "new_index": 2,
        ])
        #expect(reorderIntents.count == 1)
        if case .reorderTrack(let id, let idx) = reorderIntents[0] {
            #expect(id == trackID)
            #expect(idx == 2)
        } else {
            Issue.record("reorder_track should resolve to reorderTrack")
        }
    }

    @MainActor
    @Test("Link clips tool resolves correctly")
    func linkClipsToolResolution() throws {
        let resolver = AIToolResolver()
        let clip1 = UUID()
        let clip2 = UUID()

        let linkIntents = try resolver.resolve(toolName: "link_clips", arguments: [
            "clip_ids": [clip1.uuidString, clip2.uuidString],
            "link": true,
        ])
        #expect(linkIntents.count == 1)
        if case .linkClips(let ids, let groupID) = linkIntents[0] {
            #expect(ids.count == 2)
            #expect(ids.contains(clip1))
            #expect(ids.contains(clip2))
            #expect(groupID != nil)
        } else {
            Issue.record("link_clips with link=true should resolve to linkClips with non-nil groupID")
        }

        let unlinkIntents = try resolver.resolve(toolName: "link_clips", arguments: [
            "clip_ids": [clip1.uuidString],
            "link": false,
        ])
        if case .linkClips(_, let groupID) = unlinkIntents[0] {
            #expect(groupID == nil)
        } else {
            Issue.record("link_clips with link=false should have nil groupID")
        }
    }

    @MainActor
    @Test("Batch tool resolves to batch intent with nested operations")
    func batchToolResolution() throws {
        let resolver = AIToolResolver()
        let trackID = UUID()
        let clipID = UUID()

        let ops = """
        [{"tool":"solo_track","args":{"track_id":"\(trackID.uuidString)","soloed":true}},{"tool":"set_clip_volume","args":{"clip_id":"\(clipID.uuidString)","volume":0.5}}]
        """

        let intents = try resolver.resolve(toolName: "batch", arguments: [
            "operations": ops,
        ])
        #expect(intents.count == 1)
        if case .batch(let nested) = intents[0] {
            #expect(nested.count == 2)
            if case .soloTrack(let id, let soloed) = nested[0] {
                #expect(id == trackID)
                #expect(soloed == true)
            } else {
                Issue.record("First batch op should be soloTrack")
            }
            if case .setClipVolume(let id, let vol) = nested[1] {
                #expect(id == clipID)
                #expect(vol == 0.5)
            } else {
                Issue.record("Second batch op should be setClipVolume")
            }
        } else {
            Issue.record("batch should resolve to .batch")
        }
    }

    @MainActor
    @Test("Batch rejects nested remove_silence")
    func batchRejectsRemoveSilence() throws {
        let resolver = AIToolResolver()
        let ops = """
        [{"tool":"remove_silence","args":{"min_duration":0.5}}]
        """
        #expect(throws: AIToolError.self) {
            try resolver.resolve(toolName: "batch", arguments: ["operations": ops])
        }
    }

    @MainActor
    @Test("AppState tools resolve to empty intents (handled upstream)")
    func appStateToolResolution() throws {
        let resolver = AIToolResolver()

        for toolName in ["undo", "redo", "play_pause", "seek", "toggle_loop", "get_action_log"] {
            let intents = try resolver.resolve(toolName: toolName, arguments: [:])
            #expect(intents.isEmpty, "'\(toolName)' should resolve to empty intents (handled upstream)")
        }
    }

    @MainActor
    @Test("activate_skill resolves to empty intents (handled upstream)")
    func activateSkillToolResolution() throws {
        let resolver = AIToolResolver()
        let intents = try resolver.resolve(toolName: "activate_skill", arguments: [
            "name": "podcast-episode-producer",
        ])
        #expect(intents.isEmpty, "activate_skill should resolve to empty intents (handled upstream)")
    }

    @MainActor
    @Test("Overlay presentation tools resolve correctly")
    func overlayPresentationToolResolution() throws {
        let resolver = AIToolResolver()
        let clipID = UUID()

        // set_clip_overlay_presentation
        let overlayIntents = try resolver.resolve(toolName: "set_clip_overlay_presentation", arguments: [
            "clip_id": clipID.uuidString,
            "mode": "pip",
            "shadow": "heavy",
            "corner_radius": 12.0,
            "mask_shape": "roundedRect",
            "border_visible": true,
            "border_width": 3.0,
        ])
        #expect(overlayIntents.count == 1)
        if case .setClipOverlayPresentation(let id, let pres) = overlayIntents[0] {
            #expect(id == clipID)
            #expect(pres.mode == .pip)
            #expect(pres.shadow == .heavy)
            #expect(pres.cornerRadius == 12.0)
            #expect(pres.maskShape == .roundedRect)
            #expect(pres.border.isVisible == true)
            #expect(pres.border.width == 3.0)
        } else {
            Issue.record("set_clip_overlay_presentation should resolve to setClipOverlayPresentation")
        }

        // apply_pip_preset
        let pipIntents = try resolver.resolve(toolName: "apply_pip_preset", arguments: [
            "clip_id": clipID.uuidString,
            "preset": "bottomRight",
        ])
        #expect(pipIntents.count == 1)
        if case .applyClipPiPPreset(let id, let preset) = pipIntents[0] {
            #expect(id == clipID)
            #expect(preset == .bottomRight)
        } else {
            Issue.record("apply_pip_preset should resolve to applyClipPiPPreset")
        }
    }
}

@Suite("IntentRouter Tests")
struct IntentRouterTests {

    @Test("Playback keywords route to fast tier with playback tools")
    func playbackRouting() {
        let router = IntentRouter()

        for keyword in ["undo that", "redo", "play the timeline", "pause", "seek to 10", "go to the start", "loop this"] {
            let decision = router.route(keyword)
            #expect(decision.tier == .fast, "'\(keyword)' should route to fast tier")
            #expect(decision.toolSubset.contains("play_pause") || decision.toolSubset.contains("undo"),
                    "'\(keyword)' should include playback tools")
        }
    }

    @Test("New property keywords route correctly")
    func newPropertyRouting() {
        let router = IntentRouter()

        let decision = router.route("crop this clip to center")
        #expect(decision.tier == .fast)
        #expect(decision.toolSubset.contains("set_clip_crop"))

        let blendDecision = router.route("set blend mode to multiply")
        #expect(blendDecision.tier == .fast)
        #expect(blendDecision.toolSubset.contains("set_clip_blend_mode"))
    }

    @Test("New structural keywords route correctly")
    func newStructuralRouting() {
        let router = IntentRouter()

        let decision = router.route("reorder the tracks")
        #expect(decision.tier == .fast)
        #expect(decision.toolSubset.contains("reorder_track"))

        let linkDecision = router.route("link these clips together")
        #expect(linkDecision.tier == .fast)
        #expect(linkDecision.toolSubset.contains("link_clips"))
    }
}

@Suite("Lemmatizer Tests")
struct LemmatizerTests {

    @Test("Lemmatizes common word forms")
    func basicLemmatization() {
        let lemmatizer = Lemmatizer()
        // These are single-word lemmatizations — less context, but core verbs work
        #expect(lemmatizer.lemmatize(word: "running") == "run")
        #expect(lemmatizer.lemmatize(word: "talked") == "talk")
        #expect(lemmatizer.lemmatize(word: "edited") == "edit")
    }

    @Test("Lemmatizes transcript with sentence context")
    func transcriptLemmatization() {
        let lemmatizer = Lemmatizer()
        let words = [
            TranscriptWord(word: "We", start: 0, end: 0.2),
            TranscriptWord(word: "were", start: 0.3, end: 0.5),
            TranscriptWord(word: "discussing", start: 0.6, end: 1.0),
            TranscriptWord(word: "pricing", start: 1.1, end: 1.5),
            TranscriptWord(word: "models", start: 1.6, end: 2.0),
        ]

        let result = lemmatizer.lemmatizeTranscript(words)

        // Every word should have a lemma
        for word in result {
            #expect(word.lemma != nil)
        }

        // "discussing" should lemmatize to "discuss"
        #expect(result[2].lemma == "discuss")
        // "pricing" should lemmatize to "price"
        #expect(result[3].lemma == "price")
    }
}

@Suite("Transcript Search Tests")
struct TranscriptSearchTests {

    @Test("Finds exact word match")
    func exactMatch() {
        let asset = makeAsset(words: [
            TranscriptWord(word: "we", lemma: "we", start: 0, end: 0.2),
            TranscriptWord(word: "launched", lemma: "launch", start: 0.3, end: 0.6),
            TranscriptWord(word: "in", lemma: "in", start: 0.7, end: 0.8),
            TranscriptWord(word: "Seattle", lemma: "seattle", start: 0.9, end: 1.3),
            TranscriptWord(word: "last", lemma: "last", start: 1.4, end: 1.6),
            TranscriptWord(word: "month", lemma: "month", start: 1.7, end: 2.0),
        ])

        let engine = TranscriptSearchEngine()
        let results = engine.search(query: "Seattle", assets: [asset])

        #expect(results.count == 1)
        #expect(results[0].matchWord == "Seattle")
        #expect(results[0].matchTime == 0.9)
    }

    @Test("Finds morphological match via lemma — price matches pricing")
    func lemmaMatch() {
        let asset = makeAsset(words: [
            TranscriptWord(word: "the", lemma: "the", start: 4.5, end: 4.7),
            TranscriptWord(word: "pricing", lemma: "price", start: 5.0, end: 5.5),
            TranscriptWord(word: "model", lemma: "model", start: 5.6, end: 6.0),
        ])

        let engine = TranscriptSearchEngine()
        let results = engine.searchAsset(query: "price", asset: asset)

        #expect(results.count == 1)
        if let first = results.first {
            #expect(first.matchWord == "pricing")
        }
    }

    @Test("Returns empty for no matches")
    func noMatch() {
        let asset = makeAsset(words: [
            TranscriptWord(word: "hello", lemma: "hello", start: 0, end: 0.5),
            TranscriptWord(word: "world", lemma: "world", start: 0.6, end: 1.0),
        ])

        let engine = TranscriptSearchEngine()
        let results = engine.search(query: "goodbye", assets: [asset])

        #expect(results.isEmpty)
    }

    @Test("Phrase search matches consecutive words only")
    func phraseSearch() {
        let asset = makeAsset(words: [
            TranscriptWord(word: "the", lemma: "the", start: 0, end: 0.2),
            TranscriptWord(word: "pricing", lemma: "price", start: 0.3, end: 0.6),
            TranscriptWord(word: "model", lemma: "model", start: 0.7, end: 1.0),
            TranscriptWord(word: "is", lemma: "be", start: 1.1, end: 1.2),
            TranscriptWord(word: "great", lemma: "great", start: 1.3, end: 1.6),
            TranscriptWord(word: "the", lemma: "the", start: 2.0, end: 2.2),
            TranscriptWord(word: "model", lemma: "model", start: 2.3, end: 2.6),
            TranscriptWord(word: "pricing", lemma: "price", start: 2.7, end: 3.0),
        ])

        let engine = TranscriptSearchEngine()

        // "pricing model" should match at 0.3s (consecutive) but NOT at 2.3s (reversed order)
        let results = engine.searchAsset(query: "pricing model", asset: asset)
        #expect(results.count == 1)
        if let first = results.first {
            #expect(first.matchTime == 0.3)
            #expect(first.matchWord == "pricing model")
        }
    }

    @Test("Phrase search does not match non-consecutive words")
    func phraseSearchNonConsecutive() {
        let asset = makeAsset(words: [
            TranscriptWord(word: "pricing", lemma: "price", start: 0, end: 0.3),
            TranscriptWord(word: "is", lemma: "be", start: 0.4, end: 0.5),
            TranscriptWord(word: "the", lemma: "the", start: 0.6, end: 0.7),
            TranscriptWord(word: "model", lemma: "model", start: 0.8, end: 1.0),
        ])

        let engine = TranscriptSearchEngine()
        // "pricing model" should NOT match — "is the" breaks the phrase
        let results = engine.searchAsset(query: "pricing model", asset: asset)
        #expect(results.isEmpty)
    }

    @Test("Skips assets without transcripts")
    func skipsUntranscribed() {
        let asset = MediaAsset(
            name: "test", sourceURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            type: .video, duration: 10
        )

        let engine = TranscriptSearchEngine()
        let results = engine.search(query: "hello", assets: [asset])

        #expect(results.isEmpty)
    }

    @Test("Searches specific asset")
    func searchSingleAsset() {
        let asset = makeAsset(words: [
            TranscriptWord(word: "testing", lemma: "test", start: 2.0, end: 2.5),
        ])

        let engine = TranscriptSearchEngine()
        // "test" query lemmatizes to "test", matches lemma "test"
        let results = engine.searchAsset(query: "test", asset: asset)

        #expect(results.count == 1)
        #expect(results[0].assetID == asset.id)
    }

    // MARK: - Helper

    private func makeAsset(words: [TranscriptWord]) -> MediaAsset {
        MediaAsset(
            name: "test-video",
            sourceURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            type: .video,
            duration: 60,
            analysis: MediaAnalysis(transcript: words)
        )
    }
}

@Suite("SkillRegistry Tests")
struct SkillRegistryTests {

    @Test("skillCatalog returns formatted catalog of loaded skills")
    func skillCatalog() {
        let registry = SkillRegistry()
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let skillsDir = projectRoot.appendingPathComponent(".claude/skills")
        registry.loadSkills(from: skillsDir)

        let catalog = registry.skillCatalog()
        #expect(catalog.contains("<available_skills>"))
        #expect(catalog.contains("</available_skills>"))
        #expect(catalog.contains("podcast-episode-producer"))
        #expect(catalog.contains("activate_skill"))
    }

    @Test("skillCatalog returns empty string when no skills loaded")
    func emptyCatalog() {
        let registry = SkillRegistry()
        let catalog = registry.skillCatalog()
        #expect(catalog.isEmpty)
    }
}
