import Foundation
@preconcurrency import AVFoundation

/// Exports timeline to video file using AVAssetExportSession.
/// Phase 1 uses high-level export. Phase 2 will add AVAssetReader/Writer for frame-level control.
@MainActor @Observable
public final class ExportEngine {
    public enum State: Equatable {
        case idle
        case exporting(progress: Float)
        case completed(URL)
        case failed(String)
    }

    public private(set) var state: State = .idle
    private var exportSession: AVAssetExportSession?
    private var progressTimer: Timer?

    public init() {}

    /// Export the timeline to a file at the given URL.
    public func export(
        timeline: Timeline,
        assets: [MediaAsset],
        to outputURL: URL,
        preset: String = AVAssetExportPresetHighestQuality,
        fileType: AVFileType = .mp4,
        broadcastOverlay: BroadcastOverlayConfig? = nil,
        shortFormConfig: ShortFormConfig? = nil,
        captionStyle: CaptionStyler.CaptionStyle = .standard,
        projectSettings: ProjectSettings = .default
    ) async {
        guard timeline.tracks.contains(where: { !$0.clips.isEmpty }), timeline.duration > 0 else {
            state = .failed("Nothing to export")
            return
        }

        state = .exporting(progress: 0)

        let builder = CompositionBuilder()
        let result = await builder.build(from: timeline, assets: assets, urlMode: .export, broadcastOverlay: broadcastOverlay, shortFormConfig: shortFormConfig, captionStyle: captionStyle, projectSettings: projectSettings)

        guard result.duration > 0 else {
            state = .failed("Nothing to export")
            return
        }

        guard let session = AVAssetExportSession(asset: result.composition, presetName: preset) else {
            state = .failed("Could not create export session")
            return
        }

        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)

        session.outputURL = outputURL
        session.outputFileType = fileType
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: result.duration, preferredTimescale: 600))
        if let audioMix = result.audioMix {
            session.audioMix = audioMix
        }
        if let videoComp = result.videoComposition {
            session.videoComposition = videoComp
        }

        self.exportSession = session

        // Poll progress — defer ensures cleanup on any exit path
        startProgressPolling(session: session)
        defer {
            stopProgressPolling()
            exportSession = nil
        }

        await session.export()

        switch session.status {
        case .completed:
            // Validate output file
            let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = attrs?[.size] as? Int64 ?? 0
            if fileSize == 0 {
                state = .failed("Export produced empty file")
                return
            }
            state = .completed(outputURL)
        case .failed:
            state = .failed(session.error?.localizedDescription ?? "Export failed")
        case .cancelled:
            state = .failed("Export cancelled")
        default:
            state = .failed("Unexpected export status")
        }
    }

    public func reset() {
        state = .idle
    }

    public func cancel() {
        // Clean up partial output file
        if let outputURL = exportSession?.outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        exportSession?.cancelExport()
        stopProgressPolling()
        state = .idle
    }

    // MARK: - Progress polling

    private func startProgressPolling(session: AVAssetExportSession) {
        let pollSession = session
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let progress = pollSession.progress
            Task { @MainActor in
                self?.state = .exporting(progress: progress)
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
