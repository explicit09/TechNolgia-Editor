import SwiftUI
import UIKit

/// Full-width share button that downloads the short's MP4 (and optional
/// caption/thumbnail) and presents the native UIActivityViewController so the
/// user can hand the asset off to YouTube, TikTok, Instagram, X, LinkedIn,
/// Messages, etc. Share completion is logged to Supabase `share_intents` for
/// lightweight analytics. Caption/thumbnail wiring is a placeholder for later
/// tasks (Task 9/11).
struct ShareButton: View {
    let short: Short
    let activeCaption: Caption?
    let thumbnailImage: UIImage?

    @Environment(AppState.self) private var appState

    @State private var isPreparing = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task { await prepareAndShare() }
            } label: {
                HStack(spacing: 10) {
                    if isPreparing {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline.weight(.bold))
                    }
                    Text(isPreparing ? "Preparing…" : "Share")
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(isPreparing)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { shareItems = [] }) {
            ActivityViewController(activityItems: shareItems) { activityType, completed in
                guard completed else { return }
                let platform = platform(for: activityType)
                Task {
                    try? await appState.supabase.recordShare(shortID: short.id, platform: platform)
                }
            }
        }
    }

    private func prepareAndShare() async {
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        let videoURL = appState.supabase.publicObjectURL(
            bucket: "shorts-videos",
            path: "\(short.id.uuidString.lowercased()).mp4"
        )

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: videoURL)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(short.id.uuidString.lowercased()).mp4")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            var items: [Any] = [destination]
            if let caption = activeCaption {
                let captionText = Self.formatCaption(caption)
                if !captionText.isEmpty {
                    items.append(captionText)
                }
            }
            if let thumbnailImage {
                items.append(thumbnailImage)
            }

            shareItems = items
            showShareSheet = true
        } catch {
            errorMessage = "Couldn't prepare share: \(error.localizedDescription)"
        }
    }

    private static func formatCaption(_ caption: Caption) -> String {
        var pieces: [String] = []
        if let title = caption.title, !title.isEmpty {
            pieces.append(title)
        }
        if !caption.body.isEmpty {
            pieces.append(caption.body)
        }
        if !caption.hashtags.isEmpty {
            pieces.append(caption.hashtags.joined(separator: " "))
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Best-effort mapping of UIActivity types to our Platform enum for analytics.
    private func platform(for activityType: UIActivity.ActivityType?) -> Platform {
        guard let raw = activityType?.rawValue.lowercased() else { return .youtube_shorts }
        if raw.contains("tiktok") { return .tiktok }
        if raw.contains("instagram") { return .instagram_reels }
        if raw.contains("twitter") || raw.contains("com.atebits") || raw.contains("x.com") { return .twitter }
        if raw.contains("linkedin") { return .linkedin }
        if raw.contains("youtube") || raw.contains("google.ios.youtube") { return .youtube_shorts }
        return .youtube_shorts
    }
}

/// UIKit bridge around UIActivityViewController so we can present the native
/// share sheet and observe completion.
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: (UIActivity.ActivityType?, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            onComplete(activityType, completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
