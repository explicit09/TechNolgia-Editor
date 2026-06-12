import Foundation
import Testing
import EditorCore
@testable import AIServices

@Suite("B-roll opportunity planner tests")
struct BRollOpportunityPlannerTests {
    @Test("planner ranks abstract and statistic transcript moments for generated B-roll")
    func plannerRanksBrollMoments() throws {
        let words = timedWords("""
        AI infrastructure spending is exploding because every company needs GPU data centers now.
        Revenue jumped 42 percent last quarter and the chart finally made the story obvious.
        """)

        let planner = BRollOpportunityPlanner()
        let opportunities = planner.findOpportunities(
            transcript: words,
            platform: .shorts,
            maxResults: 3
        )

        #expect(opportunities.count >= 2)
        let first = try #require(opportunities.first)
        #expect(first.score >= 0.65)
        #expect(first.duration <= 3.0)
        #expect(first.prompt.contains("documentary B-roll video"))
        #expect(first.prompt.contains("no logos"))
        #expect(first.placement == .overlay)
        #expect(first.artifactKind == "video")
        #expect(first.preferredTool == "start_broll_video_job")
        #expect(first.fallbackTool == "generate_broll_asset")
        #expect(opportunities.contains { $0.category == .statistics })
    }

    @Test("planner spaces suggestions so B-roll does not fire on every sentence")
    func plannerSpacesSuggestions() throws {
        let words = timedWords("""
        The graph shows growth. The chart shows retention. The metric shows usage.
        The number proves demand. The dashboard explains the market.
        """, secondsPerWord: 0.25)

        let planner = BRollOpportunityPlanner()
        let opportunities = planner.findOpportunities(
            transcript: words,
            platform: .podcast,
            maxResults: 10
        )

        for pair in zip(opportunities, opportunities.dropFirst()) {
            #expect(pair.1.timelineStart - pair.0.timelineStart >= 5.0)
        }
    }

    private func timedWords(_ text: String, secondsPerWord: Double = 0.45) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, raw in
            let clean = raw.trimmingCharacters(in: .punctuationCharacters)
            let start = Double(index) * secondsPerWord
            return TranscriptWord(word: clean, start: start, end: start + secondsPerWord)
        }
    }
}
