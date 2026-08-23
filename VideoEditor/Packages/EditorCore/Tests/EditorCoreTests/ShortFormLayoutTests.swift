import Testing
import Foundation
import CoreImage
import CoreGraphics
@testable import EditorCore

@Suite("Short-Form Layout Renderer Tests")
struct ShortFormLayoutTests {

    // MARK: - Helpers

    /// Create a synthetic 1920x1080 test image with left half red, right half blue.
    /// Simulates a two-person podcast frame.
    func makeTestSourceImage() -> CIImage {
        let w = 1920
        let h = 1080
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("Failed to create context") }

        // Left half: red (Person A)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))

        // Right half: blue (Person B)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))

        let cgImage = ctx.makeImage()!
        return CIImage(cgImage: cgImage)
    }

    func makeConfig(layout: ShortFormLayout = .split) -> ShortFormConfig {
        ShortFormConfig(
            isEnabled: true,
            outputAspect: .vertical9x16,
            faceTracks: [
                FaceTrack(samples: [
                    FaceSample(time: 0, center: CGPoint(x: 0.25, y: 0.45), size: 0.15)
                ]),
                FaceTrack(samples: [
                    FaceSample(time: 0, center: CGPoint(x: 0.75, y: 0.45), size: 0.15)
                ]),
            ],
            speakerToFace: [0: 0, 1: 1],
            layoutSegments: [LayoutSegment(startTime: 0, layout: layout)]
        )
    }

    /// Sample a pixel color from a CIImage at a given point.
    func sampleColor(from image: CIImage, at point: CGPoint) -> (r: Float, g: Float, b: Float) {
        let ctx = CIContext()
        var bitmap = [UInt8](repeating: 0, count: 4)
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        ctx.render(image, toBitmap: &bitmap, rowBytes: 4, bounds: rect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (r: Float(bitmap[0]) / 255, g: Float(bitmap[1]) / 255, b: Float(bitmap[2]) / 255)
    }

    // MARK: - Split Layout Tests

    @Test("Split layout produces 1080x1920 output")
    func splitOutputSize() {
        let source = makeTestSourceImage()
        let config = makeConfig(layout: .split)
        let renderSize = CGSize(width: 1080, height: 1920)

        let result = ShortFormLayoutRenderer.recompose(
            source: source, config: config, at: 0, renderSize: renderSize
        )

        // Output should cover the full render size
        #expect(result.extent.width >= 1080)
        #expect(result.extent.height >= 1920)
    }

    @Test("Split layout has red in top half, blue in bottom half")
    func splitColorRegions() {
        let source = makeTestSourceImage()
        let config = makeConfig(layout: .split)
        let renderSize = CGSize(width: 1080, height: 1920)

        let result = ShortFormLayoutRenderer.recompose(
            source: source, config: config, at: 0, renderSize: renderSize
        )

        // Sample top region (should be red — Person A from left half)
        let topColor = sampleColor(from: result, at: CGPoint(x: 540, y: 1500))
        #expect(topColor.r > 0.5, "Top region should be red (Person A)")
        #expect(topColor.b < 0.3, "Top region should not be blue")

        // Sample bottom region (should be blue — Person B from right half)
        let bottomColor = sampleColor(from: result, at: CGPoint(x: 540, y: 500))
        #expect(bottomColor.b > 0.5, "Bottom region should be blue (Person B)")
        #expect(bottomColor.r < 0.3, "Bottom region should not be red")
    }

    @Test("Split layout tiles fill full height — no black caption gap at bottom")
    func splitNoBlackCaptionGap() {
        let source = makeTestSourceImage()
        let config = makeConfig(layout: .split)
        let renderSize = CGSize(width: 1080, height: 1920)

        let result = ShortFormLayoutRenderer.recompose(
            source: source, config: config, at: 0, renderSize: renderSize
        )

        // Bottom tile should now reach y=0 (no reserved black caption area).
        // Sample near the very bottom — should contain video content (not solid black).
        let bottomColor = sampleColor(from: result, at: CGPoint(x: 540, y: 30))
        let isAllBlack = bottomColor.r < 0.01 && bottomColor.g < 0.01 && bottomColor.b < 0.01
        #expect(!isAllBlack, "Bottom of frame should contain video content, not a black caption gap")
    }

    // MARK: - Fill Layout Tests

    @Test("Fill layout produces 1080x1920 output")
    func fillOutputSize() {
        let source = makeTestSourceImage()
        let config = makeConfig(layout: .fill(activeSpeaker: 0))
        let renderSize = CGSize(width: 1080, height: 1920)

        let result = ShortFormLayoutRenderer.recompose(
            source: source, config: config, at: 0, renderSize: renderSize
        )

        #expect(result.extent.width >= 1080)
        #expect(result.extent.height >= 1920)
    }

    @Test("Fill layout with speaker 0 keeps split sizing with speaker 0 on top")
    func fillSpeaker0() {
        let source = makeTestSourceImage()
        let config = makeConfig(layout: .fill(activeSpeaker: 0))
        let renderSize = CGSize(width: 1080, height: 1920)

        let result = ShortFormLayoutRenderer.recompose(
            source: source, config: config, at: 0, renderSize: renderSize
        )

        let topColor = sampleColor(from: result, at: CGPoint(x: 540, y: 1440))
        let bottomColor = sampleColor(from: result, at: CGPoint(x: 540, y: 480))
        #expect(topColor.r > 0.5, "Speaker 0 should be on top")
        #expect(bottomColor.b > 0.5, "Speaker 1 should remain visible on bottom")
    }

    @Test("Fill layout with speaker 1 keeps split sizing with speaker 1 on top")
    func fillSpeaker1() {
        let source = makeTestSourceImage()
        let config = makeConfig(layout: .fill(activeSpeaker: 1))
        let renderSize = CGSize(width: 1080, height: 1920)

        let result = ShortFormLayoutRenderer.recompose(
            source: source, config: config, at: 0, renderSize: renderSize
        )

        let topColor = sampleColor(from: result, at: CGPoint(x: 540, y: 1440))
        let bottomColor = sampleColor(from: result, at: CGPoint(x: 540, y: 480))
        #expect(topColor.b > 0.5, "Speaker 1 should be on top")
        #expect(bottomColor.r > 0.5, "Speaker 0 should remain visible on bottom")
    }

    // MARK: - Face Tracking Tests

    @Test("Face position interpolation between samples")
    func faceInterpolation() {
        let track = FaceTrack(samples: [
            FaceSample(time: 0, center: CGPoint(x: 0.2, y: 0.4), size: 0.1),
            FaceSample(time: 1, center: CGPoint(x: 0.3, y: 0.6), size: 0.1),
        ])

        // At t=0.5, should be halfway between samples
        let mid = track.interpolatedCenter(at: 0.5)!
        #expect(abs(mid.x - 0.25) < 0.01, "X should interpolate to 0.25")
        #expect(abs(mid.y - 0.5) < 0.01, "Y should interpolate to 0.5")

        // At t=0, should be first sample
        let start = track.interpolatedCenter(at: 0)!
        #expect(abs(start.x - 0.2) < 0.01)

        // At t=1, should be last sample
        let end = track.interpolatedCenter(at: 1)!
        #expect(abs(end.x - 0.3) < 0.01)

        // Before first sample, clamp to first
        let before = track.interpolatedCenter(at: -1)!
        #expect(abs(before.x - 0.2) < 0.01)
    }

    @Test("Layout selection by time")
    func layoutAtTime() {
        let config = ShortFormConfig(
            isEnabled: true,
            layoutSegments: [
                LayoutSegment(startTime: 0, layout: .split),
                LayoutSegment(startTime: 10, layout: .fill(activeSpeaker: 0)),
                LayoutSegment(startTime: 20, layout: .split),
            ]
        )

        let l0 = config.layoutAt(time: 5)
        #expect(l0 == .split)

        let l1 = config.layoutAt(time: 15)
        #expect(l1 == .fill(activeSpeaker: 0))

        let l2 = config.layoutAt(time: 25)
        #expect(l2 == .split)
    }

    // MARK: - Config Tests

    @Test("ShortFormConfig defaults")
    func configDefaults() {
        let config = ShortFormConfig.empty
        #expect(config.isEnabled == false)
        #expect(config.outputAspect == .vertical9x16)
        #expect(config.faceTracks.isEmpty)
        #expect(config.layoutSegments.isEmpty)
    }

    @Test("OutputAspect sizes are correct")
    func aspectSizes() {
        #expect(OutputAspect.vertical9x16.size == CGSize(width: 1080, height: 1920))
        #expect(OutputAspect.square1x1.size == CGSize(width: 1080, height: 1080))
        #expect(OutputAspect.portrait4x5.size == CGSize(width: 1080, height: 1350))
    }
}
