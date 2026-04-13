import SwiftUI
import UIKit

/// One-tap "Publish to YouTube Shorts" button. Reads the YouTube caption (or
/// falls back to LinkedIn) from the per-platform captions table, downloads the
/// rendered thumbnail PNG from Storage, and runs the full YouTube publish flow
/// via `YouTubeClient.publishShort`.
///
/// States:
///   - .idle: red "Publish to YouTube" button (or "Sign in to YouTube" if not authorized)
///   - .publishing(progress): inline progress bar 0–100%
///   - .success(url): green checkmark + tappable "View on YouTube"
///   - .failure(msg): red error + Retry button
struct YouTubePublishButton: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var state: PublishState = .idle
    @State private var client = YouTubeClient()

    /// YouTube brand red.
    private let youTubeRed = Color(red: 1.0, green: 0.0, blue: 0.0)

    enum PublishState: Equatable {
        case idle
        case publishing(progress: Double)
        case success(url: URL)
        case failure(message: String)
    }

    var body: some View {
        VStack(spacing: 8) {
            mainButton

            if case .success(let url) = state {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("View on YouTube")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(youTubeRed))
                }
            }

            if case .failure(let message) = state {
                VStack(spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.95))
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await publish() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                }
            }
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        Button {
            Task { await primaryAction() }
        } label: {
            HStack(spacing: 10) {
                icon
                    .font(.headline.weight(.bold))
                Text(label)
                    .font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(buttonForeground)
            .overlay(alignment: .bottom) {
                if case .publishing(let progress) = state {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: geo.size.width * CGFloat(progress), height: 3)
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            Image(systemName: client.isAuthorized ? "play.rectangle.fill" : "person.crop.circle.badge.plus")
        case .publishing:
            ProgressView()
                .tint(.white)
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var label: String {
        switch state {
        case .idle:
            return client.isAuthorized ? "Publish to YouTube" : "Sign in to YouTube"
        case .publishing(let progress):
            return "Uploading… \(Int(progress * 100))%"
        case .success:
            return "Published to YouTube"
        case .failure:
            return "Try Again"
        }
    }

    private var buttonBackground: Color {
        switch state {
        case .success: return Color(red: 0, green: 0.78, blue: 0.33)
        case .failure: return Color.white
        default: return youTubeRed
        }
    }

    private var buttonForeground: Color {
        switch state {
        case .failure: return .black
        default: return .white
        }
    }

    private var isDisabled: Bool {
        if case .publishing = state { return true }
        return !YouTubeConfig.isConfigured && !client.isAuthorized
    }

    // MARK: - Actions

    private func primaryAction() async {
        guard YouTubeConfig.isConfigured else {
            state = .failure(message: "YouTube not configured. See docs/superpowers/setup/youtube-setup.md.")
            return
        }
        if !client.isAuthorized {
            await signIn()
            return
        }
        // Already signed in — re-tapping (success or idle) triggers a fresh publish.
        await publish()
    }

    private func signIn() async {
        do {
            _ = try await client.authorize()
            // After auth, immediately kick off the publish so the user gets the one-tap experience.
            await publish()
        } catch {
            state = .failure(message: error.localizedDescription)
        }
    }

    private func publish() async {
        state = .publishing(progress: 0.0)
        do {
            let metadata = try await loadMetadata()
            let videoURL = appState.supabase.publicObjectURL(
                bucket: "shorts-videos",
                path: "\(short.id.uuidString.lowercased()).mp4"
            )
            let thumbData = await loadThumbnailData()

            let postURL = try await client.publishShort(
                videoURL: videoURL,
                thumbnailData: thumbData,
                title: metadata.title,
                description: metadata.description,
                tags: metadata.tags,
                privacyStatus: .publicVideo,
                progress: { fraction in
                    Task { @MainActor in
                        // Only update if we're still in publishing state (avoid flashing back from .success).
                        if case .publishing = state {
                            state = .publishing(progress: fraction)
                        }
                    }
                }
            )
            state = .success(url: postURL)
            try? await appState.supabase.recordShare(shortID: short.id, platform: .youtube_shorts)
        } catch {
            state = .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Caption / metadata loading

    private struct ShortMetadata {
        let title: String
        let description: String
        let tags: [String]
    }

    /// Pulls the YouTube caption (or LinkedIn fallback) and assembles the
    /// title/description/tags trio that `videos.insert` expects. YouTube titles
    /// are capped at 100 chars; we truncate defensively.
    private func loadMetadata() async throws -> ShortMetadata {
        let captions = try await appState.supabase.listCaptions(forShort: short.id)
        let preferred = captions.first(where: { $0.platform == Platform.youtube_shorts.rawValue })
            ?? captions.first(where: { $0.platform == Platform.linkedin.rawValue })
            ?? captions.first

        let rawTitle = preferred?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? short.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Short"
        let title = String(rawTitle.prefix(100))

        let bodyParts = [
            preferred?.body.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            short.hook.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        ].compactMap { $0 }
        let description = bodyParts.joined(separator: "\n\n")

        // Hashtags from the caption become YouTube tags (strip the leading '#').
        let tags = (preferred?.hashtags ?? []).map { tag in
            tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        }

        return ShortMetadata(title: title, description: description, tags: tags)
    }

    /// Best-effort thumbnail fetch. Returns nil if the rendered thumbnail isn't
    /// available — YouTube will then auto-generate a cover from the video.
    private func loadThumbnailData() async -> Data? {
        let url = appState.supabase.publicObjectURL(
            bucket: "shorts-thumbnails",
            path: "\(short.id.uuidString.lowercased()).png"
        )
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
