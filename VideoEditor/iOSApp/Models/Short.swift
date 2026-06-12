import Foundation

struct ShortScoreBreakdown: Codable, Hashable {
    let base: Double?
    let hook: Double?
    let duration: Double?
    let trend: Double?
    let visual: Double?
    let topicBoundary: Double?
    let total: Double?

    enum CodingKeys: String, CodingKey {
        case base, hook, duration, trend, visual, total
        case topicBoundary = "topic_boundary"
    }
}

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
    var storedDistributionScore: Int? = nil
    var postingPriority: String? = nil
    var scoreWarnings: [String]? = nil
    var bestPlatforms: [String]? = nil
    var scoreBreakdown: ShortScoreBreakdown? = nil
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
        case storedDistributionScore = "distribution_score"
        case postingPriority = "posting_priority"
        case scoreWarnings = "score_warnings"
        case bestPlatforms = "best_platforms"
        case scoreBreakdown = "score_breakdown"
        case episodeName = "episode_name"
        case episodeOrder = "episode_order"
    }

    /// Fits this platform's duration limit.
    func fits(_ platform: Platform) -> Bool {
        duration <= platform.maxDurationSeconds
    }

    /// 0-100 publishing score for choosing what to post next.
    /// Trending gets a slight weight because timing matters most at publish time,
    /// while evergreen keeps durable clips from being hidden.
    var distributionScore: Int {
        if let storedDistributionScore, storedDistributionScore > 0 {
            return min(max(storedDistributionScore, 0), 100)
        }
        let evergreen = Double(Self.clampedScore(evergreenScore))
        let trending = Double(Self.clampedScore(trendingScore))
        return Int(((evergreen * 0.45 + trending * 0.55) * 10).rounded())
    }

    var distributionScoreLabel: String {
        "\(distributionScore)"
    }

    var postingPriorityLabel: String {
        if let postingPriority {
            switch postingPriority {
            case "post_now":
                return "Post now"
            case "queue":
                return "Queue"
            case "review":
                return "Review"
            default:
                break
            }
        }
        switch distributionScore {
        case 85...:
            return "Post now"
        case 65..<85:
            return "Queue"
        default:
            return "Review"
        }
    }

    var scoreSummaryLabel: String {
        if let scoreBreakdown {
            let hook = Int((scoreBreakdown.hook ?? 0).rounded())
            let visual = Int((scoreBreakdown.visual ?? 0).rounded())
            let trend = Int((scoreBreakdown.trend ?? 0).rounded())
            return "H \(hook) · V \(visual) · T \(trend)"
        }
        return "E \(Self.clampedScore(evergreenScore)) · T \(Self.clampedScore(trendingScore))"
    }

    var scoreWarningLabels: [String] {
        (scoreWarnings ?? []).map(Self.humanizedScoreToken)
    }

    var bestPlatformLabels: [String] {
        let source = (bestPlatforms?.isEmpty == false) ? (bestPlatforms ?? []) : platformFit
        return source.map(Self.humanizedScoreToken)
    }

    private static func clampedScore(_ score: Int) -> Int {
        min(max(score, 0), 10)
    }

    private static func humanizedScoreToken(_ token: String) -> String {
        token.split(separator: "_")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
