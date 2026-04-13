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
            etags: etags
        )
        progress?(0.95)

        // 6. Create the post.
        let postURN = try await createPost(
            author: tokens.memberURN,
            commentary: commentary,
            videoURN: initResponse.video,
            visibility: visibility
        )
        progress?(1.0)

        return URL(string: "https://www.linkedin.com/feed/update/\(postURN)")!
    }

    // MARK: - Retry wrapper

    /// Executes a LinkedIn API call and transparently retries once on 401 by
    /// refreshing the access token, and once on 429 after the server-advertised
    /// `Retry-After` delay. `build` is invoked each time so the fresh token is
    /// picked up on retry.
    ///
    /// Callers that need the bearer token should read it from
    /// `TokenStore.linkedIn.load()` inside `build` — the token may have been
    /// rotated by the refresh step between attempts.
    private func performWithRetry(
        _ build: () async throws -> URLRequest
    ) async throws -> (Data, URLResponse) {
        var request = try await build()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return (data, response)
        }

        if http.statusCode == 401 {
            guard let existing = try TokenStore.linkedIn.load() else {
                throw ClientError.notAuthorized
            }
            guard existing.refreshToken != nil else {
                throw ClientError.notAuthorized
            }
            _ = try await auth.refresh(using: existing)
            request = try await build()
            return try await URLSession.shared.data(for: request)
        }

        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                ?? http.value(forHTTPHeaderField: "retry-after")
            let seconds = UInt64(retryAfter?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            request = try await build()
            return try await URLSession.shared.data(for: request)
        }

        return (data, response)
    }

    /// Upload variant of `performWithRetry` — uses `URLSession.upload(for:from:)`
    /// rather than `data(for:)` so the raw body bytes stream from the `from:`
    /// parameter. We always refresh chunk bytes on retry via the `buildBody`
    /// closure (e.g. to re-read the chunk from disk).
    private func uploadWithRetry(
        buildRequest: () async throws -> URLRequest,
        buildBody: () async throws -> Data
    ) async throws -> (Data, URLResponse) {
        var request = try await buildRequest()
        var body = try await buildBody()
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            return (data, response)
        }

        if http.statusCode == 401 {
            guard let existing = try TokenStore.linkedIn.load() else {
                throw ClientError.notAuthorized
            }
            guard existing.refreshToken != nil else {
                throw ClientError.notAuthorized
            }
            _ = try await auth.refresh(using: existing)
            request = try await buildRequest()
            body = try await buildBody()
            return try await URLSession.shared.upload(for: request, from: body)
        }

        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                ?? http.value(forHTTPHeaderField: "retry-after")
            let seconds = UInt64(retryAfter?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            request = try await buildRequest()
            body = try await buildBody()
            return try await URLSession.shared.upload(for: request, from: body)
        }

        return (data, response)
    }

    /// Read a token from the Keychain for request construction. Throws
    /// `notAuthorized` if the bundle has been cleared mid-flight.
    private func currentAccessToken() throws -> String {
        guard let tokens = try TokenStore.linkedIn.load() else {
            throw ClientError.notAuthorized
        }
        return tokens.accessToken
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
            let length = Int(instruction.lastByte - instruction.firstByte + 1)
            // Chunks are processed strictly sequentially, so we can rely on the
            // file handle's current offset — no need to seek. Read exactly
            // `length` bytes; `read(upToCount:)` returns the available prefix.
            let chunk = try handle.read(upToCount: length) ?? Data()

            // Cache the chunk bytes so a 401 retry can re-upload without
            // rewinding the file handle (chunks are only 4 MB so this is cheap).
            let (data, response) = try await uploadWithRetry(
                buildRequest: {
                    var req = URLRequest(url: instruction.uploadUrl)
                    req.httpMethod = "PUT"
                    // LinkedIn's pre-signed URLs do not require auth headers;
                    // setting application/octet-stream is documented but
                    // optional. `from:` below is the source of truth for the
                    // body — do NOT also set `httpBody`, or the body would be
                    // sent twice.
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    return req
                },
                buildBody: { chunk }
            )
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
        let (respData, response) = try await uploadWithRetry(
            buildRequest: {
                var req = URLRequest(url: url)
                req.httpMethod = "PUT"
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                return req
            },
            buildBody: { data }
        )
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
        etags: [String]
    ) async throws {
        var components = URLComponents(url: LinkedInConfig.restAPIBase.appendingPathComponent("rest/videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "finalizeUpload")]
        let url = components.url!

        let bodyDict: [String: Any] = [
            "finalizeUploadRequest": [
                "video": videoURN,
                "uploadToken": uploadToken,
                "uploadedPartIds": etags,
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await performWithRetry { [weak self] in
            guard let self else { throw ClientError.notAuthorized }
            let token = try self.currentAccessToken()
            var req = self.standardRESTRequest(url: url, accessToken: token)
            req.httpMethod = "POST"
            req.httpBody = bodyData
            return req
        }
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
        visibility: Visibility
    ) async throws -> String {
        let url = LinkedInConfig.restAPIBase.appendingPathComponent("rest/posts")

        // LinkedIn's Posts API uses rest.li "little text" escaping in the
        // `commentary` field: the characters ( ) < > # \ * _ { } [ ] must be
        // prefixed with a backslash or the POST returns 422. Enforce the
        // 3000-character maximum after escaping.
        let escaped = escapeCommentary(commentary)
        let trimmed = escaped.count > 3000
            ? String(escaped.prefix(2997)) + "..."
            : escaped

        let bodyDict: [String: Any] = [
            "author": author,
            "commentary": trimmed,
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
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await performWithRetry { [weak self] in
            guard let self else { throw ClientError.notAuthorized }
            let token = try self.currentAccessToken()
            var req = self.standardRESTRequest(url: url, accessToken: token)
            req.httpMethod = "POST"
            req.httpBody = bodyData
            return req
        }
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

    /// Backslash-escape rest.li "little text" special characters. LinkedIn's
    /// Posts API otherwise returns 422 on raw parentheses, hashtags, etc.
    private func escapeCommentary(_ raw: String) -> String {
        let specials: Set<Character> = ["(", ")", "<", ">", "#", "\\", "*", "_", "{", "}", "[", "]"]
        var out = ""
        out.reserveCapacity(raw.count)
        for c in raw {
            if specials.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
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
