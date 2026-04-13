import Foundation
import UIKit

/// High-level LinkedIn API client. Wraps OAuth (delegated to `LinkedInAuth`)
/// and the 3-step Videos API + Posts API for direct video publishing.
///
/// Reference: research/2026-04-13-shorts-distribution-api-comparison.md §6
///
/// Three-step upload flow we implement in `publishShort`:
///   1. POST /rest/videos?action=initializeUpload
///        body: { initializeUploadRequest: { owner, fileSizeBytes, uploadCaptions: false, uploadThumbnail: true } }
///        returns: { value: { video, uploadInstructions: [...], thumbnailUploadUrl, uploadToken } }
///   2. PUT each chunk to `uploadInstructions[i].uploadUrl` (4 MB parts), capturing ETag from each response
///      PUT thumbnail bytes to `thumbnailUploadUrl`
///   3. POST /rest/videos?action=finalizeUpload
///        body: { finalizeUploadRequest: { video, uploadToken, uploadedPartIds: [etag1, etag2, ...] } }
///   4. POST /rest/posts
///        body: { author, commentary, visibility, distribution, content: { media: { id: <video URN> } }, lifecycleState: "PUBLISHED", isReshareDisabledByAuthor: false }
///        returns the post URN in `x-restli-id` response header.
@MainActor
final class LinkedInClient {
    enum Visibility: String {
        case `public` = "PUBLIC"
        case connections = "CONNECTIONS"
    }

