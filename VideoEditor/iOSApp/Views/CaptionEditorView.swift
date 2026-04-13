import SwiftUI
import UIKit

/// Per-platform caption editor with tabs for the five target platforms, inline
/// editing of title/body/hashtags, save-to-DB, and Claude-powered regenerate.
struct CaptionEditorView: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var captions: [Platform: Caption] = [:]
    @State private var selectedPlatform: Platform = .youtube_shorts
    @State private var hashtagText: [Platform: String] = [:]

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isRegenerating = false

    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var copiedBody: Bool = false
    @State private var copyResetTask: Task<Void, Never>?

    private let gold = Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255)
    private let fieldFill = Color.white.opacity(0.06)
    private let fieldStroke = Color.white.opacity(0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Spacer()
                }
                .frame(minHeight: 140)
            } else if let caption = captions[selectedPlatform] {
                platformPicker
                editor(for: caption)
                actions
                statusLine(for: caption)
            } else {
                Text("No caption exists for \(selectedPlatform.displayName) yet.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let successMessage {
                Text(successMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.green.opacity(0.9)))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: successMessage)
        .task {
            await loadCaptions()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Captions")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private var platformPicker: some View {
        Picker("Platform", selection: $selectedPlatform) {
            ForEach(Platform.allCases) { platform in
                Text(platform.displayName).tag(platform)
            }
        }
        .pickerStyle(.segmented)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private func editor(for caption: Caption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if caption.title != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    TextField(
                        "Title",
                        text: Binding(
                            get: { captions[selectedPlatform]?.title ?? "" },
                            set: { captions[selectedPlatform]?.title = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(fieldFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(fieldStroke, lineWidth: 1)
                    )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Body")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        copyBody()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedBody ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                            Text(copiedBody ? "Copied" : "Copy")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(copiedBody ? 0.2 : 0.1)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                TextEditor(
                    text: Binding(
                        get: { captions[selectedPlatform]?.body ?? "" },
                        set: { captions[selectedPlatform]?.body = $0 }
                    )
                )
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
                .frame(minHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fieldFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(fieldStroke, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hashtags")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                TextField(
                    "#foo #bar",
                    text: Binding(
                        get: { hashtagText[selectedPlatform] ?? "" },
                        set: { newValue in
                            hashtagText[selectedPlatform] = newValue
                            let tags = newValue
                                .split(whereSeparator: { $0.isWhitespace })
                                .map(String.init)
                                .filter { !$0.isEmpty }
                            captions[selectedPlatform]?.hashtags = tags
                        }
                    )
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .foregroundStyle(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fieldFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(fieldStroke, lineWidth: 1)
                )
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().progressViewStyle(.circular).tint(.black)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text("Save")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(gold)
            .foregroundStyle(.black)
            .disabled(isSaving || isRegenerating || captions[selectedPlatform] == nil)

            Button {
                Task { await regenerate() }
            } label: {
                HStack(spacing: 6) {
                    if isRegenerating {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Regenerate")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .foregroundStyle(.white)
            .disabled(isSaving || isRegenerating)
        }
    }

    @ViewBuilder
    private func statusLine(for caption: Caption) -> some View {
        Text("Last edited by \(caption.lastEditedBy)")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: - Actions

    private func loadCaptions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await appState.supabase.listCaptions(forShort: short.id)
            var byPlatform: [Platform: Caption] = [:]
            var hashtagStrings: [Platform: String] = [:]
            for caption in list {
                guard let platform = Platform(rawValue: caption.platform) else { continue }
                byPlatform[platform] = caption
                hashtagStrings[platform] = caption.hashtags.joined(separator: " ")
            }
            captions = byPlatform
            hashtagText = hashtagStrings
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load captions: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let caption = captions[selectedPlatform] else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.supabase.updateCaption(
                shortID: short.id,
                platform: selectedPlatform,
                title: caption.title,
                body: caption.body,
                hashtags: caption.hashtags
            )
            captions[selectedPlatform]?.lastEditedBy = "ios"
            showSuccess("Saved \(selectedPlatform.displayName)")
            errorMessage = nil
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func regenerate() async {
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            let result = try await EdgeFunctions.regenerateCaption(
                shortID: short.id,
                platform: selectedPlatform
            )
            if var existing = captions[selectedPlatform] {
                existing.title = result.title
                existing.body = result.body
                existing.hashtags = result.hashtags
                existing.lastEditedBy = "claude_regen"
                captions[selectedPlatform] = existing
            }
            hashtagText[selectedPlatform] = result.hashtags.joined(separator: " ")
            showSuccess("Regenerated with Claude")
            errorMessage = nil
        } catch {
            errorMessage = "Regenerate failed: \(error.localizedDescription)"
        }
    }

    private func copyBody() {
        guard let body = captions[selectedPlatform]?.body, !body.isEmpty else { return }
        UIPasteboard.general.string = body
        copiedBody = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                await MainActor.run { copiedBody = false }
            }
        }
    }

    private func showSuccess(_ message: String) {
        successMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { successMessage = nil }
            }
        }
    }
}
