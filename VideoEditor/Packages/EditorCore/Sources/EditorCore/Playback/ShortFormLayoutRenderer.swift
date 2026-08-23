import Foundation
import CoreImage
import CoreGraphics

/// Recomposes a 16:9 source frame into a vertical short-form layout.
/// Called by EffectCompositor BEFORE effects/overlays are applied.
///
/// Layouts:
/// - Split: two speakers stacked, each face-tracked from source halves
/// - Fill: single speaker cropped to fill entire output
/// - Sidebar: active speaker 2/3, other 1/3
public struct ShortFormLayoutRenderer {

    /// Recompose a source frame into the target layout.
    /// Returns a new CIImage at renderSize with the layout applied.
    public static func recompose(
        source: CIImage,
        config: ShortFormConfig,
        at time: TimeInterval,
        renderSize: CGSize
    ) -> CIImage {
        // Layout segments use clip-relative time (0-based), but `time` is source time.
        // Subtract sourceTimeOffset to get clip-relative time for layout lookup.
        let clipTime = time - config.sourceTimeOffset
        let layout = config.layoutAt(time: clipTime)
        let sourceExtent = source.extent
        let sourceW = sourceExtent.width
        let sourceH = sourceExtent.height

        switch layout {
        case .split:
            return renderSplit(
                source: source, sourceW: sourceW, sourceH: sourceH,
                config: config, time: time, renderSize: renderSize
            )
        case .fill(let activeSpeaker):
            return renderSplit(
                source: source, sourceW: sourceW, sourceH: sourceH,
                config: config, time: time, renderSize: renderSize,
                topSpeaker: activeSpeaker
            )
        case .sidebar(let activeSpeaker):
            return renderSidebar(
                source: source, sourceW: sourceW, sourceH: sourceH,
                config: config, time: time, renderSize: renderSize,
                activeSpeaker: activeSpeaker
            )
        }
    }
}

// MARK: - Split Layout

extension ShortFormLayoutRenderer {

    /// Two speakers stacked vertically, each cropped from their half of the source.
    static func renderSplit(
        source: CIImage, sourceW: CGFloat, sourceH: CGFloat,
        config: ShortFormConfig, time: TimeInterval, renderSize: CGSize,
        topSpeaker: Int = 0
    ) -> CIImage {
        let divider = config.dividerWidth * (renderSize.height / 1920)
        let availableH = renderSize.height
        let regionH = (availableH - divider) / 2
        let halfW = sourceW / 2

        // Face positions (normalized 0-1)
        let faceA = config.faceCenterAt(faceIndex: 0, time: time)
            ?? CGPoint(x: 0.25, y: 0.5) // Default: center of left half
        let faceB = config.faceCenterAt(faceIndex: 1, time: time)
            ?? CGPoint(x: 0.75, y: 0.5) // Default: center of right half

        // Crop region for person A (left half of source)
        let cropA = computeFaceCrop(
            faceCenter: CGPoint(x: faceA.x * 2, y: faceA.y), // Normalize within left half (0-1)
            halfWidth: halfW, sourceHeight: sourceH,
            targetAspect: renderSize.width / regionH
        )
        let sourceRectA = CGRect(
            x: cropA.origin.x,
            y: sourceH - cropA.origin.y - cropA.height, // CIImage y is flipped
            width: cropA.width,
            height: cropA.height
        )

        // Crop region for person B (right half of source)
        let cropB = computeFaceCrop(
            faceCenter: CGPoint(x: (faceB.x - 0.5) * 2, y: faceB.y), // Normalize within right half
            halfWidth: halfW, sourceHeight: sourceH,
            targetAspect: renderSize.width / regionH
        )
        let sourceRectB = CGRect(
            x: halfW + cropB.origin.x,
            y: sourceH - cropB.origin.y - cropB.height,
            width: cropB.width,
            height: cropB.height
        )

        func scaledHalf(sourceRect: CGRect, yOffset: CGFloat) -> CIImage {
            let cropped = source.cropped(to: sourceRect)
            let scaleX = renderSize.width / sourceRect.width
            let scaleY = regionH / sourceRect.height
            return cropped
                .transformed(by: CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: 0, y: yOffset))
        }

        let topRect: CGRect
        let bottomRect: CGRect
        if topSpeaker == 1 {
            topRect = sourceRectB
            bottomRect = sourceRectA
        } else {
            topRect = sourceRectA
            bottomRect = sourceRectB
        }

        let scaledTop = scaledHalf(sourceRect: topRect, yOffset: regionH + divider)
        let scaledBottom = scaledHalf(sourceRect: bottomRect, yOffset: 0)

        // Black background
        let bg = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))

        // Divider line (dark gray)
        let dividerY = regionH
        let dividerImage = CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15))
            .cropped(to: CGRect(x: 0, y: dividerY, width: renderSize.width, height: divider))

        // Composite: bg → bottom speaker → divider → top speaker
        return scaledTop
            .composited(over: dividerImage
                .composited(over: scaledBottom
                    .composited(over: bg)))
    }

    /// Compute a crop rect within a half-frame, centered on a face.
    /// faceCenter is normalized 0-1 within the half.
    private static func computeFaceCrop(
        faceCenter: CGPoint, halfWidth: CGFloat, sourceHeight: CGFloat,
        targetAspect: CGFloat
    ) -> CGRect {
        // Use full width of the half, compute height from target aspect
        let cropW = halfWidth
        let cropH = cropW / targetAspect

        // Center vertically on face, clamp to bounds
        let facePxY = faceCenter.y * sourceHeight
        var cropY = facePxY - cropH / 2
        cropY = max(0, min(cropY, sourceHeight - cropH))

        return CGRect(x: 0, y: cropY, width: cropW, height: cropH)
    }
}

