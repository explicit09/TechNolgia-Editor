import Foundation
import CoreImage
import CoreText
import CoreGraphics

/// Renders broadcast-style overlays onto video frames.
/// Matches the Remotion "Technologia Talks" overlay components exactly.
/// Stateless: all animation is computed from `time`. Same pattern as SubtitleRenderer.
public struct BroadcastOverlayRenderer {

    // Reference resolution — all Remotion pixel values are at this size
    private static let refW: CGFloat = 3840
    private static let refH: CGFloat = 2160

    public static func render(
        config: BroadcastOverlayConfig,
        at time: TimeInterval,
        renderSize: CGSize
    ) -> CIImage? {
        let s = renderSize.width / refW
        let w = Int(renderSize.width)
        let h = Int(renderSize.height)
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        if config.shortFormMode {
            // Short-form mode: only render the minimal brand signature bar
            drawShortFormBrandBar(ctx: ctx, config: config, size: renderSize)
        } else {
            let fps: Double = 30
            let frame = time * fps

            // Draw layers bottom to top (CGContext y=0 is bottom of screen)
            drawSmartTicker(ctx: ctx, config: config, time: time, frame: frame, fps: fps, s: s, size: renderSize)
            drawHostNameBar(ctx: ctx, config: config, time: time, frame: frame, fps: fps, s: s, size: renderSize)
            drawHostIntroStrip(ctx: ctx, config: config, time: time, s: s, size: renderSize)
            drawEpisodeTitleCard(ctx: ctx, config: config, time: time, s: s, size: renderSize)
            drawChapterCard(ctx: ctx, config: config, time: time, s: s, size: renderSize)
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

// MARK: - Short-Form Brand Bar
// Minimal brand signature for 9:16 vertical exports.
// Sits at the very bottom of the frame (y = 0 in CG coords).
// Height: ~80px at 1080x1920 reference so captions at fh*0.15 are never overlapped.
// Elements: thin gold accent line on top, dark-navy translucent background, show name centered.

extension BroadcastOverlayRenderer {

    static func drawShortFormBrandBar(
        ctx: CGContext, config: BroadcastOverlayConfig, size: CGSize
    ) {
        // Reference is 1080-wide (9:16 output). Scale relative to output width.
        let s = size.width / 1080.0

        let st = config.style
        let gold  = OverlayStyle.parseHex(st.goldHex)
        let navy  = OverlayStyle.parseHex(st.darkNavyHex)

        // Bar dimensions
        let barH: CGFloat = 80.0 * s
        let accentH: CGFloat = 3.0 * s

        // Position: y=0 is bottom of frame in CGContext
        let barRect = CGRect(x: 0, y: 0, width: size.width, height: barH)

        // Dark translucent background (navy at 90% opacity)
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.90))
        ctx.fill(barRect)

        // Gold accent line along the top of the bar
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: barH - accentH, width: size.width, height: accentH))

        // Determine display name: showName → episodeTitle → hard fallback
        let displayName: String
        if !config.showName.isEmpty {
            displayName = config.showName.uppercased()
        } else if !config.episodeTitle.isEmpty {
            displayName = config.episodeTitle.uppercased()
        } else {
            displayName = "TECHNOLOGIA TALKS"
        }

