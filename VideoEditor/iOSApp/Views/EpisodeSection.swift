import SwiftUI

/// Lets the user assign a Short to an episode + set its position in that episode.
/// Library view groups by episode_name and sorts by episode_order so the user
/// can control the publishing sequence of all shorts cut from one recording.
struct EpisodeSection: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var episodeName: String = ""
    @State private var orderString: String = ""
    @State private var isSaving = false
    @State private var savedAt: Date? = nil
    @State private var errorMessage: String? = nil

    private let gold = Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255)
    private let fieldFill = Color.white.opacity(0.06)
    private let fieldStroke = Color.white.opacity(0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Episode")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }

            HStack(spacing: 8) {
                field(
                    placeholder: "Episode name",
                    text: $episodeName,
                    flex: 2
                )
                .autocorrectionDisabled(true)

                field(
                    placeholder: "#",
                    text: $orderString,
                    flex: 0.6
                )
                .keyboardType(.numberPad)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().progressViewStyle(.circular).tint(.black)
                        } else if savedAt != nil {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        Text(savedAt != nil ? "Saved" : "Save episode")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(gold)
                .foregroundStyle(.black)
                .disabled(isSaving)

                if !episodeName.isEmpty {
                    Button(role: .destructive) {
                        Task { await clear() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "minus.circle")
                            Text("Unassign")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .disabled(isSaving)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.95))
            }
        }
        .onAppear {
            episodeName = short.episodeName ?? ""
            if let ord = short.episodeOrder {
                orderString = String(ord)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: savedAt)
    }

    private func field(placeholder: String, text: Binding<String>, flex: CGFloat) -> some View {
        TextField(placeholder, text: text)
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
            .frame(maxWidth: flex > 1 ? .infinity : 80)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let name = episodeName.trimmingCharacters(in: .whitespaces)
            let order = Int(orderString.trimmingCharacters(in: .whitespaces))
            try await appState.supabase.updateEpisode(
                shortID: short.id,
                name: name.isEmpty ? nil : name,
                order: order
            )
            // Refresh library so grouping picks up the change.
            await appState.refreshLibrary()
            savedAt = Date()
            errorMessage = nil
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { savedAt = nil }
            }
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func clear() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.supabase.updateEpisode(
                shortID: short.id,
                name: nil,
                order: nil
            )
            episodeName = ""
            orderString = ""
            await appState.refreshLibrary()
            savedAt = Date()
            errorMessage = nil
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { savedAt = nil }
            }
        } catch {
            errorMessage = "Clear failed: \(error.localizedDescription)"
        }
    }
}
