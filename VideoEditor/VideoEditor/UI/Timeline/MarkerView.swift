import SwiftUI
import EditorCore

struct MarkersOverlay: View {
    let markers: [Marker]
    let viewState: TimelineViewState

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(markers) { marker in
                let x = viewState.durationToWidth(marker.time)
                let accent = MarkerColor.swiftUIColor(marker.color)

                // Marker line (thin, full height)
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    .stroke(accent.opacity(0.45), lineWidth: 0.5)
                }

                // Marker flag pinned to top edge only
                HStack(spacing: 2) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(accent)

                    if !marker.label.isEmpty {
                        Text(marker.label)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(accent.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .offset(x: x - 3, y: 0) // Pin to very top
            }
        }
        .allowsHitTesting(false)
    }
}

private enum MarkerColor {
    static func swiftUIColor(_ colorString: String) -> Color {
        let trimmed = colorString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let hex = trimmed.dropFirst()
            if let color = Color(hexDigits: String(hex)) {
                return color
            }
        } else if let color = Color(hexDigits: trimmed) {
            return color
        }
        switch trimmed.lowercased() {
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "cyan": return .cyan
        case "magenta": return .pink
        default: return CinematicTheme.primary
        }
    }
}

private extension Color {
    init?(hexDigits: String) {
        let s = hexDigits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (s.count == 6 || s.count == 8), let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255.0
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255.0
        let a = hasAlpha ? Double(value & 0xFF) / 255.0 : 1.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
