import SwiftUI
import UIKit

/// One-tap "Post to LinkedIn" button. Reads the LinkedIn caption (or falls back
/// to YouTube) from the per-platform captions table, downloads the rendered
/// thumbnail PNG from Storage, and runs the full LinkedIn publish flow via
/// `LinkedInClient.publishShort`.
///
/// States:
///   - .idle: gold "Post to LinkedIn" button (or "Sign in to LinkedIn" if not authorized)
///   - .publishing(progress): inline progress bar 0–100%
///   - .success(url): green checkmark + tappable "View on LinkedIn"
///   - .failure(msg): red error + Retry button
struct LinkedInPublishButton: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var state: PublishState = .idle
    @State private var client = LinkedInClient()

    private let gold = Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255)
    private let linkedInBlue = Color(red: 10 / 255, green: 102 / 255, blue: 194 / 255)

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
                        Text("View on LinkedIn")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(linkedInBlue))
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
                            .fill(Color.white.opacity(0.35))
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
            Image(systemName: client.isAuthorized ? "paperplane.fill" : "person.crop.circle.badge.plus")
        case .publishing:
            ProgressView()
                .tint(.black)
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var label: String {
        switch state {
        case .idle:
            return client.isAuthorized ? "Post to LinkedIn" : "Sign in to LinkedIn"
        case .publishing(let progress):
            return "Publishing… \(Int(progress * 100))%"
        case .success:
            return "Posted to LinkedIn"
        case .failure:
            return "Try Again"
        }
    }

    private var buttonBackground: Color {
        switch state {
        case .success: return Color(red: 0, green: 0.78, blue: 0.33)
        case .failure: return Color.white
        default: return gold
        }
    }

    private var buttonForeground: Color {
        switch state {
        case .success: return .white
        default: return .black
        }
    }

    private var isDisabled: Bool {
        if case .publishing = state { return true }
        return !LinkedInConfig.isConfigured && !client.isAuthorized
    }

    // MARK: - Actions

    private func primaryAction() async {
        guard LinkedInConfig.isConfigured else {
            state = .failure(message: "LinkedIn not configured. See docs/superpowers/setup/linkedin-setup.md.")
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
            let commentary = try await loadCommentary()
            let videoURL = appState.supabase.publicObjectURL(
                bucket: "shorts-videos",
                path: "\(short.id.uuidString.lowercased()).mp4"
            )
            let thumbData = await loadThumbnailData()

            let postURL = try await client.publishShort(
                videoURL: videoURL,
                thumbnailData: thumbData,
                commentary: commentary,
                visibility: .public,
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
            try? await appState.supabase.recordShare(shortID: short.id, platform: .linkedin)
        } catch {
            state = .failure(message: error.localizedDescription)
        }
    }

    /// Pulls the LinkedIn caption (or YouTube fallback) and renders it as plain
    /// commentary text suitable for LinkedIn's `commentary` field.
    private func loadCommentary() async throws -> String {
        let captions = try await appState.supabase.listCaptions(forShort: short.id)
        let preferred = captions.first(where: { $0.platform == Platform.linkedin.rawValue })
            ?? captions.first(where: { $0.platform == Platform.youtube_shorts.rawValue })
            ?? captions.first

        if let caption = preferred {
            return Self.formatCaption(caption)
        }
        // Last-resort: use the short's hook so the post isn't empty.
        return short.hook
    }

    private static func formatCaption(_ caption: Caption) -> String {
        var pieces: [String] = []
        if let title = caption.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            pieces.append(title)
        }
        let body = caption.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            pieces.append(body)
        }
        if !caption.hashtags.isEmpty {
            pieces.append(caption.hashtags.joined(separator: " "))
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Best-effort thumbnail fetch. Returns nil if the rendered thumbnail isn't
    /// available — LinkedIn will then auto-generate a cover from the video.
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
