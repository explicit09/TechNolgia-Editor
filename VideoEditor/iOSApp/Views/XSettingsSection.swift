import SwiftUI

/// Settings row group for managing X auth: sign-in / connected handle + name
/// / sign-out. Designed to live inside SettingsView's List.
struct XSettingsSection: View {
    @State private var client = XClient()
    @State private var status: Status = .loading
    @State private var errorMessage: String?

    enum Status: Equatable {
        case loading
        case signedOut
        case signedIn(username: String, name: String?)
        case signingIn
    }

    var body: some View {
        Section("X") {
            switch status {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                }
            case .signedOut:
                if !XConfig.isConfigured {
                    notConfiguredRow
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Label("Sign in with X", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            case .signingIn:
                HStack {
                    ProgressView()
                    Text("Signing in…").foregroundStyle(.secondary)
                }
            case .signedIn(let username, let name):
                LabeledContent("Account") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("@\(username)")
                            .foregroundStyle(.secondary)
                        if let name, !name.isEmpty {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                    }
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
            Text("Set the X client ID in Config/XConfig.swift. See docs/superpowers/setup/x-setup.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() {
        if let tokens = client.currentTokens {
            status = .signedIn(username: tokens.username, name: tokens.name)
        } else {
            status = .signedOut
        }
        errorMessage = nil
    }

    private func signIn() async {
        guard XConfig.isConfigured else {
            errorMessage = "X client ID not set."
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