    enum ClientError: Error, LocalizedError {
        case notAuthorized
        case notConfigured
        case downloadFailed(URLError)
        case downloadStatus(Int)
        case fileSystem(String)
        case requestFailed(String, Int, String)
        case decodeFailed(String, Error)
        case uploadChunkFailed(Int, Int, String)
        case missingResponseField(String)
        case thumbnailUploadFailed(Int, String)
        case finalizeFailed(Int, String)
        case postCreateFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Sign in with LinkedIn first."
            case .notConfigured: return "LinkedIn not configured. See docs/superpowers/setup/linkedin-setup.md."
            case .downloadFailed(let err): return "Video download failed: \(err.localizedDescription)"
            case .downloadStatus(let code): return "Video download returned HTTP \(code)."
            case .fileSystem(let detail): return "File system error: \(detail)"
            case .requestFailed(let label, let code, let body):
                return "\(label) failed (HTTP \(code)): \(body)"
            case .decodeFailed(let label, let err):
                return "\(label) decode failed: \(err.localizedDescription)"
            case .uploadChunkFailed(let index, let code, let body):
                return "Upload chunk \(index) failed (HTTP \(code)): \(body)"
            case .missingResponseField(let field):
                return "LinkedIn response missing expected field: \(field)"
            case .thumbnailUploadFailed(let code, let body):
                return "Thumbnail upload failed (HTTP \(code)): \(body)"
            case .finalizeFailed(let code, let body):
                return "Finalize upload failed (HTTP \(code)): \(body)"
            case .postCreateFailed(let code, let body):
                return "Create post failed (HTTP \(code)): \(body)"
            }
        }
    }

    /// Progress callback. Reports overall publish progress 0.0 → 1.0 spanning
    /// download (5%), chunked upload (80%), thumbnail (5%), finalize (5%), post (5%).
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let auth: LinkedInAuth
    /// 4 MB per LinkedIn's chunk requirement.
    private let chunkSize: Int = 4 * 1024 * 1024

    init() {
        self.auth = LinkedInAuth()
    }

    init(auth: LinkedInAuth) {
        self.auth = auth
    }

    // MARK: - Authorization surface

    var isAuthorized: Bool {
        (try? TokenStore.linkedIn.load()) != nil
    }

    var currentTokens: LinkedInTokens? {
        try? TokenStore.linkedIn.load()
    }

    /// Run the full OAuth flow. Returns the resolved member URN.
    @discardableResult
    func authorize() async throws -> String {
        let tokens = try await auth.authorize()
        return tokens.memberURN
    }

    func signOut() {
        TokenStore.linkedIn.clear()
    }

    /// Returns a token guaranteed fresh (refreshes if needed and possible).
    private func validAccessToken() async throws -> LinkedInTokens {
        guard let tokens = try TokenStore.linkedIn.load() else { throw ClientError.notAuthorized }
        if tokens.isFresh { return tokens }
        if tokens.refreshToken != nil {
            return try await auth.refresh(using: tokens)
        }
        // Token expired and no refresh token — caller must re-authorize.
        throw ClientError.notAuthorized
    }

    // MARK: - Public publish entry point

    /// Downloads the MP4 from `videoURL`, uploads it to LinkedIn in 4 MB chunks,
    /// uploads `thumbnailData` (PNG/JPEG bytes) to the dedicated thumbnail URL,
    /// finalizes, and creates the post. Returns the public LinkedIn URL.
    func publishShort(
        videoURL: URL,
        thumbnailData: Data?,
        commentary: String,
        visibility: Visibility = .public,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        guard LinkedInConfig.isConfigured else { throw ClientError.notConfigured }
        let tokens = try await validAccessToken()

        progress?(0.0)

        // 1. Download MP4 to a temp file so we can chunk by byte offset.
        let localFile = try await downloadVideo(from: videoURL)
        defer { try? FileManager.default.removeItem(at: localFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: localFile.path)
        guard let fileSize = (attrs[.size] as? NSNumber)?.int64Value, fileSize > 0 else {
            throw ClientError.fileSystem("Downloaded file has zero size")
        }
        progress?(0.05)

        // 2. Initialize upload — get chunked PUT URLs + thumbnail URL + token.
        let initResponse = try await initializeUpload(
            owner: tokens.memberURN,
            fileSizeBytes: fileSize,
            wantThumbnail: thumbnailData != nil,
            accessToken: tokens.accessToken
        )

        // 3. Chunked PUT, capture ETags in order.
        let etags = try await uploadChunks(
            file: localFile,
            instructions: initResponse.uploadInstructions,
            progress: { fraction in
                // Map upload portion to overall 5% → 85%.
                progress?(0.05 + fraction * 0.80)
            }
        )

        // 4. Thumbnail upload (if we have one).
        if let thumbnailData, let thumbnailURL = initResponse.thumbnailUploadUrl {
            try await uploadThumbnail(thumbnailData, to: thumbnailURL)
        }
        progress?(0.90)

        // 5. Finalize.
        try await finalizeUpload(
            videoURN: initResponse.video,
            uploadToken: initResponse.uploadToken,
            etags: etags,
            accessToken: tokens.accessToken
        )
        progress?(0.95)

        // 6. Create the post.
        let postURN = try await createPost(
            author: tokens.memberURN,
            commentary: commentary,
            videoURN: initResponse.video,
            visibility: visibility,
            accessToken: tokens.accessToken
        )
        progress?(1.0)

        return URL(string: "https://www.linkedin.com/feed/update/\(postURN)")!
    }

    // MARK: - Download

    private func downloadVideo(from url: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("li-upload-\(UUID().uuidString).mp4")
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ClientError.downloadStatus(http.statusCode)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch let urlErr as URLError {
            throw ClientError.downloadFailed(urlErr)
        } catch let clientErr as ClientError {
            throw clientErr
        } catch {
            throw ClientError.fileSystem(error.localizedDescription)
        }
    }

    // MARK: - Initialize upload

    private struct InitializeUploadResponse {
        let video: String                // urn:li:video:...
        let uploadToken: String
        let uploadInstructions: [UploadInstruction]
        let thumbnailUploadUrl: URL?
    }

    private struct UploadInstruction {
        let uploadUrl: URL
        let firstByte: Int64
        let lastByte: Int64
    }

    private func initializeUpload(
        owner: String,
        fileSizeBytes: Int64,
        wantThumbnail: Bool,
        accessToken: String
    ) async throws -> InitializeUploadResponse {
        var components = URLComponents(url: LinkedInConfig.restAPIBase.appendingPathComponent("rest/videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "initializeUpload")]
        var request = standardRESTRequest(url: components.url!, accessToken: accessToken)
        request.httpMethod = "POST"

        let body: [String: Any] = [
            "initializeUploadRequest": [
                "owner": owner,
                "fileSizeBytes": fileSizeBytes,
                "uploadCaptions": false,
                "uploadThumbnail": wantThumbnail,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw ClientError.requestFailed("initializeUpload", http?.statusCode ?? -1, bodyStr)
        }

        // LinkedIn wraps the response in {"value": {...}}. We parse defensively
        // because rest.li payloads are notoriously fiddly.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? [String: Any] else {
            throw ClientError.missingResponseField("value")
        }
        guard let videoURN = value["video"] as? String else {
            throw ClientError.missingResponseField("value.video")
        }
        guard let uploadToken = value["uploadToken"] as? String else {
            throw ClientError.missingResponseField("value.uploadToken")
        }
        guard let rawInstructions = value["uploadInstructions"] as? [[String: Any]], !rawInstructions.isEmpty else {
            throw ClientError.missingResponseField("value.uploadInstructions")
        }

        let instructions: [UploadInstruction] = try rawInstructions.map { dict in
            guard let urlStr = dict["uploadUrl"] as? String, let url = URL(string: urlStr) else {
                throw ClientError.missingResponseField("uploadInstructions[].uploadUrl")
            }
            let first = (dict["firstByte"] as? NSNumber)?.int64Value ?? 0
            let last = (dict["lastByte"] as? NSNumber)?.int64Value ?? 0
            return UploadInstruction(uploadUrl: url, firstByte: first, lastByte: last)
        }

        let thumbURL = (value["thumbnailUploadUrl"] as? String).flatMap(URL.init(string:))
        return InitializeUploadResponse(
            video: videoURN,
            uploadToken: uploadToken,
            uploadInstructions: instructions,
            thumbnailUploadUrl: thumbURL
        )
    }

    // MARK: - Chunked upload

    private func uploadChunks(
        file: URL,
        instructions: [UploadInstruction],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var etags: [String] = []
        let total = instructions.count
        for (index, instruction) in instructions.enumerated() {
            try handle.seek(toOffset: UInt64(instruction.firstByte))
            let length = Int(instruction.lastByte - instruction.firstByte + 1)
            // FileHandle.read(upToCount:) is appropriate for sequential chunks.
            let chunk = handle.readData(ofLength: length)

            var request = URLRequest(url: instruction.uploadUrl)
            request.httpMethod = "PUT"
            // LinkedIn's pre-signed URLs do not require auth headers; setting
            // application/octet-stream is documented but optional.
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = chunk

            let (data, response) = try await URLSession.shared.upload(for: request, from: chunk)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.uploadChunkFailed(index, -1, "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                throw ClientError.uploadChunkFailed(index, http.statusCode, bodyStr)
            }
            // ETag header is canonical; some CDNs return it as `etag` (lowercase).
            let rawEtag = http.value(forHTTPHeaderField: "ETag")
                ?? http.value(forHTTPHeaderField: "Etag")
                ?? http.value(forHTTPHeaderField: "etag")
                ?? ""
            // LinkedIn expects the unquoted ETag value as `uploadedPartIds`.
            let cleanedEtag = rawEtag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !cleanedEtag.isEmpty else {
                throw ClientError.uploadChunkFailed(index, http.statusCode, "Missing ETag header")
            }
            etags.append(cleanedEtag)
            progress(Double(index + 1) / Double(total))
        }
        return etags
    }

    // MARK: - Thumbnail upload

    private func uploadThumbnail(_ data: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.thumbnailUploadFailed(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: respData, encoding: .utf8) ?? "<non-utf8>"
            throw ClientError.thumbnailUploadFailed(http.statusCode, bodyStr)
        }
    }

    // MARK: - Finalize

    private func finalizeUpload(
        videoURN: String,
        uploadToken: String,
        etags: [String],
        accessToken: String
    ) async throws {
        var components = URLComponents(url: LinkedInConfig.restAPIBase.appendingPathComponent("rest/videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "finalizeUpload")]
        var request = standardRESTRequest(url: components.url!, accessToken: accessToken)
        request.httpMethod = "POST"

        let body: [String: Any] = [
            "finalizeUploadRequest": [
                "video": videoURN,
                "uploadToken": uploadToken,
                "uploadedPartIds": etags,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.finalizeFailed(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw ClientError.finalizeFailed(http.statusCode, bodyStr)
        }
    }

    // MARK: - Create post

    /// Returns the URN of the created post (e.g. `urn:li:share:7123456789`).
    private func createPost(
        author: String,
        commentary: String,
        videoURN: String,
        visibility: Visibility,
        accessToken: String
    ) async throws -> String {
        let url = LinkedInConfig.restAPIBase.appendingPathComponent("rest/posts")
        var request = standardRESTRequest(url: url, accessToken: accessToken)
        request.httpMethod = "POST"

        let body: [String: Any] = [
            "author": author,
            "commentary": commentary,
            "visibility": visibility.rawValue,
            "distribution": [
                "feedDistribution": "MAIN_FEED",
                "targetEntities": [],
                "thirdPartyDistributionChannels": [],
            ],
            "content": [
                "media": [
                    "id": videoURN,
                ],
            ],
            "lifecycleState": "PUBLISHED",
            "isReshareDisabledByAuthor": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.postCreateFailed(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw ClientError.postCreateFailed(http.statusCode, bodyStr)
        }
        // The post URN is returned in the `x-restli-id` response header.
        if let urn = http.value(forHTTPHeaderField: "x-restli-id")
            ?? http.value(forHTTPHeaderField: "X-RestLi-Id")
            ?? http.value(forHTTPHeaderField: "X-Restli-Id"),
           !urn.isEmpty {
            return urn
        }
        // Fallback: try parsing the body.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }
        throw ClientError.missingResponseField("x-restli-id")
    }

    // MARK: - Headers

    /// Builds a request with the four headers every LinkedIn /rest call needs.
    private func standardRESTRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(LinkedInConfig.apiVersion, forHTTPHeaderField: "LinkedIn-Version")
        request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