        let fontSize: CGFloat = 32.0 * s
        let font = condensedFont(size: fontSize)
        let goldColor = CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1.0)
        // Vertical center baseline for text (below accent line)
        let textY = (barH - accentH) / 2 - fontSize * 0.3

        // Try to load logo from brandLogoPath
        let logoImage: CGImage? = loadLogoImage(path: config.brandLogoPath)

        if let logo = logoImage {
            // Logo layout: logo on left, text to the right
            let leftPad: CGFloat = 32.0 * s
            let logoGap: CGFloat = 16.0 * s
            let logoMaxH: CGFloat = 60.0 * s
            let logoAspect = CGFloat(logo.width) / CGFloat(logo.height)
            let logoH = min(logoMaxH, barH - accentH - 8.0 * s)
            let logoW = logoH * logoAspect
            let logoY = (barH - accentH - logoH) / 2  // vertically centered in bar below accent

            ctx.draw(logo, in: CGRect(x: leftPad, y: logoY, width: logoW, height: logoH))

            let textX = leftPad + logoW + logoGap
            drawText(ctx: ctx, text: displayName, x: textX, y: textY, font: font, color: goldColor)
        } else {
            // No logo: center text in bar
            let textW = measureText(displayName, font: font)
            let textX = (size.width - textW) / 2
            drawText(ctx: ctx, text: displayName, x: textX, y: textY, font: font, color: goldColor)
        }
    }

    /// Load a CGImage from an optional file path. Returns nil if path is nil or file missing.
    private static func loadLogoImage(path: String?) -> CGImage? {
        guard let path = path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Episode Title Card
// Remotion: EpisodeTitleCard.tsx — centered, fit-content, fade in/out

extension BroadcastOverlayRenderer {

    static func drawEpisodeTitleCard(
        ctx: CGContext, config: BroadcastOverlayConfig,
        time: TimeInterval, s: CGFloat, size: CGSize
    ) {
        let st = config.style
        guard time < st.titleVisibleEnd else { return }
        guard !config.episodeTitle.isEmpty else { return }

        // Opacity: linear interpolate [0, fadeInEnd, fadeOutStart, fadeOutEnd] → [0, 1, 1, 0]
        let opacity: CGFloat
        if time < st.titleFadeInEnd {
            opacity = CGFloat(time / st.titleFadeInEnd)
        } else if time > st.titleFadeOutStart {
            opacity = max(0, CGFloat(1.0 - (time - st.titleFadeOutStart) / (st.titleVisibleEnd - st.titleFadeOutStart)))
        } else {
            opacity = 1.0
        }
        guard opacity > 0.01 else { return }

        // Slide up 40px as it fades in
        let slideY = st.titleFadeInEnd > 0
            ? CGFloat(40) * s * max(0, CGFloat(1.0 - time / st.titleFadeInEnd))
            : 0

        let gold = OverlayStyle.parseHex(st.goldHex)
        let navy = OverlayStyle.parseHex(st.darkNavyHex)
        let cyan = OverlayStyle.parseHex(st.cyanHex)
        let gray = OverlayStyle.parseHex("#94A3B8")

        // Measure text to compute fit-content width
        let titleFont = condensedFont(size: 110 * s)
        let labelFont = condensedFont(size: 36 * s)
        let subFont = bodyFont(size: 46 * s)

        let titleW = measureText(config.episodeTitle.uppercased(), font: titleFont)
        let subW = config.episodeSubtitle.isEmpty ? CGFloat(0) : measureText(config.episodeSubtitle, font: subFont)
        let contentW = max(titleW, subW)

        let padX: CGFloat = 120 * s
        let padY: CGFloat = 70 * s
        let cardW = min(contentW + padX * 2, size.width * 0.85)
        let cardH = padY + 36 * s + 24 * s + 110 * s + (config.episodeSubtitle.isEmpty ? 0 : 36 * s + 46 * s) + padY
        let cardX = (size.width - cardW) / 2
        // Center vertically, apply slideY (CG: positive Y = up, but slide is down in screen coords = negative in CG)
        let cardY = (size.height - cardH) / 2 - slideY

        ctx.saveGState()
        ctx.setAlpha(opacity)

        // Background: rgba(7, 13, 23, 0.88)
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.88))
        ctx.fill(CGRect(x: cardX, y: cardY, width: cardW, height: cardH))

        // Gold top border: 4px solid GOLD (top of card = cardY + cardH in CG)
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1))
        ctx.fill(CGRect(x: cardX, y: cardY + cardH - 4 * s, width: cardW, height: 4 * s))

        // Cyan bottom border: 2px solid CYAN at 0x44 alpha
        ctx.setFillColor(CGColor(red: cyan.r, green: cyan.g, blue: cyan.b, alpha: 0.27))
        ctx.fill(CGRect(x: cardX, y: cardY, width: cardW, height: 2 * s))

        // "EPISODE" label — gold, 36px, letter-spacing 0.24em, opacity 0.8
        let labelY = cardY + cardH - padY - 36 * s
        let goldAlpha = CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 0.8)
        drawText(ctx: ctx, text: "EPISODE", x: cardX + padX, y: labelY, font: labelFont, color: goldAlpha)

        // Title — white, 110px, uppercase
        let titleY = labelY - 24 * s - 110 * s
        drawText(ctx: ctx, text: config.episodeTitle.uppercased(), x: cardX + padX, y: titleY, font: titleFont, color: .white)

        // Subtitle — gray, 46px, Inter
        if !config.episodeSubtitle.isEmpty {
            let subY = titleY - 36 * s - 46 * s
            let grayColor = CGColor(red: gray.r, green: gray.g, blue: gray.b, alpha: 1)
            drawText(ctx: ctx, text: config.episodeSubtitle, x: cardX + padX, y: subY, font: subFont, color: grayColor)
        }

        ctx.restoreGState()
    }
}

