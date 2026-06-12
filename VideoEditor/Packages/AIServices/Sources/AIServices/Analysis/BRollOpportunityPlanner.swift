import Foundation
import EditorCore

public enum BRollPlatform: String, Codable, Sendable {
    case podcast
    case shorts

    public var defaultDuration: TimeInterval {
        switch self {
        case .podcast: 5.0
        case .shorts: 2.5
        }
    }

    public var aspectRatio: String {
        switch self {
        case .podcast: "16:9"
        case .shorts: "9:16"
        }
    }
}

public enum BRollOpportunityCategory: String, Codable, Sendable {
    case visualConcept = "visual_concept"
    case explanatory
    case abstractToConcrete = "abstract_to_concrete"
    case statistics
    case storyReconstruction = "story_reconstruction"
    case jumpCutCover = "jump_cut_cover"
    case emotional
}

public enum BRollPlacement: String, Codable, Sendable {
    case overlay
    case replace
}

public struct BRollOpportunity: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timelineStart: TimeInterval
    public let duration: TimeInterval
    public let category: BRollOpportunityCategory
    public let score: Double
    public let subject: String
    public let reason: String
    public let transcriptExcerpt: String
    public let searchQuery: String
    public let prompt: String
    public let fallbackPrompt: String
    public let placement: BRollPlacement
    public let aspectRatio: String
    public let provider: String
    public let artifactKind: String
    public let preferredTool: String
    public let fallbackTool: String

    public init(
        id: UUID = UUID(),
        timelineStart: TimeInterval,
        duration: TimeInterval,
        category: BRollOpportunityCategory,
        score: Double,
        subject: String,
        reason: String,
        transcriptExcerpt: String,
        searchQuery: String,
        prompt: String,
        fallbackPrompt: String,
        placement: BRollPlacement = .overlay,
        aspectRatio: String,
        provider: String = "openrouter",
        artifactKind: String = "video",
        preferredTool: String = "start_broll_video_job",
        fallbackTool: String = "generate_broll_asset"
    ) {
        self.id = id
        self.timelineStart = timelineStart
        self.duration = duration
        self.category = category
        self.score = score
        self.subject = subject
        self.reason = reason
        self.transcriptExcerpt = transcriptExcerpt
        self.searchQuery = searchQuery
        self.prompt = prompt
        self.fallbackPrompt = fallbackPrompt
        self.placement = placement
        self.aspectRatio = aspectRatio
        self.provider = provider
        self.artifactKind = artifactKind
        self.preferredTool = preferredTool
        self.fallbackTool = fallbackTool
    }
}

public struct BRollOpportunityPlanner: Sendable {
    private let minimumSpacing: TimeInterval

    public init(minimumSpacing: TimeInterval = 5.0) {
        self.minimumSpacing = minimumSpacing
    }

