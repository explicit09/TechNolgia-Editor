import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Namespace private var glassNamespace

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 8 / 255, green: 12 / 255, blue: 19 / 255),
                    Color(red: 17 / 255, green: 28 / 255, blue: 47 / 255),
                    Color(red: 51 / 255, green: 39 / 255, blue: 16 / 255),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    statusStrip
                    draftSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Distribution")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private var hero: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        Label("Factory to Phone", systemImage: "sparkles.rectangle.stack")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect(.regular.tint(.white.opacity(0.14)), in: .capsule)

                        Spacer()

                        Image("technolgia_logo_tight")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Review, tune, and ship shorts from anywhere.")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("This first pass is the shell: shared library, caption editing, thumbnail editing, and posting flow come next.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    HStack(spacing: 12) {
                        Button("Open Library") {}
                            .buttonStyle(.glassProminent)
                        Button("See Plan") {}
                            .buttonStyle(.glass)
                    }
                }
                .padding(22)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .glassEffect(.regular.tint(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Image("technolgia_logo_tight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120)
                Text("Review, tune, and ship shorts from anywhere.")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("This first pass is the shell: shared library, caption editing, thumbnail editing, and posting flow come next.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            MetricPill(title: "Library", value: "Ready")
            MetricPill(title: "Captions", value: "Soon")
            MetricPill(title: "Thumbs", value: "Soon")
        }
    }

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(appState.shorts) { short in
                    NavigationLink {
                        ShortDetailView(short: short)
                    } label: {
                        ShortCard(short: short)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

private struct ShortCard: View {
    let short: ShortItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: short.thumbnailGradient.compactMap { hex in
                            guard let color = makeColor(hex: hex) else { return nil }
                            return color
                        },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 178)
                .overlay(alignment: .topTrailing) {
                    Image("technolgia_logo_tight")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76)
                        .padding(12)
                }
                .overlay(alignment: .bottom) {
                    Text(short.thumbnailSettings.labelText)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255), in: Capsule())
                        .padding(12)
                }

            Text(short.label)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text(short.sourceTitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))

            Text(short.durationText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func makeColor(hex: String) -> Color? {
        let raw = hex.replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

#Preview {
    NavigationStack {
        LibraryView()
            .environment(AppState())
    }
}
