import Foundation

/// Routes AI requests to the appropriate model tier and tool subset.
/// Zero-cost code-based classification — no LLM call needed.
public struct IntentRouter: Sendable {

    public enum ModelTier: String, Sendable {
        /// Haiku 4.5 — fast, cheap. Single-tool mechanical operations.
        case fast = "claude-haiku-4-5-20251001"
        /// Sonnet 4.6 — default. Multi-tool, ambiguous, content-aware.
        case standard = "claude-sonnet-4-6"
    }

    public struct RoutingDecision: Sendable {
        public let tier: ModelTier
        public let toolSubset: [String]  // Tool names to include
    }

    public init() {}

    /// Classify a user message and return routing decision.
    public func route(_ message: String) -> RoutingDecision {
        let lower = message.lowercased()

        // Content-aware operations → Sonnet + content tools
        if matchesAny(lower, keywords: contentKeywords) {
            return RoutingDecision(
                tier: .standard,
                toolSubset: contentTools
            )
        }

        // Multi-step editing operations → Sonnet + editing tools
        if matchesAny(lower, keywords: complexEditKeywords) {
            return RoutingDecision(
                tier: .standard,
                toolSubset: fullEditTools
            )
        }

        // Playback / undo / redo → Haiku + playback tools
        if matchesAny(lower, keywords: playbackKeywords) {
            return RoutingDecision(
                tier: .fast,
                toolSubset: playbackTools
            )
        }

        // Simple property changes → Haiku + property tools
        if matchesAny(lower, keywords: propertyKeywords) {
            return RoutingDecision(
                tier: .fast,
                toolSubset: propertyTools
            )
        }

        // Simple structural operations → Haiku + structural tools
        if matchesAny(lower, keywords: structuralKeywords) {
            return RoutingDecision(
                tier: .fast,
                toolSubset: structuralTools
            )
        }

        // Questions / conversation → Sonnet, full tools (model decides whether to use them)
        if matchesAny(lower, keywords: questionKeywords) {
            return RoutingDecision(tier: .standard, toolSubset: allKnownToolNames)
        }

        // Default: Sonnet with ALL tools — agent has full access
        return RoutingDecision(tier: .standard, toolSubset: allKnownToolNames)
    }

    // MARK: - Keyword sets

    private let playbackKeywords = [
        "undo", "redo", "play", "pause", "stop",
        "seek", "go to", "jump to", "loop", "rewind",
    ]

    private let contentKeywords = [
        "transcript", "says", "said", "mention", "spoken", "talking",
        "silence", "silent", "filler", "um", "uh", "search",
        "find where", "what do i say", "what did i", "transcribe",
        "short", "shorts", "viral", "hook",
        "reel", "reels", "tiktok", "youtube shorts", "opus",
    ]

    private let complexEditKeywords = [
        "remove section", "remove all", "clean up", "highlight reel",
        "rearrange", "reorganize", "normalize", "fix the audio",
        "create a", "make a", "assemble", "compile",
    ]

    private let propertyKeywords = [
        "volume", "opacity", "speed", "mute", "unmute",
        "louder", "quieter", "softer", "faster", "slower",
        "fade", "transparent", "visible", "lock", "unlock",
        "crop", "blend", "composite", "solo", "unsolo",
    ]

    private let structuralKeywords = [
        "add track", "new track", "delete", "remove", "split",
        "cut", "trim", "move", "duplicate", "copy", "paste",
        "marker", "rename",
        "reorder", "link", "unlink", "group", "ungroup",
    ]

    private let questionKeywords = [
        "how many", "what tracks", "what clips", "how long",
        "tell me", "what is", "show me", "help", "hello",
        "thanks", "hi", "hey",
    ]

    // MARK: - Tool subsets

    private let playbackTools = [
        "play_pause", "seek", "toggle_loop", "undo", "redo",
    ]

    private let contentTools = [
        "get_transcript", "transcribe_asset", "search_transcript",
        "remove_silence", "remove_section", "split_clip", "delete_clips",
        "get_full_transcript", "analyze_transcript", "analyze_audio_energy",
        "find_viral_moments", "extract_segment", "make_short",
        "analyze_for_shorts", "create_short", "export_for_platform",
        "generate_short_thumbnail", "upload_short_to_library",
    ]

    private let fullEditTools = [
        "add_track", "insert_clip", "move_clip", "delete_clips",
        "split_clip", "trim_clip", "remove_section", "ripple_delete",
        "normalize_audio", "set_clip_volume", "set_clip_speed",
        "duplicate_clip", "set_marker",
        "extract_segment", "make_short", "analyze_for_shorts",
        "create_short", "export_for_platform", "generate_short_thumbnail",
    ]

    private let propertyTools = [
        "set_clip_volume", "set_clip_opacity", "set_clip_speed",
        "mute_track", "lock_track", "set_track_volume",
        "set_clip_transition", "rename_clip",
        "set_clip_crop", "set_clip_blend_mode", "solo_track", "rename_track",
    ]

    private let structuralTools = [
        "add_track", "remove_track", "insert_clip", "delete_clips",
        "split_clip", "trim_clip", "move_clip", "duplicate_clip",
        "ripple_delete", "set_marker", "delete_marker", "rename_clip",
        "reorder_track", "link_clips", "remove_clip_effect",
    ]

    private let coreTools = [
        "add_track", "insert_clip", "move_clip", "delete_clips",
        "split_clip", "trim_clip", "set_marker", "set_clip_volume",
        "mute_track", "remove_section", "ripple_delete",
        "get_transcript", "search_transcript",
    ]

    private let mcpOnlyWorkflowTools = [
        "import_media", "add_to_timeline", "extract_segment", "make_short",
        "analyze_for_shorts", "create_short", "export_for_platform",
        "list_platforms", "generate_short_thumbnail",
    ]

    private var allKnownToolNames: [String] {
        var seen = Set<String>()
        return (AIToolRegistry.allTools.map(\.name) + mcpOnlyWorkflowTools).filter { seen.insert($0).inserted }
    }

    private func matchesAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
