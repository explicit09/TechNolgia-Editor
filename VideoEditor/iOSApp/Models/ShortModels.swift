import Foundation

enum ShortPlatform: String, CaseIterable, Identifiable, Hashable {
    case youtubeShorts = "YouTube"
    case tiktok = "TikTok"
    case instagramReels = "Reels"
    case twitter = "X"
    case linkedIn = "LinkedIn"

    var id: String { rawValue }
}

enum ThumbnailGridPosition: String, CaseIterable, Identifiable, Hashable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top"
        case .topTrailing: "Top Right"
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        case .bottomLeading: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomTrailing: "Bottom Right"
        }
    }
}

struct CaptionDraft: Identifiable, Hashable {
    let platform: ShortPlatform
    var title: String?
    var body: String
    var hashtags: [String]

    var id: ShortPlatform { platform }
}

struct MockThumbnailSettings: Hashable {
    var labelText: String
    var colorName: String
    var position: ThumbnailGridPosition
    var frameIndex: Int
}

struct ShortItem: Identifiable, Hashable {
    let id: UUID
    let label: String
    let sourceTitle: String
    let durationText: String
    let hook: String
    let thumbnailGradient: [String]
    let frames: [String]
    var thumbnailSettings: MockThumbnailSettings
    var captions: [CaptionDraft]
}
