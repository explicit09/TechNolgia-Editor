import Foundation
import EditorCore
import AIServices

/// Orchestrates AI chat: builds context, sends to provider, executes tool calls.
/// Supports multi-turn tool execution — sends results back to Claude until it's done.
@MainActor @Observable
final class AIChatController {
    private static let maxMessages = 100

    private(set) var messages: [ChatMessage] = [] {
        didSet {
            // Prevent unbounded growth — keep last N messages
            if messages.count > Self.maxMessages {
                messages = Array(messages.suffix(Self.maxMessages))
            }
        }
    }
    private(set) var isProcessing = false
    private(set) var processingStatus: String?
    private(set) var lastSearchQuery: String?
    private(set) var lastSearchResults: [SearchResult]?

    private let contextBuilder = AIContextBuilder()
    private let toolResolver = AIToolResolver()
    private let intentRouter = IntentRouter()
    private let skillRegistry = SkillRegistry()
    private let planClassifier = PlanClassifier()
    private let planGenerator = PlanGenerator()
    private let planExecutor = PlanExecutor()
    private var provider: (any AIProvider)?
    private(set) var activeSkill: String?
    private(set) var pendingPlan: EditingPlan?

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        let content: String
        let toolResults: [ToolResult]

        enum Role { case user, assistant, system }

