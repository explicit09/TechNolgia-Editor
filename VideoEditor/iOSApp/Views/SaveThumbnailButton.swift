import SwiftUI
import Photos
import UIKit

/// Downloads the rendered thumbnail PNG from Supabase Storage and writes it
/// to the user's Photos library. Used on platforms that accept a custom
/// thumbnail upload (YouTube Shorts, etc.) so the user can post from their
/// camera roll in one tap.
struct SaveThumbnailButton: View {
    let short: Short
    @Environment(AppState.self) private var appState

    @State private var status: Status = .idle
    private enum Status: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                Text(label)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
            .font(.headline)
        }
        .disabled(status == .saving)
    }

    private var iconName: String {
        switch status {
        case .idle: "arrow.down.circle"
        case .saving: "arrow.down.circle"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch status {
        case .idle: "Save thumbnail"
        case .saving: "Saving…"
        case .saved: "Saved to Photos"
        case .failed(let msg): "Save failed: \(msg)"
        }
    }

    private var background: Color {
        switch status {
        case .saved: Color(red: 0, green: 0.78, blue: 0.33)
        case .failed: Color.red.opacity(0.85)
        default: Color.white.opacity(0.12)
        }
    }

    private func save() async {
        status = .saving
        do {
            let url = appState.supabase.publicObjectURL(
                bucket: "shorts-thumbnails",
                path: "\(short.id.uuidString.lowercased()).png"
            )
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                throw NSError(domain: "SaveThumbnail", code: 1, userInfo: [NSLocalizedDescriptionKey: "decode"])
            }
            try await addImageToPhotos(image)
            status = .saved
            // Revert to idle after 2s so the user can save again
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .saved = status { status = .idle }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func addImageToPhotos(_ image: UIImage) async throws {
        // Request add-only permission the first time.
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authStatus == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .denied {
            throw NSError(domain: "SaveThumbnail", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Photos access denied"])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }
}