    public func findOpportunities(
        transcript: [TranscriptWord],
        platform: BRollPlatform,
        maxResults: Int = 8
    ) -> [BRollOpportunity] {
        guard !transcript.isEmpty, maxResults > 0 else { return [] }

        let segments = makeSegments(from: transcript)
        var opportunities: [BRollOpportunity] = []
        var lastStart: TimeInterval?

        for segment in segments {
            guard let signal = score(segment.text) else { continue }
            if let lastStart, segment.start < lastStart + minimumSpacing {
                continue
            }

            let duration = min(platform.defaultDuration, max(1.0, segment.end - segment.start))
            opportunities.append(BRollOpportunity(
                timelineStart: segment.start,
                duration: duration,
                category: signal.category,
                score: signal.score,
                subject: signal.subject,
                reason: reason(for: signal.category, subject: signal.subject),
                transcriptExcerpt: segment.text,
                searchQuery: searchQuery(for: signal.subject, category: signal.category),
                prompt: prompt(subject: signal.subject, duration: duration, aspectRatio: platform.aspectRatio),
                fallbackPrompt: fallbackPrompt(subject: signal.subject, duration: duration, aspectRatio: platform.aspectRatio),
                aspectRatio: platform.aspectRatio
            ))
            lastStart = segment.start
            if opportunities.count >= maxResults { break }
        }

        return opportunities.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.timelineStart < rhs.timelineStart }
            return lhs.score > rhs.score
        }
    }

    private struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private struct Signal {
        let category: BRollOpportunityCategory
        let score: Double
        let subject: String
    }

    private func makeSegments(from words: [TranscriptWord]) -> [Segment] {
        let chunkSize = 16
        var segments: [Segment] = []
        for startIndex in stride(from: 0, to: words.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, words.count)
            let chunk = Array(words[startIndex..<endIndex])
            guard let first = chunk.first, let last = chunk.last else { continue }
            segments.append(Segment(
                start: first.start,
                end: last.end,
                text: chunk.map(\.word).joined(separator: " ")
            ))
        }
        return segments
    }

    private func score(_ text: String) -> Signal? {
        let lower = text.lowercased()
        var value = 0.0
        var category: BRollOpportunityCategory?

        if containsAny(lower, ["percent", "%", "revenue", "arr", "valuation", "million", "billion", "chart", "graph", "metric"]) {
            value += 0.35
            category = .statistics
        }
        if containsAny(lower, ["how", "because", "works", "means", "the reason", "basically", "infrastructure", "pipeline"]) {
            value += 0.22
            category = category ?? .explanatory
        }
        if containsAny(lower, ["ai", "market", "automation", "compute", "growth", "startup", "attention", "economy"]) {
            value += 0.2
            category = category ?? .abstractToConcrete
        }
        if containsAny(lower, ["gpu", "data center", "server", "factory", "warehouse", "office", "laptop", "screen", "robot", "city"]) {
            value += 0.28
            category = category ?? .visualConcept
        }
        if containsAny(lower, ["failed", "mistake", "realized", "suddenly", "almost", "story"]) {
            value += 0.2
            category = category ?? .storyReconstruction
        }
        if containsAny(lower, ["insane", "crazy", "shocking", "wild", "huge"]) {
            value += 0.12
            category = category ?? .emotional
        }

        guard let category, value >= 0.35 else { return nil }
        return Signal(category: category, score: min(1.0, value), subject: conciseSubject(from: text))
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func conciseSubject(from text: String) -> String {
        let stop = Set(["this", "that", "with", "from", "because", "every", "company", "needs", "finally", "made", "story", "obvious", "the", "and", "for", "now"])
        let words = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) }
            .prefix(6)
        return words.isEmpty ? "podcast topic" : words.joined(separator: " ")
    }

    private func searchQuery(for subject: String, category: BRollOpportunityCategory) -> String {
        switch category {
        case .statistics:
            return "\(subject) data chart visualization"
        case .abstractToConcrete, .explanatory:
            return "\(subject) documentary cutaway"
        case .storyReconstruction:
            return "\(subject) cinematic reenactment detail"
        case .jumpCutCover:
            return "\(subject) quick cutaway"
        case .visualConcept, .emotional:
            return "\(subject) realistic b-roll"
        }
    }

    private func reason(for category: BRollOpportunityCategory, subject: String) -> String {
        switch category {
        case .visualConcept:
            return "Visual concept can be shown directly: \(subject)."
        case .explanatory:
            return "Explanation becomes easier to follow with a cutaway: \(subject)."
        case .abstractToConcrete:
            return "Abstract idea needs a concrete visual anchor: \(subject)."
        case .statistics:
            return "Number or scale claim benefits from a visual anchor: \(subject)."
        case .storyReconstruction:
            return "Story beat can be reinforced with a reconstructed detail: \(subject)."
        case .jumpCutCover:
            return "B-roll can cover a hard cut while keeping the audio moving: \(subject)."
        case .emotional:
            return "Emotional spike can land harder with supporting imagery: \(subject)."
        }
    }

    private func prompt(subject: String, duration: TimeInterval, aspectRatio: String) -> String {
        """
        Editorial documentary B-roll video for a tech podcast. Intent: visually support the spoken idea without adding new claims. Subject: \(subject). Scene: grounded real-world workspace or environment connected to the subject, with one clear foreground focal point and uncluttered negative space. Action: subtle natural movement that reads immediately in \(String(format: "%.0f", duration)) seconds. Camera: single continuous shot, slow controlled push-in or lateral slide, stable motion, no whip pans. Composition: portrait-safe framing for \(aspectRatio), strong foreground/midground/depth separation, no important detail near the bottom brand bar. Lighting and tone: natural soft light, realistic documentary color, thoughtful but not glossy advertising. Audio: silent video only. Constraints: no on-screen captions, no readable text, no logos, no famous likeness, unidentifiable people if present.
        """
    }

    private func fallbackPrompt(subject: String, duration: TimeInterval, aspectRatio: String) -> String {
        """
        Generic unbranded documentary B-roll video. Intent: support the spoken idea without implying a specific real company, product, or factual claim. Subject: \(subject). Scene: fictional but realistic environment with abstract, non-readable interface or object details if needed. Action: small natural motion that is readable in \(String(format: "%.0f", duration)) seconds. Camera: single continuous slow push-in or lateral slide, stable and calm. Composition: \(aspectRatio) portrait-safe frame, clear focal point, no bottom-safe-area conflict. Audio: silent video only. Constraints: no logos, no readable text, no captions, no famous likeness, unidentifiable people if present.
        """
    }
}
