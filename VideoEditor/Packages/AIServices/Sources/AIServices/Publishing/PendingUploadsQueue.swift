import Foundation

/// Serialized representation of an upload that failed and needs retry.
public struct PendingUpload: Codable, Sendable, Equatable {
    public let shortID: UUID
    public let videoLocalPath: String   // Still on local disk at retry time
    public let label: String
    public let hook: String
    public let sourceAssetName: String
    public let sourceStart: Double
    public let sourceEnd: Double
    public let evergreenScore: Int
    public let trendingScore: Int
    public let platformFit: [String]
    public let reasoning: String

    public init(
        shortID: UUID, videoLocalPath: String, label: String, hook: String,
        sourceAssetName: String, sourceStart: Double, sourceEnd: Double,
        evergreenScore: Int, trendingScore: Int, platformFit: [String], reasoning: String
    ) {
        self.shortID = shortID
        self.videoLocalPath = videoLocalPath
        self.label = label
        self.hook = hook
        self.sourceAssetName = sourceAssetName
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.evergreenScore = evergreenScore
        self.trendingScore = trendingScore
        self.platformFit = platformFit
        self.reasoning = reasoning
    }
}

/// Persistent FIFO queue of failed uploads. File lives in the app's sandbox at storagePath.
public struct PendingUploadsQueue: Sendable {
    public let storagePath: String

    public init(storagePath: String) {
        self.storagePath = storagePath
    }

    public static func defaultQueue() -> PendingUploadsQueue {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("VideoEditor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PendingUploadsQueue(storagePath: dir.appendingPathComponent("pending_uploads.json").path)
    }

    public func load() throws -> [PendingUpload] {
        guard FileManager.default.fileExists(atPath: storagePath) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: storagePath))
        return try JSONDecoder().decode([PendingUpload].self, from: data)
    }

    public func append(_ upload: PendingUpload) throws {
        var current = (try? load()) ?? []
        current.append(upload)
        let data = try JSONEncoder().encode(current)
        try data.write(to: URL(fileURLWithPath: storagePath), options: .atomic)
    }

    public func replace(_ uploads: [PendingUpload]) throws {
        let data = try JSONEncoder().encode(uploads)
        try data.write(to: URL(fileURLWithPath: storagePath), options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: storagePath) {
            try FileManager.default.removeItem(atPath: storagePath)
        }
    }
}
