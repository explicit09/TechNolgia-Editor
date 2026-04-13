import Foundation

enum Platform: String, CaseIterable, Codable, Identifiable {
    case youtube_shorts
    case tiktok
    case instagram_reels
    case twitter
    case linkedin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtube_shorts: "YouTube"
        case .tiktok: "TikTok"
        case .instagram_reels: "Reels"
        case .twitter: "X"
        case .linkedin: "LinkedIn"
        }
    }

    var maxDurationSeconds: Double {
        switch self {
        case .youtube_shorts: 59
        case .instagram_reels: 90
        case .twitter: 140
        case .tiktok: 600
        case .linkedin: 600
        }
    }
}
