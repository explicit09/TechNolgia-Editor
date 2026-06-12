import Foundation
import Testing
@testable import AIServices

@Suite("X trend context tests")
struct XTrendContextTests {
    @Test("recent X posts become weighted trend signals")
    func recentPostsBecomeTrendSignals() throws {
        let responseJSON = """
        {
          "data": [
            {
              "id": "post-1",
              "text": "AI coding agents are changing prototype workflows",
              "public_metrics": {
                "like_count": 80,
                "retweet_count": 10,
                "reply_count": 4,
                "quote_count": 3
              }
            },
            {
              "id": "post-2",
              "text": "quiet lower engagement post",
              "public_metrics": {
                "like_count": 2,
                "retweet_count": 0,
                "reply_count": 0,
                "quote_count": 0
              }
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            XRecentSearchResponse.self,
            from: Data(responseJSON.utf8)
        )
        let context = XTrendContextBuilder.build(
            searches: [("AI coding agents", response)]
        )

        #expect(context.capabilities["x"]?.status == "configured")
        let signal = try #require(context.signals.first)
        #expect(signal.source == "x")
        #expect(signal.label == "AI coding agents")
        #expect(signal.keywords.contains("coding"))
        #expect(signal.weight == 0.9)
        #expect(signal.evidence.first?.id == "post-1")
        #expect(signal.evidence.first?.engagementScore == 110)
    }

    @Test("recent search request uses X API and bearer token")
    func recentSearchRequestUsesBearerToken() throws {
        let request = try XTrendContextClient.request(
            baseURL: URL(string: "https://api.x.com")!,
            bearerToken: "secret-token",
            query: "AI video editing",
            maxResults: 5
        )

        #expect(request.url?.absoluteString.contains("/2/tweets/search/recent") == true)
        #expect(request.url?.absoluteString.contains("query=AI%20video%20editing") == true)
        #expect(request.url?.absoluteString.contains("max_results=10") == true)
        #expect(request.url?.absoluteString.contains("tweet.fields=created_at,author_id,public_metrics") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }
}
