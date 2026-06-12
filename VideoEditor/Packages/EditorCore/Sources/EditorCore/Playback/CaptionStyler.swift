import Foundation
import CoreGraphics
import CoreText

/// Generates styled caption frames with word-by-word highlighting.
public struct CaptionStyler: Sendable {

    public enum CaptionStyle: String, Sendable, CaseIterable {
        case none
        case standard, karaoke, bold, outline, gradient
        case pop, hormozi, bounce, typewriter
    }

    public enum CaptionPlacement: Sendable {
        case bottom
        case centerBridge
    }

    // MARK: - Public API

    /// Determine which word is active at a given time.
    public static func activeWordIndex(at time: TimeInterval, words: [TranscriptWord]) -> Int? {
        words.firstIndex(where: { time >= $0.start && time < $0.end })
    }

    /// A group of words that should be shown together on screen.
    public struct Phrase: Sendable {
        public let startIndex: Int  // index into the original words array
        public let endIndex: Int    // exclusive
        public var range: Range<Int> { startIndex..<endIndex }
    }

    /// Group words into phrases for Opus-style karaoke. Each phrase stays on screen
    /// as a unit while the karaoke highlight moves within it, then jumps to the next.
    /// Break on: sentence-ending punctuation, long gaps between words, or max word count.
    public static func groupIntoPhrases(
        _ words: [TranscriptWord],
        maxWords: Int = 5,
        breakOnGapSeconds: Double = 0.4
    ) -> [Phrase] {
        guard !words.isEmpty else { return [] }
        var phrases: [Phrase] = []
        var start = 0
        let sentenceEnders: Set<Character> = [".", "?", "!"]

        for i in 0..<words.count {
            let w = words[i]
            let count = i - start + 1
            let nextGap: Double = (i + 1 < words.count) ? words[i + 1].start - w.end : 0
            let endsSentence = w.word.last.map { sentenceEnders.contains($0) } ?? false
            let shouldBreak = (count >= maxWords) || endsSentence || (nextGap >= breakOnGapSeconds) || (i == words.count - 1)
            if shouldBreak {
                phrases.append(Phrase(startIndex: start, endIndex: i + 1))
                start = i + 1
            }
        }
        return phrases
    }

    /// Render a styled caption as a CGImage. `wordProgress` (0-1) drives animation curves.
    public static func renderCaption(
        text: String, activeWordIndex: Int?, style: CaptionStyle,
        size: CGSize, fontSize: CGFloat = 40, wordProgress: Float = 0,
        placement: CaptionPlacement = .bottom
    ) -> CGImage? {
        // Render at 1x — CIImage composites pixels 1:1 onto the video frame.
        // A 2x context would produce an image twice the frame size.
        let w = Int(size.width), h = Int(size.height)
        let fs = min(fontSize, size.width * 0.06)
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        let words = text.components(separatedBy: " ")
        let fw = CGFloat(w), fh = CGFloat(h)
        // CGContext origin is bottom-left.
        let textY: CGFloat = {
            switch placement {
            case .bottom:
                return fh * 0.15
            case .centerBridge:
                return fh * 0.485
            }
        }()

        switch style {
        case .none:
            return nil
        case .standard, .gradient:
            renderPill(ctx: ctx, text: text, fontSize: fs, width: fw, textY: textY)
        case .karaoke:
            renderWordHighlight(ctx: ctx, words: words, activeIndex: activeWordIndex,
                               fontSize: fs * 1.14, width: fw, textY: textY, brandMode: true)
        case .bold:
            drawText(ctx: ctx, text: text, fontSize: fs * 1.3, x: nil, y: fh * 0.5, width: fw, color: white)
        case .outline:
            renderOutline(ctx: ctx, text: text, fontSize: fs, width: fw, textY: textY)
        case .pop:
            renderPop(ctx: ctx, words: words, activeIndex: activeWordIndex,
                     fontSize: fs, width: fw, textY: textY, progress: wordProgress)
        case .hormozi:
            renderHormozi(ctx: ctx, words: words, activeIndex: activeWordIndex,
                         fontSize: fs, width: fw, height: fh)
        case .bounce:
            renderBounce(ctx: ctx, words: words, activeIndex: activeWordIndex,
                        fontSize: fs, width: fw, textY: textY, progress: wordProgress)
        case .typewriter:
            renderTypewriter(ctx: ctx, words: words, activeIndex: activeWordIndex,
                            fontSize: fs, width: fw, textY: textY)
        }
        return ctx.makeImage()
    }

