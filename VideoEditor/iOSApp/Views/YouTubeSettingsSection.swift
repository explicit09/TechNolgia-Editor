import SwiftUI

/// Settings row group for managing YouTube auth: sign-in / connected channel
/// title + sign-out. Designed to live inside SettingsView's List.
struct YouTubeSettingsSection: View {
    @State private var client = YouTubeClient()
    @State private var status: Status = .loading
    @State private var errorMessage: String?

    enum Status: Equatable {
        case loading
        case signedOut
        case signedIn(channelTitle: String?)
        case signingIn
    }

    var body: some View {
        Section("YouTube") {
            switch status {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                }
            case .signedOut:
                if !YouTubeConfig.isConfigured {
                    notConfiguredRow
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Label("Sign in with YouTube", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            case .signingIn:
                HStack {
                    ProgressView()
                    Text("Signing in…").foregroundStyle(.secondary)
                }
            case .signedIn(let channelTitle):
                LabeledContent("Channel") {
                    Text(channelTitle ?? "Connected")
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    client.signOut()
                    refreshStatus()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { refreshStatus() }
    }

    private var notConfiguredRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not configured", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Set the YouTube client ID in Config/YouTubeConfig.swift and update the URL scheme in project.yml. See docs/superpowers/setup/youtube-setup.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() {
        if let tokens = client.currentTokens {
            status = .signedIn(channelTitle: tokens.channelTitle)
        } else {
            status = .signedOut
        }
        errorMessage = nil
    }

    private func signIn() async {
        guard YouTubeConfig.isConfigured else {
            errorMessage = "YouTube client ID not set."
            return
        }
        status = .signingIn
        errorMessage = nil
        do {
            _ = try await client.authorize()
            refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            refreshStatus()
        }
    }
}