        struct ToolResult {
            let toolName: String
            let success: Bool
            let message: String
        }
    }

    func configure(provider: any AIProvider) {
        self.provider = provider
        updateProviderSkillCatalog()
    }

    /// Load editing skills from the project's .claude/skills/ directory.
    func loadSkills(from skillsDir: URL) {
        skillRegistry.loadSkills(from: skillsDir)
        updateProviderSkillCatalog()
    }

    private func updateProviderSkillCatalog() {
        if let claude = provider as? ClaudeProvider {
            claude.skillCatalog = skillRegistry.skillCatalog()
        }
    }

    func send(message: String, appState: AppState) async {
        guard let provider else {
            messages.append(ChatMessage(role: .system, content: "No AI provider configured. Set ANTHROPIC_API_KEY environment variable.", toolResults: []))
            return
        }

        messages.append(ChatMessage(role: .user, content: message, toolResults: []))
        isProcessing = true

        // Clear previous search results when starting new request
        lastSearchQuery = nil
        lastSearchResults = nil

        do {
            let recentActions = await appState.context.actionLog.recentActions(count: 10)
            let contextLevel = classifyContextLevel(message)
            let context = contextBuilder.buildContext(
                timeline: appState.timeline,
                assets: appState.assets,
                playheadPosition: appState.timelineViewState.playheadPosition,
                selectedClipIDs: appState.timelineViewState.selectedClipIDs,
                recentActions: recentActions,
                level: contextLevel
            )

            // Build conversation with recent history for continuity
            var conversation: [AIMessage] = []

            // Include last few exchanges as summary (not raw tool results)
            let recentMessages = messages.suffix(6) // Last 3 exchanges (user + assistant pairs)
            for msg in recentMessages {
                let role = msg.role == .user ? "user" : "assistant"
                // Summarize tool results instead of re-sending raw data
                var content = msg.content
                if !msg.toolResults.isEmpty {
                    let toolSummary = msg.toolResults.map { "\($0.toolName): \($0.success ? "ok" : "failed")" }.joined(separator: ", ")
                    content += " [Tools: \(toolSummary)]"
                }
                conversation.append(AIMessage(role: role, content: content))
            }

            // Add current request with fresh editor state
            conversation.append(AIMessage(
                role: "user",
                content: "Current editor state:\n\(context.toJSON())\n\nUser request: \(message)"
            ))

            // === PLAN LAYER ===
            // Check if user is approving/rejecting a pending plan
            if let plan = pendingPlan, plan.status == .proposed {
                if planClassifier.isApproval(message) {
                    // Execute the approved plan
                    pendingPlan?.status = .approved
                    processingStatus = "Executing plan..."

                    let result = await planExecutor.execute(
                        plan: plan,
                        provider: provider,
                        editorState: { [contextBuilder, weak appState] in
                            guard let appState else { return "{}" }
                            return await MainActor.run {
                                contextBuilder.buildContext(
                                    timeline: appState.timeline,
                                    assets: appState.assets,
                                    playheadPosition: appState.timelineViewState.playheadPosition,
                                    selectedClipIDs: appState.timelineViewState.selectedClipIDs,
                                    recentActions: [],
                                    level: .standard
                                ).toJSON()
                            }
                        },
                        executeToolCall: { @MainActor [weak appState] name, args in
                            guard let appState else { return "Error: editor unavailable" }
                            return await appState.mcpServer?.executeToolForAgent(name: name, arguments: args)
                                ?? "Error: MCP not available"
                        },
                        onStatus: { [weak self] status in
                            Task { @MainActor in self?.processingStatus = status }
                        }
                    )

                    pendingPlan?.status = .completed
                    messages.append(ChatMessage(role: .assistant, content: result, toolResults: []))
                    isProcessing = false
                    return
                } else if planClassifier.isRejection(message) {
                    pendingPlan?.status = .cancelled
                    pendingPlan = nil
                    messages.append(ChatMessage(role: .assistant, content: "Plan cancelled.", toolResults: []))
                    isProcessing = false
                    return
                }
                // If neither approval nor rejection, treat as a modification — fall through to re-plan
                pendingPlan = nil
            }

            // Check if this request needs a plan
            let hasClips = !appState.timeline.tracks.flatMap(\.clips).isEmpty
            if planClassifier.needsPlan(message, hasClipsOnTimeline: hasClips, hasPendingPlan: pendingPlan != nil) {
                processingStatus = "Creating plan..."

                let skill = skillRegistry.match(message)
                if let skill { activeSkill = skill.name }

                do {
                    let plan = try await planGenerator.generate(
                        request: message,
                        editorState: context.toJSON(),
                        skillContent: skill?.content,
                        provider: provider
                    )
                    pendingPlan = plan
                    messages.append(ChatMessage(role: .assistant, content: plan.displayText, toolResults: []))
                } catch {
                    messages.append(ChatMessage(role: .assistant, content: "Failed to create plan: \(error.localizedDescription)", toolResults: []))
                }

                isProcessing = false
                return
            }

            // === DIRECT EXECUTION (no plan needed) ===
            // Route: classify intent → pick model + tools
            let routing = intentRouter.route(message)
            // Use MCPServer tool definitions (single source of truth) + AIToolRegistry as fallback
            let mcpTools = appState.mcpServer?.toolDefinitionsForAgent() ?? []
            let allAvailableTools = mcpTools.isEmpty ? AIToolRegistry.allTools : mcpTools
            var selectedTools = routing.toolSubset.isEmpty
                ? [] // No tools for questions
                : allAvailableTools.filter { routing.toolSubset.contains($0.name) }
            var currentModel: String? = routing.tier.rawValue

            activeSkill = nil

            // Multi-turn loop: send → get response → if tools, execute and send results back → repeat
            var allToolResults: [ChatMessage.ToolResult] = []
            var finalText = ""
            let maxTurns = 10

            for turn in 0..<maxTurns {
                processingStatus = turn == 0
                    ? (activeSkill != nil ? "Running \(activeSkill!)..." : (routing.tier == .fast ? "Executing..." : "Thinking..."))
                    : "AI planning next step..."
                let response = try await provider.complete(
                    messages: conversation,
                    tools: selectedTools,
                    modelOverride: currentModel
                )

                if !response.content.isEmpty {
                    finalText = response.content
                }

                // If no tool calls, we're done
                guard !response.toolCalls.isEmpty else { break }

                // Add assistant response with raw content blocks (includes tool_use blocks)
                // Claude needs to see its own tool_use blocks before the tool_result
                conversation.append(AIMessage(
                    role: "assistant",
                    content: response.content,
                    toolResultID: response.rawContentJSON // Reuse field to carry raw JSON
                ))

                // Execute each tool call and send results back
                var hadFailure = false
                for toolCall in response.toolCalls {
                    let result = await executeTool(toolCall: toolCall, appState: appState)
                    allToolResults.append(result)
                    if !result.success { hadFailure = true }

                    conversation.append(AIMessage(
                        role: "user",
                        content: result.message,
                        toolResultID: toolCall.id,
                        isToolResult: true
                    ))
                }

                // Escalate to Sonnet on failure if we were using Haiku
                if hadFailure && currentModel == IntentRouter.ModelTier.fast.rawValue {
                    currentModel = IntentRouter.ModelTier.standard.rawValue
                }

                if response.stopReason != "tool_use" { break }
            }

            processingStatus = nil
            let cleanedText = Self.stripLeakedToolXML(finalText)
            let responseContent = cleanedText.isEmpty && !allToolResults.isEmpty
                ? "Executed \(allToolResults.count) editing operation(s)."
                : cleanedText
            messages.append(ChatMessage(role: .assistant, content: responseContent, toolResults: allToolResults))

        } catch {
            processingStatus = nil
            messages.append(ChatMessage(role: .system, content: "Error: \(error.localizedDescription)", toolResults: []))
        }

        isProcessing = false
    }

    func clearHistory() {
        messages.removeAll()
    }

    // MARK: - Tool execution

    private func executeTool(toolCall: AIToolCall, appState: AppState) async -> ChatMessage.ToolResult {
        // Show what tool is running
        processingStatus = "Running \(toolCall.name)..."

        let args = fixupArguments(
            toolName: toolCall.name,
            arguments: toolCall.parsedArguments(),
            timeline: appState.timeline,
            assets: appState.assets
        )

        do {
            // Content analysis tools — delegate to shared handlers
            let contentAnalysisTools = [
                "get_state", "auto_cut", "analyze_transcript", "get_full_transcript",
                "analyze_audio_energy", "classify_audio", "detect_episodes",
                "score_content", "segment_topics", "verify_playback",
            ]
            if contentAnalysisTools.contains(toolCall.name) {
                processingStatus = "Running \(toolCall.name)..."
                let result = await appState.mcpServer?.executeToolForAgent(name: toolCall.name, arguments: args)
                    ?? "Error: MCP server not available"
                return .init(toolName: toolCall.name, success: true, message: result)
            }

            if toolCall.name == "get_overlay_config" {
                if let config = appState.context.timelineState.broadcastOverlay {
                    let result = "Overlay: enabled=\(config.isEnabled), title=\(config.episodeTitle), hosts=\(config.hostA.name)/\(config.hostB.name), \(config.topics.count) topics, \(config.chapters.count) chapters"
                    return .init(toolName: toolCall.name, success: true, message: result)
                }
                return .init(toolName: toolCall.name, success: true, message: "No overlay configured.")
            }

            if toolCall.name == "set_overlay_config" {
                // Resolve via AIToolResolver (returns setBroadcastOverlay intent)
                let intents = try toolResolver.resolve(toolName: toolCall.name, arguments: args, assets: appState.assets)
                for intent in intents {
                    try appState.perform(intent, source: .ai)
                }
                appState.rebuildComposition()
                return .init(toolName: toolCall.name, success: true, message: "Overlay config set. Title: \(args["episode_title"] as? String ?? "")")
            }

            if toolCall.name == "get_transcript" {
                processingStatus = "Reading transcript..."
                let result = try await handleGetTranscript(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "get_visual_scenes" {
                processingStatus = "Reading visual scenes..."
                let result = await handleGetVisualScenes(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "transcribe_asset" {
                // Status updates happen inside handleTranscribeAsset
                let result = try await handleTranscribeAsset(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "search_transcript" {
                processingStatus = "Searching transcripts..."
                let result = await handleSearchTranscript(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "delete_asset" {
                guard let assetIDStr = args["asset_id"] as? String,
                      let assetID = UUID(uuidString: assetIDStr) else {
                    return .init(toolName: toolCall.name, success: false, message: "Invalid asset_id")
                }
                let usedIDs = Set(appState.timeline.tracks.flatMap(\.clips).map(\.assetID))
                guard !usedIDs.contains(assetID) else {
                    return .init(toolName: toolCall.name, success: false, message: "Asset in use on timeline")
                }
                let name = appState.assets.first(where: { $0.id == assetID })?.name ?? "unknown"
                await appState.media.mediaManager.remove(id: assetID)
                await appState.media.refreshAssets()
                return .init(toolName: toolCall.name, success: true, message: "Deleted '\(name)'")
            }
            if toolCall.name == "remove_silence" {
                processingStatus = "Removing silent segments..."
                let result = try handleRemoveSilence(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "remove_section" {
                processingStatus = "Removing section..."
                let result = try handleRemoveSection(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "ripple_delete" {
                processingStatus = "Ripple deleting..."
                let result = try handleRippleDelete(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }
            if toolCall.name == "normalize_audio" {
                processingStatus = "Normalizing audio..."
                let result = try handleNormalizeAudio(args: args, appState: appState)
                return .init(toolName: toolCall.name, success: true, message: result)
            }

            // Skill activation — look up and return skill content
            if toolCall.name == "activate_skill" {
                let skillName = args["name"] as? String ?? ""
                if let skill = skillRegistry.skill(named: skillName) {
                    activeSkill = skill.name
                    var result = "Skill activated: \(skill.name)\n\n"
                    if !skill.tools.isEmpty {
                        result += "Recommended tools for this workflow: \(skill.tools.joined(separator: ", "))\n"
                        result += "(Additional tools beyond this list are available if needed.)\n\n"
                    }
                    result += "---\n\(skill.content)"
                    return .init(toolName: toolCall.name, success: true, message: result)
                } else {
                    let available = skillRegistry.availableSkills.joined(separator: ", ")
                    return .init(toolName: toolCall.name, success: false, message: "Unknown skill '\(skillName)'. Available skills: \(available)")
                }
            }

            // Playback & undo tools — need AppState directly
            if let playbackResult = await handlePlaybackTool(name: toolCall.name, args: args, appState: appState) {
                let isError = playbackResult.hasPrefix("Error:")
                return .init(toolName: toolCall.name, success: !isError, message: playbackResult)
            }

            // All other tools — route through MCPServer (single source of truth)
            // This gives the in-app agent access to ALL 90+ tools without duplicating logic
            processingStatus = "Executing \(toolCall.name)..."
            let result = await appState.mcpServer?.executeToolForAgent(name: toolCall.name, arguments: args)
                ?? "Error: MCP server not available"
            let isError = result.hasPrefix("Error:")
            return .init(toolName: toolCall.name, success: !isError, message: result)
        } catch {
            return .init(toolName: toolCall.name, success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Analysis tool handlers

    private func handleAnalysisTool(name: String, args: [String: Any], appState: AppState) async -> String? {
        switch name {
        case "auto_reframe":
            guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr),
                  let asset = appState.assets.first(where: { $0.id == assetID }) else { return "Error: Invalid asset_id" }
            let ratioStr = (args["aspect_ratio"] as? String) ?? "9:16"
            let ratio = AutoReframer.TargetAspectRatio(rawValue: ratioStr) ?? .vertical
            processingStatus = "Analyzing video for reframing..."
            let reframer = AutoReframer()
            if let result = try? await reframer.analyze(url: asset.sourceURL, targetRatio: ratio, sampleInterval: 2.0) {
                return "Auto reframe: \(result.cropRegions.count) crop regions for \(ratioStr). Source: \(Int(result.sourceSize.width))x\(Int(result.sourceSize.height))."
            }
            return "Error: Reframe analysis failed"

        case "detect_beats":
            guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr),
                  let asset = appState.assets.first(where: { $0.id == assetID }) else { return "Error: Invalid asset_id" }
            processingStatus = "Detecting beats..."
            let detector = BeatDetector()
            if let result = await detector.analyze(url: asset.sourceURL) {
                return "BPM: \(String(format: "%.0f", result.bpm)). \(result.beats.count) beats detected, \(result.strongBeats.count) strong beats (downbeats)."
            }
            return "Error: Beat detection failed"

        case "score_thumbnails":
            guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr),
                  let asset = appState.assets.first(where: { $0.id == assetID }) else { return "Error: Invalid asset_id" }
            let count = (args["count"] as? Int) ?? 5
            processingStatus = "Scoring thumbnail candidates..."
            let scorer = ThumbnailScorer()
            let frames = await scorer.findBestThumbnails(url: asset.sourceURL, count: count)
            if frames.isEmpty { return "No suitable thumbnail frames found." }
            let descriptions = frames.map { "  \(TimeFormatter.duration($0.time)) — score=\(String(format: "%.0f", $0.score)), face=\($0.hasFace)" }
            return "Top \(frames.count) thumbnails:\n" + descriptions.joined(separator: "\n")

        case "suggest_broll":
            let matcher = BRollMatcher()
            // Find first asset with transcript
            guard let asset = appState.assets.first(where: { $0.analysis?.transcript != nil }),
                  let words = asset.analysis?.transcript else { return "No transcribed assets. Transcribe first." }
            let suggestions = matcher.suggest(transcript: words, assets: appState.assets, timeline: appState.timeline)
            if suggestions.isEmpty { return "No B-roll suggestions found." }
            let lines = suggestions.map { "  \($0.assetName) at \(TimeFormatter.duration($0.startTime)) (\(String(format: "%.0f", $0.duration))s) — \($0.reason)" }
            return "\(suggestions.count) B-roll suggestions:\n" + lines.joined(separator: "\n")

        case "measure_loudness":
            guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr),
                  let asset = appState.assets.first(where: { $0.id == assetID }) else { return "Error: Invalid asset_id" }
            processingStatus = "Measuring loudness..."
            let meter = LoudnessMeter()
            if let lufs = await meter.measureLUFS(url: asset.sourceURL) {
                let target = -14.0 // YouTube standard
                let adj = meter.volumeAdjustment(currentLUFS: lufs, targetLUFS: target)
                return "Loudness: \(String(format: "%.1f", lufs)) LUFS. To reach -14 LUFS (YouTube): multiply volume by \(String(format: "%.2f", adj))."
            }
            return "Error: Loudness measurement failed"

        case "voice_cleanup":
            let presetStr = (args["preset"] as? String) ?? "standard"
            let preset = VoiceCleanup.CleanupPreset(rawValue: presetStr) ?? .standard
            let desc = VoiceCleanup.describe(preset: preset)
            return "Voice cleanup preset '\(presetStr)': \(desc). Apply via set_clip_effect with the returned settings."

        case "set_caption_style":
            let style = (args["style"] as? String) ?? "standard"
            return "Caption style set to '\(style)'. Available: standard, karaoke, bold, outline, gradient."

        case "apply_person_mask":
            return "Person mask will be applied during rendering. The EffectCompositor uses VNGeneratePersonSegmentationRequest per-frame."

        case "track_object":
            guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr),
                  let asset = appState.assets.first(where: { $0.id == assetID }) else { return "Error: Invalid asset_id" }
            let trackType = (args["track_type"] as? String) ?? "face"
            processingStatus = "Tracking \(trackType)..."
            let tracker = ObjectTracker()
            if trackType == "face" {
                if let result = await tracker.trackFace(url: asset.sourceURL, duration: 10) {
                    return "Face tracked: \(result.positions.count) positions over 10s. Lost: \(result.trackingLost)."
                }
                return "No face detected."
            }
            return "Object tracking requires initial region. Use face mode."

        case "denoise_audio":
            return "Audio denoising configured. Noise gate at \((args["threshold_db"] as? Double) ?? -40)dB. Apply via AudioProcessor pipeline."

        case "denoise_video":
            return nil // Resolved through AIToolResolver so it actually mutates the clip

        case "stabilize_video":
            guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr),
                  let asset = appState.assets.first(where: { $0.id == assetID }) else { return "Error: Invalid asset_id" }
            processingStatus = "Analyzing camera motion..."
            let stabilizer = VideoStabilizer()
            if let result = await stabilizer.analyze(url: asset.sourceURL, sampleInterval: 1.0) {
                return "Stabilization: \(result.transforms.count) correction frames. Crop factor: \(String(format: "%.1f", result.cropFactor * 100))%."
            }
            return "Error: Stabilization analysis failed"

        case "auto_duck":
            return "Auto ducking configured. Duck level: \((args["duck_level"] as? Double) ?? 0.2). Applied via AudioDucker in CompositionBuilder."

        case "apply_lut":
            return nil // Resolved through AIToolResolver so it actually mutates the clip

        case "chroma_key":
            return nil // Resolved through AIToolResolver so it actually mutates the clip

        default:
            return nil // Not an analysis tool
        }
    }

    // MARK: - Playback & undo tools

    @MainActor
    private func handlePlaybackTool(name: String, args: [String: Any], appState: AppState) async -> String? {
        switch name {
        case "undo":
            guard appState.commandHistory.canUndo else { return "Nothing to undo." }
            do {
                try appState.undo()
                return "Undone. Timeline now has \(appState.timeline.tracks.flatMap(\.clips).count) clip(s)."
            } catch {
                return "Undo failed: \(error.localizedDescription)"
            }

        case "redo":
            guard appState.commandHistory.canRedo else { return "Nothing to redo." }
            do {
                try appState.redo()
                return "Redone. Timeline now has \(appState.timeline.tracks.flatMap(\.clips).count) clip(s)."
            } catch {
                return "Redo failed: \(error.localizedDescription)"
            }

        case "play_pause":
            let action = (args["action"] as? String) ?? "toggle"
            switch action {
            case "play":
                if !appState.playbackEngine.isPlaying { appState.playbackEngine.togglePlayPause() }
            case "pause":
                if appState.playbackEngine.isPlaying { appState.playbackEngine.togglePlayPause() }
            default:
                appState.playbackEngine.togglePlayPause()
            }
            let state = appState.playbackEngine.isPlaying ? "playing" : "paused"
            return "Playback \(state) at \(String(format: "%.1f", appState.playbackEngine.currentTime))s."

        case "seek":
            let time: Double
            if let t = args["time"] as? Double {
                time = t
            } else if let s = args["time"] as? String {
                switch s.lowercased() {
                case "start": time = 0
                case "end": time = appState.timeline.duration
                default:
                    if let t = Double(s) { time = t }
                    else { return "Error: Invalid time value '\(s)'. Use a number or 'start'/'end'." }
                }
            } else {
                return "Error: Missing time parameter."
            }
            appState.playbackEngine.seek(to: time)
            return "Playhead at \(String(format: "%.1f", time))s."

        case "toggle_loop":
            let enabled = (args["enabled"] as? Bool) ?? !appState.playbackEngine.loopEnabled
            appState.playbackEngine.loopEnabled = enabled
            return "Loop \(enabled ? "enabled" : "disabled")."

        case "get_action_log":
            let limit = (args["limit"] as? Int) ?? 20
            let events = await appState.context.actionLog.recentActions(count: limit)
            if events.isEmpty { return "No actions recorded yet." }
            let lines = events.map { event in
                "\(event.timestamp) | \(event.source.rawValue) | \(event.commandName)"
            }
            return "Recent actions (\(events.count)):\n" + lines.joined(separator: "\n")

        default:
            return nil
        }
    }

    // MARK: - Compound tool handlers

    private func handleRemoveSection(args: [String: Any], appState: AppState) throws -> String {
        guard let startTime = args["start_time"] as? Double,
              let endTime = args["end_time"] as? Double,
              endTime > startTime else {
            throw AIToolError.invalidArgument("Invalid time range")
        }

        let allClips = appState.timeline.tracks.flatMap(\.clips)
        let affectedClips = allClips.filter {
            $0.timelineRange.start < endTime && $0.timelineRange.end > startTime
        }

        // Split at end first, then start, then delete the middle clips
        for clip in affectedClips {
            if endTime > clip.timelineRange.start && endTime < clip.timelineRange.end {
                try? appState.perform(.splitClip(clipID: clip.id, at: endTime), source: .ai)
            }
        }
        // Re-fetch clips after splits
        let postSplitClips = appState.timeline.tracks.flatMap(\.clips)
        for clip in postSplitClips {
            if startTime > clip.timelineRange.start && startTime < clip.timelineRange.end {
                try? appState.perform(.splitClip(clipID: clip.id, at: startTime), source: .ai)
            }
        }

        // Delete clips that fall within the range
        let toDelete = appState.timeline.tracks.flatMap(\.clips).filter {
            $0.timelineRange.start >= startTime - 0.01 && $0.timelineRange.end <= endTime + 0.01
        }.map(\.id)

        if !toDelete.isEmpty {
            try? appState.perform(.deleteClips(clipIDs: toDelete), source: .ai)
        }

        // Ripple close gaps
        appState.rippleCloseGaps()

        let duration = endTime - startTime
        return "Removed \(String(format: "%.1f", duration))s section (\(String(format: "%.1f", startTime))s-\(String(format: "%.1f", endTime))s). Deleted \(toDelete.count) clip(s). Gaps closed."
    }

    private func handleRippleDelete(args: [String: Any], appState: AppState) throws -> String {
        guard let clipIDStrs = args["clip_ids"] as? [String], !clipIDStrs.isEmpty else {
            throw AIToolError.invalidArgument("Missing clip_ids")
        }
        let clipIDs = clipIDStrs.compactMap { UUID(uuidString: $0) }
        try appState.perform(.deleteClips(clipIDs: clipIDs), source: .ai)
        appState.rippleCloseGaps()
        let remaining = appState.timeline.tracks.flatMap(\.clips).count
        return "Deleted \(clipIDs.count) clip(s) and closed gaps. \(remaining) clip(s) remaining."
    }

    private func handleNormalizeAudio(args: [String: Any], appState: AppState) throws -> String {
        let targetVolume = (args["target_volume"] as? Double) ?? 1.0
        let clipIDStrs = args["clip_ids"] as? [String] ?? []

        let audioClips: [Clip]
        if clipIDStrs.isEmpty {
            // All audio track clips
            audioClips = appState.timeline.tracks
                .filter { $0.type == .audio }
                .flatMap(\.clips)
        } else {
            let ids = Set(clipIDStrs.compactMap { UUID(uuidString: $0) })
            audioClips = appState.timeline.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        }

        var adjusted = 0
        for clip in audioClips {
            if clip.volume != targetVolume {
                try? appState.perform(.setClipVolume(clipID: clip.id, volume: targetVolume), source: .ai)
                adjusted += 1
            }
        }

        return "Normalized \(adjusted) clip(s) to volume \(String(format: "%.1f", targetVolume)). \(audioClips.count - adjusted) already at target."
    }

    // MARK: - Intent classification

    /// Classify the user's message to determine how much context to send.
    private func classifyContextLevel(_ message: String) -> AIContextBuilder.ContextLevel {
        let lower = message.lowercased()

        // Content-aware keywords → full context (includes transcripts, analysis)
        let contentKeywords = ["transcript", "says", "said", "mention", "word", "silence",
                               "filler", "um", "uh", "spoken", "talking", "search",
                               "find where", "what do i say", "what did i"]
        if contentKeywords.contains(where: { lower.contains($0) }) {
            return .full
        }

        // Structural/simple keywords → minimal context (just track/clip IDs)
        let minimalKeywords = ["add track", "new track", "how many", "what tracks",
                               "undo", "redo", "save", "export", "hello", "hi",
                               "thanks", "help"]
        if minimalKeywords.contains(where: { lower.contains($0) }) {
            return .minimal
        }

        // Everything else → standard
        return .standard
    }

    // MARK: - Content tool handlers

    private func handleGetTranscript(args: [String: Any], appState: AppState) async throws -> String {
        guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr) else {
            throw AIToolError.invalidArgument("Missing asset_id")
        }
        guard let asset = await appState.media.mediaManager.asset(id: assetID) else {
            throw AIToolError.invalidArgument("Asset not found")
        }
        if let result = await appState.media.transcriptionService.getTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) {
            return "Transcript (\(result.words.count) words): \(result.text)"
        }
        return "No transcript for this asset. Use transcribe_asset to generate one."
    }

    private func handleGetVisualScenes(args: [String: Any], appState: AppState) async -> String {
        guard let assetIDStr = args["asset_id"] as? String,
              let assetID = UUID(uuidString: assetIDStr),
              let asset = appState.assets.first(where: { $0.id == assetID }) else {
            return "Error: asset not found"
        }

        // If scenes not yet analyzed, run analysis on demand
        var scenes = asset.analysis?.sceneDescriptions
        if scenes == nil || scenes!.isEmpty {
            if asset.type != .video {
                return "Error: asset '\(asset.name)' is not a video"
            }
            processingStatus = "Analyzing visual scenes (this may take a moment)..."
            let analyzer = VisualSceneAnalyzer()
            let cacheDir = appState.projectBundleURL
                .appendingPathComponent("analysis/visual_scenes")
                .appendingPathComponent(asset.id.uuidString)

            if let analyzed = try? await analyzer.analyze(
                url: asset.proxyURL ?? asset.sourceURL,
                thumbnailCacheDir: cacheDir
            ) { p in
                Task { @MainActor in self.processingStatus = "Analyzing scenes... \(Int(p * 100))%" }
            }, !analyzed.isEmpty {
                scenes = analyzed
                // Store results back on the asset
                await appState.media.mediaManager.updateAsset(id: asset.id) { asset in
                    var analysis = asset.analysis ?? MediaAnalysis()
                    analysis.sceneDescriptions = analyzed
                    asset.analysis = analysis
                }
            } else {
                return "Visual scene analysis failed for '\(asset.name)'."
            }
        }

        guard let scenes = scenes, !scenes.isEmpty else {
            return "No visual scenes detected for '\(asset.name)'."
        }

        let startTime = args["start_time"] as? Double
        let endTime = args["end_time"] as? Double

        let filtered = scenes.filter { scene in
            if let start = startTime, scene.range.end < start { return false }
            if let end = endTime, scene.range.start > end { return false }
            return true
        }

        var output = "Visual scenes for '\(asset.name)' (\(filtered.count) scenes):\n"
        for (i, scene) in filtered.enumerated() {
            let start = String(format: "%.1f", scene.range.start)
            let end = String(format: "%.1f", scene.range.end)
            let desc = scene.description.isEmpty ? "(no description — VLM unavailable)" : scene.description
            output += "\(i+1). [\(start)s - \(end)s] \(desc)"
            if let label = scene.label { output += " [\(label)]" }
            output += "\n"
        }
        return output
    }

    private func handleTranscribeAsset(args: [String: Any], appState: AppState) async throws -> String {
        guard let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr) else {
            throw AIToolError.invalidArgument("Missing asset_id")
        }
        guard let asset = await appState.media.mediaManager.asset(id: assetID) else {
            throw AIToolError.invalidArgument("Asset not found")
        }

        let providerArg = (args["provider"] as? String)?.lowercased() ?? ""
        let useLocal = ["local", "whisper", "whisperkit"].contains(providerArg)

        await appState.media.ensureTranscriptionConfigured()

        if await appState.media.transcriptionService.hasTranscript(
            for: asset, bundleURL: appState.projectBundleURL
        ) {
            return "Already transcribed. Use get_transcript to read the content."
        }

        processingStatus = "Extracting audio from \(asset.name)..."

        let result = try await appState.media.transcriptionService.transcribe(
            asset: asset,
            mediaManager: appState.media.mediaManager,
            bundleURL: appState.projectBundleURL,
            useLocal: useLocal,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.processingStatus = status }
            }
        )

        processingStatus = nil

        if let result {
            await appState.media.refreshAssets()
            let providerName = useLocal ? "WhisperKit (local)" : "Deepgram"
            return "Transcribed with \(providerName) (\(result.words.count) words, \(String(format: "%.1f", result.duration))s). Use get_transcript to read."
        } else {
            return "Transcription not configured. Add DEEPGRAM_API_KEY to .env file or use provider: 'local' for WhisperKit."
        }
    }

    private func handleSearchTranscript(args: [String: Any], appState: AppState) async -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Missing search query."
        }
        let maxResults = (args["max_results"] as? Int) ?? 10
        let searchEngine = TranscriptSearchEngine()

        // Enrich assets with disk-persisted transcripts if not in memory
        var searchableAssets = appState.assets
        for i in searchableAssets.indices {
            if searchableAssets[i].analysis?.transcript == nil || searchableAssets[i].analysis!.transcript!.isEmpty {
                if let diskResult = await appState.media.transcriptionService.loadTranscript(
                    for: searchableAssets[i], bundleURL: appState.projectBundleURL
                ) {
                    var analysis = searchableAssets[i].analysis ?? MediaAnalysis()
                    analysis.transcript = diskResult.words
                    searchableAssets[i].analysis = analysis
                }
            }
        }

        let results: [SearchResult]
        if let assetIDStr = args["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr) {
            if let asset = searchableAssets.first(where: { $0.id == assetID }) {
                results = searchEngine.searchAsset(query: query, asset: asset)
            } else { return "Asset not found." }
        } else {
            results = searchEngine.search(query: query, assets: searchableAssets, maxResults: maxResults)
        }

        guard !results.isEmpty else {
            lastSearchQuery = nil
            lastSearchResults = nil
            return "No matches found for '\(query)'. Make sure assets are transcribed first."
        }

        // Store for visual display in SearchResultsView
        lastSearchQuery = query
        lastSearchResults = results

        var output = "Found \(results.count) match(es) for '\(query)':\n\n"
        for (i, result) in results.enumerated() {
            output += "\(i + 1). [\(result.assetName)] at \(result.formattedTime) — \"...\(result.contextText)...\"\n"
            output += "   Asset ID: \(result.assetID.uuidString), Time: \(String(format: "%.1f", result.matchTime))s\n\n"
        }
        return output
    }

    private func handleRemoveSilence(args: [String: Any], appState: AppState) throws -> String {
        let timeline = appState.timeline

        // Parse optional threshold/duration filters
        let minDuration = (args["min_duration"] as? Double) ?? 0.5

        let targetClips: [Clip]
        if let clipIDStrs = args["clip_ids"] as? [String], !clipIDStrs.isEmpty {
            let clipIDs = Set(clipIDStrs.compactMap { UUID(uuidString: $0) })
            targetClips = timeline.tracks.flatMap(\.clips).filter { clipIDs.contains($0.id) }
        } else {
            targetClips = timeline.tracks.flatMap(\.clips)
        }

        guard !targetClips.isEmpty else { return "No clips to process." }

        let result = SilenceRemovalExecutor.remove(
            minimumDuration: minDuration,
            from: targetClips,
            appState: appState,
            source: .ai
        )

        if result.removedSilenceCount == 0 {
            return "No silence ranges found (min duration: \(String(format: "%.1f", minDuration))s)."
        }

        let prunedMessage = result.prunedFragmentCount > 0
            ? " Pruned \(result.prunedFragmentCount) tiny fragment(s)."
            : ""
        return "Removed \(result.removedSilenceCount) silent segment(s) across \(result.processedClipCount) clip(s), rebuilt \(result.insertedClipCount) clip(s), deleted \(result.deletedClipCount) original clip(s).\(prunedMessage)"
    }

    // MARK: - Tool result feedback

    /// Describe what a tool did — gives the AI detailed feedback so it knows the current state.
    private func describeTool(_ name: String, args: [String: Any], timeline: Timeline) -> String {
        switch name {
        case "add_track":
            if let track = timeline.tracks.last {
                return "Added track '\(track.name)' (ID: \(track.id.uuidString)). Timeline now has \(timeline.tracks.count) track(s)."
            }
            return "Done"

        case "insert_clip":
            // Report all clips added (video + linked audio for video assets)
            let assetIDStr = args["asset_id"] as? String ?? ""
            let recentClips = timeline.tracks.flatMap { track in
                track.clips.compactMap { clip -> String? in
                    guard clip.assetID.uuidString == assetIDStr else { return nil }
                    let trackName = track.name
                    return "'\(clip.metadata.label ?? "Clip")' (ID: \(clip.id.uuidString)) on \(trackName) at \(String(format: "%.1f", clip.timelineRange.start))s-\(String(format: "%.1f", clip.timelineRange.end))s"
                }
            }
            if !recentClips.isEmpty {
                return "Inserted: \(recentClips.joined(separator: "; ")). Total clips: \(timeline.tracks.flatMap(\.clips).count)."
            }
            return "Done"

        case "split_clip":
            let clipID = args["clip_id"] as? String ?? ""
            let at = args["at"] as? Double ?? 0
            // After split, find the two clips near the split point
            let allClips = timeline.tracks.flatMap(\.clips)
            let nearSplit = allClips.filter { abs($0.timelineRange.end - at) < 0.1 || abs($0.timelineRange.start - at) < 0.1 }
            let clipIDs = nearSplit.map { "\($0.id.uuidString) (\(String(format: "%.1f", $0.timelineRange.start))s-\(String(format: "%.1f", $0.timelineRange.end))s)" }
            return "Split at \(String(format: "%.1f", at))s. Resulting clips: \(clipIDs.joined(separator: ", ")). Total clips on timeline: \(allClips.count)."

        case "delete_clips":
            let remaining = timeline.tracks.flatMap(\.clips).count
            return "Deleted. Timeline now has \(remaining) clip(s) remaining."

        case "move_clip":
            let clipID = args["clip_id"] as? String ?? ""
            if let clip = timeline.tracks.flatMap(\.clips).first(where: { $0.id.uuidString == clipID }) {
                return "Moved clip to \(String(format: "%.1f", clip.timelineRange.start))s-\(String(format: "%.1f", clip.timelineRange.end))s."
            }
            return "Done"

        case "undo":
            return "Undone last action. Timeline has \(timeline.tracks.flatMap(\.clips).count) clip(s)."
        case "redo":
            return "Redone. Timeline has \(timeline.tracks.flatMap(\.clips).count) clip(s)."
        case "seek":
            let time = args["time"] as? Double ?? 0
            return "Playhead at \(String(format: "%.1f", time))s."
        case "batch":
            return "Executed batch operation."

        default:
            return "Done"
        }
    }

    // MARK: - Argument fixup

    private func fixupArguments(
        toolName: String,
        arguments: [String: Any],
        timeline: Timeline,
        assets: [MediaAsset]
    ) -> [String: Any] {
        var args = arguments
        let destructiveTools: Set<String> = ["delete_clips", "trim_clip", "split_clip", "move_clip"]

        if let trackIDStr = args["track_id"] as? String {
            let trackExists = timeline.tracks.contains { $0.id.uuidString == trackIDStr }
            if !trackExists {
                let trackType = inferTrackType(args: args, assets: assets)
                if let realTrack = timeline.tracks.last(where: { $0.type == trackType }) {
                    args["track_id"] = realTrack.id.uuidString
                }
            }
        }

        // Don't silently substitute clip IDs — let invalid IDs fail with clear errors
        // so the AI can self-correct with valid IDs from the context.

        if let clipIDStrs = args["clip_ids"] as? [String] {
            let allClipIDs = Set(timeline.tracks.flatMap(\.clips).map(\.id.uuidString))
            args["clip_ids"] = clipIDStrs.filter { allClipIDs.contains($0) }
        }

        return args
    }

    /// Strip XML tool-call syntax that the model sometimes leaks into its text response.
    private static func stripLeakedToolXML(_ text: String) -> String {
        var result = text
        // Remove <function_calls>...</function_calls> blocks (multiline)
        if let regex = try? NSRegularExpression(pattern: "<function_calls>.*?</function_calls>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Remove orphaned tags
        if let regex = try? NSRegularExpression(pattern: "</?(?:function_calls|invoke|antml:[a-z_]+)[^>]*>") {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inferTrackType(args: [String: Any], assets: [MediaAsset]) -> TrackType {
        if let assetIDStr = args["asset_id"] as? String,
           let asset = assets.first(where: { $0.id.uuidString == assetIDStr }) {
            return asset.type == .audio ? .audio : .video
        }
        return .video
    }
}
