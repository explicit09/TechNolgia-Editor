import Foundation

public struct XTrendContextClient: Sendable {
    public let baseURL: URL
    public let bearerToken: String
    public let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api.x.com")!,
        bearerToken: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    public func recentSearch(query: String, maxResults: Int) async throws -> XRecentSearchResponse {
        let request = try Self.request(
            baseURL: baseURL,
            bearerToken: bearerToken,
            query: query,
            maxResults: maxResults
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XTrendContextError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data.prefix(512), as: UTF8.self)
            throw XTrendContextError.api(statusCode: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(XRecentSearchResponse.self, from: data)
    }

    public static func request(
        baseURL: URL,
        bearerToken: String,
        query: String,
        maxResults: Int
    ) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/2/tweets/search/recent"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "max_results", value: "\(max(10, min(100, maxResults)))"),
            URLQueryItem(name: "tweet.fields", value: "created_at,author_id,public_metrics"),
        ]
        guard let url = components?.url else {
            throw XTrendContextError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

public enum XTrendContextError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case api(statusCode: Int, message: String)
}

public struct XRecentSearchResponse: Codable, Sendable {
    public let data: [XTweet]

    public init(data: [XTweet] = []) {
        self.data = data
    }
}

public struct XTweet: Codable, Sendable {
    public let id: String
    public let text: String
    public let publicMetrics: XPublicMetrics

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case publicMetrics = "public_metrics"
    }

    public init(id: String, text: String, publicMetrics: XPublicMetrics = XPublicMetrics()) {
        self.id = id
        self.text = text
        self.publicMetrics = publicMetrics
    }
}

public struct XPublicMetrics: Codable, Sendable {
    public let retweetCount: Int
    public let replyCount: Int
    public let likeCount: Int
    public let quoteCount: Int

    enum CodingKeys: String, CodingKey {
        case retweetCount = "retweet_count"
        case replyCount = "reply_count"
        case likeCount = "like_count"
        case quoteCount = "quote_count"
    }

    public init(
        retweetCount: Int = 0,
        replyCount: Int = 0,
        likeCount: Int = 0,
        quoteCount: Int = 0
    ) {
        self.retweetCount = retweetCount
        self.replyCount = replyCount
        self.likeCount = likeCount
        self.quoteCount = quoteCount
    }

    public var engagementScore: Int {
        likeCount + (retweetCount * 2) + replyCount + (quoteCount * 2)
    }
}

public enum XTrendContextBuilder {
    public static func build(searches: [(String, XRecentSearchResponse)]) -> TrendContext {
        let signals = searches.compactMap { query, response in
            signal(query: query, response: response)
        }
        return TrendContext(
            provider: "x",
            capabilities: [
                "x": TrendCapability(
                    status: "configured",
                    reason: "X trend reads returned inspectable recent-search evidence."
                )
            ],
            signals: signals
        )
    }

    private static func signal(query: String, response: XRecentSearchResponse) -> TrendSignal? {
        let evidence = response.data
            .map { tweet in
                TrendEvidence(
                    id: tweet.id,
                    title: "X post \(tweet.id)",
                    text: truncate(tweet.text, maxCharacters: 180),
                    url: "https://x.com/i/web/status/\(tweet.id)",
                    engagementScore: tweet.publicMetrics.engagementScore
                )
            }
            .sorted { $0.engagementScore > $1.engagementScore }
            .prefix(3)
        guard let maxScore = evidence.map(\.engagementScore).max() else { return nil }
        return TrendSignal(
            source: "x",
            label: query,
            keywords: keywords(for: query),
            weight: engagementWeight(maxScore),
            reason: "Recent X search for '\(query)' returned posts with engagement evidence.",
            evidence: Array(evidence)
        )
    }

    private static func keywords(for query: String) -> [String] {
        var values = [query]
        values.append(contentsOf: query
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 })
        return Array(Set(values)).sorted()
    }

    private static func engagementWeight(_ score: Int) -> Double {
        switch score {
        case ...4:
            return 0.3
        case 5...24:
            return 0.5
        case 25...99:
            return 0.7
        default:
            return 0.9
        }
    }

    private static func truncate(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }
}
