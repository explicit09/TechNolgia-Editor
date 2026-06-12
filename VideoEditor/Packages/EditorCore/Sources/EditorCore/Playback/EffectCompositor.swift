import Foundation
import AVFoundation
import CoreImage

/// Custom AVVideoCompositing that applies CIFilter effects per-frame.
/// Used by CompositionBuilder when clips have effects, transforms, or opacity.
public final class EffectCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    // Required properties
    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    private let renderContextLock = NSLock()
    private var _renderContext: AVVideoCompositionRenderContext?
    private var renderContext: AVVideoCompositionRenderContext? {
        renderContextLock.lock()
        defer { renderContextLock.unlock() }
        return _renderContext
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContextLock.lock()
        _renderContext = newRenderContext
        renderContextLock.unlock()
    }

    static func orderedOverlayLayers(for instruction: OverlayInstruction) -> [OverlayLayer] {
        instruction.layers
            .enumerated()
            .sorted {
                if $0.element.trackOrder != $1.element.trackOrder {
                    return $0.element.trackOrder < $1.element.trackOrder
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    // MARK: - Animation Presets

    /// Animation preset duration in seconds.
    static let animationDuration: TimeInterval = 0.4

    /// Computes the effective opacity for an overlay based on entrance/exit animation presets.
    /// Returns 1.0 when no animation applies, fades from 0-1 for entrance, 1-0 for exit.
    static func presentationOpacity(
        baseOpacity: Float,
        entrance: OverlayAnimationPreset,
        exit: OverlayAnimationPreset,
        compositionTime: TimeInterval,
        clipDuration: TimeInterval
    ) -> Float {
        guard clipDuration > 0 else { return baseOpacity }

        var factor: Float = 1.0

        // Entrance animation: fade in over animationDuration from clip start
        if entrance == .fadeIn || entrance == .scaleIn || entrance == .slideIn {
            if compositionTime < animationDuration {
                factor = min(factor, Float(compositionTime / animationDuration))
            }
        }

        // Exit animation: fade out over animationDuration before clip end
        if exit == .fadeOut || exit == .scaleOut || exit == .slideOut {
            let timeFromEnd = clipDuration - compositionTime
            if timeFromEnd < animationDuration {
                factor = min(factor, Float(timeFromEnd / animationDuration))
            }
        }

        return baseOpacity * max(factor, 0)
    }

    static func applyOverlayPresentation(_ presentation: OverlayPresentation, to image: CIImage, renderSize: CGSize) -> CIImage {
        let shouldStyle = presentation.mode == .pip
            || presentation.border.isVisible
            || presentation.shadow != .none
            || presentation.cornerRadius > 0
            || presentation.maskShape != .rectangle

        guard shouldStyle else { return image }

        let extent = image.extent.integral
        guard !extent.isEmpty else { return image }

        var result = image

        if let maskImage = Self.presentationMaskImage(for: extent, presentation: presentation, renderSize: renderSize) {
            let transparentBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
            if let blend = CIFilter(name: "CIBlendWithAlphaMask") {
                blend.setValue(result, forKey: kCIInputImageKey)
                blend.setValue(transparentBackground, forKey: kCIInputBackgroundImageKey)
                blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
                result = blend.outputImage ?? result
            }
        }

        if let borderImage = Self.presentationBorderImage(for: extent, presentation: presentation, renderSize: renderSize) {
            result = borderImage.composited(over: result)
        }

        return result
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Handle transition instructions (two sources)
        if let transInstruction = request.videoCompositionInstruction as? TransitionInstruction {
            handleTransition(request, instruction: transInstruction)
            return
        }

        // Handle multi-track overlay instructions
        if let overlayInstruction = request.videoCompositionInstruction as? OverlayInstruction {
            handleOverlay(request, instruction: overlayInstruction)
            return
        }

        guard let instruction = request.videoCompositionInstruction as? EffectInstruction else {
            request.finish(with: NSError(domain: "EffectCompositor", code: -1))
            return
        }

        // Get the source frame
        guard let trackID = Self.sourceTrackID(from: instruction.requiredSourceTrackIDs),
              let sourceBuffer = request.sourceFrame(byTrackID: trackID) else {
            // No source — render background color frame (not uninitialized buffer)
            let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
            var image = CIImage(color: instruction.backgroundColor).cropped(to: CGRect(origin: .zero, size: renderSize))

            // Still render overlay on black gaps (overlay should appear even with no video)
            if let overlay = instruction.broadcastOverlay, overlay.isEnabled {
                let time = request.compositionTime.seconds
                if let overlayImage = BroadcastOverlayRenderer.render(config: overlay, at: time, renderSize: renderSize) {
                    image = overlayImage.composited(over: image)
                }
            }

            if let outputBuffer = renderContext?.newPixelBuffer() {
                ciContext.render(image, to: outputBuffer)
                request.finish(withComposedVideoFrame: outputBuffer)
            } else {
                request.finish(with: NSError(domain: "EffectCompositor", code: -2))
            }
            return
        }

        var image = CIImage(cvPixelBuffer: sourceBuffer)

        // Short-form layout recomposition — BEFORE effects
        // Restructures 16:9 source into 9:16 with speakers stacked
        if let sfConfig = instruction.shortFormConfig, sfConfig.isEnabled {
            let renderSize = renderContext?.size ?? CGSize(width: 1080, height: 1920)
            // Map timeline time → source time for face position lookups
            let sourceTime = request.compositionTime.seconds + sfConfig.sourceTimeOffset
            image = ShortFormLayoutRenderer.recompose(
                source: image, config: sfConfig, at: sourceTime, renderSize: renderSize
            )
        } else {
            image = Self.applyCropRect(instruction.cropRect, to: image)
        }

        // Apply effects in order
        for effect in instruction.effects {
            image = applyEffect(effect, to: image)
        }

        let compositionTime = request.compositionTime.seconds
        let resolvedOpacity = Self.resolvedOpacity(
            baseOpacity: instruction.opacity,
            keyframes: instruction.keyframes,
            compositionTime: compositionTime,
            clipStartTime: instruction.clipStartTime
        )
        let resolvedTransform = Self.resolvedTransform(
            baseTransform: instruction.transform,
            keyframes: instruction.keyframes,
            compositionTime: compositionTime,
            clipStartTime: instruction.clipStartTime
        )

        // Apply opacity
        if resolvedOpacity < 1.0 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(resolvedOpacity)),
            ])
        }

        // Apply transform
        if resolvedTransform != .identity {
            let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
            image = Self.applyTransform(resolvedTransform, to: image, renderSize: renderSize)
        }

        // Render subtitles / captions
        let isShortForm = instruction.shortFormConfig?.isEnabled == true
        let sfCaptionWords = instruction.shortFormConfig?.captionWords ?? []

        // Collect word-level data for styled captions.
        // NOTE: 16:9 captions require CompositionBuilder to populate captionWords on
        // EffectInstruction, which currently only happens via shortFormConfig. Threading
        // transcript words through CompositionBuilder for 16:9 is a larger change.
        var allCaptionWords = instruction.captionWords
        if allCaptionWords.isEmpty && !sfCaptionWords.isEmpty {
            let sourceOffset = instruction.shortFormConfig?.sourceTimeOffset ?? 0
            allCaptionWords = sfCaptionWords.map {
                TranscriptWord(word: $0.word, lemma: $0.lemma, start: $0.start - sourceOffset, end: $0.end - sourceOffset, confidence: $0.confidence)
            }
        }

        // Use CaptionStyler when we have word-level data and captions are enabled
        let captionStyle = instruction.captionStyle
        if captionStyle != .none && !allCaptionWords.isEmpty {
            let time = request.compositionTime.seconds
            let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
            let fontSize = isShortForm ? renderSize.height * 0.028 : max(renderSize.height * 0.04, 18)

            // Find visible words for this time (window of ~5 words around active)
            let activeIdx = CaptionStyler.activeWordIndex(at: time, words: allCaptionWords)
            if let idx = activeIdx {
                // Compute word progress (0-1 within active word)
                let activeWord = allCaptionWords[idx]
                let wordDuration = activeWord.end - activeWord.start
                let wordProgress = wordDuration > 0 ? Float((time - activeWord.start) / wordDuration) : 0

                // Hormozi = single word. Karaoke = phrase-grouped (stable until phrase ends).
                // Other styles = sliding window of ~5.
                let windowStart: Int
                let windowEnd: Int
                if captionStyle == .hormozi {
                    windowStart = idx
                    windowEnd = idx + 1
                } else if captionStyle == .karaoke {
                    let phrases = CaptionStyler.groupIntoPhrases(allCaptionWords)
                    if let phrase = phrases.first(where: { $0.range.contains(idx) }) {
                        windowStart = phrase.startIndex
                        windowEnd = phrase.endIndex
                    } else {
                        windowStart = idx
                        windowEnd = idx + 1
                    }
                } else {
                    windowStart = max(0, idx - 2)
                    windowEnd = min(allCaptionWords.count, idx + 3)
                }
                let visibleWords = Array(allCaptionWords[windowStart..<windowEnd])
                let text = visibleWords.map(\.word).joined(separator: " ")
                let localActiveIdx = idx - windowStart
                let captionPlacement: CaptionStyler.CaptionPlacement = {
                    if captionStyle == .karaoke {
                        return .bottom
                    }
                    guard isShortForm, let config = instruction.shortFormConfig else {
                        return .bottom
                    }
                    switch config.layoutAt(time: time) {
                    case .split:
                        return .centerBridge
                    case .fill, .sidebar:
                        return .bottom
                    }
                }()

                if let captionImage = CaptionStyler.renderCaption(
                    text: text,
                    activeWordIndex: localActiveIdx,
                    style: captionStyle,
                    size: renderSize,
                    fontSize: fontSize,
                    wordProgress: wordProgress,
                    placement: captionPlacement
                ) {
                    let ciCaption = CIImage(cgImage: captionImage)
                    image = ciCaption.composited(over: image)
                }

                // Progress bar for short-form
                if isShortForm, let firstWord = allCaptionWords.first, let lastWord = allCaptionWords.last {
                    let totalProgress = Float((time - firstWord.start) / (lastWord.end - firstWord.start))
                    if let barImage = CaptionStyler.renderProgressBar(
                        progress: max(0, min(1, totalProgress)),
                        size: renderSize,
                        barColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)
                    ) {
                        let ciBar = CIImage(cgImage: barImage)
                        image = ciBar.composited(over: image)
                    }
                }
            }
        } else if captionStyle != .none {
            // Fallback: standard SubtitleRenderer for grouped text
            var subtitleEntries = instruction.subtitles
            if subtitleEntries.isEmpty && !allCaptionWords.isEmpty {
                subtitleEntries = SubtitleRenderer.groupWordsIntoSubtitles(allCaptionWords, wordsPerLine: 5)
            }

            if !subtitleEntries.isEmpty {
                let time = request.compositionTime.seconds
                let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
                let captionMargin: CGFloat? = isShortForm ? renderSize.height * 0.03 : nil
                let captionFontSize: CGFloat? = isShortForm ? renderSize.height * 0.028 : nil

                image = SubtitleRenderer.render(
                    subtitles: subtitleEntries,
                    at: time,
                    onto: image,
                    renderSize: renderSize,
                    bottomMarginOverride: captionMargin,
                    fontSizeOverride: captionFontSize
                )
            }
        }

        // Render broadcast overlay if configured
        if let overlay = instruction.broadcastOverlay, overlay.isEnabled {
            let time = request.compositionTime.seconds
            let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
            if let overlayImage = BroadcastOverlayRenderer.render(
                config: overlay, at: time, renderSize: renderSize
            ) {
                image = overlayImage.composited(over: image)
            }
        }

        // Apply blend mode (composites against background for single-clip)
        let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
        if instruction.blendMode != .normal {
            let background = CIImage(color: instruction.backgroundColor).cropped(to: CGRect(origin: .zero, size: renderSize))
            if let blendFilter = CIFilter(name: instruction.blendMode.ciFilterName) {
                blendFilter.setValue(background, forKey: kCIInputBackgroundImageKey)
                blendFilter.setValue(image, forKey: kCIInputImageKey)
                if let blended = blendFilter.outputImage {
                    image = blended
                }
            }
        }

        image = Self.fitToRenderFrame(image, renderSize: renderSize, backgroundColor: instruction.backgroundColor)

        // Render to output buffer
        guard let outputBuffer = renderContext?.newPixelBuffer() else {
            request.finish(with: NSError(domain: "EffectCompositor", code: -3))
            return
        }

        ciContext.render(image, to: outputBuffer, bounds: CGRect(origin: .zero, size: renderSize), colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    public func cancelAllPendingVideoCompositionRequests() {
        // No-op: synchronous processing
    }

    static func sourceTrackID(from requiredSourceTrackIDs: [NSValue]?) -> CMPersistentTrackID? {
        guard let first = requiredSourceTrackIDs?.first else { return nil }

        if let number = first as? NSNumber {
            let trackID = CMPersistentTrackID(number.int32Value)
            return trackID == kCMPersistentTrackID_Invalid ? nil : trackID
        }

        return nil
    }

    static func applyCropRect(_ cropRect: CropRect, to image: CIImage) -> CIImage {
        let clampedCrop = cropRect.clamped
        guard !clampedCrop.isFullFrame else { return image }

        let extent = image.extent.integral
        let cropBounds = CGRect(
            x: extent.minX + (extent.width * clampedCrop.x),
            y: extent.minY + (extent.height * clampedCrop.y),
            width: extent.width * clampedCrop.width,
            height: extent.height * clampedCrop.height
        ).intersection(extent)

        guard !cropBounds.isEmpty else { return image }

        let cropped = image.cropped(to: cropBounds)
        let normalized = cropped.transformed(
            by: CGAffineTransform(translationX: -cropBounds.minX, y: -cropBounds.minY)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: extent.width / cropBounds.width,
                y: extent.height / cropBounds.height
            )
        )
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    static func composite(
        _ sourceImage: CIImage,
        over backgroundImage: CIImage,
        blendMode: BlendMode,
        opacity: Float
    ) -> CIImage {
        let resolvedSource: CIImage
        if opacity < 1.0 {
            resolvedSource = sourceImage.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
            ])
        } else {
            resolvedSource = sourceImage
        }

        if blendMode != .normal, let blendFilter = CIFilter(name: blendMode.ciFilterName) {
            blendFilter.setValue(backgroundImage, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(resolvedSource, forKey: kCIInputImageKey)
            if let blended = blendFilter.outputImage {
                return blended
            }
        }

        return resolvedSource.composited(over: backgroundImage)
    }

    static func presentationMaskImage(
        for extent: CGRect,
        presentation: OverlayPresentation,
        renderSize: CGSize
    ) -> CIImage? {
        let width = max(Int(ceil(extent.width)), 1)
        let height = max(Int(ceil(extent.height)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(Self.presentationPath(
            for: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            presentation: presentation,
            renderSize: renderSize
        ))
        context.fillPath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    static func presentationBorderImage(
        for extent: CGRect,
        presentation: OverlayPresentation,
        renderSize: CGSize
    ) -> CIImage? {
        guard presentation.border.isVisible, presentation.border.width > 0 else { return nil }

        let width = max(Int(ceil(extent.width)), 1)
        let height = max(Int(ceil(extent.height)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let borderColor = OverlayStyle.parseHex(presentation.border.colorHex)
        context.setStrokeColor(CGColor(red: borderColor.r, green: borderColor.g, blue: borderColor.b, alpha: 1))
        context.setLineWidth(CGFloat(presentation.border.width))
        context.setLineJoin(.round)

        let inset = CGFloat(presentation.border.width) / 2
        let rect = CGRect(
            x: inset,
            y: inset,
            width: CGFloat(width) - CGFloat(presentation.border.width),
            height: CGFloat(height) - CGFloat(presentation.border.width)
        )
        context.addPath(Self.presentationPath(for: rect, presentation: presentation, renderSize: renderSize))
        context.strokePath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    static func presentationPath(
        for rect: CGRect,
        presentation: OverlayPresentation,
        renderSize: CGSize
    ) -> CGPath {
        let radius = Self.presentationCornerRadius(for: presentation, renderSize: renderSize, rect: rect)

        switch presentation.maskShape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedRect:
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .rectangle:
            if radius > 0 {
                return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            return CGPath(rect: rect, transform: nil)
        }
    }

    static func presentationCornerRadius(
        for presentation: OverlayPresentation,
        renderSize: CGSize,
        rect: CGRect
    ) -> CGFloat {
        let maxRadius = min(rect.width, rect.height) / 2

        if presentation.cornerRadius > 0 {
            return min(CGFloat(presentation.cornerRadius), maxRadius)
        }

        if presentation.maskShape == .roundedRect {
            let defaultRadius = max(8, min(renderSize.width, renderSize.height) * 0.015)
            return min(defaultRadius, maxRadius)
        }

        return 0
    }

    static func applyTransform(_ transform: Transform2D, to image: CIImage, renderSize: CGSize) -> CIImage {
        guard transform != .identity else { return image }

        let anchorPoint = CGPoint(
            x: renderSize.width * CGFloat(transform.anchorX),
            y: renderSize.height * CGFloat(transform.anchorY)
        )

        return image
            .transformed(by: CGAffineTransform(translationX: -anchorPoint.x, y: -anchorPoint.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(transform.scaleX), y: CGFloat(transform.scaleY)))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(transform.rotation) * .pi / 180))
            .transformed(by: CGAffineTransform(
                translationX: anchorPoint.x + CGFloat(transform.positionX),
                y: anchorPoint.y + CGFloat(transform.positionY)
            ))
    }

    static func resolvedTransform(
        baseTransform: Transform2D,
        keyframes: KeyframeStore,
        compositionTime: TimeInterval,
        clipStartTime: TimeInterval
    ) -> Transform2D {
        guard !keyframes.tracks.isEmpty else { return baseTransform }

        let localTime = max(0, compositionTime - clipStartTime)
        let interpolator = KeyframeInterpolator()
        var resolved = baseTransform

        if let track = keyframes.tracks["positionX"], let value = interpolator.value(at: localTime, keyframes: track) {
            resolved.positionX = value
        }
        if let track = keyframes.tracks["positionY"], let value = interpolator.value(at: localTime, keyframes: track) {
            resolved.positionY = value
        }
        if let track = keyframes.tracks["scaleX"], let value = interpolator.value(at: localTime, keyframes: track) {
            resolved.scaleX = value
        }
        if let track = keyframes.tracks["scaleY"], let value = interpolator.value(at: localTime, keyframes: track) {
            resolved.scaleY = value
        }
        if let track = keyframes.tracks["rotation"], let value = interpolator.value(at: localTime, keyframes: track) {
            resolved.rotation = value
        }

        return resolved
    }

    static func resolvedOpacity(
        baseOpacity: Float,
        keyframes: KeyframeStore,
        compositionTime: TimeInterval,
        clipStartTime: TimeInterval
    ) -> Float {
        let clampedBase = Float(min(max(Double(baseOpacity), 0), 1))
        guard let track = keyframes.tracks["opacity"], !track.isEmpty else { return clampedBase }

        let localTime = max(0, compositionTime - clipStartTime)
        let interpolator = KeyframeInterpolator()
        guard let value = interpolator.value(at: localTime, keyframes: track) else { return clampedBase }

        return Float(Double(clampedBase) * min(max(value, 0), 1))
    }

    static func fitToRenderFrame(_ image: CIImage, renderSize: CGSize, backgroundColor: CIColor = .black) -> CIImage {
        let renderRect = CGRect(origin: .zero, size: renderSize)
        let background = CIImage(color: backgroundColor).cropped(to: renderRect)
        return image.composited(over: background).cropped(to: renderRect)
    }

    static func scaleToFillRenderFrame(_ image: CIImage, renderSize: CGSize) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, renderSize.width > 0, renderSize.height > 0 else {
            return image
        }

        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = max(renderSize.width / extent.width, renderSize.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let centered = normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (renderSize.width - scaledWidth) / 2,
                y: (renderSize.height - scaledHeight) / 2
            ))
        return centered.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    // MARK: - Transition Handling

    private func handleTransition(_ request: AVAsynchronousVideoCompositionRequest, instruction: TransitionInstruction) {
        let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)

        // Calculate transition progress (0 = start, 1 = end)
        let elapsed = CMTimeSubtract(request.compositionTime, instruction.timeRange.start)
        let progress = CGFloat(elapsed.seconds / instruction.timeRange.duration.seconds)

        // Get source frames
        let bgColor = instruction.backgroundColor
        let fromImage: CIImage
        if let fromBuffer = request.sourceFrame(byTrackID: instruction.fromTrackID) {
            fromImage = CIImage(cvPixelBuffer: fromBuffer)
        } else {
            fromImage = CIImage(color: bgColor).cropped(to: CGRect(origin: .zero, size: renderSize))
        }

        let toImage: CIImage
        if let toBuffer = request.sourceFrame(byTrackID: instruction.toTrackID) {
            toImage = CIImage(cvPixelBuffer: toBuffer)
        } else {
            toImage = CIImage(color: bgColor).cropped(to: CGRect(origin: .zero, size: renderSize))
        }

        // Blend based on transition type
        let result: CIImage
        switch instruction.transitionType {
        case .crossDissolve:
            result = fromImage.applyingFilter("CIDissolveTransition", parameters: [
                "inputTargetImage": toImage,
                "inputTime": progress,
            ])
        case .fadeToBlack:
            let bg = CIImage(color: bgColor).cropped(to: fromImage.extent)
            result = fromImage.applyingFilter("CIDissolveTransition", parameters: [
                "inputTargetImage": bg,
                "inputTime": progress,
            ])
        case .fadeFromBlack:
            let bg = CIImage(color: bgColor).cropped(to: toImage.extent)
            result = bg.applyingFilter("CIDissolveTransition", parameters: [
                "inputTargetImage": toImage,
                "inputTime": progress,
            ])
        case .wipeLeft:
            let wipeX = renderSize.width * (1 - progress)
            let fromCropped = fromImage.cropped(to: CGRect(x: 0, y: 0, width: wipeX, height: renderSize.height))
            let toCropped = toImage.cropped(to: CGRect(x: wipeX, y: 0, width: renderSize.width - wipeX, height: renderSize.height))
            result = fromCropped.composited(over: toCropped)
        case .wipeRight:
            let wipeX = renderSize.width * progress
            let toCropped = toImage.cropped(to: CGRect(x: 0, y: 0, width: wipeX, height: renderSize.height))
            let fromCropped = fromImage.cropped(to: CGRect(x: wipeX, y: 0, width: renderSize.width - wipeX, height: renderSize.height))
            result = toCropped.composited(over: fromCropped)
        case .none:
            result = toImage
        }

        guard let outputBuffer = renderContext?.newPixelBuffer() else {
            request.finish(with: NSError(domain: "EffectCompositor", code: -4))
            return
        }

        ciContext.render(result, to: outputBuffer, bounds: CGRect(origin: .zero, size: renderSize), colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    // MARK: - Overlay Handling (Multi-Track)

    private func handleOverlay(_ request: AVAsynchronousVideoCompositionRequest, instruction: OverlayInstruction) {
        let renderSize = renderContext?.size ?? CGSize(width: 1920, height: 1080)
        let renderRect = CGRect(origin: .zero, size: renderSize)

        // Start with background color
        var composited = CIImage(color: instruction.backgroundColor).cropped(to: renderRect)

        // Composite layers bottom-to-top in stable track order. In short-form mode,
        // only the bottom/main camera layer should receive speaker-aware 9:16
        // recomposition; upper layers are B-roll/overlays and must stay visible.
        let orderedLayers = Self.orderedOverlayLayers(for: instruction)
        let baseShortFormTrackID = orderedLayers.first?.trackID
        let hasShortFormCutaway = instruction.shortFormConfig?.isEnabled == true && orderedLayers.count > 1
        for layer in orderedLayers {
            if hasShortFormCutaway, layer.trackID == baseShortFormTrackID {
                continue
            }

            guard let sourceBuffer = request.sourceFrame(byTrackID: layer.trackID) else {
                continue // Skip layers with no frame at this time
            }

            var layerImage = CIImage(cvPixelBuffer: sourceBuffer)

            if let sfConfig = instruction.shortFormConfig,
               sfConfig.isEnabled,
               layer.trackID == baseShortFormTrackID {
                let sourceTime = request.compositionTime.seconds + sfConfig.sourceTimeOffset
                layerImage = ShortFormLayoutRenderer.recompose(
                    source: layerImage,
                    config: sfConfig,
                    at: sourceTime,
                    renderSize: renderSize
                )
            } else {
                // Apply crop to overlays/B-roll without speaker-aware recomposition.
                layerImage = Self.applyCropRect(layer.cropRect, to: layerImage)
                if instruction.shortFormConfig?.isEnabled == true {
                    layerImage = Self.scaleToFillRenderFrame(layerImage, renderSize: renderSize)
                }
            }

            // Apply per-layer effects
            for effect in layer.effects {
                layerImage = applyEffect(effect, to: layerImage)
            }

            let compositionTime = request.compositionTime.seconds
            let resolvedTransform = Self.resolvedTransform(
                baseTransform: layer.transform,
                keyframes: layer.keyframes,
                compositionTime: compositionTime,
                clipStartTime: layer.clipStartTime
            )

            if resolvedTransform != .identity {
                // Overlay layers use normalized position (-0.5…0.5 of canvas).
                // Convert to pixel offsets before the shared applyTransform path.
                var pixelTransform = resolvedTransform
                pixelTransform.positionX = resolvedTransform.positionX * Double(renderSize.width)
                pixelTransform.positionY = resolvedTransform.positionY * Double(renderSize.height)
                layerImage = Self.applyTransform(pixelTransform, to: layerImage, renderSize: renderSize)
            }

            layerImage = Self.applyOverlayPresentation(layer.presentation, to: layerImage, renderSize: renderSize)

            var resolvedOpacity = Self.resolvedOpacity(
                baseOpacity: layer.opacity,
                keyframes: layer.keyframes,
                compositionTime: compositionTime,
                clipStartTime: layer.clipStartTime
            )

            // Apply entrance/exit animation presets
            if layer.presentation.entranceAnimation != .none || layer.presentation.exitAnimation != .none {
                let localTime = compositionTime - layer.clipStartTime
                resolvedOpacity = Self.presentationOpacity(
                    baseOpacity: resolvedOpacity,
                    entrance: layer.presentation.entranceAnimation,
                    exit: layer.presentation.exitAnimation,
                    compositionTime: localTime,
                    clipDuration: layer.clipDuration
                )
            }

            composited = Self.composite(
                layerImage,
                over: composited,
                blendMode: layer.blendMode,
                opacity: resolvedOpacity
            )
        }

        // Render broadcast overlay if configured
        if let overlay = instruction.broadcastOverlay, overlay.isEnabled {
            let time = request.compositionTime.seconds
            if let overlayImage = BroadcastOverlayRenderer.render(config: overlay, at: time, renderSize: renderSize) {
                composited = overlayImage.composited(over: composited)
            }
        }

        guard let outputBuffer = renderContext?.newPixelBuffer() else {
            request.finish(with: NSError(domain: "EffectCompositor", code: -5))
            return
        }

        composited = Self.fitToRenderFrame(composited, renderSize: renderSize, backgroundColor: instruction.backgroundColor)
        ciContext.render(composited, to: outputBuffer, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    // MARK: - Effect Application

    private func applyEffect(_ effect: EffectInstance, to image: CIImage) -> CIImage {
        guard effect.isEnabled else { return image }

        switch effect.type {
        case EffectInstance.typeColorCorrection:
            return applyColorCorrection(effect.parameters, to: image)
        case EffectInstance.typeLUT:
            guard let lutPath = effect.stringParameters["path"],
                  let filter = LUTLoader.cachedFilter(at: lutPath) else {
                return image
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            return filter.outputImage ?? image
        case EffectInstance.typeBlur:
            let radius = effect.parameters["radius"] ?? 10
            return image.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
        case EffectInstance.typeSharpen:
            let sharpness = effect.parameters["sharpness"] ?? 0.4
            return image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": sharpness])
        case EffectInstance.typeVideoDenoise:
            return VideoDenoiser.denoise(
                image: image,
                level: effect.parameters["level"] ?? 0.5,
                sharpness: effect.parameters["sharpness"] ?? 0.4
            )
        case EffectInstance.typeChromaKey:
            return ChromaKey.apply(
                to: image,
                targetHue: effect.parameters["targetHue"] ?? 0.33,
                tolerance: effect.parameters["tolerance"] ?? 0.1
            )
        case EffectInstance.typeVignette:
            let intensity = effect.parameters["intensity"] ?? 0.5
            let feather = effect.parameters["feather"] ?? 0.7
            let vignetteFilter = CIFilter(name: "CIVignette")!
            vignetteFilter.setValue(image, forKey: kCIInputImageKey)
            vignetteFilter.setValue(intensity * 2.0, forKey: kCIInputIntensityKey)
            vignetteFilter.setValue(feather * 10.0, forKey: kCIInputRadiusKey)
            return vignetteFilter.outputImage ?? image
        default:
            return image
        }
    }

    private func applyColorCorrection(_ params: [String: Double], to image: CIImage) -> CIImage {
        var result = image

        let brightness = params["brightness"] ?? 0
        let contrast = params["contrast"] ?? 1
        let saturation = params["saturation"] ?? 1

        result = result.applyingFilter("CIColorControls", parameters: [
            "inputBrightness": brightness,
            "inputContrast": contrast,
            "inputSaturation": saturation,
        ])

        // Temperature (approximate via CITemperatureAndTint)
        if let temperature = params["temperature"], temperature != 6500 {
            let neutral = CIVector(x: CGFloat(temperature), y: 0)
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": neutral,
            ])
        }

        return result
    }
}

// MARK: - EffectInstruction

/// Custom instruction that carries per-clip effect data to the compositor.
public final class EffectInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening: Bool
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let effects: [EffectInstance]
    public let opacity: Float
    public let transform: Transform2D
    public let cropRect: CropRect
    public let blendMode: BlendMode
    public let keyframes: KeyframeStore
    public let clipStartTime: TimeInterval
    public let subtitles: [SubtitleRenderer.SubtitleEntry]
    public let broadcastOverlay: BroadcastOverlayConfig?
    public let shortFormConfig: ShortFormConfig?
    public let captionStyle: CaptionStyler.CaptionStyle
    public let captionWords: [TranscriptWord]
    public let backgroundColor: CIColor

    public init(
        timeRange: CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        effects: [EffectInstance],
        opacity: Float = 1.0,
        transform: Transform2D = .identity,
        cropRect: CropRect = .fullFrame,
        blendMode: BlendMode = .normal,
        keyframes: KeyframeStore = KeyframeStore(),
        clipStartTime: TimeInterval = 0,
        subtitles: [SubtitleRenderer.SubtitleEntry] = [],
        broadcastOverlay: BroadcastOverlayConfig? = nil,
        shortFormConfig: ShortFormConfig? = nil,
        captionStyle: CaptionStyler.CaptionStyle = .standard,
        captionWords: [TranscriptWord] = [],
        backgroundColor: CIColor = .black
    ) {
        self.timeRange = timeRange
        if sourceTrackID == kCMPersistentTrackID_Invalid {
            self.requiredSourceTrackIDs = nil
        } else {
            self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        }
        self.containsTweening = !keyframes.tracks.isEmpty
        self.effects = effects
        self.opacity = opacity
        self.transform = transform
        self.cropRect = cropRect
        self.blendMode = blendMode
        self.keyframes = keyframes
        self.clipStartTime = clipStartTime
        self.subtitles = subtitles
        self.broadcastOverlay = broadcastOverlay
        self.shortFormConfig = shortFormConfig
        self.captionStyle = captionStyle
        self.captionWords = captionWords
        self.backgroundColor = backgroundColor
        super.init()
    }
}

// MARK: - TransitionInstruction

/// Carries transition data for blending two clips during overlap.
public final class TransitionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let fromTrackID: CMPersistentTrackID
    public let toTrackID: CMPersistentTrackID
    public let transitionType: TransitionType
    public let backgroundColor: CIColor

    public init(
        timeRange: CMTimeRange,
        fromTrackID: CMPersistentTrackID,
        toTrackID: CMPersistentTrackID,
        transitionType: TransitionType,
        backgroundColor: CIColor = .black
    ) {
        self.timeRange = timeRange
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
        self.transitionType = transitionType
        self.backgroundColor = backgroundColor
        self.requiredSourceTrackIDs = [NSNumber(value: fromTrackID), NSNumber(value: toTrackID)]
        super.init()
    }
}

// MARK: - OverlayInstruction

/// Represents a single layer in a multi-track overlay composition.
public struct OverlayLayer: Sendable {
    public let trackID: CMPersistentTrackID
    public let trackOrder: Int
    public let opacity: Float
    public let transform: Transform2D
    public let cropRect: CropRect
    public let blendMode: BlendMode
    public let effects: [EffectInstance]
    public let keyframes: KeyframeStore
    public let clipStartTime: TimeInterval
    public let clipDuration: TimeInterval
    public let presentation: OverlayPresentation

    public init(
        trackID: CMPersistentTrackID,
        trackOrder: Int = 0,
        opacity: Float = 1.0,
        transform: Transform2D = .identity,
        cropRect: CropRect = .fullFrame,
        blendMode: BlendMode = .normal,
        effects: [EffectInstance] = [],
        keyframes: KeyframeStore = KeyframeStore(),
        clipStartTime: TimeInterval = 0,
        clipDuration: TimeInterval = 0,
        presentation: OverlayPresentation = .default
    ) {
        self.trackID = trackID
        self.trackOrder = trackOrder
        self.opacity = opacity
        self.transform = transform
        self.cropRect = cropRect
        self.blendMode = blendMode
        self.effects = effects
        self.keyframes = keyframes
        self.clipStartTime = clipStartTime
        self.clipDuration = clipDuration
        self.presentation = presentation
    }
}

/// Instruction for compositing multiple video tracks (overlay).
/// Layers are ordered bottom-to-top (index 0 = background).
public final class OverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening: Bool
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let layers: [OverlayLayer]
    public let broadcastOverlay: BroadcastOverlayConfig?
    public let shortFormConfig: ShortFormConfig?
    public let captionStyle: CaptionStyler.CaptionStyle
    public let captionWords: [TranscriptWord]
    public let backgroundColor: CIColor

    public init(
        timeRange: CMTimeRange,
        layers: [OverlayLayer],
        broadcastOverlay: BroadcastOverlayConfig? = nil,
        shortFormConfig: ShortFormConfig? = nil,
        captionStyle: CaptionStyler.CaptionStyle = .standard,
        captionWords: [TranscriptWord] = [],
        backgroundColor: CIColor = .black
    ) {
        self.timeRange = timeRange
        self.layers = layers
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        self.containsTweening = layers.contains { !$0.keyframes.tracks.isEmpty }
        self.broadcastOverlay = broadcastOverlay
        self.shortFormConfig = shortFormConfig
        self.captionStyle = captionStyle
        self.captionWords = captionWords
        self.backgroundColor = backgroundColor
        super.init()
    }
}
