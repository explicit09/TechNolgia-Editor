import Foundation

public struct ViralMomentCandidate: Sendable {
    public let id: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let evergreenScore: Int
    public let trendingScore: Int
    public let hook: String
    public let trendEvidenceLabels: [String]

    public init(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        evergreenScore: Int,
        trendingScore: Int,
        hook: String,
        trendEvidenceLabels: [String]
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.evergreenScore = evergreenScore
        self.trendingScore = trendingScore
        self.hook = hook
        self.trendEvidenceLabels = trendEvidenceLabels
    }

    public var duration: TimeInterval {
        max(0, end - start)
    }
}

public struct ViralMomentVisualEvidence: Sendable {
    public static let empty = ViralMomentVisualEvidence(ranges: [], topicBoundaries: [])

    public let ranges: [ViralMomentVisualRange]
    public let topicBoundaries: [TimeInterval]

    public init(ranges: [ViralMomentVisualRange], topicBoundaries: [TimeInterval]) {
        self.ranges = ranges
        self.topicBoundaries = topicBoundaries
    }
}

public struct ViralMomentVisualRange: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let kind: ViralMomentVisualKind

    public init(start: TimeInterval, end: TimeInterval, kind: ViralMomentVisualKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public enum ViralMomentVisualKind: Sendable {
    case talkingHead
    case bRoll
    case titleCard
    case unknown
}

public struct ViralMomentScoreBreakdown: Sendable {
    public let base: Double
    public let hook: Double
    public let duration: Double
    public let trend: Double
    public let visual: Double
    public let topicBoundary: Double
    public let total: Double
}

public enum ViralMomentPriority: String, Sendable, Codable {
    case postNow = "post_now"
    case queue
    case review
}

public enum ViralMomentTasteStatus: String, Sendable, Codable {
    case pass
    case downgrade
    case reject
}

public enum ViralMomentWarning: String, Sendable, Codable {
    case weakHook = "weak_hook"
    case tooShort = "too_short"
    case tooLong = "too_long"
    case missingVisualSupport = "missing_visual_support"
    case lowTrend = "low_trend"
    case contextRisk = "context_risk"
}

public struct ViralMomentPipelineGrade: Sendable, Codable {
    public let score: Int
    public let priority: ViralMomentPriority
    public let tasteStatus: ViralMomentTasteStatus
    public let warnings: [ViralMomentWarning]
    public let bestPlatforms: [String]

    public init(
        score: Int,
        priority: ViralMomentPriority,
        tasteStatus: ViralMomentTasteStatus,
        warnings: [ViralMomentWarning],
        bestPlatforms: [String]
    ) {
        self.score = score
        self.priority = priority
        self.tasteStatus = tasteStatus
        self.warnings = warnings
        self.bestPlatforms = bestPlatforms
    }
}

public struct ViralMomentScoredCandidate: Sendable {
    public let candidate: ViralMomentCandidate
    public let breakdown: ViralMomentScoreBreakdown
    public let grade: ViralMomentPipelineGrade
}

public enum ViralMomentScorecardError: Error, Equatable {
    case invalidOverlapRatio
}

public enum ViralMomentScorecard {
    public static func rank(
        _ candidates: [ViralMomentCandidate],
        visualEvidence: ViralMomentVisualEvidence,
        limit: Int,
        maxOverlapRatio: Double?
    ) -> [ViralMomentScoredCandidate] {
        var scored = candidates
            .map { candidate in
                let breakdown = breakdown(for: candidate, visualEvidence: visualEvidence)
                return ViralMomentScoredCandidate(
                    candidate: candidate,
                    breakdown: breakdown,
                    grade: grade(for: candidate, breakdown: breakdown)
                )
            }
            .sorted { (left: ViralMomentScoredCandidate, right: ViralMomentScoredCandidate) in
                if left.breakdown.total == right.breakdown.total {
                    return left.candidate.start < right.candidate.start
                }
                return left.breakdown.total > right.breakdown.total
            }

        if let maxOverlapRatio, (try? validatedOverlapRatio(maxOverlapRatio)) != nil {
            scored = suppressOverlaps(scored, maxOverlapRatio: maxOverlapRatio)
        }
        return Array(scored.prefix(max(0, limit)))
    }

    public static func validatedOverlapRatio(_ ratio: Double) throws -> Double {
        guard (0.0...1.0).contains(ratio) else {
            throw ViralMomentScorecardError.invalidOverlapRatio
        }
        return ratio
    }

    public static func overlapRatio(_ left: ViralMomentCandidate, _ right: ViralMomentCandidate) -> Double {
        let overlap = max(0, min(left.end, right.end) - max(left.start, right.start))
        let shorter = min(left.duration, right.duration)
        guard shorter > 0 else { return 0 }
        return overlap / shorter
    }

    private static func breakdown(
        for candidate: ViralMomentCandidate,
        visualEvidence: ViralMomentVisualEvidence
    ) -> ViralMomentScoreBreakdown {
        let base = Double(max(candidate.evergreenScore, candidate.trendingScore)) * 10
        let hook = hookScore(candidate.hook)
        let duration = durationScore(candidate.duration)
        let trend: Double = candidate.trendEvidenceLabels.isEmpty ? 0 : 6
        let visual = visualScore(candidate, evidence: visualEvidence)
        let topic = topicBoundaryScore(candidate, evidence: visualEvidence)
        let total: Double = base + hook + duration + trend + visual + topic
        return ViralMomentScoreBreakdown(
            base: base,
            hook: hook,
            duration: duration,
            trend: trend,
            visual: visual,
            topicBoundary: topic,
            total: total
        )
    }

    private static func hookScore(_ hook: String) -> Double {
        let lower = hook.lowercased()
        let terms = ["?", "actually", "truth", "never", "always", "mistake", "realized", "secret", "problem", "why"]
        return terms.contains { lower.contains($0) } ? 8 : 0
    }

    private static func durationScore(_ duration: TimeInterval) -> Double {
        switch duration {
        case 20...90:
            return 8
        case 15..<20, 90...140:
            return 2
        default:
            return -8
        }
    }

    private static func visualScore(_ candidate: ViralMomentCandidate, evidence: ViralMomentVisualEvidence) -> Double {
        let overlaps = evidence.ranges.filter { range in
            max(0, min(candidate.end, range.end) - max(candidate.start, range.start)) > 0
        }
        guard !overlaps.isEmpty else { return 0 }
        if overlaps.contains(where: { $0.kind == .talkingHead }) { return 6 }
        if overlaps.contains(where: { $0.kind == .bRoll }) { return 4 }
        return 2
    }

    private static func topicBoundaryScore(_ candidate: ViralMomentCandidate, evidence: ViralMomentVisualEvidence) -> Double {
        evidence.topicBoundaries.contains { boundary in
            abs(candidate.start - boundary) <= 5 || abs(candidate.end - boundary) <= 5
        } ? 5 : 0
    }

    private static func grade(
        for candidate: ViralMomentCandidate,
        breakdown: ViralMomentScoreBreakdown
    ) -> ViralMomentPipelineGrade {
        let score = min(100, max(0, Int(breakdown.total.rounded())))
        let warnings = warnings(for: candidate, breakdown: breakdown)
        let tasteStatus: ViralMomentTasteStatus
        if warnings.contains(.tooLong) || score < 45 {
            tasteStatus = .reject
        } else if warnings.isEmpty {
            tasteStatus = .pass
        } else {
            tasteStatus = .downgrade
        }

        let priority: ViralMomentPriority
        if tasteStatus == .pass && score >= 85 {
            priority = .postNow
        } else if tasteStatus != .reject && score >= 65 {
            priority = .queue
        } else {
            priority = .review
        }

        return ViralMomentPipelineGrade(
            score: score,
            priority: priority,
            tasteStatus: tasteStatus,
            warnings: warnings,
            bestPlatforms: platformFit(for: candidate.duration)
        )
    }

    private static func warnings(
        for candidate: ViralMomentCandidate,
        breakdown: ViralMomentScoreBreakdown
    ) -> [ViralMomentWarning] {
        var warnings: [ViralMomentWarning] = []
        if breakdown.hook <= 0 { warnings.append(.weakHook) }
        if candidate.duration < 15 { warnings.append(.tooShort) }
        if candidate.duration > 480 { warnings.append(.tooLong) }
        if breakdown.visual <= 0 { warnings.append(.missingVisualSupport) }
        if candidate.trendingScore <= 2 && candidate.trendEvidenceLabels.isEmpty { warnings.append(.lowTrend) }
        if hasContextRisk(candidate.hook) { warnings.append(.contextRisk) }
        return warnings
    }

    private static func hasContextRisk(_ hook: String) -> Bool {
        let lower = hook.lowercased()
        let contextTerms = ["this", "that", "they", "them", "it", "he", "she"]
        let concreteTerms = ["why", "how", "because", "problem", "mistake", "lesson", "truth", "secret"]
        return contextTerms.contains { lower.contains($0) }
            && !concreteTerms.contains { lower.contains($0) }
    }

    private static func platformFit(for duration: TimeInterval) -> [String] {
        var platforms: [String] = []
        if duration <= 59 { platforms.append("youtube_shorts") }
        if duration <= 90 { platforms.append("instagram_reels") }
        if duration <= 180 { platforms.append("tiktok") }
        if duration <= 140 { platforms.append("twitter") }
        if duration <= 600 { platforms.append("linkedin") }
        return platforms
    }

    private static func suppressOverlaps(
        _ candidates: [ViralMomentScoredCandidate],
        maxOverlapRatio: Double
    ) -> [ViralMomentScoredCandidate] {
        var kept: [ViralMomentScoredCandidate] = []
        for candidate in candidates {
            if kept.contains(where: { overlapRatio(candidate.candidate, $0.candidate) > maxOverlapRatio }) {
                continue
            }
            kept.append(candidate)
        }
        return kept
    }
}
