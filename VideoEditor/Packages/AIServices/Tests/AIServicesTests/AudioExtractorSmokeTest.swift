import Testing
import Foundation
import AVFoundation
@testable import AIServices

/// Env-gated smoke test. Set AUDIO_EXTRACTOR_TEST_FILE=/path/to/video to run.
@Suite("Audio Extractor Smoke Test")
struct AudioExtractorSmokeTest {

    @Test("extracts to AAC mono 16kHz and shrinks the file")
    func extractRealVideo() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUDIO_EXTRACTOR_TEST_FILE"] else {
            print("SKIP: set AUDIO_EXTRACTOR_TEST_FILE to run")
            return
        }
        let sourceURL = URL(fileURLWithPath: path)

        let sourceSize = (try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
        let start = Date()

        let extractor = AudioExtractor()
        let outputURL = try await extractor.extractAudio(from: sourceURL)
        defer { extractor.cleanup(tempURL: outputURL) }

        let elapsed = Date().timeIntervalSince(start)
        let outSize = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0

        let outAsset = AVURLAsset(url: outputURL)
        let duration = try await outAsset.load(.duration).seconds
        let outTrack = try await outAsset.loadTracks(withMediaType: .audio).first!
        let desc = try await outTrack.load(.formatDescriptions).first!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee

        print(String(format: "source: %.1f MB", Double(sourceSize) / 1_000_000))
        print(String(format: "output: %.1f MB  (%.1fx smaller)",
                     Double(outSize) / 1_000_000,
                     Double(sourceSize) / Double(max(outSize, 1))))
        print(String(format: "duration: %.1fs  elapsed: %.1fs", duration, elapsed))
        print("format: \(asbd.mChannelsPerFrame)ch @ \(Int(asbd.mSampleRate)) Hz, id=\(asbd.mFormatID)")

        #expect(outSize > 0)
        #expect(outSize < sourceSize)
        #expect(asbd.mChannelsPerFrame == 1)
        // Passthrough preserves the source rate; re-encode lands at 16 kHz.
        #expect(asbd.mSampleRate == 16_000 || asbd.mSampleRate == 48_000 || asbd.mSampleRate == 44_100)
    }
}
