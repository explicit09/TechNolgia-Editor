import Foundation

/// Thin wrapper around Supabase REST + Storage HTTP APIs.
/// Uses service-role key, so RLS is bypassed — Mac is trusted.
public struct SupabaseClient: Sendable {
    public let baseURL: URL
    public let serviceKey: String
    public let schema: String?
    public let session: URLSession

    public init(baseURL: URL, serviceKey: String, schema: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.serviceKey = serviceKey
        self.schema = schema
        self.session = session
    }

    public static func fromEnvironment(session: URLSession = .shared) -> SupabaseClient? {
        guard let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
              let url = URL(string: urlString),
              let key = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_KEY"],
              !key.isEmpty else {
            return nil
        }
        let schema = ProcessInfo.processInfo.environment["SUPABASE_SCHEMA"] ?? "shorts_app"
        return SupabaseClient(baseURL: url, serviceKey: key, schema: schema, session: session)
    }

    // MARK: - Request builders

    /// Build an INSERT request targeting the configured schema. Body is any JSON-encodable dictionary.
    public func buildInsertRequest(table: String, body: [String: Any]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("rest/v1/\(table)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue(serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        if let schema = schema {
            request.setValue(schema, forHTTPHeaderField: "Content-Profile")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Build a storage upload request. Body is set by the caller (usually file data).
    public func buildStorageUploadRequest(
        bucket: String,
        objectPath: String,
        contentType: String
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(objectPath)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        return request
    }

    /// Build a storage DELETE request for rollback.
    public func buildStorageDeleteRequest(bucket: String, objectPath: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(objectPath)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Execute

    /// Run a request, return body data. Throws on non-2xx.
    public func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(status: http.statusCode, body: body)
        }
        return data
    }

    /// Run an upload request with a file payload. Reads from disk via stream.
    public func uploadFile(_ request: URLRequest, fileURL: URL) async throws -> Data {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(status: http.statusCode, body: body)
        }
        return data
    }

    /// Run an upload with in-memory data (e.g. PNG/JPG bytes).
    public func uploadData(_ request: URLRequest, data: Data) async throws -> Data {
        let (respData, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(status: http.statusCode, body: body)
        }
        return respData
    }
}

public enum SupabaseError: Error, LocalizedError {
    case invalidResponse
    case httpError(status: Int, body: String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Supabase"
        case .httpError(let s, let b): "Supabase HTTP \(s): \(b.prefix(200))"
        case .notConfigured: "Supabase not configured (missing SUPABASE_URL or SUPABASE_SERVICE_KEY)"
        }
    }
}
