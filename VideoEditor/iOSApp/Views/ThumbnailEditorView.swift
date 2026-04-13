import SwiftUI

/// Edit the thumbnail for a Short: pick one of 10 candidate frames, type a label,
/// choose a brand color and 9-point position. Live-previews via `ThumbnailCompositor`
/// and persists changes to Supabase.
struct ThumbnailEditorView: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var settings: ThumbnailSettings?
    @State private var frameImages: [Int: UIImage] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedAt: Date? = nil
    @State private var savedTask: Task<Void, Never>? = nil

    private let gold = Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255)
    private let borderDefault = Color.white.opacity(0.4)

    private let frameCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().progressViewStyle(.circular).tint(.white)
                    Spacer()
                }
                .frame(minHeight: 140)
            } else if let current = settings {
                preview(for: current)

                labelField(
                    text: Binding(
                        get: { settings?.labelText ?? "" },
                        set: { settings?.labelText = $0 }
                    )
                )

                sectionLabel("Color")
                colorPicker(
                    selected: Binding(
                        get: { settings?.labelColor ?? "#C9A028" },
                        set: { settings?.labelColor = $0 }
                    )
                )

                sectionLabel("Position")
                positionGrid(
                    selected: Binding(
                        get: { settings?.labelPosition ?? .bottomCenter },
                        set: { settings?.labelPosition = $0 }
                    )
                )

                sectionLabel("Frame")
                frameStrip(
                    selected: Binding(
                        get: { settings?.frameIndex ?? 0 },
                        set: { settings?.frameIndex = $0 }
                    )
                )

                HStack(spacing: 10) {
                    saveButton
                    SaveThumbnailButton(short: short)
                }
            } else {
                Text("Unable to load thumbnail settings.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let savedAt, Date().timeIntervalSince(savedAt) < 2 {
                Text("Saved ✓")
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
        .animation(.easeInOut(duration: 0.2), value: savedAt)
        .task {
            await loadAll()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Thumbnail")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    @ViewBuilder
    private func preview(for current: ThumbnailSettings) -> some View {
        let composed = renderedPreview(for: current)
        ZStack {
            if let composed {
                Image(uiImage: composed)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.5))
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay(
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private func renderedPreview(for current: ThumbnailSettings) -> UIImage? {
        guard let frame = frameImages[current.frameIndex] else { return nil }
        return ThumbnailCompositor.render(
            frame: frame,
            labelText: current.labelText,
            labelColor: current.labelColor,
            labelPosition: current.labelPosition
        )
    }

    private func labelField(text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Label")
            TextField("e.g. ELONS BIGGEST FAN", text: text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
    }

    private func colorPicker(selected: Binding<String>) -> some View {
        HStack(spacing: 10) {
            ForEach(Config.brandPalette) { brand in
                Button {
                    selected.wrappedValue = brand.hex
                } label: {
                    Circle()
                        .fill(brand.color)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .stroke(
                                    selected.wrappedValue.caseInsensitiveCompare(brand.hex) == .orderedSame
                                        ? gold
                                        : borderDefault,
                                    lineWidth: selected.wrappedValue.caseInsensitiveCompare(brand.hex) == .orderedSame ? 3 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(brand.name))
            }
            Spacer()
        }
    }

    private func positionGrid(selected: Binding<ThumbnailSettings.Position>) -> some View {
        let rows: [[ThumbnailSettings.Position]] = [
            [.topLeft, .topCenter, .topRight],
            [.centerLeft, .center, .centerRight],
            [.bottomLeft, .bottomCenter, .bottomRight],
        ]
        return VStack(spacing: 8) {
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                HStack(spacing: 8) {
                    ForEach(rows[rowIdx], id: \.self) { pos in
                        Button {
                            selected.wrappedValue = pos
                        } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            selected.wrappedValue == pos ? gold : borderDefault,
                                            lineWidth: selected.wrappedValue == pos ? 2 : 1
                                        )
                                )
                                .overlay(
                                    Circle()
                                        .fill(selected.wrappedValue == pos ? gold : Color.white.opacity(0.4))
                                        .frame(width: 8, height: 8)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(pos.rawValue))
                    }
                }
            }
        }
    }

    private func frameStrip(selected: Binding<Int>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<frameCount, id: \.self) { idx in
                    Button {
                        selected.wrappedValue = idx
                    } label: {
                        ZStack {
                            if let img = frameImages[idx] {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.black.opacity(0.3)
                            }
                        }
                        .frame(width: 60, height: 106)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    selected.wrappedValue == idx ? gold : borderDefault,
                                    lineWidth: selected.wrappedValue == idx ? 3 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 6) {
                if isSaving {
                    ProgressView().progressViewStyle(.circular).tint(.black)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text("Save settings")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(gold)
        .foregroundStyle(.black)
        .disabled(isSaving || settings == nil)
    }

    // MARK: - Data

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        // Thumbnail settings (optimistic default on not-found).
        do {
            let s = try await appState.supabase.getThumbnailSettings(forShort: short.id)
            settings = s
            errorMessage = nil
        } catch {
            // Optimistic fallback so the user can still edit.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("not found") || msg.contains("no rows") || msg.contains("0 rows") {
                settings = ThumbnailSettings(
                    shortID: short.id,
                    labelText: short.label,
                    labelColor: "#C9A028",
                    labelPosition: .bottomCenter,
                    frameIndex: 0,
                    updatedAt: Date()
                )
                errorMessage = nil
            } else {
                errorMessage = "Failed to load thumbnail settings: \(error.localizedDescription)"
                // Still provide defaults so UI is usable.
                settings = ThumbnailSettings(
                    shortID: short.id,
                    labelText: short.label,
                    labelColor: "#C9A028",
                    labelPosition: .bottomCenter,
                    frameIndex: 0,
                    updatedAt: Date()
                )
            }
        }

        await loadFrames()
    }

    private func loadFrames() async {
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for i in 0..<frameCount {
                group.addTask {
                    let data = await fetchFrame(index: i)
                    guard let data, let img = UIImage(data: data) else { return (i, nil) }
                    return (i, img)
                }
            }
            for await (idx, img) in group {
                if let img {
                    frameImages[idx] = img
                }
            }
        }
    }

    private func fetchFrame(index: Int) async -> Data? {
        if let cached = FrameCache.shared.get(shortID: short.id, frameIndex: index) {
            return cached
        }
        let url = appState.supabase.publicObjectURL(
            bucket: "shorts-frames",
            path: "\(short.id.uuidString.lowercased())/frame_\(index).jpg"
        )
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            FrameCache.shared.put(shortID: short.id, frameIndex: index, data: data)
            return data
        } catch {
            return nil
        }
    }

    private func save() async {
        guard let settings else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.supabase.updateThumbnailSettings(settings)
            errorMessage = nil
            showSaved()
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func showSaved() {
        savedAt = Date()
        savedTask?.cancel()
        savedTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { savedAt = nil }
            }
        }
    }
}
