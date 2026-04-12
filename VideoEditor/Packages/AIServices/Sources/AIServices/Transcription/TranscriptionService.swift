import Foundation
import EditorCore

/// Manages transcription lifecycle: trigger, cache, store results.
/// Transcripts are tied to asset IDs and never regenerated without explicit permission.
public actor TranscriptionService {
    private var provider: (any TranscriptionProvider)?
    private var localProvider: (any TranscriptionProvider)?
    private var inProgress: Set<UUID> = []

    public init() {}

    public func configure(provider: any TranscriptionProvider) {
        self.provider = provider
    }

    public func configureLocal(provider: any TranscriptionProvider) {
        self.localProvider = provider
    }

    /// Resolve which provider to use based on preference and availability.
    /// - When `useLocal` is true, always use local provider.
    /// - When diarization is needed and cloud provider exists, prefer cloud (it supports diarization).
    /// - Otherwise fall back to local if cloud is unavailable.
    public func resolveProvider(preferLocal: Bool, needsDiarization: Bool) -> (any TranscriptionProvider)? {
        if preferLocal {
            return localProvider ?? provider
        }
        if needsDiarization, provider != nil {
            return provider
        }
        return provider ?? localProvider
    }

    /// Get transcript for an asset. Checks: in-memory → disk → returns nil.
    /// Does NOT trigger transcription. Use `transcribe` for that.
    public func getTranscript(
        for asset: MediaAsset,
        bundleURL: URL
    ) -> TranscriptionResult? {
        // Check in-memory (on the asset)
        if let words = asset.analysis?.transcript, !words.isEmpty {
            return TranscriptionResult(
                text: words.map(\.word).joined(separator: " "),
                words: words,
                speakers: asset.analysis?.speakerSegments,
                duration: asset.duration
            )
        }

        // Check persisted on disk — source-stable key first, then legacy asset ID
        return loadTranscript(for: asset, bundleURL: bundleURL)
    }

    /// Transcribe an asset. Only runs if no transcript exists (or force = true).
    /// Returns the result, or nil if no provider is configured.
    /// Set `useLocal` to force local (WhisperKit) transcription.
    public func transcribe(
        asset: MediaAsset,
        mediaManager: MediaManager,
        bundleURL: URL,
        force: Bool = false,
        useLocal: Bool = false,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> TranscriptionResult? {
        if !force {
            if let existing = getTranscript(for: asset, bundleURL: bundleURL) {
                return existing
            }
        }

        guard !inProgress.contains(asset.id) else { return nil }

        let enableDiarization = !useLocal // Only cloud providers support diarization
        guard let activeProvider = resolveProvider(
            preferLocal: useLocal,
            needsDiarization: enableDiarization
        ) else { return nil }

        inProgress.insert(asset.id)
        defer { inProgress.remove(asset.id) }

        let isLocal = activeProvider.name == "WhisperKit"

        // Step 1: Extract + re-encode audio to AAC mono 16 kHz @ 48 kbps.
        // Runs for both video and audio assets — the compact encoding shrinks
        // upload size for cloud providers and is a no-op accuracy-wise for local
        // providers (which resample internally anyway).
        let audioExtractor = AudioExtractor()
        let prepStatus = asset.type == .video ? "Extracting audio from video..." : "Preparing audio..."
        onStatus?(prepStatus)
        let audioURL = try await audioExtractor.extractAudio(from: asset.sourceURL)
        let next = isLocal ? "Transcribing locally..." : "Uploading to \(activeProvider.name)..."
        onStatus?("Audio ready. \(next)")
        defer { audioExtractor.cleanup(tempURL: audioURL) }

        // Step 2: Transcribe
        onStatus?("Transcribing with \(activeProvider.name)...")
        let rawResult = try await activeProvider.transcribe(
            audioURL: audioURL,
            language: nil,
            enableDiarization: enableDiarization,
            progress: { _ in }
        )

        // Step 3: Lemmatize for search
        onStatus?("Processing \(rawResult.words.count) words...")
        let lemmatizer = Lemmatizer()
        let lemmatizedWords = lemmatizer.lemmatizeTranscript(rawResult.words)
        let result = TranscriptionResult(
            text: rawResult.text,
            words: lemmatizedWords,
            speakers: rawResult.speakers,
            language: rawResult.language,
            duration: rawResult.duration
        )

        // Store on asset in memory
        await mediaManager.updateAsset(id: asset.id) { asset in
            var analysis = asset.analysis ?? MediaAnalysis()
            analysis.transcript = result.words
            analysis.speakerSegments = result.speakers
            asset.analysis = analysis
        }

        // Persist to disk — keyed by source file (name + size), survives re-imports
        persistTranscript(result, asset: asset, bundleURL: bundleURL)

        return result
    }

    /// Check if a transcript exists for this asset (memory, disk by source key, or legacy asset ID).
    public func hasTranscript(for asset: MediaAsset, bundleURL: URL) -> Bool {
        if let transcript = asset.analysis?.transcript, !transcript.isEmpty { return true }
        if FileManager.default.fileExists(atPath: transcriptPath(for: asset, bundleURL: bundleURL)) { return true }
        if FileManager.default.fileExists(atPath: globalTranscriptPath(for: asset)) { return true }
        if FileManager.default.fileExists(atPath: legacyTranscriptPath(for: asset.id, bundleURL: bundleURL)) { return true }
        return false
    }

    /// Load a persisted transcript from disk.
    /// Search order: project-local (stable key) → global cache → project-local (legacy UUID)
    public func loadTranscript(for asset: MediaAsset, bundleURL: URL) -> TranscriptionResult? {
        // 1. Project-local: source-stable key (name + fileSize)
        let path = transcriptPath(for: asset, bundleURL: bundleURL)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return try? JSONDecoder().decode(TranscriptionResult.self, from: data)
        }
        // 2. Global cache: shared across all projects
        let globalPath = globalTranscriptPath(for: asset)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: globalPath)) {
            let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data)
            // Copy to project-local for portability
            if let result { persistTranscript(result, asset: asset, bundleURL: bundleURL) }
            return result
        }
        // 3. Legacy fallback: old asset-ID-keyed files
        let legacyPath = legacyTranscriptPath(for: asset.id, bundleURL: bundleURL)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: legacyPath)) {
            return try? JSONDecoder().decode(TranscriptionResult.self, from: data)
        }
        return nil
    }

    /// Check if transcription is currently running for an asset.
    public func isTranscribing(assetID: UUID) -> Bool {
        inProgress.contains(assetID)
    }

    // MARK: - Private

    /// Stable transcript path keyed by source file name + size. Survives re-imports.
    private func transcriptPath(for asset: MediaAsset, bundleURL: URL) -> String {
        let key = stableKey(for: asset)
        return bundleURL.appendingPathComponent("analysis/transcripts/\(key).json").path
    }

    /// Legacy path keyed by asset UUID — kept for reading old transcripts.
    private func legacyTranscriptPath(for assetID: UUID, bundleURL: URL) -> String {
        bundleURL.appendingPathComponent("analysis/transcripts/\(assetID.uuidString).json").path
    }

    private func persistTranscript(_ result: TranscriptionResult, asset: MediaAsset, bundleURL: URL) {
        let key = stableKey(for: asset)
        if let data = try? JSONEncoder().encode(result) {
            // Save to project-local
            let localDir = bundleURL.appendingPathComponent("analysis/transcripts")
            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            try? data.write(to: localDir.appendingPathComponent("\(key).json"))

            // Save to global cache (shared across projects)
            let globalDir = URL(fileURLWithPath: Self.globalCacheDir)
            try? FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
            try? data.write(to: globalDir.appendingPathComponent("\(key).json"))
        }
    }

    /// Global transcript cache directory — shared across all projects.
    /// Lives in Application Support, not inside any project bundle.
    private static var globalCacheDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VideoEditor/global_transcripts").path
    }

    /// Path to a transcript in the global cache.
    private func globalTranscriptPath(for asset: MediaAsset) -> String {
        let key = stableKey(for: asset)
        return "\(Self.globalCacheDir)/\(key).json"
    }

    /// Stable key from asset display name + file size.
    /// Uses asset.name (original filename without extension, set at import) instead of
    /// sourceURL.lastPathComponent (which becomes the UUID after bundle copy).
    private func stableKey(for asset: MediaAsset) -> String {
        let name = asset.name
        let size = asset.fileSize
        return "\(name)_\(size)".replacingOccurrences(of: " ", with: "_")
    }
}
