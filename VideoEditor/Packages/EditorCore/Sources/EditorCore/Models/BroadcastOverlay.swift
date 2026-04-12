import Foundation

// MARK: - Broadcast Overlay Configuration

/// Configuration for professional broadcast-style overlays rendered on the video.
/// Includes episode title card, host name bar, scrolling ticker, chapter cards,
/// and host intro strip. All dimensions reference 4K (3840x2160) and scale automatically.
public struct BroadcastOverlayConfig: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var episodeTitle: String
    public var episodeSubtitle: String
    public var hostA: HostInfo
    public var hostB: HostInfo
    public var sponsors: [String]
    public var topics: [TimedEntry]
    public var chapters: [TimedEntry]
    public var style: OverlayStyle
    /// When true, only the minimal brand bar (show name + thin gold accent line) is rendered.
    /// All other overlay elements (title card, chapters, ticker, host strip) are suppressed.
    /// Defaults to false so existing 16:9 exports are unaffected.
    public var shortFormMode: Bool

    public init(
        isEnabled: Bool = false,
        episodeTitle: String = "",
        episodeSubtitle: String = "",
        hostA: HostInfo = HostInfo(),
        hostB: HostInfo = HostInfo(),
        sponsors: [String] = [],
        topics: [TimedEntry] = [],
        chapters: [TimedEntry] = [],
        style: OverlayStyle = .default,
        shortFormMode: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.episodeTitle = episodeTitle
        self.episodeSubtitle = episodeSubtitle
        self.hostA = hostA
        self.hostB = hostB
        self.sponsors = sponsors
        self.topics = topics
        self.chapters = chapters
        self.style = style
        self.shortFormMode = shortFormMode
    }

    // MARK: - Codable (manual, for decodeIfPresent on shortFormMode)
    enum CodingKeys: String, CodingKey {
        case isEnabled, episodeTitle, episodeSubtitle, hostA, hostB
        case sponsors, topics, chapters, style, shortFormMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled       = try c.decode(Bool.self, forKey: .isEnabled)
        episodeTitle    = try c.decodeIfPresent(String.self, forKey: .episodeTitle) ?? ""
        episodeSubtitle = try c.decodeIfPresent(String.self, forKey: .episodeSubtitle) ?? ""
        hostA           = try c.decodeIfPresent(HostInfo.self, forKey: .hostA) ?? HostInfo()
        hostB           = try c.decodeIfPresent(HostInfo.self, forKey: .hostB) ?? HostInfo()
        sponsors        = try c.decodeIfPresent([String].self, forKey: .sponsors) ?? []
        topics          = try c.decodeIfPresent([TimedEntry].self, forKey: .topics) ?? []
        chapters        = try c.decodeIfPresent([TimedEntry].self, forKey: .chapters) ?? []
        style           = try c.decodeIfPresent(OverlayStyle.self, forKey: .style) ?? .default
        shortFormMode   = try c.decodeIfPresent(Bool.self, forKey: .shortFormMode) ?? false
    }

    public static let empty = BroadcastOverlayConfig()
}

// MARK: - Host Info

public struct HostInfo: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var photoPath: String?

    public init(name: String = "", title: String = "", photoPath: String? = nil) {
        self.name = name
        self.title = title
        self.photoPath = photoPath
    }
}

// MARK: - Timed Entry (topics and chapters share the same structure)

public struct TimedEntry: Codable, Sendable, Equatable {
    public var timeSeconds: TimeInterval
    public var text: String

    public init(timeSeconds: TimeInterval, text: String) {
        self.timeSeconds = timeSeconds
        self.text = text
    }
}

// MARK: - Overlay Style

/// Timing and color configuration. Defaults match the Remotion "Technologia Talks" overlay.
public struct OverlayStyle: Codable, Sendable, Equatable {
    // Colors (hex)
    public var goldHex: String
    public var goldLightHex: String
    public var cyanHex: String
    public var darkNavyHex: String

    // Title card timing
    public var titleFadeInEnd: TimeInterval      // 1.5s — title fully visible
    public var titleFadeOutStart: TimeInterval    // 29.0s — title starts fading
    public var titleVisibleEnd: TimeInterval      // 30.0s — title fully gone

    // Host intro strip timing
    public var hostIntroStart: TimeInterval       // 38.0s — gold strip slides in
    public var hostIntroEnd: TimeInterval         // 92.0s — gold strip slides out

    // Ticker timing (41-second cycle)
    public var tickerSponsorDuration: TimeInterval // 25.0s
    public var tickerFadeDuration: TimeInterval    // 1.0s
    public var tickerTopicDuration: TimeInterval   // 14.0s

    // Chapter card
    public var chapterDisplayDuration: TimeInterval // 6.0s

    // Heights (at 4K reference 3840x2160)
    public var nameBarHeight: Double               // 150
    public var tickerHeight: Double                // 200
    public var hostStripHeight: Double             // 320

    public init(
        goldHex: String = "#C9A028",
        goldLightHex: String = "#E8C040",
        cyanHex: String = "#22D3EE",
        darkNavyHex: String = "#070D17",
        titleFadeInEnd: TimeInterval = 1.5,
        titleFadeOutStart: TimeInterval = 29.0,
        titleVisibleEnd: TimeInterval = 30.0,
        hostIntroStart: TimeInterval = 38.0,
        hostIntroEnd: TimeInterval = 92.0,
        tickerSponsorDuration: TimeInterval = 25.0,
        tickerFadeDuration: TimeInterval = 1.0,
        tickerTopicDuration: TimeInterval = 14.0,
        chapterDisplayDuration: TimeInterval = 6.0,
        nameBarHeight: Double = 150,
        tickerHeight: Double = 200,
        hostStripHeight: Double = 320
    ) {
        self.goldHex = goldHex
        self.goldLightHex = goldLightHex
        self.cyanHex = cyanHex
        self.darkNavyHex = darkNavyHex
        self.titleFadeInEnd = titleFadeInEnd
        self.titleFadeOutStart = titleFadeOutStart
        self.titleVisibleEnd = titleVisibleEnd
        self.hostIntroStart = hostIntroStart
        self.hostIntroEnd = hostIntroEnd
        self.tickerSponsorDuration = tickerSponsorDuration
        self.tickerFadeDuration = tickerFadeDuration
        self.tickerTopicDuration = tickerTopicDuration
        self.chapterDisplayDuration = chapterDisplayDuration
        self.nameBarHeight = nameBarHeight
        self.tickerHeight = tickerHeight
        self.hostStripHeight = hostStripHeight
    }

    public static let `default` = OverlayStyle()

    /// Total ticker cycle duration (sponsors + fade + topic + fade)
    public var tickerCycleDuration: TimeInterval {
        tickerSponsorDuration + tickerFadeDuration + tickerTopicDuration + tickerFadeDuration
    }
}

// MARK: - Color Helpers

extension OverlayStyle {
    /// Parse hex string to (r, g, b, a) components (0-1).
    public static func parseHex(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let val = UInt32(h, radix: 16) else {
            return (0, 0, 0)
        }
        return (
            r: CGFloat((val >> 16) & 0xFF) / 255.0,
            g: CGFloat((val >> 8) & 0xFF) / 255.0,
            b: CGFloat(val & 0xFF) / 255.0
        )
    }
}
