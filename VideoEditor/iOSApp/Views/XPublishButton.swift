import SwiftUI
import UIKit

/// One-tap "Publish to X" button. Reads the X caption (falling back to
/// YouTube → LinkedIn → any) from the per-platform captions table, and runs
/// the full X publish flow via `XClient.publishShort`.
///
/// States:
///   - .idle: black "Publish to X" button (or "Sign in to X" if not authorized)
///   - .publishing(progress): inline progress bar 0–100%
///   - .success(url): green checkmark + tappable "View on X"
///   - .failure(msg): red error + Retry button
///
/// X does not accept custom thumbnails — the success card notes that X
/// auto-generates the cover from a video frame.
struct XPublishButton: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var state: PublishState = .idle
    @State private var client = XClient()

    /// X's monochrome brand palette.
    private let xBlack = Color.black
    private let xAccent = Color.white

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
                VStack(spacing: 4) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                            Text("View on X")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(xBlack))
                        .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                    Text("X auto-generates cover from video frame")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
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
                    .font(.headline.weight(.black))
                Text(label)
                    .font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(buttonStrokeColor, lineWidth: 1)
            )
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
            if client.isAuthorized {
                Text("X")
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
            }
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
            return client.isAuthorized ? "Publish to X" : "Sign in to X"
        case .publishing(let progress):
            return "Uploading… \(Int(progress * 100))%"
        case .success:
            return "Published to X"
        case .failure:
            return "Try Again"
        }
    }

    private var buttonBackground: Color {
        switch state {
        case .success: return Color(red: 0, green: 0.78, blue: 0.33)
        case .failure: return Color.white
        default: return xBlack
        }
    }

    private var buttonStrokeColor: Color {
        switch state {
        case .success, .failure: return .clear
        default: return Color.white.opacity(0.25)
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
        return !XConfig.isConfigured && !client.isAuthorized
    }

    // MARK: - Actions

    private func primaryAction() async {
        guard XConfig.isConfigured else {
            state = .failure(message: "X not configured. See docs/superpowers/setup/x-setup.md.")
            return
        }
        if !client.isAuthorized {
            await signIn()
            return
        }
        await publish()
    }

    private func signIn() async {
        do {
            _ = try await client.authorize()
            await publish()
        } catch {
            state = .failure(message: error.localizedDescription)
        }
    }

    private func publish() async {
        state = .publishing(progress: 0.0)
        do {
            let payload = try await loadCaption()
            let videoURL = appState.supabase.publicObjectURL(
                bucket: "shorts-videos",
                path: "\(short.id.uuidString.lowercased()).mp4"
            )

            let postURL = try await client.publishShort(
                videoURL: videoURL,
                caption: payload.body,
                hashtags: payload.hashtags,
                progress: { fraction in
                    Task { @MainActor in
                        if case .publishing = state {
                            state = .publishing(progress: fraction)
                        }
                    }
                }
            )
            state = .success(url: postURL)
            try? await appState.supabase.recordShare(shortID: short.id, platform: .twitter)
        } catch {
            state = .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Caption loading

    private struct XCaption {
        let body: String
        let hashtags: [String]
    }

    /// Prefer the user's X-specific caption; fall back to YouTube → LinkedIn →
    /// any caption → the short's hook. We pass body + hashtags separately so
    /// `XClient.buildTweetText` can truncate cleanly to 280 chars.
    private func loadCaption() async throws -> XCaption {
        let captions = try await appState.supabase.listCaptions(forShort: short.id)
        let preferred = captions.first(where: { $0.platform == Platform.twitter.rawValue })
            ?? captions.first(where: { $0.platform == Platform.youtube_shorts.rawValue })
            ?? captions.first(where: { $0.platform == Platform.linkedin.rawValue })
            ?? captions.first

        if let caption = preferred {
            var bodyParts: [String] = []
            if let title = caption.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                bodyParts.append(title)
            }
            let body = caption.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { bodyParts.append(body) }
            let joinedBody = bodyParts.joined(separator: " — ")
            return XCaption(
                body: joinedBody.isEmpty ? short.hook : joinedBody,
                hashtags: caption.hashtags
            )
        }
        return XCaption(body: short.hook, hashtags: [])
    }
}
