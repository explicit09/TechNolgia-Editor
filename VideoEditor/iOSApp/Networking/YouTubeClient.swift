import Foundation
import UIKit

/// High-level YouTube API client. Wraps OAuth (delegated to `YouTubeAuth`) and
/// the two-step Shorts publish flow:
///
///   1. `videos.insert` resumable upload
///        - POST  https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status
///          headers: `Authorization`, `Content-Type: application/json; charset=UTF-8`,
///                   `X-Upload-Content-Type: video/mp4`, `X-Upload-Content-Length: <bytes>`
///          body:   { snippet: { title, description, tags, categoryId }, status: { ... } }
///          returns `Location: <session_url>` header.
///        - PUT   <session_url>  with `Content-Type: video/mp4` and the full mp4 bytes.
///          Single-shot PUT (resumable in name only — we don't chunk).
///          On 200/201 the response body is the created video resource → `id`.
///
///   2. `thumbnails.set`
///        - POST  https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=<id>&uploadType=media
///          headers: `Authorization`, `Content-Type: image/png`
///          body:   the PNG bytes.
///        - May return 400 if the channel isn't phone-verified — we catch and
///          continue with YouTube's auto-generated thumbnail.
///
/// Reference: research/2026-04-13-shorts-distribution-api-comparison.md §1.
@MainActor
final class YouTubeClient {
    enum Privacy: String {
        case publicVideo = "public"
        case unlisted
        case privateVideo = "private"
    }

