import SwiftUI

/// Settings row group for managing LinkedIn auth: sign-in / connected display
/// name + sign-out. Designed to live inside SettingsView's List.
struct LinkedInSettingsSection: View {
    @State private var client = LinkedInClient()
    @State private var status: Status = .loading
    @State private var errorMessage: String?

    enum Status: Equatable {
        case loading
        case signedOut
        case signedIn(displayName: String?)
        case signingIn
    }

    var body: some View {
        Section("LinkedIn") {
            switch status {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                }
            case .signedOut:
                if !LinkedInConfig.isConfigured {
                    notConfiguredRow
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Label("Sign in with LinkedIn", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            case .signingIn:
                HStack {
                    ProgressView()
                    Text("Signing in…").foregroundStyle(.secondary)
                }
            case .signedIn(let displayName):
                LabeledContent("Account") {
                    Text(displayName ?? "Connected")
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
            Text("Set the LinkedIn client ID in Config/LinkedInConfig.swift and add LINKEDIN_CLIENT_SECRET as a Supabase secret. See docs/superpowers/setup/linkedin-setup.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() {
        if let tokens = client.currentTokens {
            status = .signedIn(displayName: tokens.displayName)
        } else {
            status = .signedOut
        }
        errorMessage = nil
    }

    private func signIn() async {
        guard LinkedInConfig.isConfigured else {
            errorMessage = "LinkedIn client ID not set."
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
