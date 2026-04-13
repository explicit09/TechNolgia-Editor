import SwiftUI

struct ShortDetailView: View {
    @State private var short: ShortItem
    @State private var selectedPlatform: ShortPlatform = .youtubeShorts

    init(short: ShortItem) {
        _short = State(initialValue: short)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                previewPanel
                captionPanel
                thumbnailPanel
            }
            .padding(20)
            .padding(.bottom, 32)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .navigationTitle(short.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            thumbnailPreview(height: 250)

            VStack(alignment: .leading, spacing: 8) {
                Text(short.sourceTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(short.hook)
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: 10) {
                    detailChip(short.durationText, systemImage: "timer")
                    detailChip(selectedPlatform.rawValue, systemImage: "bubble.left.and.text.bubble.right")
                    detailChip(short.frames[safe: short.thumbnailSettings.frameIndex] ?? "Frame 1", systemImage: "photo")
                }
            }
        }
    }

    private var captionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Captions")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            Picker("Platform", selection: $selectedPlatform) {
                ForEach(ShortPlatform.allCases) { platform in
                    Text(platform.rawValue).tag(platform)
                }
            }
            .pickerStyle(.segmented)

            if let index = short.captions.firstIndex(where: { $0.platform == selectedPlatform }) {
                VStack(alignment: .leading, spacing: 12) {
                    if selectedPlatform == .youtubeShorts {
                        TextField(
                            "Title",
                            text: Binding(
                                get: { short.captions[index].title ?? "" },
                                set: { short.captions[index].title = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    TextField(
                        "Body",
                        text: Binding(
                            get: { short.captions[index].body },
                            set: { short.captions[index].body = $0 }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "Hashtags",
                        text: Binding(
                            get: { short.captions[index].hashtags.joined(separator: " ") },
                            set: { newValue in
                                short.captions[index].hashtags = newValue
                                    .split(separator: " ")
                                    .map(String.init)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
        .panelStyle()
    }

    private var thumbnailPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Thumbnail")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            TextField(
                "Label",
                text: Binding(
                    get: { short.thumbnailSettings.labelText },
                    set: { short.thumbnailSettings.labelText = String($0.prefix(28)).uppercased() }
                )
            )
            .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                HStack(spacing: 10) {
                    ForEach(Config.brandPalette) { brand in
                        Button {
                            short.thumbnailSettings.colorName = brand.name
                        } label: {
                            Circle()
                                .fill(brand.color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if short.thumbnailSettings.colorName == brand.name {
                                        Circle()
                                            .stroke(.white, lineWidth: 2)
                                            .padding(2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Position")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach(ThumbnailGridPosition.allCases) { position in
                        Button(position.title) {
                            short.thumbnailSettings.position = position
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            short.thumbnailSettings.position == position
                                ? .white.opacity(0.18)
                                : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Frame")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Picker("Frame", selection: $short.thumbnailSettings.frameIndex) {
                    ForEach(Array(short.frames.enumerated()), id: \.offset) { index, frame in
                        Text(frame).tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .panelStyle()
    }

    @ViewBuilder
    private func thumbnailPreview(height: CGFloat) -> some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack(alignment: labelAlignment(for: short.thumbnailSettings.position)) {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(backgroundGradient)
                    .overlay(alignment: .topTrailing) {
                        Image("technolgia_logo_tight")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 108)
                            .padding(18)
                    }

                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: size.width * 0.42)
                    .offset(x: size.width * 0.16, y: -size.height * 0.06)

                Text(short.thumbnailSettings.labelText)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(textColor(for: currentBrandColor))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(currentBrandColor, in: Capsule())
                    .padding(labelPadding(for: short.thumbnailSettings.position))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var currentBrandColor: Color {
        Config.brandPalette.first(where: { $0.name == short.thumbnailSettings.colorName })?.color ?? .white
    }

    private var backgroundGradient: LinearGradient {
        let colors = short.thumbnailGradient.compactMap(Color.init(hex:))
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func labelAlignment(for position: ThumbnailGridPosition) -> Alignment {
        switch position {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        }
    }

    private func labelPadding(for position: ThumbnailGridPosition) -> EdgeInsets {
        switch position {
        case .topLeading:
            EdgeInsets(top: 22, leading: 22, bottom: 0, trailing: 0)
        case .top:
            EdgeInsets(top: 22, leading: 0, bottom: 0, trailing: 0)
        case .topTrailing:
            EdgeInsets(top: 22, leading: 0, bottom: 0, trailing: 22)
        case .leading:
            EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 0)
        case .center:
            EdgeInsets()
        case .trailing:
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 22)
        case .bottomLeading:
            EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 0)
        case .bottom:
            EdgeInsets(top: 0, leading: 0, bottom: 22, trailing: 0)
        case .bottomTrailing:
            EdgeInsets(top: 0, leading: 0, bottom: 22, trailing: 22)
        }
    }

    private func textColor(for color: Color) -> Color {
        short.thumbnailSettings.colorName == "White"
            ? Config.brandPalette.first(where: { $0.name == "Navy" })?.color ?? .black
            : .white
    }

    private func detailChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: Capsule())
    }
}

private extension View {
    func panelStyle() -> some View {
        self
            .padding(18)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private extension Color {
    init?(hex: String) {
        let raw = hex.replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    NavigationStack {
        ShortDetailView(short: MockShorts.library[0])
    }
}
