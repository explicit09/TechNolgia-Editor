import Testing
@testable import AIServices

@Suite("CaptionDrafter tests")
struct CaptionDrafterTests {
    @Test("parseCaptions extracts 5 platforms from JSON response")
    func parseCaptions() throws {
        let raw = """
        {
          "youtube_shorts": {"title": "YT Title", "body": "yt body", "hashtags": ["#a"]},
          "tiktok": {"title": null, "body": "tt body", "hashtags": ["#b"]},
          "instagram_reels": {"title": null, "body": "ig body", "hashtags": ["#c"]},
          "twitter": {"title": null, "body": "x body", "hashtags": ["#d"]},
          "linkedin": {"title": null, "body": "li body", "hashtags": ["#e"]}
        }
        """
        let captions = try CaptionDrafter.parseCaptions(from: raw)
        #expect(captions.count == 5)
        #expect(captions["youtube_shorts"]?.title == "YT Title")
        #expect(captions["tiktok"]?.title == nil)
        #expect(captions["linkedin"]?.body == "li body")
    }

    @Test("parseCaptions strips markdown code fence wrapping")
    func parseCaptionsWithFence() throws {
        let raw = """
        ```json
        {
          "youtube_shorts": {"title": "T", "body": "B", "hashtags": []},
          "tiktok": {"title": null, "body": "B", "hashtags": []},
          "instagram_reels": {"title": null, "body": "B", "hashtags": []},
          "twitter": {"title": null, "body": "B", "hashtags": []},
          "linkedin": {"title": null, "body": "B", "hashtags": []}
        }
        ```
        """
        let captions = try CaptionDrafter.parseCaptions(from: raw)
        #expect(captions.count == 5)
    }
}
