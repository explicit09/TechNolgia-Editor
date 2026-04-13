import Foundation

struct Short: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let sourceAsset: String
    let hook: String
    let label: String
    let duration: Double
    let evergreenScore: Int
    let trendingScore: Int
    let platformFit: [String]
    let sourceStart: Double
    let sourceEnd: Double
    let videoPath: String
    let thumbnailPath: String
    let videoSize: Int64
    let reasoning: String
    var episodeName: String?
    var episodeOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case sourceAsset = "source_asset"
        case hook, label, duration
        case evergreenScore = "evergreen_score"
        case trendingScore = "trending_score"
        case platformFit = "platform_fit"
        case sourceStart = "source_start"
        case sourceEnd = "source_end"
        case videoPath = "video_path"
        case thumbnailPath = "thumbnail_path"
        case videoSize = "video_size"
        case reasoning
        case episodeName = "episode_name"
        case episodeOrder = "episode_order"
    }

    /// Fits this platform's duration limit.
    func fits(_ platform: Platform) -> Bool {
        duration <= platform.maxDurationSeconds
    }
}
