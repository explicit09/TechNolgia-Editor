import Foundation

public struct TrendContext: Codable, Sendable {
    public let provider: String
    public let capabilities: [String: TrendCapability]
    public let signals: [TrendSignal]
    public let usage: TrendUsage

    public init(
        provider: String = "mixed",
        capabilities: [String: TrendCapability],
        signals: [TrendSignal],
        usage: TrendUsage = .defaultHandoff
    ) {
        self.provider = provider
        self.capabilities = capabilities
        self.signals = signals
        self.usage = usage
    }

    public static func missingCredentials(sources: [String], queries: [String]) -> TrendContext {
        let normalizedSources = sources.isEmpty ? ["web"] : sources.map { $0.lowercased() }
        var capabilities: [String: TrendCapability] = [:]
        for source in normalizedSources {
            capabilities[source] = TrendCapability(
                status: "missing_credentials",
                reason: missingCredentialReason(for: source)
            )
        }
        return TrendContext(
            capabilities: capabilities,
            signals: [],
            usage: TrendUsage(
                passTo: TrendUsage.defaultHandoff.passTo,
                note: "Trend reads need credentials for \(normalizedSources.joined(separator: ", ")). Queries: \(queries.joined(separator: ", "))"
            )
        )
    }

    public func prettyJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(["trend_context": self])
        return String(decoding: data, as: UTF8.self)
    }

    private static func missingCredentialReason(for source: String) -> String {
        switch source {
        case "x", "twitter", "twitter_x":
            return "Direct X trend reads need an X bearer token. Use web trend reads until X credentials are configured."
        case "web":
            return "Web trend reads need an AI provider key with web search enabled."
        default:
            return "Trend reads for \(source) are not configured."
        }
    }
}

public struct TrendCapability: Codable, Sendable {
    public let status: String
    public let reason: String

    public init(status: String, reason: String) {
        self.status = status
        self.reason = reason
    }
}

public struct TrendSignal: Codable, Sendable {
    public let source: String
    public let label: String
    public let keywords: [String]
    public let weight: Double
    public let reason: String
    public let evidence: [TrendEvidence]

    public init(
        source: String,
        label: String,
        keywords: [String],
        weight: Double,
        reason: String,
        evidence: [TrendEvidence]
    ) {
        self.source = source
        self.label = label
        self.keywords = keywords
        self.weight = weight
        self.reason = reason
        self.evidence = evidence
    }
}

public struct TrendEvidence: Codable, Sendable {
    public let id: String
    public let title: String
    public let text: String
    public let url: String?
    public let engagementScore: Int

    public init(
        id: String,
        title: String,
        text: String,
        url: String?,
        engagementScore: Int
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.url = url
        self.engagementScore = engagementScore
    }
}

public struct TrendUsage: Codable, Sendable {
    public static let defaultHandoff = TrendUsage(
        passTo: "find_viral_moments.trend_context",
        note: "Use matched trend signals as a boost only after hook, standalone clarity, energy, payoff, and visual suitability pass."
    )

    public let passTo: String
    public let note: String

    public init(passTo: String, note: String) {
        self.passTo = passTo
        self.note = note
    }
}

public enum TrendContextBuilder {
    public static func build(
        source: String,
        resultsByQuery: [String: [TrendEvidence]]
    ) -> TrendContext {
        let normalizedSource = source.lowercased()
        let signals = resultsByQuery
            .compactMap { query, evidence in
                signal(source: normalizedSource, query: query, evidence: evidence)
            }
            .sorted { $0.weight == $1.weight ? $0.label < $1.label : $0.weight > $1.weight }

        return TrendContext(
            capabilities: [
                normalizedSource: TrendCapability(
                    status: "configured",
                    reason: "\(normalizedSource) trend reads returned inspectable evidence."
                )
            ],
            signals: signals
        )
    }

    private static func signal(source: String, query: String, evidence: [TrendEvidence]) -> TrendSignal? {
        let sortedEvidence = evidence
            .sorted { $0.engagementScore > $1.engagementScore }
            .prefix(3)
        guard let maxScore = sortedEvidence.map(\.engagementScore).max() else { return nil }
        return TrendSignal(
            source: source,
            label: query,
            keywords: keywords(for: query),
            weight: engagementWeight(maxScore),
            reason: "\(source) trend check for '\(query)' returned current evidence.",
            evidence: Array(sortedEvidence)
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
}
