import Testing
@testable import AIServices

@Suite("Trend context tests")
struct TrendContextTests {
    @Test("missing credentials returns setup payload instead of failure")
    func missingCredentialsContext() throws {
        let context = TrendContext.missingCredentials(
            sources: ["x"],
            queries: ["AI video editing"]
        )

        #expect(context.provider == "mixed")
        #expect(context.signals.isEmpty)
        #expect(context.capabilities["x"]?.status == "missing_credentials")
        #expect(context.usage.passTo == "find_viral_moments.trend_context")
        #expect(context.usage.note.contains("AI video editing"))
    }

    @Test("evidence becomes weighted trend signals")
    func evidenceBecomesSignals() throws {
        let context = TrendContextBuilder.build(
            source: "web",
            resultsByQuery: [
                "AI agents": [
                    TrendEvidence(
                        id: "high",
                        title: "AI agents are changing video workflows",
                        text: "Creators are using AI agents to find clips faster.",
                        url: "https://example.com/high",
                        engagementScore: 140
                    ),
                    TrendEvidence(
                        id: "low",
                        title: "Small post",
                        text: "Quiet update.",
                        url: "https://example.com/low",
                        engagementScore: 3
                    ),
                ]
            ]
        )

        #expect(context.signals.count == 1)
        let signal = try #require(context.signals.first)
        #expect(signal.source == "web")
        #expect(signal.label == "AI agents")
        #expect(signal.keywords.contains("agents"))
        #expect(signal.weight == 0.9)
        #expect(signal.evidence.count == 2)
        #expect(signal.evidence.first?.id == "high")
    }

    @Test("trend context serializes as planner handoff JSON")
    func plannerHandoffJSON() throws {
        let context = TrendContextBuilder.build(
            source: "web",
            resultsByQuery: [
                "creator economy": [
                    TrendEvidence(
                        id: "1",
                        title: "Creator economy funding",
                        text: "A current funding discussion.",
                        url: nil,
                        engagementScore: 25
                    )
                ]
            ]
        )

        let json = try context.prettyJSONString()

        #expect(json.contains("\"trend_context\""))
        #expect(json.contains("\"signals\""))
        #expect(json.contains("\"creator economy\""))
        #expect(json.contains("\"pass_to\" : \"find_viral_moments.trend_context\""))
    }

    @MainActor
    @Test("tool registry exposes check_trend_context as app handled")
    func toolRegistryExposesTrendContext() throws {
        #expect(AIToolRegistry.allTools.contains { $0.name == "check_trend_context" })

        let intents = try AIToolResolver().resolve(
            toolName: "check_trend_context",
            arguments: ["queries": ["AI video editing"]]
        )

        #expect(intents.isEmpty)
    }

    @Test("find viral moments accepts trend context handoff")
    func findViralMomentsAcceptsTrendContext() throws {
        let tool = try #require(AIToolRegistry.allTools.first { $0.name == "find_viral_moments" })

        #expect(tool.parameters.properties?["trend_context"]?.type == "string")
        #expect(tool.parameters.properties?["trend_context"]?.description?.contains("check_trend_context") == true)
    }
}
