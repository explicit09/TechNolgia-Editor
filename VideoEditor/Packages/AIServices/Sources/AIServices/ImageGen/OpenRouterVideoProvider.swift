import Foundation

public enum OpenRouterVideoError: Error, Equatable {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case apiError(status: Int, body: String)
}

extension OpenRouterVideoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENROUTER_API_KEY is missing."
        case .invalidURL:
            return "OpenRouter video request URL is invalid."
        case .invalidResponse:
            return "OpenRouter video response could not be parsed."
        case let .apiError(status, body):
            return "OpenRouter video request failed with HTTP \(status): \(body)"
        }
    }
}

public struct OpenRouterVideoJob: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let pollingURL: String?
    public let unsignedURLs: [String]
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case pollingURL = "polling_url"
        case unsignedURLs = "unsigned_urls"
        case error
    }

    public init(id: String, status: String, pollingURL: String? = nil, unsignedURLs: [String] = [], error: String? = nil) {
        self.id = id
        self.status = status
        self.pollingURL = pollingURL
        self.unsignedURLs = unsignedURLs
        self.error = error
    }
}

public actor OpenRouterVideoProvider {
    public static let defaultModel = "bytedance/seedance-2.0"

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = OpenRouterVideoProvider.defaultModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func submit(
        prompt: String,
        duration: Int,
        resolution: String = "720p",
        aspectRatio: String
    ) async throws -> OpenRouterVideoJob {
        let request = try Self.submitRequest(
            apiKey: apiKey,
            model: model,
            prompt: prompt,
            duration: duration,
            resolution: resolution,
            aspectRatio: aspectRatio
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.parseJob(from: data)
    }

    public func poll(job: OpenRouterVideoJob) async throws -> OpenRouterVideoJob {
        let request = try Self.pollRequest(apiKey: apiKey, pollingURL: job.pollingURL, jobID: job.id)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.parseJob(from: data)
    }

    public func download(job: OpenRouterVideoJob) async throws -> Data {
        let request = try Self.downloadRequest(
            apiKey: apiKey,
            jobID: job.id,
            unsignedURL: job.unsignedURLs.first
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

    public static func submitRequest(
        apiKey: String,
        model: String,
        prompt: String,
        duration: Int,
        resolution: String,
        aspectRatio: String
    ) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/videos") else {
            throw OpenRouterVideoError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TechNolgia", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "duration": duration,
            "resolution": resolution,
            "aspect_ratio": aspectRatio,
            "generate_audio": false,
        ] as [String: Any])
        return request
    }

    public static func pollRequest(apiKey: String, pollingURL: String?, jobID: String) throws -> URLRequest {
        let urlString: String
        if let pollingURL, pollingURL.hasPrefix("http") {
            urlString = pollingURL
        } else if let pollingURL {
            urlString = "https://openrouter.ai\(pollingURL)"
        } else {
            urlString = "https://openrouter.ai/api/v1/videos/\(jobID)"
        }
        guard let url = URL(string: urlString) else {
            throw OpenRouterVideoError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func downloadRequest(apiKey: String, jobID: String, unsignedURL: String?) throws -> URLRequest {
        let urlString = unsignedURL ?? "https://openrouter.ai/api/v1/videos/\(jobID)/content?index=0"
        guard let url = URL(string: urlString) else {
            throw OpenRouterVideoError.invalidURL
        }
        var request = URLRequest(url: url)
        if urlString.hasPrefix("https://openrouter.ai/api/") {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public static func parseJob(from data: Data) throws -> OpenRouterVideoJob {
        do {
            return try JSONDecoder().decode(OpenRouterVideoJob.self, from: data)
        } catch {
            throw OpenRouterVideoError.invalidResponse
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterVideoError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterVideoError.apiError(
                status: http.statusCode,
                body: String(decoding: data.prefix(500), as: UTF8.self)
            )
        }
    }
}
