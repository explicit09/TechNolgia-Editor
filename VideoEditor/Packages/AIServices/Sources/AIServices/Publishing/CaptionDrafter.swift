import Foundation

/// Draft JSON shape for one platform's caption.
public struct CaptionDraft: Codable, Sendable, Equatable {
    public let title: String?
    public let body: String
    public let hashtags: [String]

    public init(title: String?, body: String, hashtags: [String]) {
        self.title = title
        self.body = body
        self.hashtags = hashtags
    }
}

/// Generates one draft caption per platform by calling Claude once with all 5 platforms.
/// Platform keys: "youtube_shorts", "tiktok", "instagram_reels", "twitter", "linkedin".
public struct CaptionDrafter: Sendable {
    public static let platforms: [String] = [
        "youtube_shorts", "tiktok", "instagram_reels", "twitter", "linkedin"
    ]

    private let provider: any AIProvider

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    /// Generate all 5 captions. Returns dictionary keyed by platform.
    public func draftCaptions(
        hook: String,
        reasoning: String,
        label: String,
        duration: Double
    ) async throws -> [String: CaptionDraft] {
        let prompt = Self.buildPrompt(hook: hook, reasoning: reasoning, label: label, duration: duration)
        let response = try await provider.complete(
            messages: [AIMessage(role: "user", content: prompt)],
            tools: []
        )
        return try Self.parseCaptions(from: response.content)
    }

    /// Build the Claude prompt. Exposed for testing.
    static func buildPrompt(hook: String, reasoning: String, label: String, duration: Double) -> String {
        return """
        You are writing one social-media caption for EACH of 5 platforms for a short-form video clip.

        The clip:
        - Hook: "\(hook)"
        - Label: "\(label)"
        - Why it's viral: \(reasoning)
        - Duration: \(Int(duration)) seconds

        Platform rules:
        - youtube_shorts: title ≤100 chars (curiosity-driving), body up to 500 words, 3-5 hashtags
        - tiktok: title=null, body up to 150 words with inline hashtags, 5-10 hashtags total, casual
        - instagram_reels: title=null, body up to 150 words, 10-15 hashtags at the very end, lifestyle tone
        - twitter: title=null, body under 240 chars, 1-3 hashtags, punchy
        - linkedin: title=null, body 200-400 words in 2-4 paragraphs, 3-5 hashtags at end, professional but human

        Return ONLY a JSON object — no prose before or after, no markdown fence.
        Shape (exact keys):
        {
          "youtube_shorts": {"title": "string", "body": "string", "hashtags": ["#tag1", "#tag2"]},
          "tiktok": {"title": null, "body": "string", "hashtags": ["#tag1"]},
          "instagram_reels": {"title": null, "body": "string", "hashtags": []},
          "twitter": {"title": null, "body": "string", "hashtags": []},
          "linkedin": {"title": null, "body": "string", "hashtags": []}
        }

        Every hashtag must start with #. All 5 keys must be present.
        """
    }

    /// Parse Claude's response. Handles optional ```json ... ``` wrapping.
    public static func parseCaptions(from rawText: String) throws -> [String: CaptionDraft] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip optional markdown fence
        let stripped: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: "\n")
            stripped = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            stripped = trimmed
        }
        guard let data = stripped.data(using: .utf8) else {
            throw CaptionDrafterError.invalidJSON("not utf-8")
        }
        let decoded = try JSONDecoder().decode([String: CaptionDraft].self, from: data)
        return decoded
    }
}

public enum CaptionDrafterError: Error, LocalizedError {
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): "Caption JSON parse failed: \(detail)"
        }
    }
}
