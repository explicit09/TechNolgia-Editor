import Foundation
import Testing
@testable import AIServices

@Suite("OpenRouter image provider tests")
struct OpenRouterImageProviderTests {
    @Test("request uses chat completions image modality and aspect ratio")
    func requestUsesImageModality() throws {
        let request = try OpenRouterImageProvider.request(
            apiKey: "test-key",
            model: "google/gemini-3.1-flash-image-preview",
            prompt: "Generate B-roll",
            aspectRatio: "9:16",
            imageSize: "1K"
        )

        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let model = try #require(json["model"] as? String)
        let modalities = try #require(json["modalities"] as? [String])
        let config = try #require(json["image_config"] as? [String: Any])
        let aspectRatio = try #require(config["aspect_ratio"] as? String)
        let imageSize = try #require(config["image_size"] as? String)

        #expect(model == "google/gemini-3.1-flash-image-preview")
        #expect(modalities == ["image", "text"])
        #expect(aspectRatio == "9:16")
        #expect(imageSize == "1K")
    }

    @Test("parser decodes base64 data url image from assistant message")
    func parserDecodesDataURL() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
        let response = """
        {
          "choices": [
            {
              "message": {
                "images": [
                  { "image_url": { "url": "\(dataURL)" } }
                ]
              }
            }
          ]
        }
        """

        let parsed = try OpenRouterImageProvider.parseImageData(from: Data(response.utf8))
        #expect(parsed == png)
    }
}
