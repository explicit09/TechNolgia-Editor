import SwiftUI

struct DetailView: View {
    let short: Short
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                playerSection
                metadataSection
                EpisodeSection(short: short)
                ThumbnailEditorView(short: short)
                CaptionEditorView(short: short)
                VStack(spacing: 12) {
                    ShareButton(short: short, activeCaption: nil, thumbnailImage: nil)
                    LinkedInPublishButton(short: short)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 8 / 255, green: 12 / 255, blue: 19 / 255),
                    Color(red: 17 / 255, green: 28 / 255, blue: 47 / 255),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle(short.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var playerSection: some View {
        let url = appState.supabase.publicObjectURL(
            bucket: "shorts-videos",
            path: "\(short.id.uuidString.lowercased()).mp4"
        )

        VideoPlayerView(videoURL: url)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(short.label)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            Text(short.hook)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))

            metricsRow

            Text(short.reasoning)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 4)
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 10) {
            metricPill(
                icon: "leaf.fill",
                label: "Evergreen",
                value: "\(short.evergreenScore)/10"
            )
            metricPill(
                icon: "flame.fill",
                label: "Trending",
                value: "\(short.trendingScore)/10"
            )
            metricPill(
                icon: "scissors",
                label: "Source",
                value: sourceRangeLabel
            )
        }
    }

    private var sourceRangeLabel: String {
        let start = Int(short.sourceStart.rounded())
        let end = Int(short.sourceEnd.rounded())
        return "\(start)–\(end)s"
    }

    private func metricPill(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: Capsule())
    }
}
