import UIKit
import CoreGraphics

/// Locally composites a 1080x1920 thumbnail from a frame image + label overlay.
/// Mirrors the TBPN-style brand treatment used on macOS: dark green brand bar,
/// gold accent line, centered logo, and a colored pill label placed over the frame.
enum ThumbnailCompositor {

    /// Output size for the rendered thumbnail (Shorts / Reels portrait).
    static let outputSize = CGSize(width: 1080, height: 1920)

    /// Composites `frame` + label into a full-size thumbnail.
    ///
    /// - Parameters:
    ///   - frame: The candidate frame JPG decoded into a `UIImage`.
    ///   - labelText: The pill text (e.g. "ELONS BIGGEST FAN").
    ///   - labelColor: Hex color for the pill background (e.g. "#C9A028").
    ///   - labelPosition: Nine-point placement for the pill.
    /// - Returns: Rendered `UIImage`, or `nil` if rendering failed.
    static func render(
        frame: UIImage,
        labelText: String,
        labelColor: String,
        labelPosition: ThumbnailSettings.Position
    ) -> UIImage? {
        let size = outputSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 1. Fill background with the frame, aspect-fill style.
            drawAspectFill(image: frame, in: CGRect(origin: .zero, size: size))

            // 2. Dark overlay for legibility (subtle, only at bottom 50%).
            let gradientRect = CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.55)
            drawVerticalGradient(
                in: gradientRect,
                colors: [
                    UIColor.black.withAlphaComponent(0.0),
                    UIColor.black.withAlphaComponent(0.35),
                ],
                context: cg
            )

            // 3. Pill label.
            drawLabel(
                text: labelText,
                hex: labelColor,
                position: labelPosition,
                canvasSize: size,
                context: cg
            )
        }
    }

    // MARK: - Drawing helpers

    private static func drawAspectFill(image: UIImage, in rect: CGRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale
        let x = rect.midX - scaledW / 2
        let y = rect.midY - scaledH / 2
        image.draw(in: CGRect(x: x, y: y, width: scaledW, height: scaledH))
    }

    private static func drawVerticalGradient(
        in rect: CGRect,
        colors: [UIColor],
        context: CGContext
    ) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgColors = colors.map { $0.cgColor } as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: cgColors,
            locations: [0.0, 1.0]
        ) else { return }

        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
        context.restoreGState()
    }

    private static func drawLabel(
        text: String,
        hex: String,
        position: ThumbnailSettings.Position,
        canvasSize: CGSize,
        context: CGContext
    ) {
        guard !text.isEmpty else { return }

        let bg = UIColor(hex: hex) ?? UIColor(red: 201 / 255, green: 160 / 255, blue: 40 / 255, alpha: 1)
        let fg = bestTextColor(on: bg)

        let fontSize: CGFloat = 96
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: paragraph,
            .kern: 1.5,
        ]

        let textNS = text as NSString
        let maxWidth = canvasSize.width - 80
        let measured = textNS.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )

        let horizontalPadding: CGFloat = 48
        let verticalPadding: CGFloat = 28
        let pillWidth = min(measured.width + horizontalPadding * 2, canvasSize.width - 40)
        let pillHeight = measured.height + verticalPadding * 2

        let origin = pillOrigin(
            position: position,
            canvasSize: canvasSize,
            pillSize: CGSize(width: pillWidth, height: pillHeight)
        )

        let pillRect = CGRect(origin: origin, size: CGSize(width: pillWidth, height: pillHeight))
        let cornerRadius = pillHeight / 2

        // Drop shadow for pop.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 6),
            blur: 18,
            color: UIColor.black.withAlphaComponent(0.45).cgColor
        )
        let path = UIBezierPath(roundedRect: pillRect, cornerRadius: cornerRadius)
        bg.setFill()
        path.fill()
        context.restoreGState()

        let textRect = CGRect(
            x: pillRect.minX + horizontalPadding,
            y: pillRect.midY - measured.height / 2,
            width: pillRect.width - horizontalPadding * 2,
            height: measured.height
        )
        textNS.draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
    }

    private static func pillOrigin(
        position: ThumbnailSettings.Position,
        canvasSize: CGSize,
        pillSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 80
        let xLeft: CGFloat = margin
        let xCenter: CGFloat = (canvasSize.width - pillSize.width) / 2
        let xRight: CGFloat = canvasSize.width - pillSize.width - margin

        let yTop: CGFloat = margin
        let yCenter: CGFloat = (canvasSize.height - pillSize.height) / 2
        let yBottom: CGFloat = canvasSize.height - pillSize.height - margin

        switch position {
        case .topLeft:      return CGPoint(x: xLeft,   y: yTop)
        case .topCenter:    return CGPoint(x: xCenter, y: yTop)
        case .topRight:     return CGPoint(x: xRight,  y: yTop)
        case .centerLeft:   return CGPoint(x: xLeft,   y: yCenter)
        case .center:       return CGPoint(x: xCenter, y: yCenter)
        case .centerRight:  return CGPoint(x: xRight,  y: yCenter)
        case .bottomLeft:   return CGPoint(x: xLeft,   y: yBottom)
        case .bottomCenter: return CGPoint(x: xCenter, y: yBottom)
        case .bottomRight:  return CGPoint(x: xRight,  y: yBottom)
        }
    }

    /// Pick black or white for text based on pill background luminance.
    private static func bestTextColor(on background: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Perceived luminance (Rec. 709-ish)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .black : .white
    }
}

// MARK: - UIColor hex convenience

extension UIColor {
    /// Initialize from a hex string like "#C9A028" or "C9A028".
    convenience init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }

    /// Hex string representation like "#RRGGBB".
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(round(r * 255))
        let gi = Int(round(g * 255))
        let bi = Int(round(b * 255))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}