// MARK: - Host Name Bar
// Remotion: HostNameBar.tsx — bottom: TICKER_H, height: NAME_BAR_H
// Names and titles on same line (baseline aligned), Host B right-aligned

extension BroadcastOverlayRenderer {

    static func drawHostNameBar(
        ctx: CGContext, config: BroadcastOverlayConfig,
        time: TimeInterval, frame: Double, fps: Double, s: CGFloat, size: CGSize
    ) {
        let st = config.style
        guard !config.hostA.name.isEmpty || !config.hostB.name.isEmpty else { return }

        let barH = st.nameBarHeight * s     // 150
        let tickerH = st.tickerHeight * s   // 200
        let barBaseY = tickerH              // Sits above ticker

        // Hide slide: interpolate [hideFrom, hideFrom+15f, hideUntil-15f, hideUntil] → [0, barH+tickerH, barH+tickerH, 0]
        let hideFrom = st.hostIntroStart * fps
        let hideUntil = st.hostIntroEnd * fps
        let hideSlide: CGFloat
        if frame < hideFrom || frame > hideUntil {
            hideSlide = 0
        } else if frame < hideFrom + 15 {
            hideSlide = CGFloat((frame - hideFrom) / 15) * (barH + tickerH)
        } else if frame > hideUntil - 15 {
            hideSlide = CGFloat((hideUntil - frame) / 15) * (barH + tickerH)
        } else {
            hideSlide = barH + tickerH
        }

        let barY = barBaseY - hideSlide
        guard barY > -barH else { return } // Fully offscreen

        let gold = OverlayStyle.parseHex(st.goldHex)
        let navy = OverlayStyle.parseHex(st.darkNavyHex)

        // Background: rgba(7, 13, 23, 0.92)
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.92))
        ctx.fill(CGRect(x: 0, y: barY, width: size.width, height: barH))

        // Gold top border: 2px solid GOLD at 0x55 alpha
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 0.33))
        ctx.fill(CGRect(x: 0, y: barY + barH - 2 * s, width: size.width, height: 2 * s))

        let nameFont = condensedFont(size: 64 * s)
        let titleFont = condensedFont(size: 46 * s)
        let padX: CGFloat = 56 * s
        let midX = size.width / 2
        let baselineY = barY + barH / 2 - 16 * s

        let goldColor = CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1)

        // Host A: name + title on same line, left-aligned
        let aNameW = measureText(config.hostA.name.uppercased(), font: nameFont)
        drawText(ctx: ctx, text: config.hostA.name.uppercased(), x: padX, y: baselineY, font: nameFont, color: .white)
        drawText(ctx: ctx, text: config.hostA.title.uppercased(), x: padX + aNameW + 16 * s, y: baselineY, font: titleFont, color: goldColor)

        // Divider: 2px wide, 64px tall, centered, GOLD at 0x55 alpha
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 0.33))
        ctx.fill(CGRect(x: midX - 1 * s, y: barY + (barH - 64 * s) / 2, width: 2 * s, height: 64 * s))

        // Host B: name + title on same line, right-aligned (justifyContent: flex-end)
        let bNameW = measureText(config.hostB.name.uppercased(), font: nameFont)
        let bTitleW = measureText(config.hostB.title.uppercased(), font: titleFont)
        let bTotalW = bNameW + 16 * s + bTitleW
        let bStartX = size.width - padX - bTotalW
        drawText(ctx: ctx, text: config.hostB.name.uppercased(), x: bStartX, y: baselineY, font: nameFont, color: .white)
        drawText(ctx: ctx, text: config.hostB.title.uppercased(), x: bStartX + bNameW + 16 * s, y: baselineY, font: titleFont, color: goldColor)
    }
}

// MARK: - Smart Ticker
// Remotion: SmartTicker.tsx — TICKER_H=200, LABEL_W=680, SCROLL_SPD=1.6
// Cycle: 25s sponsors → 1s fade → 14s topic → 1s fade → repeat

