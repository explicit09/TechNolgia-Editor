import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailCandidatesError: Error, CustomStringConvertible {
    case noFramesExtracted(attempted: Int)

    public var description: String {
        switch self {
        case .noFramesExtracted(let n):
            return "Failed to extract any thumbnail frames (attempted \(n))"
        }
    }
}

/// Produces N post-composition 9:16 JPG frames across a source time range.
/// Uses the same ShortFormLayoutRenderer the final video uses, so frames match
/// exactly what iOS will composite the pill+logo on top of.
public struct ThumbnailCandidates {
    /// Produce `count` JPG frames evenly spaced in [sourceStart, sourceEnd].
    /// Returns an array of (time, jpgData) tuples, index 0 = earliest.
    public static func extract(
        sourceURL: URL,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        shortFormConfig: ShortFormConfig,
        count: Int = 10,
        outputSize: CGSize = CGSize(width: 1080, height: 1920),
        jpegQuality: CGFloat = 0.80
    ) async throws -> [(time: TimeInterval, data: Data)] {
        precondition(count > 0)
        precondition(sourceEnd > sourceStart)

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        let ciContext = CIContext()
        var results: [(TimeInterval, Data)] = []

        for i in 0..<count {
            let fraction = (Double(i) + 0.5) / Double(count)
            let t = sourceStart + (sourceEnd - sourceStart) * fraction
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)

            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: cmTime).image
            } catch {
                continue
            }

            // Apply the same 9:16 composition the video uses
            let sourceCI = CIImage(cgImage: cgImage)
            let composed = ShortFormLayoutRenderer.recompose(
                source: sourceCI,
                config: shortFormConfig,
                at: t,
                renderSize: outputSize
            )

            // Render to CGImage at outputSize
            let rect = CGRect(origin: .zero, size: outputSize)
            guard let composedCG = ciContext.createCGImage(composed, from: rect) else { continue }

            // Encode as JPEG
            guard let jpgData = encodeJPEG(composedCG, quality: jpegQuality) else { continue }
            results.append((t, jpgData))
        }

        if results.isEmpty {
            throw ThumbnailCandidatesError.noFramesExtracted(attempted: count)
        }

        return results
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
