import Foundation

enum MockShorts {
    static let library: [ShortItem] = [
        ShortItem(
            id: UUID(),
            label: "ELONS BIGGEST FAN",
            sourceTitle: "Technologia Talks Ep. 1",
            durationText: "0:38",
            hook: "The opening claim lands fast and feels like a direct clip title already.",
            thumbnailGradient: ["#0B1320", "#594217"],
            frames: ["Frame 1", "Frame 2", "Frame 3", "Frame 4"],
            thumbnailSettings: ThumbnailSettings(
                labelText: "ELONS BIGGEST FAN",
                colorName: "Gold",
                position: .center,
                frameIndex: 0
            ),
            captions: [
                CaptionDraft(platform: .youtubeShorts, title: "Elon's Biggest Fan?", body: "A wild opening take from Technologia Talks. Full clip breaks down why fandom can distort product judgment.", hashtags: ["#shorts", "#tech", "#elon"]),
                CaptionDraft(platform: .tiktok, title: nil, body: "This take starts hot and only gets sharper. Would you call this admiration or delusion?", hashtags: ["#techtok", "#startup", "#opinion"]),
                CaptionDraft(platform: .instagramReels, title: nil, body: "A sharp one-liner that turns into a bigger conversation about loyalty and judgment.", hashtags: ["#reels", "#technology", "#founders"]),
                CaptionDraft(platform: .twitter, title: nil, body: "This clip opens with one of the most loaded lines from the episode.", hashtags: ["#tech", "#ElonMusk"]),
                CaptionDraft(platform: .linkedIn, title: nil, body: "Strong personalities can skew product evaluation. This short tees up that discussion immediately.", hashtags: ["#leadership", "#technology"])
            ]
        ),
        ShortItem(
            id: UUID(),
            label: "WHY VIRALITY IS FAKE",
            sourceTitle: "Technologia Talks Ep. 1",
            durationText: "1:17",
            hook: "Debunks the instinct to chase virality before product-market clarity.",
            thumbnailGradient: ["#161A2E", "#762E1D"],
            frames: ["Frame 1", "Frame 2", "Frame 3", "Frame 4"],
            thumbnailSettings: ThumbnailSettings(
                labelText: "WHY VIRALITY IS FAKE",
                colorName: "Pink",
                position: .bottom,
                frameIndex: 1
            ),
            captions: [
                CaptionDraft(platform: .youtubeShorts, title: "Why Virality Is Fake", body: "A hard reset for anyone optimizing views before building something people actually keep.", hashtags: ["#shorts", "#creator", "#startup"]),
                CaptionDraft(platform: .tiktok, title: nil, body: "Everyone wants reach. Almost nobody wants retention. That is the whole problem.", hashtags: ["#virality", "#marketing", "#creatoreconomy"]),
                CaptionDraft(platform: .instagramReels, title: nil, body: "The clip argues that virality without substance is mostly noise.", hashtags: ["#reels", "#business", "#growth"]),
                CaptionDraft(platform: .twitter, title: nil, body: "Virality is not traction. This clip explains the difference fast.", hashtags: ["#growth", "#startups"]),
                CaptionDraft(platform: .linkedIn, title: nil, body: "A concise argument for prioritizing durable value over distribution spikes.", hashtags: ["#productstrategy", "#audience"])
            ]
        ),
        ShortItem(
            id: UUID(),
            label: "BUILD THE ROADS FIRST",
            sourceTitle: "Technologia Talks Ep. 1",
            durationText: "0:16",
            hook: "A short, clean infrastructure metaphor that travels well across platforms.",
            thumbnailGradient: ["#132A34", "#305026"],
            frames: ["Frame 1", "Frame 2", "Frame 3", "Frame 4"],
            thumbnailSettings: ThumbnailSettings(
                labelText: "BUILD THE ROADS FIRST",
                colorName: "Green",
                position: .top,
                frameIndex: 2
            ),
            captions: [
                CaptionDraft(platform: .youtubeShorts, title: "Build The Roads First", body: "Short version: infrastructure before hype.", hashtags: ["#shorts", "#infrastructure", "#innovation"]),
                CaptionDraft(platform: .tiktok, title: nil, body: "This metaphor is simple, but it cuts straight through the noise.", hashtags: ["#policy", "#future", "#startup"]),
                CaptionDraft(platform: .instagramReels, title: nil, body: "You cannot scale what you never built foundations for.", hashtags: ["#reels", "#build", "#tech"]),
                CaptionDraft(platform: .twitter, title: nil, body: "Build the roads first. Everything else sits on top of that.", hashtags: ["#infrastructure", "#innovation"]),
                CaptionDraft(platform: .linkedIn, title: nil, body: "A crisp reminder that systems work starts before market storytelling.", hashtags: ["#systems", "#leadership"])
            ]
        ),
    ]
}
