import Foundation
import AVFoundation
import CoreMedia

/// Extracts audio for transcription upload.
/// - Passthrough path: if the source audio is already compressed mono at a
///   reasonable bitrate, copies the track as-is via AVAssetExportSession.
///   Skips decode/resample/re-encode — much faster, identical accuracy since
///   Deepgram resamples internally.
/// - Re-encode path: falls back to AAC mono 16 kHz @ 48 kbps via
///   AVAssetReader/Writer for stereo, high-bitrate, or PCM sources.
public struct AudioExtractor: Sendable {

    /// Max source audio bitrate (bits/sec) eligible for passthrough. Above this
    /// the upload savings from re-encode outweigh the extraction cost.
    private static let passthroughBitrateCeiling: Float = 160_000

    public init() {}

    public func extractAudio(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioExtractorError.noAudioTrack
        }

        if try await canPassthrough(track: audioTrack) {
            return try await passthroughExtract(asset: asset)
        }

        return try await reencode(asset: asset, audioTrack: audioTrack)
    }

    // MARK: - Passthrough

    /// Returns true if the source audio track is already a compressed mono
    /// stream at or below the bitrate ceiling — Deepgram's internal resampler
    /// handles everything else.
    private func canPassthrough(track: AVAssetTrack) async throws -> Bool {
        let descriptions = try await track.load(.formatDescriptions)
        guard let desc = descriptions.first else { return false }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return false
        }

        // Must already be compressed (PCM would make the file huge).
        let compressedFormats: Set<AudioFormatID> = [
            kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
            kAudioFormatMPEGLayer3, kAudioFormatOpus,
        ]
        guard compressedFormats.contains(asbd.mFormatID) else { return false }
        guard asbd.mChannelsPerFrame == 1 else { return false }

        let bitrate = try await track.load(.estimatedDataRate)
        return bitrate > 0 && bitrate <= Self.passthroughBitrateCeiling
    }

    private func passthroughExtract(asset: AVURLAsset) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription_\(UUID().uuidString).m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioExtractorError.exportSessionFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a

        await session.export()

        guard session.status == .completed else {
            throw AudioExtractorError.exportFailed(session.error?.localizedDescription ?? "passthrough failed")
        }
        return outputURL
    }

    // MARK: - Re-encode

    private func reencode(asset: AVURLAsset, audioTrack: AVAssetTrack) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription_\(UUID().uuidString).m4a")

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        guard reader.canAdd(readerOutput) else {
            throw AudioExtractorError.exportSessionFailed
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioExtractorError.exportSessionFailed
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw AudioExtractorError.exportFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            throw AudioExtractorError.exportFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        let queue = DispatchQueue(label: "audio-extractor.encode")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            continuation.resume(throwing: AudioExtractorError.exportFailed(
                                writer.error?.localizedDescription ?? "append failed"
                            ))
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            continuation.resume(throwing: AudioExtractorError.exportFailed(
                                reader.error?.localizedDescription ?? "reader failed"
                            ))
                        } else {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AudioExtractorError.exportFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }

        return outputURL
    }

    public func cleanup(tempURL: URL) {
        try? FileManager.default.removeItem(at: tempURL)
    }
}

public enum AudioExtractorError: Error, LocalizedError {
    case noAudioTrack
    case exportSessionFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "No audio track found in media"
        case .exportSessionFailed: "Could not create audio export session"
        case .exportFailed(let msg): "Audio extraction failed: \(msg)"
        }
    }
}