    enum ClientError: Error, LocalizedError {
        case notAuthorized
        case notConfigured
        case downloadFailed(URLError)
        case downloadStatus(Int)
        case fileSystem(String)
        case requestFailed(String, Int, String)
        case decodeFailed(String, Error)
        case missingResponseField(String)
        /// YouTube daily upload quota (default 10,000 units / ~6 uploads) exhausted.
        /// `videos.insert` returns HTTP 403 with `errors[].reason == "quotaExceeded"`.
        case quotaExceeded

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Sign in with YouTube first."
            case .notConfigured: return "YouTube not configured. See docs/superpowers/setup/youtube-setup.md."
            case .downloadFailed(let err): return "Video download failed: \(err.localizedDescription)"
            case .downloadStatus(let code): return "Video download returned HTTP \(code)."
            case .fileSystem(let detail): return "File system error: \(detail)"
            case .requestFailed(let label, let code, let body):
                return "\(label) failed (HTTP \(code)): \(body)"
            case .decodeFailed(let label, let err):
                return "\(label) decode failed: \(err.localizedDescription)"
            case .missingResponseField(let field):
                return "YouTube response missing expected field: \(field)"
            case .quotaExceeded:
                return "YouTube daily upload quota exceeded — try again tomorrow."
            }
        }
    }

    /// Progress callback. Reports overall publish progress 0.0 → 1.0 spanning
    /// download (5%), resumable init (5%), upload (80%), thumbnail (5%), finalize/return (5%).
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let auth: YouTubeAuth

    init() {
        self.auth = YouTubeAuth()
    }

    init(auth: YouTubeAuth) {
        self.auth = auth
    }

    // MARK: - Authorization surface

    var isAuthorized: Bool {
        (try? TokenStore.youTube.load()) != nil
    }

    var currentTokens: YouTubeTokens? {
        try? TokenStore.youTube.load()
    }

    /// Run the full OAuth flow. Returns the resolved channel ID.
    @discardableResult
    func authorize() async throws -> String {
        let tokens = try await auth.authorize()
        return tokens.channelID
    }

    func signOut() {
        TokenStore.youTube.clear()
    }

    /// Returns a token guaranteed fresh (refreshes if needed and possible).
    ///
    /// `minimumValidity` is how much life the token must have left before we
    /// consider it usable. Default 60 s is fine for short requests; long-running
    /// operations (the upload PUT) should pass a larger window so the token
    /// can't expire mid-flight.
    private func validAccessToken(minimumValidity: TimeInterval = 60) async throws -> YouTubeTokens {
        guard let tokens = try TokenStore.youTube.load() else { throw ClientError.notAuthorized }
        if Date().addingTimeInterval(minimumValidity) < tokens.expiresAt { return tokens }
        if tokens.refreshToken != nil {
            return try await auth.refresh(using: tokens)
        }
        // Token expired and no refresh token — caller must re-authorize.
        throw ClientError.notAuthorized
    }

    // MARK: - Public publish entry point

    /// Downloads the MP4 from `videoURL`, uploads it via `videos.insert` resumable,
    /// then attaches `thumbnailData` (PNG bytes) via `thumbnails.set`. Returns
    /// the public Shorts URL.
    ///
    /// `tags` and the `" #Shorts"` suffix on description help YouTube classify
    /// the upload as a Short (in addition to the inherent ≤60s + 9:16 detection).
    func publishShort(
        videoURL: URL,
        thumbnailData: Data?,
        title: String,
        description: String,
        tags: [String],
        categoryID: String = YouTubeConfig.defaultCategoryID,
        privacyStatus: Privacy = .publicVideo,
        madeForKids: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        guard YouTubeConfig.isConfigured else { throw ClientError.notConfigured }
        // A 220 MB upload PUT can take several minutes on slow networks. Refresh
        // now if the access token would expire within 30 min — otherwise a
        // mid-flight expiry bubbles up as a raw 401. Single-shot PUT is not retried.
        let tokens = try await validAccessToken(minimumValidity: 30 * 60)

        progress?(0.0)

        // 1. Download MP4 to a temp file. Single PUT means we need it fully on disk
        //    so we can read its length and upload the bytes.
        let localFile = try await downloadVideo(from: videoURL)
        defer { try? FileManager.default.removeItem(at: localFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: localFile.path)
        guard let fileSize = (attrs[.size] as? NSNumber)?.int64Value, fileSize > 0 else {
            throw ClientError.fileSystem("Downloaded file has zero size")
        }
        progress?(0.05)

        // 2. Initialize resumable upload — get session URL.
        let sessionURL = try await initializeResumableUpload(
            title: title,
            description: appendShortsTagIfMissing(description),
            tags: tags,
            categoryID: categoryID,
            privacyStatus: privacyStatus,
            madeForKids: madeForKids,
            fileSizeBytes: fileSize,
            accessToken: tokens.accessToken
        )
        progress?(0.10)

        // 3. Single-shot PUT of the full file to the session URL.
        let videoID = try await uploadVideo(
            file: localFile,
            sessionURL: sessionURL,
            fileSize: fileSize,
            progress: { fraction in
                // Map upload portion to overall 10% → 90%.
                progress?(0.10 + fraction * 0.80)
            }
        )

        // 4. Thumbnail (best-effort).
        //    The video is already live by this point, so thumbnail failure must
        //    NEVER abort the publish. Common causes we swallow:
        //      - 400: image too large / wrong format
        //      - 403: channel isn't phone-verified
        //      - 401: access token expired mid-publish
        //      - 413: payload too large
        //      - 5xx: transient Google-side issue
        //    In all cases YouTube auto-generates a cover — cosmetic degrade only.
        if let thumbnailData {
            do {
                try await setThumbnail(videoID: videoID, pngData: thumbnailData, accessToken: tokens.accessToken)
            } catch {
                NSLog("[YouTube] thumbnails.set failed (\(error.localizedDescription)); continuing with auto-generated thumbnail.")
            }
        }
        progress?(1.0)

        // Shorts viewer URL. YouTube auto-redirects to the watch URL on desktop
        // but presents the vertical Shorts player on mobile + youtube.com itself.
        return URL(string: "https://www.youtube.com/shorts/\(videoID)")!
    }

    // MARK: - Download

    private func downloadVideo(from url: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-upload-\(UUID().uuidString).mp4")
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

    // MARK: - Initialize resumable upload

    private func initializeResumableUpload(
        title: String,
        description: String,
        tags: [String],
        categoryID: String,
        privacyStatus: Privacy,
        madeForKids: Bool,
        fileSizeBytes: Int64,
        accessToken: String
    ) async throws -> URL {
        var components = URLComponents(url: YouTubeConfig.uploadBase.appendingPathComponent("videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "part", value: "snippet,status"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(fileSizeBytes), forHTTPHeaderField: "X-Upload-Content-Length")

        let body: [String: Any] = [
            "snippet": [
                "title": title,
                "description": description,
                "tags": tags,
                "categoryId": categoryID,
            ],
            "status": [
                "privacyStatus": privacyStatus.rawValue,
                "selfDeclaredMadeForKids": madeForKids,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("videos.insert init", -1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            // 403 with reason=="quotaExceeded" → typed error so the UI can
            // surface a specific message (daily cap = 10,000 units ≈ 6 uploads).
            // Other 403s (auth/permission) fall through to the generic error.
            if http.statusCode == 403, Self.isQuotaExceeded(body: data) {
                throw ClientError.quotaExceeded
            }
            throw ClientError.requestFailed("videos.insert init", http.statusCode, bodyStr)
        }
        // Header lookup is case-insensitive in HTTPURLResponse but depend on
        // multiple casings to be safe.
        let location = http.value(forHTTPHeaderField: "Location")
            ?? http.value(forHTTPHeaderField: "location")
        guard let location, let url = URL(string: location) else {
            throw ClientError.missingResponseField("Location")
        }
        return url
    }

    // MARK: - Upload video bytes

    /// Single-shot PUT of the full file to the resumable session URL. Uses
    /// `URLSession.upload(for:fromFile:)` with a delegate so we get byte-level
    /// progress without buffering the whole file in memory.
    /// Returns the new video's `id`.
    private func uploadVideo(
        file: URL,
        sessionURL: URL,
        fileSize: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let delegate = UploadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("videos.insert upload", -1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            if http.statusCode == 403, Self.isQuotaExceeded(body: data) {
                throw ClientError.quotaExceeded
            }
            throw ClientError.requestFailed("videos.insert upload", http.statusCode, bodyStr)
        }

        // 200/201 body is the created video resource: { id, snippet, status, ... }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw ClientError.missingResponseField("id")
        }
        return id
    }

    // MARK: - Thumbnail

    private func setThumbnail(videoID: String, pngData: Data, accessToken: String) async throws {
        var components = URLComponents(url: YouTubeConfig.uploadBase.appendingPathComponent("thumbnails/set"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "videoId", value: videoID),
            URLQueryItem(name: "uploadType", value: "media"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, from: pngData)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("thumbnails.set", -1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw ClientError.requestFailed("thumbnails.set", http.statusCode, bodyStr)
        }
    }

    // MARK: - Helpers

    /// Append " #Shorts" to the description if not already present (case-insensitive).
    /// YouTube's research docs note this helps discoverability for borderline-Shorts uploads.
    private func appendShortsTagIfMissing(_ description: String) -> String {
        if description.lowercased().contains("#shorts") { return description }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "#Shorts" : "\(trimmed)\n\n#Shorts"
    }

    /// Inspect a YouTube Data API error body for `errors[].reason == "quotaExceeded"`.
    /// Shape: `{"error":{"code":403,"errors":[{"reason":"quotaExceeded",...}], ...}}`
    private static func isQuotaExceeded(body: Data) -> Bool {
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let errors = error["errors"] as? [[String: Any]]
        else { return false }
        return errors.contains { ($0["reason"] as? String) == "quotaExceeded" }
    }
}

// MARK: - Upload progress delegate

/// `URLSessionTaskDelegate` that forwards `bytesSent / totalBytesExpectedToSend`
/// fractions to a callback. Invoked on the session's delegate queue (not main).
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        progress(fraction)
    }
}
