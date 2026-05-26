import Foundation
import AVFoundation

/// Builds AVComposition from Timeline and drives playback.
@MainActor @Observable
public final class PlaybackEngine {
    public private(set) var player: AVPlayer
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public internal(set) var duration: TimeInterval = 0
    public var loopEnabled: Bool = false
    public var playbackRate: Float = 1.0

    private var composition: AVMutableComposition?
    private var timeObserver: Any?
    private var buildTask: Task<Void, Never>?
    private var loopObserver: NSObjectProtocol?

    public init() {
        self.player = AVPlayer()
        setupTimeObserver()
    }

    deinit {
        MainActor.assumeIsolated {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
        }
    }

    // MARK: - Build composition from timeline

    public func buildComposition(from timeline: Timeline, assets: [MediaAsset], broadcastOverlay: BroadcastOverlayConfig? = nil, shortFormConfig: ShortFormConfig? = nil, captionStyle: CaptionStyler.CaptionStyle = .standard, projectSettings: ProjectSettings = .default) {
        // Cancel any in-flight build to prevent race conditions
        buildTask?.cancel()
        let resumeTime = currentTime
        let shouldResumePlayback = isPlaying
        buildTask = Task {
            await buildCompositionAsync(
                from: timeline,
                assets: assets,
                resumeTime: resumeTime,
                shouldResumePlayback: shouldResumePlayback,
                broadcastOverlay: broadcastOverlay,
                shortFormConfig: shortFormConfig,
                captionStyle: captionStyle,
                projectSettings: projectSettings
            )
        }
    }

    private func buildCompositionAsync(
        from timeline: Timeline,
        assets: [MediaAsset],
        resumeTime: TimeInterval,
        shouldResumePlayback: Bool,
        broadcastOverlay: BroadcastOverlayConfig? = nil,
        shortFormConfig: ShortFormConfig? = nil,
        captionStyle: CaptionStyler.CaptionStyle = .standard,
        projectSettings: ProjectSettings = .default
    ) async {
        let builder = CompositionBuilder()
        let result = await builder.build(from: timeline, assets: assets, urlMode: .preview, broadcastOverlay: broadcastOverlay, shortFormConfig: shortFormConfig, captionStyle: captionStyle, projectSettings: projectSettings)

        guard !Task.isCancelled else { return }

        self.composition = result.composition
        self.duration = result.duration

        let playerItem = AVPlayerItem(asset: result.composition)
        if let audioMix = result.audioMix {
            playerItem.audioMix = audioMix
        }
        if let videoComp = result.videoComposition {
            playerItem.videoComposition = videoComp
        }
        player.replaceCurrentItem(with: playerItem)
        setupLoopObserver()

        let restoredTime = min(max(resumeTime, 0), result.duration)
        let restoredCMTime = CMTime(seconds: restoredTime, preferredTimescale: 600)
        await player.seek(to: restoredCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = restoredTime

        if shouldResumePlayback, result.duration > 0 {
            player.rate = playbackRate
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    // MARK: - Transport controls

    public func play() {
        guard player.currentItem != nil else { return }
        player.rate = playbackRate
        isPlaying = true
        setupLoopObserver()
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to time: TimeInterval) {
        let upperBound = duration > 0 ? duration : max(0, time)
        let clampedTime = min(max(0, time), upperBound)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clampedTime
    }

    // MARK: - Loop observer

    private func setupLoopObserver() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loopEnabled else { return }
                self.seek(to: 0)
                self.player.rate = self.playbackRate
            }
        }
    }

    // MARK: - Time observer

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = time.seconds
            }
        }
    }
}