extension BroadcastOverlayRenderer {

    static func drawSmartTicker(
        ctx: CGContext, config: BroadcastOverlayConfig,
        time: TimeInterval, frame: Double, fps: Double, s: CGFloat, size: CGSize
    ) {
        let st = config.style
        let tickerH = st.tickerHeight * s   // 200
        let labelW: CGFloat = 680 * s
        let navy = OverlayStyle.parseHex(st.darkNavyHex)
        let gold = OverlayStyle.parseHex(st.goldHex)
        let goldLight = OverlayStyle.parseHex(st.goldLightHex)
        let cyan = OverlayStyle.parseHex(st.cyanHex)

        // Slide down when HostIntroStrip is visible
        let hideFrom = st.hostIntroStart * fps
        let hideUntil = st.hostIntroEnd * fps
        let slideDown: CGFloat
        if frame < hideFrom || frame > hideUntil {
            slideDown = 0
        } else if frame < hideFrom + 15 {
            slideDown = CGFloat((frame - hideFrom) / 15) * tickerH
        } else if frame > hideUntil - 15 {
            slideDown = CGFloat((hideUntil - frame) / 15) * tickerH
        } else {
            slideDown = tickerH
        }

        let tickerY: CGFloat = 0 - slideDown
        guard tickerY > -tickerH else { return }

        // Background: solid DARK_NAVY
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: tickerY, width: size.width, height: tickerH))

        // Gold top border: 3px
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: tickerY + tickerH - 3 * s, width: size.width, height: 3 * s))

        // Left label: gold gradient background, "TECHNOLOGIA TALKS"
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: tickerY, width: labelW, height: tickerH - 3 * s))

        let labelFont = condensedFont(size: 52 * s)
        let navyColor = CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 1)
        let labelTextW = measureText("TECHNOLOGIA TALKS", font: labelFont)
        let labelTextX = (labelW - labelTextW) / 2
        drawText(ctx: ctx, text: "TECHNOLOGIA TALKS", x: labelTextX, y: tickerY + tickerH / 2 - 16 * s, font: labelFont, color: navyColor)

        // Cycle math
        let cycleSec = st.tickerCycleDuration // 41
        let sponsorSec = st.tickerSponsorDuration // 25
        let fadeSec = st.tickerFadeDuration // 1
        let cyclePos = time.truncatingRemainder(dividingBy: cycleSec)

        // Sponsor opacity: [0, (25-1)*fps, 25*fps, (41-1)*fps, 41*fps] → [1,1,0,0,1]
        let sponsorOpacity: CGFloat
        let topicOpacity: CGFloat

        let activeTopic = config.topics.last(where: { $0.timeSeconds <= time })
        let topicReady = activeTopic != nil

        if !topicReady {
            sponsorOpacity = 1
            topicOpacity = 0
        } else {
            let cf = cyclePos * fps
            let sp = sponsorSec * fps
            let fd = fadeSec * fps
            let cy = cycleSec * fps

            if cf < sp - fd {
                sponsorOpacity = 1
            } else if cf < sp {
                sponsorOpacity = CGFloat(1.0 - (cf - (sp - fd)) / fd)
            } else if cf < cy - fd {
                sponsorOpacity = 0
            } else {
                sponsorOpacity = CGFloat((cf - (cy - fd)) / fd)
            }

            if cf < sp - fd {
                topicOpacity = 0
            } else if cf < sp {
                topicOpacity = CGFloat((cf - (sp - fd)) / fd)
            } else if cf < cy - fd {
                topicOpacity = 1
            } else {
                topicOpacity = CGFloat(1.0 - (cf - (cy - fd)) / fd)
            }
        }

        let contentX = labelW + 48 * s
        let contentW = size.width - contentX - 48 * s
        let contentCenterY = tickerY + tickerH / 2

        // Sponsor scroll
        if sponsorOpacity > 0.01 && !config.sponsors.isEmpty {
            ctx.saveGState()
            ctx.setAlpha(sponsorOpacity)
            ctx.clip(to: CGRect(x: labelW, y: tickerY, width: size.width - labelW, height: tickerH))

            let separator = "   ◆   "
            let sponsorText = config.sponsors.joined(separator: separator) + separator
            let repeated = sponsorText + sponsorText + sponsorText
            let segmentW = CGFloat(sponsorText.count) * 28 * s
            let scrollX = CGFloat(frame * 1.6 * Double(s)).truncatingRemainder(dividingBy: max(segmentW, 1))

            let scrollFont = condensedFont(size: 64 * s)
            let scrollColor = CGColor(red: 0.80, green: 0.84, blue: 0.88, alpha: 1) // #CBD5E1
            drawText(ctx: ctx, text: repeated, x: contentX - scrollX, y: contentCenterY - 20 * s, font: scrollFont, color: scrollColor)

            ctx.restoreGState()
        }

        // Topic display
        if topicOpacity > 0.01, let topic = activeTopic {
            ctx.saveGState()
            ctx.setAlpha(topicOpacity)

            // "NOW DISCUSSING" badge
            let badgeFont = condensedFont(size: 46 * s)
            let badgeText = "NOW DISCUSSING"
            let badgeTextW = measureText(badgeText, font: badgeFont)
            let badgePadX: CGFloat = 24 * s
            let badgePadY: CGFloat = 8 * s
            let badgeW = badgeTextW + badgePadX * 2
            let badgeH: CGFloat = 46 * s + badgePadY * 2

            let badgeRect = CGRect(x: contentX, y: contentCenterY - badgeH / 2, width: badgeW, height: badgeH)
            ctx.setFillColor(CGColor(red: cyan.r, green: cyan.g, blue: cyan.b, alpha: 1))
            let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil)
            ctx.addPath(badgePath)
            ctx.fillPath()

            drawText(ctx: ctx, text: badgeText, x: contentX + badgePadX, y: contentCenterY - 14 * s, font: badgeFont, color: navyColor)

            // Topic text: Inter 66px weight 400
            let topicFont = bodyFont(size: 66 * s)
            drawText(ctx: ctx, text: topic.text, x: contentX + badgeW + 28 * s, y: contentCenterY - 20 * s, font: topicFont, color: .white)

            ctx.restoreGState()
        }
    }
}

