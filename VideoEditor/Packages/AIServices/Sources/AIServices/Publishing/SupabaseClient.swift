import Foundation
import os

/// Thin wrapper around Supabase REST + Storage HTTP APIs.
/// Uses service-role key, so RLS is bypassed — Mac is trusted.
public struct SupabaseClient: Sendable {
    private static let tusLog = Logger(subsystem: "com.videoeditor.app", category: "SupabaseTUS")

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

    // MARK: - TUS resumable upload

    /// Upload a file to Supabase Storage using the TUS resumable protocol.
    /// Required for files > 50 MB (the simple PUT endpoint caps at 50 MB).
    ///
    /// This implementation does NOT support resuming from an aborted upload.
    /// Any failure throws; the caller's retry logic will restart from a fresh POST.
    ///
    /// - Parameters:
    ///   - bucket: Storage bucket name (e.g. "shorts-videos").
    ///   - objectPath: Path within the bucket (e.g. "<uuid>.mp4").
    ///   - fileURL: Local file to upload.
    ///   - contentType: MIME type (e.g. "video/mp4").
    ///   - chunkSizeBytes: Size per PATCH. Defaults to 6 MB (Supabase's recommendation).
    ///   - progress: Optional callback invoked after each chunk with `bytesUploaded / totalBytes`.
    public func uploadFileResumable(
        bucket: String,
        objectPath: String,
        fileURL: URL,
        contentType: String,
        chunkSizeBytes: Int = 6 * 1024 * 1024,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // 1. Determine total size.
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let sizeNum = attrs[.size] as? NSNumber else {
            throw SupabaseError.invalidResponse
        }
        let totalBytes = sizeNum.int64Value
        Self.tusLog.debug("TUS start bucket=\(bucket, privacy: .public) path=\(objectPath, privacy: .public) size=\(totalBytes)")

        // 2. POST create — returns Location header for the upload URL.
        let createURL = baseURL.appendingPathComponent("storage/v1/upload/resumable")
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        createReq.setValue(serviceKey, forHTTPHeaderField: "apikey")
        createReq.setValue("true", forHTTPHeaderField: "x-upsert")
        createReq.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        createReq.setValue(String(totalBytes), forHTTPHeaderField: "Upload-Length")
        createReq.setValue(Self.tusUploadMetadata(
            bucketName: bucket, objectName: objectPath, contentType: contentType
        ), forHTTPHeaderField: "Upload-Metadata")

        let (createBody, createResp) = try await session.upload(for: createReq, from: Data())
        guard let createHTTP = createResp as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200..<300).contains(createHTTP.statusCode) else {
            let body = String(data: createBody, encoding: .utf8) ?? ""
            throw SupabaseError.httpError(status: createHTTP.statusCode, body: body)
        }
        guard let locationValue = createHTTP.value(forHTTPHeaderField: "Location"),
              let uploadURL = Self.resolveTusLocation(locationValue, relativeTo: baseURL) else {
            throw SupabaseError.httpError(status: createHTTP.statusCode, body: "Missing or invalid Location header on TUS create")
        }

        // 3. PATCH chunks.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        while offset < totalBytes {
            let chunk = try handle.read(upToCount: chunkSizeBytes) ?? Data()
            if chunk.isEmpty { break }

            var patchReq = URLRequest(url: uploadURL)
            patchReq.httpMethod = "PATCH"
            patchReq.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
            patchReq.setValue(serviceKey, forHTTPHeaderField: "apikey")
            patchReq.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            patchReq.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            patchReq.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")

            let (patchBody, patchResp) = try await session.upload(for: patchReq, from: chunk)
            guard let patchHTTP = patchResp as? HTTPURLResponse else {
                throw SupabaseError.invalidResponse
            }
            guard (200..<300).contains(patchHTTP.statusCode) else {
                let body = String(data: patchBody, encoding: .utf8) ?? ""
                throw SupabaseError.httpError(status: patchHTTP.statusCode, body: body)
            }

            // Advance offset from server header if present; fall back to local computation.
            if let newOffsetStr = patchHTTP.value(forHTTPHeaderField: "Upload-Offset"),
               let newOffset = Int64(newOffsetStr) {
                offset = newOffset
            } else {
                offset += Int64(chunk.count)
            }

            Self.tusLog.debug("TUS chunk offset=\(offset) / \(totalBytes)")
            if let progress, totalBytes > 0 {
                progress(Double(offset) / Double(totalBytes))
            }
        }

        guard offset == totalBytes else {
            throw SupabaseError.httpError(
                status: 0,
                body: "TUS upload incomplete: offset=\(offset) total=\(totalBytes)"
            )
        }
        Self.tusLog.debug("TUS complete bucket=\(bucket, privacy: .public) path=\(objectPath, privacy: .public) bytes=\(totalBytes)")
    }

    /// Build the `Upload-Metadata` header value: comma-separated `key <base64(value)>` pairs.
    /// Uses standard base64 (no URL-safe swaps, with padding).
    static func tusUploadMetadata(bucketName: String, objectName: String, contentType: String) -> String {
        func enc(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
        }
        return "bucketName \(enc(bucketName)),objectName \(enc(objectName)),contentType \(enc(contentType))"
    }

    /// Resolve the `Location` header from a TUS create response.
    /// It may be absolute or a path relative to `baseURL`.
    static func resolveTusLocation(_ value: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
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
