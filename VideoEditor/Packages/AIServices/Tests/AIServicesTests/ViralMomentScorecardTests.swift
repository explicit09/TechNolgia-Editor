import Testing
import Foundation
@testable import AIServices

@Suite("Viral moment scorecard tests")
struct ViralMomentScorecardTests {
    @Test("scorecard boosts hook trend visual and good duration")
    func scorecardBoostsEvidence() throws {
        let candidates = [
            ViralMomentCandidate(
                id: "strong",
                start: 10,
                end: 50,
                evergreenScore: 8,
                trendingScore: 7,
                hook: "Why AI agents changed video editing",
                trendEvidenceLabels: ["AI agents"]
            ),
            ViralMomentCandidate(
                id: "weak",
                start: 80,
                end: 110,
                evergreenScore: 5,
                trendingScore: 5,
                hook: "General update",
                trendEvidenceLabels: []
            ),
        ]

        let ranked = ViralMomentScorecard.rank(
            candidates,
            visualEvidence: ViralMomentVisualEvidence(
                ranges: [
                    ViralMomentVisualRange(start: 8, end: 55, kind: .talkingHead),
                ],
                topicBoundaries: [10]
            ),
            limit: 10,
            maxOverlapRatio: nil
        )

        let first = try #require(ranked.first)
        #expect(first.candidate.id == "strong")
        #expect(first.breakdown.hook > 0)
        #expect(first.breakdown.trend > 0)
        #expect(first.breakdown.visual > 0)
        #expect(first.breakdown.topicBoundary > 0)
        #expect(first.grade.priority == .postNow)
        #expect(first.grade.tasteStatus == .pass)
        #expect(first.grade.bestPlatforms.contains("youtube_shorts"))
    }

    @Test("scorecard downgrades candidates with weak hook or no visual support")
    func scorecardDowngradesWeakCandidates() throws {
        let candidate = ViralMomentCandidate(
            id: "needs-review",
            start: 0,
            end: 12,
            evergreenScore: 7,
            trendingScore: 1,
            hook: "General context before we get started",
            trendEvidenceLabels: []
        )

        let ranked = ViralMomentScorecard.rank(
            [candidate],
            visualEvidence: .empty,
            limit: 1,
            maxOverlapRatio: nil
        )

        let first = try #require(ranked.first)
        #expect(first.grade.priority == .review)
        #expect(first.grade.tasteStatus == .downgrade)
        #expect(first.grade.warnings.contains(.weakHook))
        #expect(first.grade.warnings.contains(.tooShort))
        #expect(first.grade.warnings.contains(.missingVisualSupport))
    }

    @Test("scorecard suppresses lower scored overlapping variants")
    func scorecardSuppressesOverlappingVariants() throws {
        let candidates = [
            ViralMomentCandidate(id: "best", start: 0, end: 40, evergreenScore: 9, trendingScore: 2, hook: "Big mistake", trendEvidenceLabels: []),
            ViralMomentCandidate(id: "duplicate", start: 5, end: 38, evergreenScore: 6, trendingScore: 2, hook: "Big mistake extended", trendEvidenceLabels: []),
            ViralMomentCandidate(id: "separate", start: 90, end: 125, evergreenScore: 7, trendingScore: 1, hook: "Second idea", trendEvidenceLabels: []),
        ]

        let ranked = ViralMomentScorecard.rank(
            candidates,
            visualEvidence: .empty,
            limit: 10,
            maxOverlapRatio: 0.5
        )

        #expect(ranked.map(\.candidate.id) == ["best", "separate"])
    }

    @Test("invalid overlap ratio is rejected")
    func invalidOverlapRatioIsRejected() throws {
        #expect(throws: ViralMomentScorecardError.invalidOverlapRatio) {
            _ = try ViralMomentScorecard.validatedOverlapRatio(1.2)
        }
    }
}
