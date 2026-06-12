import Foundation

public enum OpenRouterImageError: Error, Equatable {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case apiError(status: Int, body: String)
}

public actor OpenRouterImageProvider: ImageGenProvider {
    public static let defaultModel = "google/gemini-3.1-flash-image-preview"

    public let name = "openrouter"

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = OpenRouterImageProvider.defaultModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public static func fromEnvironment(model: String = OpenRouterImageProvider.defaultModel) throws -> OpenRouterImageProvider {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else {
            throw OpenRouterImageError.missingAPIKey
        }
        return OpenRouterImageProvider(apiKey: key, model: model)
    }

    public func generateImage(
        prompt: String,
        referenceImages: [Data],
        size: ImageGenSize
    ) async throws -> Data {
        let aspectRatio: String
        switch size {
        case .thumbnail:
            aspectRatio = "16:9"
        case .square:
            aspectRatio = "1:1"
        case .portrait:
            aspectRatio = "9:16"
        }
        let request = try Self.request(
            apiKey: apiKey,
            model: model,
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageSize: "1K"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterImageError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterImageError.apiError(
                status: http.statusCode,
                body: String(decoding: data.prefix(500), as: UTF8.self)
            )
        }
        return try Self.parseImageData(from: data)
    }

    public static func request(
        apiKey: String,
        model: String,
        prompt: String,
        aspectRatio: String,
        imageSize: String
    ) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw OpenRouterImageError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ],
            ],
            "modalities": ["image", "text"],
            "stream": false,
            "image_config": [
                "aspect_ratio": aspectRatio,
                "image_size": imageSize,
            ],
        ] as [String: Any])
        return request
    }

    public static func parseImageData(from data: Data) throws -> Data {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let images = message["images"] as? [[String: Any]],
            let imageURL = images.first?["image_url"] as? [String: Any],
            let url = imageURL["url"] as? String
        else {
            throw OpenRouterImageError.invalidResponse
        }
        if let commaIndex = url.firstIndex(of: ","),
           url[..<commaIndex].contains("base64") {
            let encoded = String(url[url.index(after: commaIndex)...])
            guard let decoded = Data(base64Encoded: encoded) else {
                throw OpenRouterImageError.invalidResponse
            }
            return decoded
        }
        guard let remoteURL = URL(string: url), let remoteData = try? Data(contentsOf: remoteURL) else {
            throw OpenRouterImageError.invalidResponse
        }
        return remoteData
    }
}