// MARK: - Fill Layout

extension ShortFormLayoutRenderer {

    /// Single speaker fills the entire output frame.
    static func renderFill(
        source: CIImage, sourceW: CGFloat, sourceH: CGFloat,
        config: ShortFormConfig, time: TimeInterval, renderSize: CGSize,
        activeSpeaker: Int
    ) -> CIImage {
        let face = config.faceCenterAt(faceIndex: activeSpeaker, time: time)
            ?? CGPoint(x: 0.5, y: 0.5)

        // For 9:16 output from 16:9 source: crop a narrow vertical strip
        let targetAspect = renderSize.width / renderSize.height // 0.5625 for 9:16
        let cropW = sourceH * targetAspect // Width needed at source height
        let cropH = sourceH

        // Center horizontally on face
        let facePxX = face.x * sourceW
        var cropX = facePxX - cropW / 2
        cropX = max(0, min(cropX, sourceW - cropW))

        // Center vertically on face
        let facePxY = face.y * sourceH
        var cropY = facePxY - cropH / 2
        cropY = max(0, min(cropY, sourceH - cropH))

        let sourceRect = CGRect(
            x: cropX,
            y: sourceH - cropY - cropH, // CIImage y flip
            width: cropW,
            height: cropH
        )

        let cropped = source.cropped(to: sourceRect)
        let scaleX = renderSize.width / cropW
        let scaleY = renderSize.height / cropH

        return cropped
            .transformed(by: CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}

// MARK: - Sidebar Layout

extension ShortFormLayoutRenderer {

    /// Active speaker takes 2/3 of frame, other takes 1/3.
    static func renderSidebar(
        source: CIImage, sourceW: CGFloat, sourceH: CGFloat,
        config: ShortFormConfig, time: TimeInterval, renderSize: CGSize,
        activeSpeaker: Int
    ) -> CIImage {
        let captionH = config.captionRegionHeight * (renderSize.height / 1920)
        let availableH = renderSize.height - captionH
        let mainH = availableH * 0.65
        let secondaryH = availableH * 0.35
        let halfW = sourceW / 2

        let otherSpeaker = activeSpeaker == 0 ? 1 : 0

        let mainFace = config.faceCenterAt(faceIndex: activeSpeaker, time: time)
            ?? CGPoint(x: 0.5, y: 0.5)
        let otherFace = config.faceCenterAt(faceIndex: otherSpeaker, time: time)
            ?? CGPoint(x: otherSpeaker == 0 ? 0.25 : 0.75, y: 0.5)

        // Main speaker crop (from their half)
        let mainCenterInHalf = CGPoint(
            x: activeSpeaker == 0 ? mainFace.x * 2 : (mainFace.x - 0.5) * 2,
            y: mainFace.y
        )
        let mainCrop = computeSidebarCrop(
            faceCenter: mainCenterInHalf, halfWidth: halfW, sourceHeight: sourceH,
            targetAspect: renderSize.width / mainH, sourceXOffset: activeSpeaker == 0 ? 0 : halfW
        )

        let mainCropped = source.cropped(to: mainCrop)
        let mainScaleX = renderSize.width / mainCrop.width
        let mainScaleY = mainH / mainCrop.height
        let mainScaled = mainCropped
            .transformed(by: CGAffineTransform(translationX: -mainCrop.minX, y: -mainCrop.minY))
            .transformed(by: CGAffineTransform(scaleX: mainScaleX, y: mainScaleY))
            .transformed(by: CGAffineTransform(translationX: 0, y: secondaryH + captionH))

        // Secondary speaker crop
        let otherCenterInHalf = CGPoint(
            x: otherSpeaker == 0 ? otherFace.x * 2 : (otherFace.x - 0.5) * 2,
            y: otherFace.y
        )
        let otherCrop = computeSidebarCrop(
            faceCenter: otherCenterInHalf, halfWidth: halfW, sourceHeight: sourceH,
            targetAspect: renderSize.width / secondaryH, sourceXOffset: otherSpeaker == 0 ? 0 : halfW
        )

        let otherCropped = source.cropped(to: otherCrop)
        let otherScaleX = renderSize.width / otherCrop.width
        let otherScaleY = secondaryH / otherCrop.height
        let otherScaled = otherCropped
            .transformed(by: CGAffineTransform(translationX: -otherCrop.minX, y: -otherCrop.minY))
            .transformed(by: CGAffineTransform(scaleX: otherScaleX, y: otherScaleY))
            .transformed(by: CGAffineTransform(translationX: 0, y: captionH))

        let bg = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))

        return mainScaled
            .composited(over: otherScaled
                .composited(over: bg))
    }

    private static func computeSidebarCrop(
        faceCenter: CGPoint, halfWidth: CGFloat, sourceHeight: CGFloat,
        targetAspect: CGFloat, sourceXOffset: CGFloat
    ) -> CGRect {
        let cropW = halfWidth
        let cropH = cropW / targetAspect

        let facePxY = faceCenter.y * sourceHeight
        var cropY = facePxY - cropH / 2
        cropY = max(0, min(cropY, sourceHeight - cropH))

        // CIImage y is from bottom
        return CGRect(
            x: sourceXOffset,
            y: sourceHeight - cropY - cropH,
            width: cropW,
            height: cropH
        )
    }
}
