import SwiftUI
import AVFoundation
import EditorCore
import AIServices

@Observable
@MainActor
final class AppState {
    let context: EditingContext
    let commandHistory: CommandHistory
    let intentResolver: IntentResolver
    let timelineViewState: TimelineViewState
    let playbackEngine: PlaybackEngine
    let exportEngine: ExportEngine
    private(set) var media: MediaCoordinator
    let aiChat: AIChatController
    let projectStore: ProjectStore
    let projectIndex: ProjectIndexManager

    // Reactive access
    var timeline: Timeline { context.timelineState.timeline }
    var assets: [MediaAsset] { media.assets }
    var clipCount: Int { timeline.tracks.reduce(into: 0) { $0 += $1.clips.count } }
    var canExportCurrentTimeline: Bool { clipCount > 0 && timeline.duration > 0 }

    // Clipboard
    private(set) var clipboardClips: [(clip: Clip, trackType: TrackType)] = []

    /// Project bundle directory — changes when switching projects.
    private(set) var projectBundleURL: URL
    private(set) var mcpServer: MCPServer?

    private var playbackSyncTask: Task<Void, Never>?
    private var saveDebounceTask: Task<Void, Never>?
    private var hasShutdown = false

    /// Base directory for all projects.
    static var appSupportBaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VideoEditor")
    }

    var workspaceLayoutsBaseURL: URL {
        projectBundleURL.appendingPathComponent("WorkspaceLayouts", isDirectory: true)
    }

    init() {
        let baseURL = Self.appSupportBaseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let indexManager = ProjectIndexManager(baseURL: baseURL)
        indexManager.migrateLegacyIfNeeded()

        // If no projects exist, create "Untitled"
        if indexManager.index.projects.isEmpty {
            indexManager.addProject(name: "Untitled")
            indexManager.setActive("Untitled")
        }
        // If active project doesn't exist in index, fall back to first
        if !indexManager.projectExists(indexManager.activeProjectName),
           let first = indexManager.index.projects.first {
            indexManager.setActive(first.name)
        }

        let bundleURL = indexManager.activeBundleURL
        Self.ensureProjectDirectories(at: bundleURL)

        self.projectIndex = indexManager
        self.projectBundleURL = bundleURL
        self.projectStore = ProjectStore()
        self.context = EditingContext()
        self.commandHistory = CommandHistory()
        self.intentResolver = IntentResolver()
        self.timelineViewState = TimelineViewState()
        self.playbackEngine = PlaybackEngine()
        self.exportEngine = ExportEngine()
        self.media = MediaCoordinator(bundleURL: bundleURL)
        self.aiChat = AIChatController()

        // Load API keys from .env file or environment
        let keys = Self.loadEnvKeys()
        if let claudeKey = keys["ANTHROPIC_API_KEY"] {
            aiChat.configure(provider: ClaudeProvider(apiKey: claudeKey))
        }

        // Load editing skills from .claude/skills/
        // Search: repo root (dev), bundle resources (release), working directory
        let skillSearchPaths: [URL] = [
            // Walk up from the built binary to find the repo root
            Bundle.main.bundleURL
                .deletingLastPathComponent() // Products/Debug
                .deletingLastPathComponent() // Products
                .deletingLastPathComponent() // Build
                .deletingLastPathComponent() // DerivedData/VideoEditor-xxx
                .deletingLastPathComponent() // DerivedData
                .deletingLastPathComponent() // Developer/Xcode
                .deletingLastPathComponent() // Developer
                .deletingLastPathComponent() // Library
                .appendingPathComponent("Projects/video-editor/.claude/skills"),
            // Direct repo path (development)
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/video-editor/.claude/skills"),
            // Current working directory
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills"),
            // Bundle resources (for distribution)
            Bundle.main.resourceURL?.appendingPathComponent("skills"),
        ].compactMap { $0 }

        for dir in skillSearchPaths {
            if FileManager.default.fileExists(atPath: dir.path) {
                aiChat.loadSkills(from: dir)
                print("[AppState] Loaded skills from: \(dir.path)")
                break
            }
        }
        if let dgKey = keys["DEEPGRAM_API_KEY"] {
            media.setTranscriptionProvider(DeepgramProvider(apiKey: dgKey))
        }
        // Always configure WhisperKit as local fallback (offline, free)
        media.setLocalTranscriptionProvider(WhisperKitProvider())

        // Rebuild composition when proxy/analysis completes in background
        media.onAnalysisComplete = { [weak self] in
            self?.rebuildComposition()
        }
        // Save when assets change (import, proxy, analysis, transcription)
        media.onAssetsChanged = { [weak self] in
            self?.scheduleSave()
        }

        // Load existing project if timeline.json exists
        loadProject()

        let dbPath = bundleURL.appendingPathComponent("metadata.sqlite").path
        Task {
            do {
                try await context.actionLog.open(at: dbPath)
            } catch {
                print("[AppState] ActionLog failed to open: \(error.localizedDescription). Using in-memory fallback.")
            }
        }

        startPlayheadSync()

        // Start MCP server for external tool access (Claude Code, etc.)
        let server = MCPServer(appState: self)
        self.mcpServer = server
        server.start()
    }

    // MARK: - Overlay Monitor Interaction

    /// The currently selected clip if it is a PiP overlay on a non-primary video track.
    var selectedVideoOverlayClip: Clip? {
        guard timelineViewState.selectedClipIDs.count == 1,
              let clipID = timelineViewState.selectedClipIDs.first else { return nil }
        for (index, track) in timeline.tracks.enumerated() {
            guard track.type == .video, index > 0 else { continue }
            if let clip = track.clips.first(where: { $0.id == clipID }),
               clip.overlayPresentation.mode == .pip {
                return clip
            }
        }
        return nil
    }

    private func clipByID(_ id: UUID) -> Clip? {
        for track in timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return clip
            }
        }
        return nil
    }

    // MARK: - Clipboard

    func copySelectedClips() {
        let selectedIDs = timelineViewState.selectedClipIDs
        guard !selectedIDs.isEmpty else { return }

        clipboardClips = []
        for track in timeline.tracks {
            for clip in track.clips where selectedIDs.contains(clip.id) {
                clipboardClips.append((clip: clip, trackType: track.type))
            }
        }
    }

    func pasteClips() {
        guard !clipboardClips.isEmpty else { return }
        let playhead = timelineViewState.playheadPosition

        // Find the earliest clip start to compute relative offsets
        let earliestStart = clipboardClips.map(\.clip.timelineRange.start).min() ?? 0
        var linkGroupMap: [UUID: UUID] = [:]

        for (original, trackType) in clipboardClips {
            let trackID = resolveTrackID(for: trackType, preferredTrackID: nil)
            let offset = original.timelineRange.start - earliestStart
            let pasteStart = playhead + offset
            let pastedLinkGroupID = original.linkGroupID.map { originalID in
                linkGroupMap[originalID] ?? {
                    let newID = UUID()
                    linkGroupMap[originalID] = newID
                    return newID
                }()
            }

            let newClip = Clip(
                assetID: original.assetID,
                timelineRange: TimeRange(start: pasteStart, duration: original.timelineRange.duration),
                sourceRange: original.sourceRange,
                transform: original.transform,
                cropRect: original.cropRect,
                opacity: original.opacity,
                volume: original.volume,
                effects: original.effects,
                keyframes: original.keyframes,
                metadata: ClipMetadata(label: (original.metadata.label ?? "Clip") + " (paste)"),
                speed: original.speed,
                transitionIn: original.transitionIn,
                linkGroupID: pastedLinkGroupID,
                blendMode: original.blendMode
            )
            try? perform(.insertClip(clip: newClip, trackID: trackID))
        }
    }

    func duplicateSelection(source: ActionSource = .user) {
        let selectedClips = timeline.tracks
            .enumerated()
            .flatMap { trackIndex, track in
                track.clips.compactMap { clip -> (trackIndex: Int, trackID: UUID, clip: Clip)? in
                    guard timelineViewState.selectedClipIDs.contains(clip.id) else { return nil }
                    return (trackIndex, track.id, clip)
                }
            }
            .sorted { lhs, rhs in
                if lhs.trackIndex != rhs.trackIndex {
                    return lhs.trackIndex < rhs.trackIndex
                }
                if lhs.clip.timelineRange.start != rhs.clip.timelineRange.start {
                    return lhs.clip.timelineRange.start < rhs.clip.timelineRange.start
                }
                return lhs.clip.timelineRange.end < rhs.clip.timelineRange.end
            }

        guard !selectedClips.isEmpty else { return }

        if selectedClips.count == 1, let onlyClip = selectedClips.first {
            try? perform(.duplicateClip(clipID: onlyClip.clip.id), source: source)
            return
        }

        var duplicatedIDs = Set<UUID>()
        var duplicatedClips: [UUID] = []
        var linkGroupMap: [UUID: UUID] = [:]
        let intents: [EditorIntent] = selectedClips.compactMap { entry in
            guard duplicatedIDs.insert(entry.clip.id).inserted else { return nil }

            let duplicateLinkGroupID = entry.clip.linkGroupID.map { originalID in
                linkGroupMap[originalID] ?? {
                    let newID = UUID()
                    linkGroupMap[originalID] = newID
                    return newID
                }()
            }

            let duplicate = Clip(
                assetID: entry.clip.assetID,
                timelineRange: TimeRange(
                    start: entry.clip.timelineRange.end,
                    duration: entry.clip.timelineRange.duration
                ),
                sourceRange: entry.clip.sourceRange,
                transform: entry.clip.transform,
                cropRect: entry.clip.cropRect,
                opacity: entry.clip.opacity,
                volume: entry.clip.volume,
                effects: entry.clip.effects,
                keyframes: entry.clip.keyframes,
                metadata: ClipMetadata(
                    label: (entry.clip.metadata.label ?? "Clip") + " (copy)",
                    tags: entry.clip.metadata.tags,
                    transcriptSegment: entry.clip.metadata.transcriptSegment,
                    sceneType: entry.clip.metadata.sceneType
                ),
                speed: entry.clip.speed,
                transitionIn: entry.clip.transitionIn,
                linkGroupID: duplicateLinkGroupID,
                blendMode: entry.clip.blendMode
            )
            duplicatedClips.append(duplicate.id)
            return .insertClip(clip: duplicate, trackID: entry.trackID)
        }

        guard !intents.isEmpty else { return }
        try? perform(intents.count == 1 ? intents[0] : .batch(intents), source: source)

        if let firstTrackID = intents.compactMap({ intentTrackID(for: $0) }).first {
            timelineViewState.selectedClipIDs = Set(duplicatedClips)
            timelineViewState.selectedTrackID = firstTrackID
        }
    }

    func toggleClipSelection(_ clipID: UUID, extend: Bool) {
        guard let selectedTrackID = trackID(for: clipID) else { return }

        if extend {
            let clipIDs = linkedSelectionIDs(for: clipID)

            // Range selection: if there's an anchor, select all clips between anchor and target
            if let anchorID = timelineViewState.lastSelectedClipID,
               let anchorTrackID = trackID(for: anchorID),
               anchorTrackID == selectedTrackID,
               let track = timeline.tracks.first(where: { $0.id == selectedTrackID }) {
                timelineViewState.rangeSelect(to: clipID, in: track.clips)
            } else {
                let isEntireGroupSelected = clipIDs.allSatisfy { timelineViewState.selectedClipIDs.contains($0) }
                if isEntireGroupSelected {
                    clipIDs.forEach { timelineViewState.selectedClipIDs.remove($0) }
                } else {
                    clipIDs.forEach { timelineViewState.selectedClipIDs.insert($0) }
                }
            }

            let selectedTrackIDs = Set(timelineViewState.selectedClipIDs.compactMap { self.trackID(for: $0) })
            timelineViewState.selectedTrackID = selectedTrackIDs.count == 1 ? selectedTrackIDs.first : selectedTrackID
        } else {
            timelineViewState.selectClip(clipID, in: selectedTrackID)
        }
        timelineViewState.lastSelectedClipID = clipID
    }

    func moveSelection(primaryClipID: UUID, newStart: TimeInterval, targetTrackID: UUID) {
        guard timelineViewState.selectedClipIDs.contains(primaryClipID),
              timelineViewState.selectedClipIDs.count > 1,
              let primaryClip = clip(for: primaryClipID),
              let primaryTrack = track(for: primaryClipID) else {
            try? perform(.moveClip(clipID: primaryClipID, newStart: newStart, trackID: targetTrackID))
            return
        }

        let selectedClips = timeline.tracks
            .flatMap(\.clips)
            .filter { timelineViewState.selectedClipIDs.contains($0.id) }
        guard !selectedClips.isEmpty else { return }

        let delta = newStart - primaryClip.timelineRange.start
        let orderedClips = selectedClips.sorted { lhs, rhs in
            if delta >= 0 {
                if lhs.timelineRange.start != rhs.timelineRange.start {
                    return lhs.timelineRange.start > rhs.timelineRange.start
                }
                return lhs.timelineRange.end > rhs.timelineRange.end
            }
            if lhs.timelineRange.start != rhs.timelineRange.start {
                return lhs.timelineRange.start < rhs.timelineRange.start
            }
            return lhs.timelineRange.end < rhs.timelineRange.end
        }

        let intents: [EditorIntent] = orderedClips.compactMap { clip in
            guard let originalTrackID = trackID(for: clip.id) else { return nil }
            let clipTrackType = track(for: clip.id)?.type
            let destinationTrackID: UUID

            if clip.id == primaryClipID {
                destinationTrackID = targetTrackID
            } else if clip.linkGroupID != nil,
                      clip.linkGroupID == primaryClip.linkGroupID,
                      let clipTrackType,
                      clipTrackType != primaryTrack.type {
                destinationTrackID = pairedTrackID(
                    for: targetTrackID,
                    sourceType: primaryTrack.type,
                    targetType: clipTrackType
                )
            } else {
                destinationTrackID = originalTrackID
            }

            return .moveClip(
                clipID: clip.id,
                newStart: max(0, clip.timelineRange.start + delta),
                trackID: destinationTrackID
            )
        }

        guard !intents.isEmpty else { return }
        try? perform(intents.count == 1 ? intents[0] : .batch(intents))
    }

    // MARK: - Add to timeline (creates linked audio track only when media actually has audio)

    func addAssetToTimeline(
        _ asset: MediaAsset,
        source: ActionSource = .user,
        preferredTrackID: UUID? = nil,
        startTime: TimeInterval? = nil,
        sourceStart: TimeInterval? = nil,
        sourceEnd: TimeInterval? = nil
    ) async {
        // If source range specified, delegate to insertAssetSegment
        if let srcStart = sourceStart, let srcEnd = sourceEnd, srcEnd > srcStart {
            let sourceRange = TimeRange(start: srcStart, end: srcEnd)
            await insertAssetSegment(
                asset,
                sourceRange: sourceRange,
                source: source,
                preferredTrackID: preferredTrackID,
                startTime: startTime
            )
            return
        }

        let fullDuration = defaultTimelineDuration(for: asset)
        let effectiveSrcStart = sourceStart ?? 0
        let effectiveSrcEnd = sourceEnd ?? fullDuration
        let clipDuration = min(effectiveSrcEnd - effectiveSrcStart, fullDuration)
        let srcRange = TimeRange(start: effectiveSrcStart, duration: clipDuration)

        let requestedTrackID = preferredTrackID ?? timelineViewState.selectedTrackID
        let requestedTrack = requestedTrackID.flatMap { id in
            timeline.tracks.first(where: { $0.id == id })
        }

        switch asset.type {
        case .video:
            let hasAudio = asset.hasAudioTrack
            let videoTrackID: UUID
            let audioTrackID: UUID?

            if let requestedTrack {
                switch requestedTrack.type {
                case .video:
                    videoTrackID = resolveTrackID(for: .video, preferredTrackID: requestedTrack.id)
                    audioTrackID = hasAudio ? pairedTrackID(for: requestedTrack.id, sourceType: .video, targetType: .audio) : nil
                case .audio:
                    videoTrackID = pairedTrackID(for: requestedTrack.id, sourceType: .audio, targetType: .video)
                    audioTrackID = hasAudio ? requestedTrack.id : nil
                default:
                    videoTrackID = resolveTrackID(for: .video, preferredTrackID: nil)
                    audioTrackID = hasAudio ? pairedTrackID(for: videoTrackID, sourceType: .video, targetType: .audio) : nil
                }
            } else {
                videoTrackID = resolveTrackID(for: .video, preferredTrackID: timelineViewState.selectedTrackID)
                audioTrackID = hasAudio ? pairedTrackID(for: videoTrackID, sourceType: .video, targetType: .audio) : nil
            }

            let clipStart = resolvedInsertionStart(
                explicitStart: startTime,
                primaryTrackID: videoTrackID,
                companionTrackID: audioTrackID
            )
            let linkID = UUID() // Shared link group for video+audio pair
            let videoClip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: clipStart, duration: clipDuration),
                sourceRange: srcRange,
                metadata: ClipMetadata(label: asset.name),
                linkGroupID: hasAudio ? linkID : nil
            )
            try? perform(.insertClip(clip: videoClip, trackID: videoTrackID), source: source)
            timelineViewState.selectClip(videoClip.id, in: videoTrackID)

            if let audioTrackID {
                let audioClip = Clip(
                    assetID: asset.id,
                    timelineRange: TimeRange(start: clipStart, duration: clipDuration),
                    sourceRange: srcRange,
                    metadata: ClipMetadata(label: asset.name),
                    linkGroupID: linkID
                )
                try? perform(.insertClip(clip: audioClip, trackID: audioTrackID), source: source)
            }

        case .audio:
            let trackID: UUID
            if let requestedTrack {
                switch requestedTrack.type {
                case .audio:
                    trackID = requestedTrack.id
                case .video:
                    trackID = pairedTrackID(for: requestedTrack.id, sourceType: .video, targetType: .audio)
                default:
                    trackID = resolveTrackID(for: .audio, preferredTrackID: nil)
                }
            } else {
                trackID = resolveTrackID(for: .audio, preferredTrackID: timelineViewState.selectedTrackID)
            }

            let clipStart = startTime ?? trackEnd(for: trackID)
            let clip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: clipStart, duration: clipDuration),
                sourceRange: srcRange,
                metadata: ClipMetadata(label: asset.name)
            )
            try? perform(.insertClip(clip: clip, trackID: trackID), source: source)
            timelineViewState.selectClip(clip.id, in: trackID)

        case .image:
            let trackID = resolveTrackID(for: .video, preferredTrackID: requestedTrack?.type == .video ? requestedTrack?.id : nil)
            let clipStart = startTime ?? trackEnd(for: trackID)
            let clip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: clipStart, duration: clipDuration),
                sourceRange: srcRange,
                metadata: ClipMetadata(label: asset.name)
            )
            try? perform(.insertClip(clip: clip, trackID: trackID), source: source)
            timelineViewState.selectClip(clip.id, in: trackID)
        }
    }

    func insertAssetSegment(
        _ asset: MediaAsset,
        sourceRange requestedSourceRange: TimeRange,
        source: ActionSource = .user,
        preferredTrackID: UUID? = nil,
        startTime: TimeInterval? = nil,
        label: String? = nil
    ) async {
        let sourceRange = clampedSourceRange(for: asset, proposed: requestedSourceRange)
        let duration = max(sourceRange.duration, 1)
        let requestedTrackID = preferredTrackID ?? timelineViewState.selectedTrackID
        let requestedTrack = requestedTrackID.flatMap { id in
            timeline.tracks.first(where: { $0.id == id })
        }

        switch asset.type {
        case .video:
            let hasAudio = asset.hasAudioTrack
            let videoTrackID: UUID
            let audioTrackID: UUID?

            if let requestedTrack {
                switch requestedTrack.type {
                case .video:
                    videoTrackID = resolveTrackID(for: .video, preferredTrackID: requestedTrack.id)
                    audioTrackID = hasAudio ? pairedTrackID(for: requestedTrack.id, sourceType: .video, targetType: .audio) : nil
                case .audio:
                    videoTrackID = pairedTrackID(for: requestedTrack.id, sourceType: .audio, targetType: .video)
                    audioTrackID = hasAudio ? requestedTrack.id : nil
                default:
                    videoTrackID = resolveTrackID(for: .video, preferredTrackID: nil)
                    audioTrackID = hasAudio ? pairedTrackID(for: videoTrackID, sourceType: .video, targetType: .audio) : nil
                }
            } else {
                videoTrackID = resolveTrackID(for: .video, preferredTrackID: timelineViewState.selectedTrackID)
                audioTrackID = hasAudio ? pairedTrackID(for: videoTrackID, sourceType: .video, targetType: .audio) : nil
            }

            let clipStart = resolvedInsertionStart(
                explicitStart: startTime,
                primaryTrackID: videoTrackID,
                companionTrackID: audioTrackID
            )
            let linkID = UUID()
            let videoClip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: clipStart, duration: duration),
                sourceRange: sourceRange,
                metadata: ClipMetadata(label: label ?? asset.name),
                linkGroupID: hasAudio ? linkID : nil
            )
            try? perform(.insertClip(clip: videoClip, trackID: videoTrackID), source: source)
            timelineViewState.selectClip(videoClip.id, in: videoTrackID)

            if let audioTrackID {
                let audioClip = Clip(
                    assetID: asset.id,
                    timelineRange: TimeRange(start: clipStart, duration: duration),
                    sourceRange: sourceRange,
                    metadata: ClipMetadata(label: label ?? asset.name),
                    linkGroupID: linkID
                )
                try? perform(.insertClip(clip: audioClip, trackID: audioTrackID), source: source)
            }

        case .audio:
            let trackID: UUID
            if let requestedTrack {
                switch requestedTrack.type {
                case .audio:
                    trackID = requestedTrack.id
                case .video:
                    trackID = pairedTrackID(for: requestedTrack.id, sourceType: .video, targetType: .audio)
                default:
                    trackID = resolveTrackID(for: .audio, preferredTrackID: nil)
                }
            } else {
                trackID = resolveTrackID(for: .audio, preferredTrackID: timelineViewState.selectedTrackID)
            }

            let clipStart = startTime ?? trackEnd(for: trackID)
            let clip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: clipStart, duration: duration),
                sourceRange: sourceRange,
                metadata: ClipMetadata(label: label ?? asset.name)
            )
            try? perform(.insertClip(clip: clip, trackID: trackID), source: source)
            timelineViewState.selectClip(clip.id, in: trackID)

        case .image:
            let trackID = resolveTrackID(for: .video, preferredTrackID: requestedTrack?.type == .video ? requestedTrack?.id : nil)
            let clipStart = startTime ?? trackEnd(for: trackID)
            let clip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: clipStart, duration: duration),
                sourceRange: sourceRange,
                metadata: ClipMetadata(label: label ?? asset.name)
            )
            try? perform(.insertClip(clip: clip, trackID: trackID), source: source)
            timelineViewState.selectClip(clip.id, in: trackID)
        }
    }

    func insertAssetSegmentAtPlayhead(
        _ asset: MediaAsset,
        sourceRange requestedSourceRange: TimeRange,
        source: ActionSource = .user,
        preferredTrackID: UUID? = nil,
        label: String? = nil
    ) {
        let sourceRange = clampedSourceRange(for: asset, proposed: requestedSourceRange)
        let insertionStart = max(timelineViewState.playheadPosition, 0)
        let plan = buildPlacementInsertionPlan(
            for: asset,
            sourceRange: sourceRange,
            preferredTrackID: preferredTrackID,
            startTime: insertionStart,
            label: label
        )
        let prepIntents = plan.affectedTrackIDs.flatMap {
            buildInsertGapIntents(trackID: $0, at: insertionStart, duration: sourceRange.duration)
        }
        let intents = prepIntents + plan.intents
        guard !intents.isEmpty else { return }

        try? perform(intents.count == 1 ? intents[0] : .batch(intents), source: source)
        timelineViewState.selectClip(plan.primaryClipID, in: plan.primaryTrackID)
    }

    func overwriteAssetSegmentAtPlayhead(
        _ asset: MediaAsset,
        sourceRange requestedSourceRange: TimeRange,
        source: ActionSource = .user,
        preferredTrackID: UUID? = nil,
        label: String? = nil
    ) {
        let sourceRange = clampedSourceRange(for: asset, proposed: requestedSourceRange)
        let insertionStart = max(timelineViewState.playheadPosition, 0)
        let overwriteRange = TimeRange(start: insertionStart, duration: sourceRange.duration)
        let plan = buildPlacementInsertionPlan(
            for: asset,
            sourceRange: sourceRange,
            preferredTrackID: preferredTrackID,
            startTime: insertionStart,
            label: label
        )
        let prepIntents = plan.affectedTrackIDs.flatMap {
            buildOverwriteGapIntents(trackID: $0, replacing: overwriteRange)
        }
        let intents = prepIntents + plan.intents
        guard !intents.isEmpty else { return }

        try? perform(intents.count == 1 ? intents[0] : .batch(intents), source: source)
        timelineViewState.selectClip(plan.primaryClipID, in: plan.primaryTrackID)
    }

    func addTrack(of type: TrackType, positionedAfter afterTrackID: UUID? = nil) {
        let insertionIndex = afterTrackID.flatMap { id in
            timeline.tracks.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        }
        _ = createTrack(of: type, insertionIndex: insertionIndex)
    }

    func updateTrack(id: UUID, _ transform: (inout Track) -> Void) {
        var timeline = context.timelineState.timeline
        guard let index = timeline.tracks.firstIndex(where: { $0.id == id }) else { return }
        transform(&timeline.tracks[index])
        context.timelineState.timeline = timeline
        rebuildComposition()
        scheduleSave()
    }

    func renameTrack(id: UUID, to name: String) {
        try? perform(.renameTrack(trackID: id, name: name))
    }

    func toggleTrackSolo(_ trackID: UUID) {
        guard let track = timeline.tracks.first(where: { $0.id == trackID }) else { return }
        try? perform(.soloTrack(trackID: trackID, soloed: !track.isSoloed))
    }

    func toggleTrackCollapse(_ trackID: UUID) {
        timelineViewState.trackLayoutState.toggleCollapse(trackID)
    }

    func cycleTrackHeight(_ trackID: UUID) {
        timelineViewState.trackLayoutState.cycleHeight(for: trackID)
    }

    func updateClip(id: UUID, _ transform: (inout Clip) -> Void) {
        var timeline = context.timelineState.timeline

        for trackIndex in timeline.tracks.indices {
            guard let clipIndex = timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) else { continue }
            transform(&timeline.tracks[trackIndex].clips[clipIndex])
            context.timelineState.timeline = timeline
            rebuildComposition()
            scheduleSave()
            return
        }
    }

    @discardableResult
    private func createTrack(
        of type: TrackType,
        insertionIndex: Int? = nil,
        name: String? = nil,
        source: ActionSource = .user
    ) -> UUID {
        let track = Track(name: name ?? nextTrackName(for: type), type: type)
        var command = AddTrackCommand(track: track, insertionIndex: insertionIndex)
        try? commandHistory.execute(&command, context: context, source: source)
        rebuildComposition()
        scheduleSave()
        return track.id
    }

    private func resolveTrackID(for type: TrackType, preferredTrackID: UUID?) -> UUID {
        if let preferredTrackID,
           let preferredTrack = timeline.tracks.first(where: { $0.id == preferredTrackID }),
           preferredTrack.type == type,
           !preferredTrack.isLocked {
            return preferredTrackID
        }

        if let existing = timeline.tracks.last(where: { $0.type == type && !$0.isLocked }) {
            return existing.id
        }

        return createTrack(of: type)
    }

    private func pairedTrackID(for sourceTrackID: UUID, sourceType: TrackType, targetType: TrackType) -> UUID {
        guard let sourceTrackIndex = timeline.tracks.firstIndex(where: { $0.id == sourceTrackID }) else {
            return resolveTrackID(for: targetType, preferredTrackID: nil)
        }

        let preferredOffsets: [Int]
        switch (sourceType, targetType) {
        case (.video, .audio):
            preferredOffsets = [1, -1]
        case (.audio, .video):
            preferredOffsets = [-1, 1]
        default:
            preferredOffsets = [1, -1]
        }

        for offset in preferredOffsets {
            let candidateIndex = sourceTrackIndex + offset
            guard timeline.tracks.indices.contains(candidateIndex) else { continue }
            let candidateTrack = timeline.tracks[candidateIndex]
            if candidateTrack.type == targetType, !candidateTrack.isLocked {
                return candidateTrack.id
            }
        }

        let sourceOrdinal = timeline.tracks
            .filter { $0.type == sourceType }
            .firstIndex(where: { $0.id == sourceTrackID }) ?? 0
        let targetTracks = timeline.tracks.filter { $0.type == targetType && !$0.isLocked }
        if targetTracks.indices.contains(sourceOrdinal) {
            return targetTracks[sourceOrdinal].id
        }

        let insertionIndex = targetType == .audio ? sourceTrackIndex + 1 : sourceTrackIndex
        return createTrack(of: targetType, insertionIndex: insertionIndex)
    }

    private func nextTrackName(for type: TrackType) -> String {
        let count = timeline.tracks.filter { $0.type == type }.count + 1
        let baseName: String = switch type {
        case .video: "Video"
        case .audio: "Audio"
        case .text: "Text"
        case .effect: "Effect"
        }
        return count == 1 ? baseName : "\(baseName) \(count)"
    }

    private func trackEnd(for trackID: UUID) -> TimeInterval {
        timeline.tracks.first(where: { $0.id == trackID })?.clips.map(\.timelineRange.end).max() ?? 0
    }

    private func resolvedInsertionStart(
        explicitStart: TimeInterval?,
        primaryTrackID: UUID,
        companionTrackID: UUID?
    ) -> TimeInterval {
        TimelineInsertionStartResolver.resolve(
            explicitStart: explicitStart,
            primaryTrackEnd: trackEnd(for: primaryTrackID),
            companionTrackEnd: companionTrackID.map(trackEnd(for:))
        )
    }

    private func defaultTimelineDuration(for asset: MediaAsset) -> TimeInterval {
        switch asset.type {
        case .image:
            return max(asset.duration, EditorTimelineDefaults.stillImageDuration)
        case .audio, .video:
            return max(asset.duration, 1)
        }
    }

    private func clampedSourceRange(for asset: MediaAsset, proposed: TimeRange) -> TimeRange {
        guard asset.duration > 0 else {
            return TimeRange(start: max(proposed.start, 0), duration: max(proposed.duration, 1))
        }

        let maxStart = max(asset.duration - 0.1, 0)
        let start = min(max(proposed.start, 0), maxStart)
        let remaining = max(asset.duration - start, 0.1)
        let duration = min(max(proposed.duration, 0.1), remaining)
        return TimeRange(start: start, duration: duration)
    }

    private struct PlacementInsertionPlan {
        let primaryTrackID: UUID
        let primaryClipID: UUID
        let affectedTrackIDs: [UUID]
        let intents: [EditorIntent]
    }

    private func buildPlacementInsertionPlan(
        for asset: MediaAsset,
        sourceRange: TimeRange,
        preferredTrackID: UUID?,
        startTime: TimeInterval,
        label: String?
    ) -> PlacementInsertionPlan {
        let requestedTrackID = preferredTrackID ?? timelineViewState.selectedTrackID
        let requestedTrack = requestedTrackID.flatMap { id in
            timeline.tracks.first(where: { $0.id == id })
        }

        switch asset.type {
        case .video:
            let hasAudio = asset.hasAudioTrack
            let videoTrackID: UUID
            let audioTrackID: UUID?

            if let requestedTrack {
                switch requestedTrack.type {
                case .video:
                    videoTrackID = resolveTrackID(for: .video, preferredTrackID: requestedTrack.id)
                    audioTrackID = hasAudio ? pairedTrackID(for: requestedTrack.id, sourceType: .video, targetType: .audio) : nil
                case .audio:
                    videoTrackID = pairedTrackID(for: requestedTrack.id, sourceType: .audio, targetType: .video)
                    audioTrackID = hasAudio ? requestedTrack.id : nil
                default:
                    videoTrackID = resolveTrackID(for: .video, preferredTrackID: nil)
                    audioTrackID = hasAudio ? pairedTrackID(for: videoTrackID, sourceType: .video, targetType: .audio) : nil
                }
            } else {
                videoTrackID = resolveTrackID(for: .video, preferredTrackID: timelineViewState.selectedTrackID)
                audioTrackID = hasAudio ? pairedTrackID(for: videoTrackID, sourceType: .video, targetType: .audio) : nil
            }

            let linkID = UUID()
            let videoClip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: startTime, duration: sourceRange.duration),
                sourceRange: sourceRange,
                metadata: ClipMetadata(label: label ?? asset.name),
                linkGroupID: hasAudio ? linkID : nil
            )

            var intents: [EditorIntent] = [
                .insertClip(clip: videoClip, trackID: videoTrackID)
            ]
            var affectedTrackIDs = [videoTrackID]

            if let audioTrackID {
                let audioClip = Clip(
                    assetID: asset.id,
                    timelineRange: TimeRange(start: startTime, duration: sourceRange.duration),
                    sourceRange: sourceRange,
                    metadata: ClipMetadata(label: label ?? asset.name),
                    linkGroupID: linkID
                )
                intents.append(.insertClip(clip: audioClip, trackID: audioTrackID))
                affectedTrackIDs.append(audioTrackID)
            }

            return PlacementInsertionPlan(
                primaryTrackID: videoTrackID,
                primaryClipID: videoClip.id,
                affectedTrackIDs: affectedTrackIDs,
                intents: intents
            )

        case .audio:
            let trackID: UUID
            if let requestedTrack {
                switch requestedTrack.type {
                case .audio:
                    trackID = requestedTrack.id
                case .video:
                    trackID = pairedTrackID(for: requestedTrack.id, sourceType: .video, targetType: .audio)
                default:
                    trackID = resolveTrackID(for: .audio, preferredTrackID: nil)
                }
            } else {
                trackID = resolveTrackID(for: .audio, preferredTrackID: timelineViewState.selectedTrackID)
            }

            let clip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: startTime, duration: sourceRange.duration),
                sourceRange: sourceRange,
                metadata: ClipMetadata(label: label ?? asset.name)
            )

            return PlacementInsertionPlan(
                primaryTrackID: trackID,
                primaryClipID: clip.id,
                affectedTrackIDs: [trackID],
                intents: [.insertClip(clip: clip, trackID: trackID)]
            )

        case .image:
            let trackID = resolveTrackID(
                for: .video,
                preferredTrackID: requestedTrack?.type == .video ? requestedTrack?.id : nil
            )
            let clip = Clip(
                assetID: asset.id,
                timelineRange: TimeRange(start: startTime, duration: sourceRange.duration),
                sourceRange: sourceRange,
                metadata: ClipMetadata(label: label ?? asset.name)
            )

            return PlacementInsertionPlan(
                primaryTrackID: trackID,
                primaryClipID: clip.id,
                affectedTrackIDs: [trackID],
                intents: [.insertClip(clip: clip, trackID: trackID)]
            )
        }
    }

    private func buildInsertGapIntents(trackID: UUID, at insertionStart: TimeInterval, duration: TimeInterval) -> [EditorIntent] {
        guard let track = timeline.tracks.first(where: { $0.id == trackID }) else { return [] }
        let sortedClips = track.clips.sorted { lhs, rhs in
            if lhs.timelineRange.start != rhs.timelineRange.start {
                return lhs.timelineRange.start < rhs.timelineRange.start
            }
            return lhs.timelineRange.end < rhs.timelineRange.end
        }

        var trimIntents: [EditorIntent] = []
        var moveIntents: [EditorIntent] = []
        var fragmentIntents: [EditorIntent] = []

        if let spanningClip = sortedClips.first(where: {
            $0.timelineRange.start < insertionStart && $0.timelineRange.end > insertionStart
        }) {
            let leftDuration = insertionStart - spanningClip.timelineRange.start
            let rightDuration = spanningClip.timelineRange.end - insertionStart
            let rightSourceStart = spanningClip.sourceRange.start + leftDuration

            trimIntents.append(
                .trimClip(
                    clipID: spanningClip.id,
                    newSourceRange: TimeRange(
                        start: spanningClip.sourceRange.start,
                        duration: leftDuration
                    )
                )
            )

            fragmentIntents.append(
                .insertClip(
                    clip: makeFragmentClip(
                        from: spanningClip,
                        timelineStart: insertionStart + duration,
                        sourceStart: rightSourceStart,
                        duration: rightDuration
                    ),
                    trackID: trackID
                )
            )
        }

        let downstreamClips = sortedClips
            .filter { $0.timelineRange.start >= insertionStart }
            .sorted { lhs, rhs in
                if lhs.timelineRange.start != rhs.timelineRange.start {
                    return lhs.timelineRange.start > rhs.timelineRange.start
                }
                return lhs.timelineRange.end > rhs.timelineRange.end
            }

        for clip in downstreamClips {
            moveIntents.append(
                .moveClip(
                    clipID: clip.id,
                    newStart: clip.timelineRange.start + duration,
                    trackID: trackID
                )
            )
        }

        return trimIntents + moveIntents + fragmentIntents
    }

    private func buildOverwriteGapIntents(trackID: UUID, replacing overwriteRange: TimeRange) -> [EditorIntent] {
        guard let track = timeline.tracks.first(where: { $0.id == trackID }) else { return [] }

        var trimIntents: [EditorIntent] = []
        var deleteIDs: [UUID] = []
        var fragmentIntents: [EditorIntent] = []

        for clip in track.clips where clip.timelineRange.overlaps(overwriteRange) {
            let clipStart = clip.timelineRange.start
            let clipEnd = clip.timelineRange.end
            let overwriteStart = overwriteRange.start
            let overwriteEnd = overwriteRange.end

            if clipStart < overwriteStart && clipEnd > overwriteEnd {
                let leftDuration = overwriteStart - clipStart
                let rightDuration = clipEnd - overwriteEnd
                let rightSourceStart = clip.sourceRange.start + (overwriteEnd - clipStart)

                trimIntents.append(
                    .trimClip(
                        clipID: clip.id,
                        newSourceRange: TimeRange(
                            start: clip.sourceRange.start,
                            duration: leftDuration
                        )
                    )
                )

                fragmentIntents.append(
                    .insertClip(
                        clip: makeFragmentClip(
                            from: clip,
                            timelineStart: overwriteEnd,
                            sourceStart: rightSourceStart,
                            duration: rightDuration
                        ),
                        trackID: trackID
                    )
                )
            } else if clipStart < overwriteStart && clipEnd > overwriteStart {
                let keptDuration = overwriteStart - clipStart
                trimIntents.append(
                    .trimClip(
                        clipID: clip.id,
                        newSourceRange: TimeRange(
                            start: clip.sourceRange.start,
                            duration: keptDuration
                        )
                    )
                )
            } else if clipStart < overwriteEnd && clipEnd > overwriteEnd {
                let newSourceStart = clip.sourceRange.start + (overwriteEnd - clipStart)
                trimIntents.append(
                    .trimClip(
                        clipID: clip.id,
                        newSourceRange: TimeRange(start: newSourceStart, end: clip.sourceRange.end)
                    )
                )
            } else {
                deleteIDs.append(clip.id)
            }
        }

        var intents = trimIntents
        if !deleteIDs.isEmpty {
            intents.append(.deleteClips(clipIDs: deleteIDs))
        }
        intents.append(contentsOf: fragmentIntents)
        return intents
    }

    private func makeFragmentClip(
        from clip: Clip,
        timelineStart: TimeInterval,
        sourceStart: TimeInterval,
        duration: TimeInterval
    ) -> Clip {
        Clip(
            assetID: clip.assetID,
            timelineRange: TimeRange(start: timelineStart, duration: duration),
            sourceRange: TimeRange(start: sourceStart, duration: duration),
            transform: clip.transform,
            cropRect: clip.cropRect,
            opacity: clip.opacity,
            volume: clip.volume,
            effects: clip.effects,
            keyframes: clip.keyframes,
            metadata: clip.metadata,
            speed: clip.speed,
            transitionIn: clip.transitionIn,
            linkGroupID: clip.linkGroupID,
            blendMode: clip.blendMode
        )
    }

    private func assetHasAudio(_ asset: MediaAsset) async -> Bool {
        switch asset.type {
        case .audio:
            return true
        case .image:
            return false
        case .video:
            let url = asset.sourceURL
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let avAsset = AVURLAsset(url: url)
            do {
                let tracks = try await avAsset.loadTracks(withMediaType: .audio)
                return !tracks.isEmpty
            } catch {
                return false
            }
        }
    }

    private func removeAudiolessVideoClips(using assets: [MediaAsset]) async {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let candidateAssetIDs = AudiolessClipCleanupPlanner.candidateVideoAssetIDs(
            in: context.timelineState.timeline,
            assetsByID: assetsByID
        )
        guard !candidateAssetIDs.isEmpty else { return }

        var assetsWithNoAudio = Set<UUID>()

        for assetID in candidateAssetIDs {
            guard let asset = assetsByID[assetID] else { continue }
            if await !assetHasAudio(asset) {
                assetsWithNoAudio.insert(asset.id)
            }
        }

        guard !assetsWithNoAudio.isEmpty else { return }

        var timeline = context.timelineState.timeline
        var removedAny = false

        for index in timeline.tracks.indices where timeline.tracks[index].type == .audio {
            let originalCount = timeline.tracks[index].clips.count
            timeline.tracks[index].clips.removeAll { clip in
                guard let asset = assetsByID[clip.assetID] else { return false }
                return asset.type == .video && assetsWithNoAudio.contains(asset.id)
            }
            removedAny = removedAny || timeline.tracks[index].clips.count != originalCount
        }

        guard removedAny else { return }
        context.timelineState.timeline = timeline
        rebuildComposition()
        scheduleSave()
    }

    // MARK: - Intent pipeline (ONLY write path)

    func perform(_ intent: EditorIntent, source: ActionSource = .user) throws {
        let expandedIntent = expandLinkedIntent(intent)
        let previousClipIDs = Set(timeline.tracks.flatMap(\.clips).map(\.id))
        var command = try intentResolver.resolve(expandedIntent)
        try commandHistory.execute(&command, context: context, source: source)

        // After linked split: re-link second halves with a new linkGroupID
        // so each half-pair is independently movable (DaVinci-style).
        relinkAfterSplit(expandedIntent)
        relinkAfterDuplicate(expandedIntent, previousClipIDs: previousClipIDs)
        updateSelectionAfterSplitIfNeeded(expandedIntent, previousClipIDs: previousClipIDs)

        // Ripple: close gaps after delete/trim if enabled
        if timelineViewState.rippleEnabled {
            rippleCloseGaps(for: intent)
        }

        normalizeSelection()
        rebuildComposition()
        scheduleSave()
    }

    /// Close all gaps on all tracks by shifting clips left. Public for compound tools.
    func rippleCloseGaps() {
        for trackIndex in context.timelineState.timeline.tracks.indices {
            var clips = context.timelineState.timeline.tracks[trackIndex].clips
            clips.sort { $0.timelineRange.start < $1.timelineRange.start }
            var cursor: TimeInterval = 0
            for i in clips.indices {
                if clips[i].timelineRange.start > cursor {
                    let duration = clips[i].timelineRange.duration
                    clips[i].timelineRange = TimeRange(start: cursor, duration: duration)
                }
                cursor = clips[i].timelineRange.end
            }
            context.timelineState.timeline.tracks[trackIndex].clips = clips
        }
        rebuildComposition()
        scheduleSave()
    }

    /// After a delete or trim, shift subsequent clips left to close gaps (auto, when ripple mode on).
    private func rippleCloseGaps(for intent: EditorIntent) {
        switch intent {
        case .deleteClips, .trimClip:
            for trackIndex in context.timelineState.timeline.tracks.indices {
                var clips = context.timelineState.timeline.tracks[trackIndex].clips
                clips.sort { $0.timelineRange.start < $1.timelineRange.start }

                var cursor: TimeInterval = 0
                for i in clips.indices {
                    if clips[i].timelineRange.start > cursor {
                        // Gap detected — shift this clip left
                        let duration = clips[i].timelineRange.duration
                        clips[i].timelineRange = TimeRange(start: cursor, duration: duration)
                    }
                    cursor = clips[i].timelineRange.end
                }
                context.timelineState.timeline.tracks[trackIndex].clips = clips
            }
        default:
            break
        }
    }

    /// If an intent targets a clip with linked siblings, expand to a batch.
    private func expandLinkedIntent(_ intent: EditorIntent) -> EditorIntent {
        let allClips = timeline.tracks.flatMap(\.clips)

        switch intent {
        case .moveClip(let clipID, let newStart, let trackID):
            guard let clip = allClips.first(where: { $0.id == clipID }),
                  let linkGroup = clip.linkGroupID else { return intent }
            let siblings = allClips.filter { $0.linkGroupID == linkGroup && $0.id != clipID }
            guard !siblings.isEmpty else { return intent }
            // Move all linked clips by the same delta
            let delta = newStart - clip.timelineRange.start
            var intents: [EditorIntent] = [intent]
            for sibling in siblings {
                let sibTrack = timeline.tracks.first(where: { $0.clips.contains { $0.id == sibling.id } })
                intents.append(.moveClip(clipID: sibling.id, newStart: sibling.timelineRange.start + delta, trackID: sibTrack?.id ?? trackID))
            }
            return intents.count == 1 ? intent : .batch(intents)

        case .trimClip(let clipID, let newSourceRange):
            guard let clip = allClips.first(where: { $0.id == clipID }),
                  let linkGroup = clip.linkGroupID else { return intent }
            let siblings = allClips.filter { $0.linkGroupID == linkGroup && $0.id != clipID }
            guard !siblings.isEmpty else { return intent }
            var intents: [EditorIntent] = [intent]
            for sibling in siblings {
                let siblingRange = ClipTrimResolver.linkedSiblingSourceRange(
                    primaryOriginalSourceRange: clip.sourceRange,
                    primaryProposedSourceRange: newSourceRange,
                    siblingSourceRange: sibling.sourceRange
                )
                intents.append(.trimClip(clipID: sibling.id, newSourceRange: siblingRange))
            }
            return .batch(intents)

        case .deleteClips(let clipIDs):
            var expanded = Set(clipIDs)
            for id in clipIDs {
                guard let clip = allClips.first(where: { $0.id == id }),
                      let linkGroup = clip.linkGroupID else { continue }
                let siblings = allClips.filter { $0.linkGroupID == linkGroup }
                siblings.forEach { expanded.insert($0.id) }
            }
            return .deleteClips(clipIDs: Array(expanded))

        case .splitClip(let clipID, let at):
            guard let clip = allClips.first(where: { $0.id == clipID }),
                  let linkGroup = clip.linkGroupID else { return intent }
            let siblings = allClips.filter { $0.linkGroupID == linkGroup && $0.id != clipID }
            guard !siblings.isEmpty else { return intent }
            var intents: [EditorIntent] = [intent]
            for sibling in siblings {
                intents.append(.splitClip(clipID: sibling.id, at: at))
            }
            return .batch(intents)

        case .setClipSpeed(let clipID, let speed):
            guard let clip = allClips.first(where: { $0.id == clipID }),
                  let linkGroup = clip.linkGroupID else { return intent }
            let siblings = allClips.filter { $0.linkGroupID == linkGroup && $0.id != clipID }
            guard !siblings.isEmpty else { return intent }
            var intents: [EditorIntent] = [intent]
            for sibling in siblings {
                intents.append(.setClipSpeed(clipID: sibling.id, speed: speed))
            }
            return .batch(intents)

        case .setClipVolume(let clipID, let volume):
            guard let clip = allClips.first(where: { $0.id == clipID }),
                  let linkGroup = clip.linkGroupID else { return intent }
            let siblings = allClips.filter { $0.linkGroupID == linkGroup && $0.id != clipID }
            guard !siblings.isEmpty else { return intent }
            var intents: [EditorIntent] = [intent]
            for sibling in siblings {
                intents.append(.setClipVolume(clipID: sibling.id, volume: volume))
            }
            return .batch(intents)

        case .duplicateClip(let clipID):
            guard let clip = allClips.first(where: { $0.id == clipID }),
                  let linkGroup = clip.linkGroupID else { return intent }
            let siblings = allClips.filter { $0.linkGroupID == linkGroup && $0.id != clipID }
            guard !siblings.isEmpty else { return intent }
            var intents: [EditorIntent] = [intent]
            for sibling in siblings {
                intents.append(.duplicateClip(clipID: sibling.id))
            }
            return .batch(intents)

        default:
            return intent
        }
    }

    /// After a linked split batch, the second halves all share the original linkGroupID.
    /// Re-assign them a NEW shared linkGroupID so each pair is independently movable.
    private func relinkAfterSplit(_ intent: EditorIntent) {
        guard case .batch(let intents) = intent,
              intents.count > 1,
              intents.allSatisfy({ if case .splitClip = $0 { return true } else { return false } })
        else { return }

        // Collect the clip IDs that were split
        let splitClipIDs = intents.compactMap { intent -> UUID? in
            if case .splitClip(let clipID, _) = intent { return clipID }
            return nil
        }

        // Find the second halves: clips that share a linkGroupID with a split clip
        // but have a DIFFERENT id (they're the newly created second halves)
        let allClips = timeline.tracks.flatMap(\.clips)
        let splitClips = allClips.filter { splitClipIDs.contains($0.id) }
        guard let linkGroup = splitClips.first?.linkGroupID else { return }

        // Second halves: clips with same linkGroupID but NOT in the split list
        let secondHalves = allClips.filter { $0.linkGroupID == linkGroup && !splitClipIDs.contains($0.id) }
        guard secondHalves.count > 1 else { return }

        let newLinkGroup = UUID()
        for clip in secondHalves {
            for (ti, track) in context.timelineState.timeline.tracks.enumerated() {
                if let ci = track.clips.firstIndex(where: { $0.id == clip.id }) {
                    context.timelineState.timeline.tracks[ti].clips[ci].linkGroupID = newLinkGroup
                }
            }
        }
    }

    /// After a linked duplicate batch, the new clips inherit the original's linkGroupID.
    /// Re-assign them a new shared linkGroupID so the copies form their own independent pair.
    private func relinkAfterDuplicate(_ intent: EditorIntent, previousClipIDs: Set<UUID>) {
        guard case .batch(let intents) = intent,
              intents.count > 1,
              intents.allSatisfy({ if case .duplicateClip = $0 { return true } else { return false } })
        else { return }

        // Find the newly created clips (IDs that didn't exist before)
        let allClips = timeline.tracks.flatMap(\.clips)
        let newClips = allClips.filter { !previousClipIDs.contains($0.id) }
        guard newClips.count > 1 else { return }

        // Give all new copies a shared linkGroupID
        let newLinkGroup = UUID()
        for clip in newClips {
            for (ti, track) in context.timelineState.timeline.tracks.enumerated() {
                if let ci = track.clips.firstIndex(where: { $0.id == clip.id }) {
                    context.timelineState.timeline.tracks[ti].clips[ci].linkGroupID = newLinkGroup
                }
            }
        }
    }

    private func updateSelectionAfterSplitIfNeeded(_ intent: EditorIntent, previousClipIDs: Set<UUID>) {
        let isSplitIntent: Bool
        switch intent {
        case .splitClip:
            isSplitIntent = true
        case .batch(let intents):
            isSplitIntent = !intents.isEmpty && intents.allSatisfy {
                if case .splitClip = $0 { return true }
                return false
            }
        default:
            isSplitIntent = false
        }

        guard isSplitIntent else { return }

        let newClips = timeline.tracks
            .flatMap { track in track.clips.map { (trackID: track.id, clip: $0) } }
            .filter { !previousClipIDs.contains($0.clip.id) }

        guard !newClips.isEmpty else { return }

        timelineViewState.selectedClipIDs = Set(newClips.map(\.clip.id))
        let selectedTrackIDs = Set(newClips.map(\.trackID))
        timelineViewState.selectedTrackID = selectedTrackIDs.count == 1 ? selectedTrackIDs.first : nil
        timelineViewState.lastSelectedClipID = newClips
            .sorted {
                if $0.clip.timelineRange.start != $1.clip.timelineRange.start {
                    return $0.clip.timelineRange.start < $1.clip.timelineRange.start
                }
                return $0.clip.timelineRange.end < $1.clip.timelineRange.end
            }
            .first?.clip.id
    }

    func undo() throws {
        try commandHistory.undo(context: context)
        normalizeSelection()
        rebuildComposition()
        scheduleSave()
    }

    func redo() throws {
        try commandHistory.redo(context: context)
        normalizeSelection()
        rebuildComposition()
        scheduleSave()
    }

    // MARK: - Project persistence

    /// Save project after a short debounce (avoids saving on every keystroke/drag).
    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistProjectState(waitForCompletion: false)
        }
    }

    func flushPendingState() {
        guard !hasShutdown else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        persistProjectState(waitForCompletion: false)
    }

    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true

        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        compositionRebuildTask?.cancel()
        compositionRebuildTask = nil
        playbackSyncTask?.cancel()
        playbackSyncTask = nil
        playbackEngine.pause()

        media.onAnalysisComplete = nil
        media.onAssetsChanged = nil
        media.stopBackgroundWork()

        mcpServer?.stop()
        mcpServer = nil

        persistProjectState(waitForCompletion: true)
    }

    private func persistProjectState(waitForCompletion: Bool) {
        let timelineSnapshot = timeline
        let bundleURL = projectBundleURL
        let projectStore = self.projectStore
        let mediaManager = media.mediaManager

        let overlaySnapshot = context.timelineState.broadcastOverlay
        let shortFormSnapshot = context.timelineState.shortFormConfig

        let persist: @Sendable () async -> Void = {
            try? await projectStore.save(to: bundleURL, timeline: timelineSnapshot)
            let allAssets = await mediaManager.allAssets()
            let assetsURL = bundleURL.appendingPathComponent("assets.json")
            if let data = try? JSONEncoder().encode(allAssets) {
                try? data.write(to: assetsURL)
            }
            // Persist overlay config
            let overlayURL = bundleURL.appendingPathComponent("overlay.json")
            if let overlay = overlaySnapshot {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(overlay) {
                    try? data.write(to: overlayURL)
                }
            } else {
                try? FileManager.default.removeItem(at: overlayURL)
            }
            // Persist short-form config
            let shortFormURL = bundleURL.appendingPathComponent("shortform.json")
            if let sf = shortFormSnapshot {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(sf) {
                    try? data.write(to: shortFormURL)
                }
            } else {
                try? FileManager.default.removeItem(at: shortFormURL)
            }
        }

        if waitForCompletion {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                defer { semaphore.signal() }
                await persist()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        } else {
            Task.detached(priority: .utility) {
                await persist()
            }
        }
    }

    /// Load project from bundle on launch.
    private func loadProject() {
        let timelinePath = projectBundleURL.appendingPathComponent("timeline.json")
        guard FileManager.default.fileExists(atPath: timelinePath.path) else { return }

        Task {
            var restoredAssets: [MediaAsset] = []

            // Load timeline and project settings
            if let loadedTimeline = try? await projectStore.load(from: projectBundleURL) {
                context.timelineState.timeline = loadedTimeline
                let metadata = await projectStore.projectMetadata()
                context.timelineState.projectSettings = metadata.settings
            }

            // Load overlay config
            let overlayURL = projectBundleURL.appendingPathComponent("overlay.json")
            if let overlayData = try? Data(contentsOf: overlayURL),
               let overlay = try? JSONDecoder().decode(BroadcastOverlayConfig.self, from: overlayData) {
                context.timelineState.broadcastOverlay = overlay
            }

            // Load short-form config
            let shortFormURL = projectBundleURL.appendingPathComponent("shortform.json")
            if let sfData = try? Data(contentsOf: shortFormURL),
               let sf = try? JSONDecoder().decode(ShortFormConfig.self, from: sfData) {
                context.timelineState.shortFormConfig = sf
            }

            // Load assets and merge persisted transcripts
            let assetsURL = projectBundleURL.appendingPathComponent("assets.json")
            if let data = try? Data(contentsOf: assetsURL),
               let loadedAssets = try? JSONDecoder().decode([MediaAsset].self, from: data) {
                restoredAssets = loadedAssets
                for var asset in loadedAssets {
                    // Restore transcript from disk if not in assets.json
                    if asset.analysis?.transcript == nil || asset.analysis!.transcript!.isEmpty {
                        if let diskResult = await media.transcriptionService.loadTranscript(
                            for: asset, bundleURL: projectBundleURL
                        ) {
                            var analysis = asset.analysis ?? MediaAnalysis()
                            analysis.transcript = diskResult.words
                            analysis.speakerSegments = diskResult.speakers
                            asset.analysis = analysis
                        }
                    }
                    // Activate bookmark access for reference imports, then validate
                    let accessible = ExportFolderManager.canAccessWithoutCopy(path: asset.sourceURL.path)
                        || FileManager.default.fileExists(atPath: asset.sourceURL.path)
                    if accessible {
                        await media.mediaManager.add(asset)
                    } else {
                        print("[AppState] Missing media file: \(asset.sourceURL.lastPathComponent) at \(asset.sourceURL.path)")
                    }
                }
                await media.refreshAssets()
                await media.regenerateMissingThumbnails()
                await removeAudiolessVideoClips(using: loadedAssets)
            } else {
                print("[AppState] No assets.json at \(assetsURL.path)")
            }

            timelineViewState.clearSelection()
            normalizeSelection()
            rebuildComposition()

            if !restoredAssets.isEmpty {
                Task(priority: .utility) { [weak self] in
                    await self?.removeAudiolessVideoClips(using: restoredAssets)
                }
            }
        }
    }

    // MARK: - Project management

    static func ensureProjectDirectories(at bundleURL: URL) {
        for subdir in ["media", "proxies", "cache/thumbnails", "cache/waveforms", "cache/render", "analysis"] {
            try? FileManager.default.createDirectory(
                at: bundleURL.appendingPathComponent(subdir),
                withIntermediateDirectories: true
            )
        }
    }

    /// Create a new project and switch to it.
    func createProject(name: String) async -> String {
        let sanitized = sanitizedProjectName(name)

        if projectIndex.projectExists(sanitized) {
            return "Error: project '\(sanitized)' already exists"
        }

        // Save current project first
        persistProjectState(waitForCompletion: true)

        // Create directory structure
        let newURL = projectIndex.bundleURL(for: sanitized)
        Self.ensureProjectDirectories(at: newURL)

        // Register in index
        projectIndex.addProject(name: sanitized)
        projectIndex.setActive(sanitized)

        // Switch to new project
        switchToBundle(newURL)

        return "Created project '\(sanitized)' at \(newURL.path)"
    }

    /// Open an existing project by name.
    func openProject(name: String) async -> String {
        let sanitized = sanitizedProjectName(name)

        guard projectIndex.projectExists(sanitized) else {
            return "Error: project '\(sanitized)' not found"
        }

        if sanitized == projectIndex.activeProjectName {
            return "Project '\(sanitized)' is already open"
        }

        // Save current project first
        persistProjectState(waitForCompletion: true)

        let targetURL = projectIndex.bundleURL(for: sanitized)
        Self.ensureProjectDirectories(at: targetURL)

        projectIndex.setActive(sanitized)
        switchToBundle(targetURL)

        return "Opened project '\(sanitized)'"
    }

    /// Save the current project explicitly.
    func saveCurrentProject() -> String {
        persistProjectState(waitForCompletion: true)
        projectIndex.markModified(projectIndex.activeProjectName)
        return "Saved project '\(projectIndex.activeProjectName)'"
    }

    /// Close current project (save first), return to empty Untitled.
    func closeProject() async -> String {
        let closedName = projectIndex.activeProjectName
        persistProjectState(waitForCompletion: true)

        // Open or create Untitled
        if !projectIndex.projectExists("Untitled") {
            projectIndex.addProject(name: "Untitled")
        }
        projectIndex.setActive("Untitled")

        let untitledURL = projectIndex.bundleURL(for: "Untitled")
        Self.ensureProjectDirectories(at: untitledURL)
        switchToBundle(untitledURL)

        return "Closed '\(closedName)', opened Untitled"
    }

    /// Delete a project by name. Cannot delete the active project.
    func deleteProject(name: String) -> String {
        let sanitized = sanitizedProjectName(name)

        guard projectIndex.projectExists(sanitized) else {
            return "Error: project '\(sanitized)' not found"
        }
        if sanitized == projectIndex.activeProjectName {
            return "Error: cannot delete the currently open project. Open a different project first."
        }

        let targetURL = projectIndex.bundleURL(for: sanitized)
        try? FileManager.default.removeItem(at: targetURL)
        projectIndex.removeProject(sanitized)

        return "Deleted project '\(sanitized)'"
    }

    /// Rename the current project.
    func renameProject(to newName: String) -> String {
        let sanitized = sanitizedProjectName(newName)
        let oldName = projectIndex.activeProjectName

        if oldName == sanitized {
            return "Project already named '\(sanitized)'"
        }
        if projectIndex.projectExists(sanitized) {
            return "Error: project '\(sanitized)' already exists"
        }

        // Save first
        persistProjectState(waitForCompletion: true)

        let oldURL = projectIndex.bundleURL(for: oldName)
        let newURL = projectIndex.bundleURL(for: sanitized)

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            return "Error renaming: \(error.localizedDescription)"
        }

        projectIndex.renameProject(from: oldName, to: sanitized)
        projectBundleURL = newURL
        media = MediaCoordinator(bundleURL: newURL)
        // Re-register callbacks
        media.onAnalysisComplete = { [weak self] in self?.rebuildComposition() }
        media.onAssetsChanged = { [weak self] in self?.scheduleSave() }

        // Reload assets into new MediaCoordinator
        loadProject()

        return "Renamed '\(oldName)' to '\(sanitized)'"
    }

    /// List all projects with metadata.
    func listProjects() -> [[String: Any]] {
        let fm = FileManager.default
        return projectIndex.index.projects.map { entry in
            let url = projectIndex.bundleURL(for: entry.name)
            let isActive = entry.name == projectIndex.activeProjectName

            // Try reading clip count and duration from timeline.json
            var clipCount = 0
            var duration: TimeInterval = 0
            let timelinePath = url.appendingPathComponent("timeline.json")
            if fm.fileExists(atPath: timelinePath.path),
               let data = try? Data(contentsOf: timelinePath),
               let timeline = try? JSONDecoder().decode(Timeline.self, from: data) {
                clipCount = timeline.tracks.flatMap(\.clips).count
                duration = timeline.duration
            }

            let formatter = ISO8601DateFormatter()
            return [
                "name": entry.name,
                "active": isActive,
                "created": formatter.string(from: entry.created),
                "modified": formatter.string(from: entry.modified),
                "clips": clipCount,
                "duration": String(format: "%.1f", duration),
            ] as [String: Any]
        }
    }

    // MARK: - Internal project switching

    /// Reset editor state and load a different project bundle.
    private func switchToBundle(_ newURL: URL) {
        // Stop playback
        playbackEngine.pause()

        // Clear current state
        context.timelineState.timeline = Timeline()
        context.timelineState.broadcastOverlay = nil
        context.timelineState.shortFormConfig = nil
        context.timelineState.captionStyle = .none
        commandHistory.clear()
        timelineViewState.clearSelection()

        // Switch bundle URL — keep the same MediaCoordinator to avoid dealloc crash,
        // just clear its assets and update the bundle URL
        projectBundleURL = newURL
        Self.ensureProjectDirectories(at: newURL)
        media.updateBundleURL(newURL)

        // Ensure removeAll completes before loading the new project
        // Note: don't refreshAssets() here — loadProject() will refresh after adding assets
        Task {
            await media.mediaManager.removeAll()
            await MainActor.run {
                loadProject()
            }
        }
    }

    // MARK: - Media import

    func importMedia(from url: URL) async throws -> MediaAsset {
        // Dedup: if an asset with the same name already exists, return it
        let importName = url.deletingPathExtension().lastPathComponent
        if let existing = assets.first(where: { $0.name == importName }) {
            return existing
        }

        // If the file is in a bookmarked media folder, reference it directly (no copy)
        let canReference = ExportFolderManager.canAccessWithoutCopy(path: url.path)
        let mediaDir = canReference ? nil : projectBundleURL.appendingPathComponent("media")
        return try await media.importMedia(from: url, mediaDir: mediaDir)
    }

    @discardableResult
    func pruneNonRenderableClips(
        minimumDuration: TimeInterval = TimelineFragmentPruner.minimumRenderableDuration
    ) -> Int {
        let result = TimelineFragmentPruner.prune(
            context.timelineState.timeline,
            minimumDuration: minimumDuration
        )
        guard !result.removedClipIDs.isEmpty else { return 0 }

        context.timelineState.timeline = result.timeline
        normalizeSelection()
        rebuildComposition()
        scheduleSave()
        return result.removedClipIDs.count
    }

    // MARK: - Playback

    private var compositionRebuildTask: Task<Void, Never>?

    func rebuildComposition() {
        // Debounce: cancel pending rebuild if another comes within 50ms
        compositionRebuildTask?.cancel()
        compositionRebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            playbackEngine.buildComposition(from: timeline, assets: assets, broadcastOverlay: context.timelineState.broadcastOverlay, shortFormConfig: context.timelineState.shortFormConfig, captionStyle: context.timelineState.captionStyle, projectSettings: context.timelineState.projectSettings)
        }
    }

    /// Force immediate rebuild (for playback start, export, etc.)
    func rebuildCompositionNow() {
        compositionRebuildTask?.cancel()
        playbackEngine.buildComposition(from: timeline, assets: assets, broadcastOverlay: context.timelineState.broadcastOverlay, shortFormConfig: context.timelineState.shortFormConfig, captionStyle: context.timelineState.captionStyle, projectSettings: context.timelineState.projectSettings)
    }

    @discardableResult
    func clearShortFormLayoutIfNeeded() -> Bool {
        guard ShortFormConflictResolver.shouldDisableForClipCrop(context.timelineState.shortFormConfig) else {
            return false
        }

        context.timelineState.shortFormConfig = nil
        scheduleSave()
        return true
    }

    func seekFromPlayhead() {
        playbackEngine.seek(to: timelineViewState.playheadPosition)
    }

    private func clip(for clipID: UUID) -> Clip? {
        timeline.tracks.flatMap(\.clips).first(where: { $0.id == clipID })
    }

    private func intentTrackID(for intent: EditorIntent) -> UUID? {
        if case let .insertClip(_, trackID) = intent {
            return trackID
        }
        return nil
    }

    private func track(for clipID: UUID) -> Track? {
        timeline.tracks.first(where: { track in
            track.clips.contains(where: { $0.id == clipID })
        })
    }

    private func linkedSelectionIDs(for clipID: UUID) -> [UUID] {
        guard timelineViewState.linkedSelectionEnabled,
              let clip = clip(for: clipID),
              let linkGroupID = clip.linkGroupID else {
            return [clipID]
        }

        let linkedIDs = timeline.tracks
            .flatMap(\.clips)
            .filter { $0.linkGroupID == linkGroupID }
            .map(\.id)

        return linkedIDs.isEmpty ? [clipID] : linkedIDs
    }

    func trackID(for clipID: UUID) -> UUID? {
        timeline.tracks.first(where: { track in
            track.clips.contains(where: { $0.id == clipID })
        })?.id
    }

    func focusTimeline(at time: TimeInterval, clipID: UUID? = nil, trackID: UUID? = nil) {
        let maxTime = max(timeline.duration, playbackEngine.duration)
        let clampedTime = min(max(time, 0), maxTime)
        playbackEngine.seek(to: clampedTime)
        timelineViewState.playheadPosition = clampedTime

        if let clipID, let trackID {
            timelineViewState.selectClip(clipID, in: trackID)
        } else if let trackID {
            timelineViewState.selectTrack(trackID)
        }
    }

    func timelineLocation(forAssetID assetID: UUID, sourceTime: TimeInterval) -> (clipID: UUID, trackID: UUID, timelineTime: TimeInterval)? {
        let playhead = timelineViewState.playheadPosition
        let selectedIDs = timelineViewState.selectedClipIDs

        struct Candidate {
            let clipID: UUID
            let trackID: UUID
            let timelineTime: TimeInterval
            let priority: Int
            let distance: TimeInterval
            let trackIndex: Int
        }

        var bestCandidate: Candidate?

        for (trackIndex, track) in timeline.tracks.enumerated() {
            for clip in track.clips where clip.assetID == assetID && clip.sourceRange.contains(sourceTime) {
                let mappedTime = clip.timelineRange.start + (sourceTime - clip.sourceRange.start)
                let candidate = Candidate(
                    clipID: clip.id,
                    trackID: track.id,
                    timelineTime: min(max(mappedTime, clip.timelineRange.start), clip.timelineRange.end),
                    priority: selectedIDs.contains(clip.id) ? 0 : (clip.timelineRange.contains(playhead) ? 1 : 2),
                    distance: abs(mappedTime - playhead),
                    trackIndex: trackIndex
                )

                if let currentBest = bestCandidate {
                    if candidate.priority < currentBest.priority
                        || (candidate.priority == currentBest.priority && candidate.distance < currentBest.distance)
                        || (candidate.priority == currentBest.priority && candidate.distance == currentBest.distance && candidate.trackIndex < currentBest.trackIndex) {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
            }
        }

        guard let bestCandidate else { return nil }
        return (bestCandidate.clipID, bestCandidate.trackID, bestCandidate.timelineTime)
    }

    func createSearchSequence(from results: [SearchResult], named query: String, source: ActionSource = .ai) async {
        guard !results.isEmpty else { return }

        let insertionIndex = timelineViewState.selectedTrackID.flatMap { id in
            timeline.tracks.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        }
        let trackName = query.isEmpty ? "Search Sequence" : "\(query) sequence"
        let videoTrackID = createTrack(of: .video, insertionIndex: insertionIndex, name: trackName, source: source)
        var position: TimeInterval = 0

        for result in results {
            guard let asset = assets.first(where: { $0.id == result.assetID }) else { continue }
            let segmentStart = max(0, result.contextStartTime)
            let segmentDuration = max(result.contextEndTime - result.contextStartTime, 1)
            await insertAssetSegment(
                asset,
                sourceRange: TimeRange(start: segmentStart, duration: segmentDuration),
                source: source,
                preferredTrackID: videoTrackID,
                startTime: position,
                label: "\(result.assetName) • \(result.formattedTime)"
            )
            position += segmentDuration
        }

        focusTimeline(at: 0, trackID: videoTrackID)
    }

    private func normalizeSelection() {
        let normalized = TimelineSelectionNormalizer.normalize(
            selection: TimelineSelectionSnapshot(
                selectedClipIDs: timelineViewState.selectedClipIDs,
                selectedTrackID: timelineViewState.selectedTrackID,
                lastSelectedClipID: timelineViewState.lastSelectedClipID
            ),
            in: timeline
        )

        timelineViewState.selectedClipIDs = normalized.selectedClipIDs
        timelineViewState.selectedTrackID = normalized.selectedTrackID
        timelineViewState.lastSelectedClipID = normalized.lastSelectedClipID
    }

    // MARK: - API key loading

    /// Load all KEY=VALUE pairs from .env files and environment.
    private static func loadEnvKeys() -> [String: String] {
        var keys: [String: String] = [:]

        // Load from .env files
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let envPaths = [
            appSupport?.appendingPathComponent("VideoEditor/.env"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("VideoEditor/.env"),
            // Also check the source project directory (for Xcode builds)
            (FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("Projects/video-editor/VideoEditor/.env"),
        ].compactMap { $0 }
        for envPath in envPaths {
            if let contents = try? String(contentsOf: envPath, encoding: .utf8) {
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                    if let eqIndex = trimmed.firstIndex(of: "=") {
                        let key = String(trimmed[trimmed.startIndex..<eqIndex])
                        let value = String(trimmed[trimmed.index(after: eqIndex)...])
                        if !value.isEmpty { keys[key] = value }
                    }
                }
            }
        }

        // Environment variables override .env file
        for key in ["ANTHROPIC_API_KEY", "DEEPGRAM_API_KEY"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                keys[key] = value
            }
        }

        return keys
    }

    private func startPlayheadSync() {
        playbackSyncTask?.cancel()
        playbackSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Read playback engine values inside observation tracking so we
                // wake up only when AVPlayer's periodic time observer pushes a
                // new currentTime or isPlaying toggles.
                let engineTime = self.playbackEngine.currentTime
                let enginePlaying = self.playbackEngine.isPlaying

                let current = PlayheadSyncSnapshot(
                    playheadPosition: self.timelineViewState.playheadPosition,
                    isPlaying: self.timelineViewState.isPlaying
                )

                if let resolved = PlayheadSyncResolver.resolve(
                    current: current,
                    playbackTime: engineTime,
                    playbackIsPlaying: enginePlaying
                ) {
                    self.timelineViewState.playheadPosition = resolved.playheadPosition
                    self.timelineViewState.isPlaying = resolved.isPlaying
                }

                // Yield until next observation change — no polling when paused.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.playbackEngine.currentTime
                        _ = self.playbackEngine.isPlaying
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            shutdown()
        }
    }
}