// MARK: - Chapter Card
// Remotion: ChapterCard.tsx — positioned at 38% from top, spring animations

extension BroadcastOverlayRenderer {

    static func drawChapterCard(
        ctx: CGContext, config: BroadcastOverlayConfig,
        time: TimeInterval, s: CGFloat, size: CGSize
    ) {
        let st = config.style
        guard time > st.titleVisibleEnd else { return }
        guard !config.chapters.isEmpty else { return }

        var chapterIdx = -1
        var chapter: TimedEntry?
        for (i, ch) in config.chapters.enumerated() {
            if ch.timeSeconds <= time { chapterIdx = i; chapter = ch }
        }
        guard let chapter, chapterIdx >= 0 else { return }

        let elapsed = time - chapter.timeSeconds
        guard elapsed < st.chapterDisplayDuration else { return }

        let gold = OverlayStyle.parseHex(st.goldHex)
        let navy = OverlayStyle.parseHex(st.darkNavyHex)

        // Animation: slide in from right, hold, slide out
        let progress: CGFloat
        if elapsed < 0.5 {
            progress = easeOut(CGFloat(elapsed / 0.5))
        } else if elapsed > st.chapterDisplayDuration - 0.5 {
            progress = easeOut(CGFloat((st.chapterDisplayDuration - elapsed) / 0.5))
        } else {
            progress = 1.0
        }

        // Position: 38% from top in screen = 62% from bottom in CG
        let cardY = size.height * 0.62
        let goldBlockW: CGFloat = 160 * s
        let goldBlockH: CGFloat = 100 * s
        let chapterFont = condensedFont(size: 72 * s)
        let numberFont = condensedFont(size: 72 * s)
        let chapterText = chapter.text.uppercased()
        let textW = measureText(chapterText, font: chapterFont)
        let textPad: CGFloat = 32 * s
        let totalW = goldBlockW + textPad * 2 + textW + 40 * s

        // Slide from right to center
        let endX = (size.width - totalW) / 2
        let startX = size.width
        let cardX = startX + (endX - startX) * progress

        // Gold accent line on top
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1))
        ctx.fill(CGRect(x: cardX, y: cardY + goldBlockH, width: totalW * progress, height: 3 * s))

        // Gold number block
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1))
        ctx.fill(CGRect(x: cardX, y: cardY, width: goldBlockW, height: goldBlockH))

        let numText = "\(chapterIdx + 1)"
        let numW = measureText(numText, font: numberFont)
        let navyColor = CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 1)
        drawText(ctx: ctx, text: numText, x: cardX + (goldBlockW - numW) / 2, y: cardY + goldBlockH / 2 - 22 * s, font: numberFont, color: navyColor)

        // Text block
        let textBlockX = cardX + goldBlockW
        let textBlockW = totalW - goldBlockW
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.88))
        ctx.fill(CGRect(x: textBlockX, y: cardY, width: textBlockW, height: goldBlockH))

        drawText(ctx: ctx, text: chapterText, x: textBlockX + textPad, y: cardY + goldBlockH / 2 - 22 * s, font: chapterFont, color: .white)

        // Bottom accent line (40% width per Remotion)
        ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 0.5))
        ctx.fill(CGRect(x: cardX, y: cardY - 2 * s, width: totalW * 0.4 * progress, height: 2 * s))
    }
}

