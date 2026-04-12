import Testing
import Foundation
import AVFoundation
@testable import AIServices
@testable import EditorCore

@Suite("Transcription Service Tests")
struct TranscriptionServiceTests {

    @Test("hasTranscript ignores empty in-memory transcript arrays")
    func hasTranscriptIgnoresEmptyTranscriptArrays() async {
        let service = TranscriptionService()
        let assetName = uniqueAssetName(prefix: "Empty Audio")
        let asset = MediaAsset(
            name: assetName,
            sourceURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            type: .audio,
            duration: 5,
            analysis: MediaAnalysis(transcript: [])
        )

        let hasTranscript = await service.hasTranscript(
            for: asset,
            bundleURL: temporaryBundleURL()
        )

        #expect(hasTranscript == false)
    }

    @Test("transcribe updates media, persists transcript, and lemmatizes words for audio assets")
    func transcribePersistsAndLemmatizesAudioAssets() async throws {
        let service = TranscriptionService()
        let provider = MockTranscriptionProvider(result: TranscriptionResult(
            text: "Running fast",
            words: [TranscriptWord(word: "Running", start: 0, end: 0.5)],
            speakers: [SpeakerSegment(speakerID: "Speaker 1", range: TimeRange(start: 0, end: 0.5))],
            language: "en",
            duration: 1
        ))
        await service.configure(provider: provider)

        let assetName = uniqueAssetName(prefix: "Transcribe Audio")
        let audioFile = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }
        let asset = MediaAsset(
            name: assetName,
            sourceURL: audioFile,
            type: .audio,
            duration: 5
        )
        let mediaManager = MediaManager(assets: [asset])
        let bundleURL = temporaryBundleURL()
        let statusCollector = StatusCollector()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let result = try await service.transcribe(
            asset: asset,
            mediaManager: mediaManager,
            bundleURL: bundleURL,
            onStatus: { statusCollector.append($0) }
        )

        #expect(result?.words.first?.lemma == "run")
        #expect(result?.language == "en")
        #expect(await provider.callCount == 1)
        #expect(statusCollector.snapshot() == [
            "Preparing audio...",
            "Audio ready. Uploading to Mock...",
            "Transcribing with Mock...",
            "Processing 1 words...",
        ])

        let updatedAsset = await mediaManager.asset(id: asset.id)
        #expect(updatedAsset?.analysis?.transcript?.first?.lemma == "run")
        #expect(updatedAsset?.analysis?.speakerSegments?.count == 1)

        let persisted = await service.loadTranscript(for: asset, bundleURL: bundleURL)
        #expect(persisted?.words.first?.lemma == "run")
        #expect(persisted?.text == "Running fast")
    }

    @Test("transcribe returns cached in-memory transcripts without invoking the provider")
    func transcribeUsesCachedTranscripts() async throws {
        let service = TranscriptionService()
        let provider = MockTranscriptionProvider(result: TranscriptionResult(
            text: "Fresh transcript",
            words: [TranscriptWord(word: "Fresh", start: 0, end: 0.5)]
        ))
        await service.configure(provider: provider)

        let cachedWords = [TranscriptWord(word: "Cached", start: 0, end: 0.5)]
        let assetName = uniqueAssetName(prefix: "Cached Audio")
        let asset = MediaAsset(
            name: assetName,
            sourceURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            type: .audio,
            duration: 5,
            analysis: MediaAnalysis(transcript: cachedWords)
        )
        let mediaManager = MediaManager(assets: [asset])

        let result = try await service.transcribe(
            asset: asset,
            mediaManager: mediaManager,
            bundleURL: temporaryBundleURL()
        )

        #expect(result?.text == "Cached")
        #expect(result?.words.count == 1)
        #expect(await provider.callCount == 0)
    }

    @Test("transcribe rejects concurrent requests for the same asset while work is in progress")
    func transcribeRejectsConcurrentRequests() async throws {
        let service = TranscriptionService()
        let provider = MockTranscriptionProvider(
            result: TranscriptionResult(
                text: "Queued",
                words: [TranscriptWord(word: "Queued", start: 0, end: 0.5)]
            ),
            delayNanoseconds: 80_000_000
        )
        await service.configure(provider: provider)

        let assetName = uniqueAssetName(prefix: "Concurrent Audio")
        let audioFile = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }
        let asset = MediaAsset(
            name: assetName,
            sourceURL: audioFile,
            type: .audio,
            duration: 5
        )
        let mediaManager = MediaManager(assets: [asset])
        let bundleURL = temporaryBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let firstTask = Task {
            try await service.transcribe(asset: asset, mediaManager: mediaManager, bundleURL: bundleURL)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await service.isTranscribing(assetID: asset.id))

        let secondResult = try await service.transcribe(
            asset: asset,
            mediaManager: mediaManager,
            bundleURL: bundleURL
        )

        #expect(secondResult == nil)
        #expect(try await firstTask.value != nil)
        #expect(await service.isTranscribing(assetID: asset.id) == false)
        #expect(await provider.callCount == 1)
    }

    private func temporaryBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-bundle-\(UUID().uuidString)", isDirectory: true)
    }

    private func uniqueAssetName(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    /// Writes ~0.5 s of silent mono 44.1 kHz AAC to a temp file so tests that
    /// exercise `transcribe` have a real asset for the extractor to read.
    private func makeSilentAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-silent-\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)

        let frameCount = 22_050 // 0.5 s
        let byteCount = frameCount * 2
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: byteCount, flags: 0,
                                           blockBufferOut: &block)
        _ = bytes.withUnsafeMutableBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount) }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 2
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format, sampleCount: frameCount,
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                             sampleBufferOut: &sample)

        input.append(sample!)
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return url
    }
}

private actor MockTranscriptionProvider: TranscriptionProvider {
    nonisolated let name = "Mock"

    private(set) var callCount = 0
    private let result: TranscriptionResult
    private let delayNanoseconds: UInt64

    init(result: TranscriptionResult, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(
        audioURL: URL,
        language: String?,
        enableDiarization: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        callCount += 1
        progress(0.5)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        progress(1.0)
        return result
    }
}

private final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String] = []

    func append(_ status: String) {
        lock.lock()
        statuses.append(status)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }
}
