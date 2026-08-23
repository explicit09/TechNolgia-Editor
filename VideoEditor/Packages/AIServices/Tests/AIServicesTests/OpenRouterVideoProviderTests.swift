import Foundation
import Testing
@testable import AIServices

@Suite("OpenRouter video provider tests")
struct OpenRouterVideoProviderTests {
    @Test("submit request uses async video endpoint")
    func submitRequestUsesVideoEndpoint() throws {
        let request = try OpenRouterVideoProvider.submitRequest(
            apiKey: "test-key",
            model: "google/veo-3.1-lite",
            prompt: "documentary B-roll",
            duration: 4,
            resolution: "720p",
            aspectRatio: "9:16"
        )

        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/videos")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "TechNolgia")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "google/veo-3.1-lite")
        #expect(json["duration"] as? Int == 4)
        #expect(json["resolution"] as? String == "720p")
        #expect(json["aspect_ratio"] as? String == "9:16")
        #expect(json["generate_audio"] as? Bool == false)
    }

    @Test("job parser captures polling url and unsigned urls")
    func parserCapturesJobFields() throws {
        let response = """
        {
          "id": "job-123",
          "status": "completed",
          "polling_url": "/api/v1/videos/job-123",
          "unsigned_urls": ["https://cdn.example/video.mp4"]
        }
        """

        let job = try OpenRouterVideoProvider.parseJob(from: Data(response.utf8))
        #expect(job.id == "job-123")
        #expect(job.status == "completed")
        #expect(job.pollingURL == "/api/v1/videos/job-123")
        #expect(job.unsignedURLs == ["https://cdn.example/video.mp4"])
    }

    @Test("job parser accepts pending submit response before content urls exist")
    func parserAcceptsPendingSubmitResponse() throws {
        let response = """
        {
          "id": "job-123",
          "polling_url": "https://openrouter.ai/api/v1/videos/job-123",
          "status": "pending"
        }
        """

        let job = try OpenRouterVideoProvider.parseJob(from: Data(response.utf8))
        #expect(job.id == "job-123")
        #expect(job.status == "pending")
        #expect(job.pollingURL == "https://openrouter.ai/api/v1/videos/job-123")
        #expect(job.unsignedURLs.isEmpty)
    }

    @Test("download request falls back to content endpoint")
    func downloadRequestFallsBackToContentEndpoint() throws {
        let request = try OpenRouterVideoProvider.downloadRequest(
            apiKey: "test-key",
            jobID: "job-123",
            unsignedURL: nil
        )

        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/videos/job-123/content?index=0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }
}
