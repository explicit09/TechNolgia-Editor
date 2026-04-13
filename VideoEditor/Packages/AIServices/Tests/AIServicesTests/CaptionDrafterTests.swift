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

    @Test("parseCaptions tolerates prose before and after the JSON block")
    func parseCaptionsWithProse() throws {
        let raw = """
        Here are the 5 platform captions you requested. I focused on making \
        the hooks distinct per platform:

        {
          "youtube_shorts": {"title": "Prose T", "body": "B1", "hashtags": ["#x"]},
          "tiktok": {"title": null, "body": "B2", "hashtags": ["#y"]},
          "instagram_reels": {"title": null, "body": "B3", "hashtags": []},
          "twitter": {"title": null, "body": "B4", "hashtags": []},
          "linkedin": {"title": null, "body": "B5", "hashtags": []}
        }

        Let me know if you'd like a different tone for any platform!
        """
        let captions = try CaptionDrafter.parseCaptions(from: raw)
        #expect(captions.count == 5)
        #expect(captions["youtube_shorts"]?.title == "Prose T")
    }

    @Test("parseCaptions balances braces inside string values")
    func parseCaptionsWithBracesInStrings() throws {
        // A caption body that includes a literal `}` in a quote must not
        // prematurely close the extracted block.
        let raw = """
        {
          "youtube_shorts": {"title": "T", "body": "This shipped with {dangerous JSON}", "hashtags": []},
          "tiktok": {"title": null, "body": "B", "hashtags": []},
          "instagram_reels": {"title": null, "body": "B", "hashtags": []},
          "twitter": {"title": null, "body": "B", "hashtags": []},
          "linkedin": {"title": null, "body": "B", "hashtags": []}
        }
        """
        let captions = try CaptionDrafter.parseCaptions(from: raw)
        #expect(captions.count == 5)
        #expect(captions["youtube_shorts"]?.body == "This shipped with {dangerous JSON}")
    }
}
