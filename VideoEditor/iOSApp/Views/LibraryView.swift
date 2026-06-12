import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Namespace private var glassNamespace
    @State private var selectedEpisodeKey: String = EpisodeGroupKey.all

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
                    liveSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .refreshable { await appState.refreshLibrary() }
        }
        .task { await appState.refreshLibrary() }
        .overlay(alignment: .top) {
            if let msg = appState.errorMessage {
                Text(msg)
                    .font(.caption)
                    .padding(10)
                    .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
        }
        .navigationTitle("Distribution")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private var hero: some View {
        HStack(alignment: .center, spacing: 14) {
            Image("technolgia_logo_tight")
                .resizable()
                .scaledToFit()
                .frame(height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("TechNolgia")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text("Factory to Phone")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            MetricPill(title: "Shorts", value: "\(appState.liveShorts.count)")
            MetricPill(title: "Episodes", value: "\(episodeGroups.filter { !$0.key.isEmpty }.count)")
            MetricPill(
                title: "Total",
                value: totalDurationLabel
            )
            MetricPill(
                title: "Top",
                value: topScoreLabel
            )
            if appState.isLoading {
                MetricPill(title: "Syncing", value: "…")
            }
            Spacer(minLength: 0)
        }
    }

    private var totalDurationLabel: String {
        let total = Int(appState.liveShorts.reduce(0) { $0 + $1.duration }.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private var topScoreLabel: String {
        guard let score = appState.liveShorts.map(\.distributionScore).max() else {
            return "—"
        }
        return "\(score)"
    }

    @ViewBuilder
    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Episodes")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if appState.isLoading {
                    ProgressView().tint(.white)
                }
                Text("\(appState.liveShorts.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            if appState.liveShorts.isEmpty && !appState.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("No shorts yet")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Produce some on Mac and they'll appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                episodeContent
            }
        }
    }

    @ViewBuilder
    private var episodeContent: some View {
        if selectedEpisodeKey == EpisodeGroupKey.all {
            episodeOverview
        } else if let group = episodeGroups.first(where: { $0.key == selectedEpisodeKey }) {
            episodeDetail(group)
        } else {
            episodeOverview
        }
    }

    private var episodeGroups: [EpisodeGroup] {
        let groups = Dictionary(grouping: appState.liveShorts) { short -> String in
            let n = (short.episodeName ?? "").trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? "" : n
        }
        let keys = groups.keys.sorted { (a, b) in
            if a.isEmpty && !b.isEmpty { return false }
            if b.isEmpty && !a.isEmpty { return true }
            return a < b
        }
        return keys.map { key in
            let shorts = (groups[key] ?? []).sorted { l, r in
                switch (l.episodeOrder, r.episodeOrder) {
                case let (.some(a), .some(b)): return a < b
                case (.some, .none): return true
                case (.none, .some): return false
                default: return l.createdAt > r.createdAt
                }
            }
            return EpisodeGroup(key: key, shorts: shorts)
        }
    }

    private var episodeOverview: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(episodeGroups) { group in
                Button {
                    selectedEpisodeKey = group.key
                } label: {
                    EpisodeFolderCard(group: group)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func episodeDetail(_ group: EpisodeGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    selectedEpisodeKey = EpisodeGroupKey.all
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("\(group.shorts.count) shorts · \(group.durationLabel)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(group.shorts) { short in
                    NavigationLink {
                        DetailView(short: short)
                    } label: {
                        LiveShortCard(short: short)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private enum EpisodeGroupKey {
    static let all = "__all__"
}

private struct EpisodeGroup: Identifiable {
    let key: String
    let shorts: [Short]

    var id: String { key }
    var title: String { key.isEmpty ? "Unassigned" : key }
    var durationLabel: String {
        Self.durationLabel(shorts.reduce(0) { $0 + $1.duration })
    }

    var latestShort: Short? {
        shorts.max { $0.createdAt < $1.createdAt }
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remaining = total % 60
        return remaining == 0 ? "\(minutes)m" : "\(minutes)m \(remaining)s"
    }
}

private struct EpisodeFolderCard: View {
    let group: EpisodeGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: group.key.isEmpty ? "tray.fill" : "rectangle.stack.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255))

                Spacer()

                Text("\(group.shorts.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(group.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(group.durationLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 0)

            if let latest = group.latestShort {
                Text(latest.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LiveShortCard: View {
    let short: Short
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: appState.supabase.publicObjectURL(
                bucket: "shorts-thumbnails",
                path: short.id.uuidString.lowercased() + ".png"
            )) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(9.0/16.0, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 178)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .empty:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 178)
                        .overlay(ProgressView().tint(.white))
                case .failure:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 178)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.5))
                        )
                @unknown default:
                    EmptyView()
                }
            }
            .overlay(alignment: .topTrailing) {
                ScoreBadge(short: short)
                    .padding(8)
            }

            Text(short.label)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(short.sourceAsset)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
            HStack(spacing: 8) {
                CompactScorePill(title: "Fit", value: short.distributionScoreLabel)
                CompactScorePill(title: short.postingPriorityLabel, value: short.scoreSummaryLabel)
            }
            Text(Self.durationLabel(short.duration))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let m = s / 60
        let r = s % 60
        return m > 0 ? "\(m):\(String(format: "%02d", r))" : "\(r)s"
    }
}

private struct ScoreBadge: View {
    let short: Short

    var body: some View {
        VStack(spacing: 1) {
            Text(short.distributionScoreLabel)
                .font(.headline.weight(.black))
                .monospacedDigit()
            Text(short.postingPriorityLabel)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(scoreColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Distribution score \(short.distributionScore), \(short.postingPriorityLabel)")
    }

    private var scoreColor: Color {
        switch short.distributionScore {
        case 85...:
            return Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255)
        case 65..<85:
            return Color(red: 119 / 255, green: 205 / 255, blue: 170 / 255)
        default:
            return Color.white.opacity(0.82)
        }
    }
}

private struct CompactScorePill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
            Text(value)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
