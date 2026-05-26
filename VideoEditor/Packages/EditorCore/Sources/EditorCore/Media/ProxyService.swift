import Foundation
@preconcurrency import AVFoundation

/// Generates editing proxies for media assets.
/// Proxies are lower-res, intraframe-friendly transcodes for responsive scrubbing.
public actor ProxyService {
    public enum ProxyState: Sendable {
        case idle
        case generating(assetID: UUID, progress: Float)
        case completed(assetID: UUID, proxyURL: URL)
        case failed(assetID: UUID, error: String)
    }

    private let proxiesDir: URL
    private var activeSessions: [UUID: AVAssetExportSession] = [:]
    private var stateCallbacks: [UUID: (ProxyState) -> Void] = [:]

    public init(proxiesDir: URL) {
        self.proxiesDir = proxiesDir
        try? FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
    }

    /// Register a callback for state changes. Returns an ID for removal.
    @discardableResult
    public func onStateChange(_ callback: @escaping @Sendable (ProxyState) -> Void) -> UUID {
        let id = UUID()
        stateCallbacks[id] = callback
        return id
    }

    /// Remove a previously registered callback.
    public func removeStateCallback(_ id: UUID) {
        stateCallbacks.removeValue(forKey: id)
    }

    /// Generate a proxy for the given asset. Returns the proxy URL on success.
    public func generateProxy(for asset: MediaAsset) async -> URL? {
        // Only video needs proxies
        guard asset.type == .video else { return nil }

        // Check if proxy already exists
        let proxyURL = proxyURL(for: asset.id)
        if FileManager.default.fileExists(atPath: proxyURL.path) {
            return proxyURL
        }

        let avAsset = AVURLAsset(url: asset.sourceURL)

        // Use medium quality preset for smaller, scrub-friendly proxies
        let preset = AVAssetExportPresetMediumQuality

        guard let session = AVAssetExportSession(asset: avAsset, presetName: preset) else {
            notify(.failed(assetID: asset.id, error: "Could not create export session"))
            return nil
        }

        // Remove existing file
        try? FileManager.default.removeItem(at: proxyURL)

        session.outputURL = proxyURL
        session.outputFileType = preset == AVAssetExportPresetAppleProRes422LPCM ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = false

        activeSessions[asset.id] = session
        notify(.generating(assetID: asset.id, progress: 0))

        // Poll progress
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let progress = session.progress
                notify(.generating(assetID: asset.id, progress: progress))
            }
        }

        await session.export()
        progressTask.cancel()
        activeSessions.removeValue(forKey: asset.id)

        switch session.status {
        case .completed:
            notify(.completed(assetID: asset.id, proxyURL: proxyURL))
            return proxyURL
        case .failed:
            let msg = session.error?.localizedDescription ?? "Export failed"
            notify(.failed(assetID: asset.id, error: msg))
            return nil
        case .cancelled:
            notify(.failed(assetID: asset.id, error: "Cancelled"))
            return nil
        default:
            return nil
        }
    }

    /// Cancel proxy generation for an asset.
    public func cancel(assetID: UUID) {
        activeSessions[assetID]?.cancelExport()
        activeSessions.removeValue(forKey: assetID)
    }

    /// Cancel all active proxy generations.
    public func cancelAll() {
        for (_, session) in activeSessions {
            session.cancelExport()
        }
        activeSessions.removeAll()
    }

    /// Check if a proxy exists for the given asset.
    public func hasProxy(for assetID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: proxyURL(for: assetID).path)
    }

    /// Get the proxy URL for an asset (may not exist yet).
    public func proxyURL(for assetID: UUID) -> URL {
        proxiesDir.appendingPathComponent("\(assetID.uuidString)_proxy.mp4")
    }

    /// Delete proxy for an asset.
    public func deleteProxy(for assetID: UUID) {
        try? FileManager.default.removeItem(at: proxyURL(for: assetID))
    }

    /// Delete all proxies.
    public func deleteAll() {
        try? FileManager.default.removeItem(at: proxiesDir)
        try? FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)
    }

    private func notify(_ state: ProxyState) {
        for callback in stateCallbacks.values {
            callback(state)
        }
    }
}