// MARK: - Host Intro Strip
// Remotion: HostIntroStrip.tsx — gold gradient, circular photos, spring slide

extension BroadcastOverlayRenderer {

    static func drawHostIntroStrip(
        ctx: CGContext, config: BroadcastOverlayConfig,
        time: TimeInterval, s: CGFloat, size: CGSize
    ) {
        let st = config.style
        guard time >= st.hostIntroStart - 1.0 && time <= st.hostIntroEnd + 1.0 else { return }
        guard !config.hostA.name.isEmpty || !config.hostB.name.isEmpty else { return }

        // Spring-like slide: ease in 1s, hold, ease out 1s
        let slideProgress: CGFloat
        if time < st.hostIntroStart {
            slideProgress = 0
        } else if time < st.hostIntroStart + 1.0 {
            slideProgress = easeOut(CGFloat((time - st.hostIntroStart) / 1.0))
        } else if time > st.hostIntroEnd - 1.0 && time <= st.hostIntroEnd {
            slideProgress = easeOut(CGFloat((st.hostIntroEnd - time) / 1.0))
        } else if time > st.hostIntroEnd {
            slideProgress = 0
        } else {
            slideProgress = 1.0
        }
        guard slideProgress > 0.01 else { return }

        let gold = OverlayStyle.parseHex(st.goldHex)
        let goldLight = OverlayStyle.parseHex(st.goldLightHex)
        let navy = OverlayStyle.parseHex(st.darkNavyHex)

        let stripH = st.hostStripHeight * s // 320
        // Strip sits at bottom of frame (y=0 in CGContext), slides up from below
        let slideOffset = stripH * (1.0 - slideProgress)
        let stripY = -slideOffset

        // Gold horizontal gradient (matches Remotion: GOLD → GOLD_LIGHT → GOLD)
        let gradColors = [
            CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1),
            CGColor(red: goldLight.r, green: goldLight.g, blue: goldLight.b, alpha: 1),
            CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradColors, locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: stripY, width: size.width, height: stripH))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: stripY + stripH / 2), end: CGPoint(x: size.width, y: stripY + stripH / 2), options: [])
            ctx.restoreGState()
        } else {
            ctx.setFillColor(CGColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: stripY, width: size.width, height: stripH))
        }

        let midX = size.width / 2
        let photoSize: CGFloat = 260 * s
        let nameFont = condensedFont(size: 100 * s)
        let titleFont = condensedFont(size: 58 * s)
        let navyColor = CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 1)
        let navyFaded = CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.62)

        let photoY = stripY + (stripH - photoSize) / 2

        // Host A: photo left, text right (padding 60px, gap 28px per Remotion)
        let padEdge: CGFloat = 60 * s
        let gap: CGFloat = 28 * s
        drawHostCircle(ctx: ctx, initial: String(config.hostA.name.prefix(1)), x: padEdge, y: photoY, size: photoSize, navy: navy, s: s, photoPath: config.hostA.photoPath)
        let textAX = padEdge + photoSize + gap
        let nameY = stripY + stripH / 2 + 10 * s
        drawText(ctx: ctx, text: config.hostA.name.uppercased(), x: textAX, y: nameY, font: nameFont, color: navyColor)
        drawText(ctx: ctx, text: config.hostA.title.uppercased(), x: textAX, y: nameY - 60 * s, font: titleFont, color: navyFaded)

        // Center divider: 3px, 110px tall
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.2))
        ctx.fill(CGRect(x: midX - 1.5 * s, y: stripY + (stripH - 110 * s) / 2, width: 3 * s, height: 110 * s))

        // Host B: photo right, text left of photo, right-aligned
        let photoBX = size.width - padEdge - photoSize
        drawHostCircle(ctx: ctx, initial: String(config.hostB.name.prefix(1)), x: photoBX, y: photoY, size: photoSize, navy: navy, s: s, photoPath: config.hostB.photoPath)

        let bNameW = measureText(config.hostB.name.uppercased(), font: nameFont)
        let bTitleW = measureText(config.hostB.title.uppercased(), font: titleFont)
        let textBEndX = photoBX - gap
        drawText(ctx: ctx, text: config.hostB.name.uppercased(), x: textBEndX - bNameW, y: nameY, font: nameFont, color: navyColor)
        drawText(ctx: ctx, text: config.hostB.title.uppercased(), x: textBEndX - bTitleW, y: nameY - 60 * s, font: titleFont, color: navyFaded)
    }

    nonisolated(unsafe) private static var photoCache: [String: CGImage] = [:]

    private static func drawHostCircle(
        ctx: CGContext, initial: String, x: CGFloat, y: CGFloat,
        size: CGFloat, navy: (r: CGFloat, g: CGFloat, b: CGFloat), s: CGFloat,
        photoPath: String? = nil
    ) {
        let rect = CGRect(x: x, y: y, width: size, height: size)

        // Try loading actual photo
        if let photoPath, let photo = loadPhoto(path: photoPath) {
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            // Aspect-fill, crop from top (shows face)
            let imgW = CGFloat(photo.width)
            let imgH = CGFloat(photo.height)
            let scale = max(size / imgW, size / imgH)
            let drawW = imgW * scale
            let drawH = imgH * scale
            let drawX = x + (size - drawW) / 2
            let drawY = y - (drawH - size) // align top of image (face) into circle
            ctx.draw(photo, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
            ctx.restoreGState()

            // Border: 4px dark navy (matches Remotion)
            ctx.setStrokeColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 1))
            ctx.setLineWidth(4 * s)
            ctx.strokeEllipse(in: rect.insetBy(dx: 2 * s, dy: 2 * s))
            return
        }

        // Fallback: circle with initial
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.setFillColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.15))
        ctx.fill(rect)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.4))
        ctx.setLineWidth(4 * s)
        ctx.strokeEllipse(in: rect.insetBy(dx: 2 * s, dy: 2 * s))

        let font = condensedFont(size: 90 * s)
        let w = measureText(initial, font: font)
        let navyColor = CGColor(red: navy.r, green: navy.g, blue: navy.b, alpha: 0.5)
        drawText(ctx: ctx, text: initial, x: x + (size - w) / 2, y: y + size / 2 - 28 * s, font: font, color: navyColor)
    }

    private static func loadPhoto(path: String) -> CGImage? {
        if let cached = photoCache[path] { return cached }
        let url = URL(fileURLWithPath: path)
        guard let provider = CGDataProvider(url: url as CFURL) else { return nil }
        let image: CGImage?
        if path.lowercased().hasSuffix(".png") {
            image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        } else {
            image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        if let image { photoCache[path] = image }
        return image
    }
}

// MARK: - Text Helpers

extension BroadcastOverlayRenderer {

    private static func drawText(ctx: CGContext, text: String, x: CGFloat, y: CGFloat, font: CTFont, color: CGColor) {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let aStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(aStr)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    private static func measureText(_ text: String, font: CTFont) -> CGFloat {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        let aStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(aStr)
        return CTLineGetBoundsWithOptions(line, []).width
    }

    private static func condensedFont(size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName("BarlowCondensed-Black" as CFString, size, nil)
        if CTFontCopyFamilyName(font) as String == "Barlow Condensed" { return font }
        return CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, size, nil)
    }

    private static func bodyFont(size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName("Inter" as CFString, size, nil)
        if CTFontCopyFamilyName(font) as String == "Inter" { return font }
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    private static func easeOut(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        return 1.0 - pow(1.0 - t, 3)
    }
}
