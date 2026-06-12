import XCTest
@testable import ShortsDistribution

final class ShortScoreTests: XCTestCase {
    func testDistributionScoreWeightsTrendSlightlyAboveEvergreen() {
        let short = makeShort(evergreenScore: 6, trendingScore: 10)

        XCTAssertEqual(short.distributionScore, 82)
        XCTAssertEqual(short.distributionScoreLabel, "82")
    }

    func testPostingPriorityUsesScoreBands() {
        XCTAssertEqual(makeShort(evergreenScore: 9, trendingScore: 9).postingPriorityLabel, "Post now")
        XCTAssertEqual(makeShort(evergreenScore: 7, trendingScore: 7).postingPriorityLabel, "Queue")
        XCTAssertEqual(makeShort(evergreenScore: 4, trendingScore: 5).postingPriorityLabel, "Review")
    }

    func testStoredPipelineGradeOverridesFallbackScore() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "created_at": "2026-06-12T10:00:00Z",
          "source_asset": "Episode.mov",
          "hook": "Why this matters",
          "label": "Test Short",
          "duration": 42,
          "evergreen_score": 4,
          "trending_score": 4,
          "platform_fit": ["youtube_shorts"],
          "source_start": 10,
          "source_end": 52,
          "video_path": "shorts/test.mp4",
          "thumbnail_path": "shorts/test.png",
          "video_size": 1000000,
          "reasoning": "Good hook.",
          "distribution_score": 91,
          "posting_priority": "post_now",
          "score_warnings": ["missing_visual_support"],
          "best_platforms": ["youtube_shorts", "instagram_reels"],
          "score_breakdown": {
            "hook": 8,
            "visual": 6,
            "trend": 6,
            "total": 91
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let short = try decoder.decode(Short.self, from: Data(json.utf8))

        XCTAssertEqual(short.distributionScore, 91)
        XCTAssertEqual(short.postingPriorityLabel, "Post now")
        XCTAssertEqual(short.scoreWarningLabels, ["Missing Visual Support"])
        XCTAssertEqual(short.bestPlatformLabels, ["Youtube Shorts", "Instagram Reels"])
        XCTAssertEqual(short.scoreSummaryLabel, "H 8 · V 6 · T 6")
    }

    private func makeShort(
        evergreenScore: Int,
        trendingScore: Int,
        platformFit: [String] = ["youtube_shorts", "tiktok"]
    ) -> Short {
        Short(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 1_781_000_000),
            sourceAsset: "Episode.mov",
            hook: "A strong hook",
            label: "Test Short",
            duration: 42,
            evergreenScore: evergreenScore,
            trendingScore: trendingScore,
            platformFit: platformFit,
            sourceStart: 10,
            sourceEnd: 52,
            videoPath: "shorts/test.mp4",
            thumbnailPath: "shorts/test.png",
            videoSize: 1_000_000,
            reasoning: "Useful because it has a clear hook.",
            episodeName: "Episode 1",
            episodeOrder: 1
        )
    }
}