    /// Thin progress bar near the bottom, fills left-to-right.
    public static func renderProgressBar(progress: Float, size: CGSize, barColor: CGColor) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let barH: CGFloat = 5
        let filled = CGFloat(w) * CGFloat(max(0, min(1, progress)))
        ctx.setFillColor(barColor)
        ctx.fill(CGRect(x: 0, y: size.height * 0.04, width: filled, height: barH))
        return ctx.makeImage()
    }

    // MARK: - Internals

    /// Safe area is 85% of frame width (7.5% margin each side).
    private static let safeAreaFraction: CGFloat = 0.85

    private static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let dimWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 0.8)
    private static let karaokeAccent = CGColor(red: 1, green: 0.92, blue: 0.0, alpha: 1)
    private static let brandGreen = CGColor(red: 0.0, green: 0.82, blue: 0.38, alpha: 1)
    private static let brandGold = CGColor(red: 1.0, green: 0.78, blue: 0.16, alpha: 1)
    private static let yellow = CGColor(red: 1, green: 0.92, blue: 0.23, alpha: 1)

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func font(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    private static func line(_ text: String, font f: CTFont) -> CTLine {
        let a: [CFString: Any] = [kCTFontAttributeName: f, kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, a as CFDictionary)!)
    }

    private static func bounds(_ l: CTLine) -> CGRect { CTLineGetBoundsWithOptions(l, []) }

    private static func pill(
        _ ctx: CGContext,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        pad: CGFloat = 16,
        strokeColor: CGColor? = nil
    ) {
        let r = CGRect(x: x - pad, y: y - pad / 2, width: w + pad * 2, height: h + pad)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        if let strokeColor {
            ctx.setStrokeColor(strokeColor)
            ctx.setLineWidth(3)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.strokePath()
        }
    }

    /// Draw text centered in the safe area with automatic line wrapping via CTFramesetter.
    private static func drawText(ctx: CGContext, text: String, fontSize: CGFloat,
                                 x: CGFloat?, y: CGFloat, width: CGFloat, color: CGColor) {
        let safeW = width * safeAreaFraction
        let marginX = (width - safeW) / 2
        let f = font(fontSize)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: f,
            kCTForegroundColorAttributeName: color,
        ]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)

        // Measure how tall the wrapped text will be
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil, CGSize(width: safeW, height: .greatestFiniteMagnitude), nil
        )

        // Center the text block horizontally, place at requested y
        let rectX = x ?? marginX
        let rect = CGRect(x: rectX, y: y, width: safeW, height: suggestedSize.height)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        ctx.saveGState()
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// Compute word positions for centered text, clamped to safe area. Returns (line, x, width) per word.
    private static func wordLayout(_ words: [String], fontSize: CGFloat, width: CGFloat) -> [(CTLine, CGFloat, CGFloat)] {
        let f = font(fontSize)
        let full = line(words.joined(separator: " "), font: f)
        let textW = bounds(full).width
        let safeW = width * safeAreaFraction
        // Center within safe area; if text exceeds safe area, start at margin
        let startX = textW <= safeW ? (width - textW) / 2 : (width - safeW) / 2
        var cx = startX
        return words.enumerated().map { i, w in
            let display = i < words.count - 1 ? w + " " : w
            let wl = line(display, font: f)
            let ww = bounds(wl).width
            defer { cx += ww }
            return (wl, cx, ww)
        }
    }

    // MARK: - Style Renderers

    private static func renderPill(ctx: CGContext, text: String, fontSize: CGFloat, width: CGFloat, textY: CGFloat) {
        let safeW = width * safeAreaFraction
        let marginX = (width - safeW) / 2
        let f = font(fontSize)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: f,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil, CGSize(width: safeW, height: .greatestFiniteMagnitude), nil
        )
        let pillW = min(suggestedSize.width, safeW)
        let pillX = (width - pillW) / 2
        pill(ctx, x: pillX, y: textY, w: pillW, h: suggestedSize.height)

        let rect = CGRect(x: marginX, y: textY, width: safeW, height: suggestedSize.height)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.setFillColor(white)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private static func renderWordHighlight(ctx: CGContext, words: [String], activeIndex: Int?,
                                            fontSize: CGFloat, width: CGFloat, textY: CGFloat, brandMode: Bool = false) {
        let f = font(fontSize)
        let full = line(words.joined(separator: " "), font: f)
        let fb = bounds(full)
        let safeW = width * safeAreaFraction
        let startX = fb.width <= safeW ? (width - fb.width) / 2 : (width - safeW) / 2
        pill(ctx, x: startX, y: textY, w: min(fb.width, safeW), h: fb.height, pad: brandMode ? 22 : 16)
        drawWords(ctx: ctx, words: words, activeIndex: activeIndex, fontSize: fontSize,
                 width: width, textY: textY, activeColor: brandMode ? brandGold : karaokeAccent, inactiveColor: brandMode ? white : dimWhite)
        if brandMode, let activeIndex, activeIndex >= 0, activeIndex < words.count {
            let layout = wordLayout(words, fontSize: fontSize, width: width)
            if activeIndex < layout.count {
                let (_, x, wordWidth) = layout[activeIndex]
                ctx.setFillColor(brandGreen)
                ctx.fill(CGRect(x: x, y: textY - 10, width: max(12, wordWidth - 10), height: 5))
            }
        }
    }

    private static func renderOutline(ctx: CGContext, text: String, fontSize: CGFloat, width: CGFloat, textY: CGFloat) {
        let safeW = width * safeAreaFraction
        let marginX = (width - safeW) / 2
        let f = font(fontSize)
        let l = line(text, font: f)
        let textW = bounds(l).width
        let tx = textW <= safeW ? (width - textW) / 2 : marginX
        ctx.setTextDrawingMode(.stroke); ctx.setLineWidth(4)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.textPosition = CGPoint(x: tx, y: textY); CTLineDraw(l, ctx)
        ctx.setTextDrawingMode(.fill); ctx.setFillColor(white)
        ctx.textPosition = CGPoint(x: tx, y: textY); CTLineDraw(l, ctx)
    }

    private static func renderPop(ctx: CGContext, words: [String], activeIndex: Int?,
                                  fontSize: CGFloat, width: CGFloat, textY: CGFloat, progress: Float) {
        let layout = wordLayout(words, fontSize: fontSize, width: width)
        let f = font(fontSize)
        let full = line(words.joined(separator: " "), font: f)
        let fb = bounds(full)
        let startX = (width - fb.width) / 2
        pill(ctx, x: startX, y: textY, w: fb.width, h: fb.height)

        let p = CGFloat(progress)
        let popScale = 1.0 + 0.35 * sin(p * .pi) * exp(-0.6 * p * 10)

        for (i, (wl, x, ww)) in layout.enumerated() {
            if i == activeIndex {
                ctx.saveGState()
                let cx = x + ww / 2, cy = textY + fontSize / 2
                ctx.translateBy(x: cx, y: cy)
                ctx.scaleBy(x: popScale, y: popScale)
                ctx.translateBy(x: -cx, y: -cy)
                ctx.setFillColor(karaokeAccent)
                ctx.textPosition = CGPoint(x: x, y: textY)
                CTLineDraw(wl, ctx)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(white)
                ctx.textPosition = CGPoint(x: x, y: textY)
                CTLineDraw(wl, ctx)
            }
        }
    }

    private static func renderHormozi(ctx: CGContext, words: [String], activeIndex: Int?,
                                      fontSize: CGFloat, width: CGFloat, height: CGFloat) {
        guard let idx = activeIndex, idx < words.count else { return }
        let word = words[idx]
        // Scale to fill ~80% width
        let testW = bounds(line(word, font: font(fontSize))).width
        let finalSize = testW > 0 ? min(fontSize * (width * 0.8 / testW), height * 0.4) : fontSize
        let f = font(finalSize)
        let l = line(word, font: f)
        let b = bounds(l)
        ctx.setFillColor(idx % 2 == 0 ? white : yellow)
        ctx.textPosition = CGPoint(x: (width - b.width) / 2, y: (height - b.height) / 2)
        CTLineDraw(l, ctx)
    }

    private static func renderBounce(ctx: CGContext, words: [String], activeIndex: Int?,
                                     fontSize: CGFloat, width: CGFloat, textY: CGFloat, progress: Float) {
        let layout = wordLayout(words, fontSize: fontSize, width: width)
        let f = font(fontSize)
        let full = line(words.joined(separator: " "), font: f)
        let fb = bounds(full)
        let startX = (width - fb.width) / 2
        pill(ctx, x: startX, y: textY, w: fb.width, h: fb.height)

        let t = CGFloat(progress)
        let bounceY = 30.0 * exp(-0.3 * 12.0 * t) * cos(12.0 * sqrt(1.0 - 0.09) * t)

        for (i, (wl, x, _)) in layout.enumerated() {
            ctx.setFillColor(i == activeIndex ? karaokeAccent : white)
            ctx.textPosition = CGPoint(x: x, y: textY + (i == activeIndex ? bounceY : 0))
            CTLineDraw(wl, ctx)
        }
    }

    private static func renderTypewriter(ctx: CGContext, words: [String], activeIndex: Int?,
                                         fontSize: CGFloat, width: CGFloat, textY: CGFloat) {
        guard let idx = activeIndex else { return }
        let f = font(fontSize)
        // Pill sized for full text, but only draw visible words
        let fullW = bounds(line(words.joined(separator: " "), font: f)).width
        let fullH = bounds(line(words.joined(separator: " "), font: f)).height
        let startX = (width - fullW) / 2
        pill(ctx, x: startX, y: textY, w: fullW, h: fullH)

        let visible = words.prefix(idx + 1).joined(separator: " ")
        ctx.setFillColor(white)
        let vl = line(visible, font: f)
        ctx.textPosition = CGPoint(x: startX, y: textY)
        CTLineDraw(vl, ctx)
    }

    private static func drawWords(ctx: CGContext, words: [String], activeIndex: Int?,
                                  fontSize: CGFloat, width: CGFloat, textY: CGFloat, activeColor: CGColor, inactiveColor: CGColor = dimWhite) {
        let layout = wordLayout(words, fontSize: fontSize, width: width)
        for (i, (wl, x, _)) in layout.enumerated() {
            ctx.setFillColor(i == activeIndex ? activeColor : inactiveColor)
            ctx.textPosition = CGPoint(x: x, y: textY)
            CTLineDraw(wl, ctx)
        }
    }
}
