# iOS Distribution App — Plan 2 of 3: Mac Uploader

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new MCP tool `upload_short_to_library` that, after a short is exported, pushes the MP4 + default thumbnail + 10 candidate frames + metadata + 5 caption drafts to Supabase. Retries on failure, queues persistently, no orphan rows.

**Architecture:** New `SupabaseUploader` class in `AIServices` package wraps the Supabase REST + Storage APIs over `URLSession`. A new `CaptionDrafter` generates the 5 platform captions in one Claude call. A new `ThumbnailCandidates` helper produces 10 post-composition JPG frames reusing `ShortFormLayoutRenderer`. The `handleUploadShortToLibrary` MCP handler orchestrates all of the above with retry + rollback. Failed uploads land in `pending_uploads.json` inside the app's sandbox.

**Tech Stack:** Swift, URLSession, JSONEncoder/JSONSerialization, existing `ClaudeProvider`, `ShortFormLayoutRenderer`, `ThumbnailScorer`.

**Reference spec:** `docs/superpowers/specs/2026-04-12-ios-distribution-app-design.md` — especially `Mac-side upload`.

**Reference plan:** Plan 1 (Supabase backend) must be complete. Schema + buckets live.

---

## File Structure

```
VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/
├── SupabaseClient.swift         # Thin REST + Storage wrapper (auth header, JSON, file upload)
├── SupabaseUploader.swift        # High-level: orchestrates all uploads + rollback
├── CaptionDrafter.swift          # Generates 5 platform captions in one Claude call
└── PendingUploadsQueue.swift     # Persist failed uploads to disk, drain on next run

VideoEditor/Packages/EditorCore/Sources/EditorCore/Rendering/
└── ThumbnailCandidates.swift     # Extract N post-composition JPGs across a source range

VideoEditor/Packages/AIServices/Sources/AIServices/Tools/
└── AIToolRegistry.swift          # MODIFY: add upload_short_to_library definition

VideoEditor/VideoEditor/App/
└── MCPServer.swift               # MODIFY: add handleUploadShortToLibrary

VideoEditor/Packages/AIServices/Tests/AIServicesTests/
├── SupabaseClientTests.swift     # Mock URLSession to test request shape
├── CaptionDrafterTests.swift     # Mock ClaudeProvider to test JSON extraction
└── PendingUploadsQueueTests.swift # Encode/decode + drain behavior
```

---

## Task 1: SupabaseClient — minimal HTTP wrapper

**Files:**
- Create: `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseClient.swift`
- Create: `VideoEditor/Packages/AIServices/Tests/AIServicesTests/SupabaseClientTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SupabaseClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AIServices

@Suite("SupabaseClient tests")
struct SupabaseClientTests {
    @Test("buildInsertRequest embeds service key in Authorization + apikey headers")
    func insertRequestHeaders() throws {
        let client = SupabaseClient(
            baseURL: URL(string: "https://example.supabase.co")!,
            serviceKey: "testkey"
        )
        let request = try client.buildInsertRequest(
            table: "shorts",
            body: ["id": "abc"]
        )

        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/shorts")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer testkey")
        #expect(request.value(forHTTPHeaderField: "apikey") == "testkey")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
    }

    @Test("buildStorageUploadRequest targets storage endpoint with correct content-type")
    func storageRequestHeaders() throws {
        let client = SupabaseClient(
            baseURL: URL(string: "https://example.supabase.co")!,
            serviceKey: "testkey"
        )
        let request = try client.buildStorageUploadRequest(
            bucket: "videos",
            objectPath: "abc.mp4",
            contentType: "video/mp4"
        )

        #expect(request.url?.absoluteString == "https://example.supabase.co/storage/v1/object/videos/abc.mp4")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer testkey")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(request.value(forHTTPHeaderField: "x-upsert") == "true")
    }
}
```

- [ ] **Step 2: Run test — should fail (SupabaseClient doesn't exist)**

Run:
```bash
cd VideoEditor/Packages/AIServices && swift test --filter SupabaseClientTests 2>&1 | tail -5
```

Expected: FAIL, compile error "Cannot find type 'SupabaseClient' in scope".

- [ ] **Step 3: Write minimal SupabaseClient**

Create `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseClient.swift`:

```swift
import Foundation

/// Thin wrapper around Supabase REST + Storage HTTP APIs.
/// Uses service-role key, so RLS is bypassed — Mac is trusted.
public struct SupabaseClient: Sendable {
    public let baseURL: URL
    public let serviceKey: String
    public let session: URLSession

    public init(baseURL: URL, serviceKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.serviceKey = serviceKey
        self.session = session
    }

    public static func fromEnvironment(session: URLSession = .shared) -> SupabaseClient? {
        guard let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
              let url = URL(string: urlString),
              let key = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_KEY"],
              !key.isEmpty else {
            return nil
        }
        return SupabaseClient(baseURL: url, serviceKey: key, session: session)
    }

    // MARK: - Request builders

    /// Build an INSERT request into a public table. Body is any JSON-encodable dictionary.
    public func buildInsertRequest(table: String, body: [String: Any]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("rest/v1/\(table)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue(serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
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
```

- [ ] **Step 4: Run tests — should pass**

```bash
cd VideoEditor/Packages/AIServices && swift test --filter SupabaseClientTests 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseClient.swift \
       VideoEditor/Packages/AIServices/Tests/AIServicesTests/SupabaseClientTests.swift
git commit -m "feat(publishing): add SupabaseClient HTTP wrapper"
```

---

## Task 2: CaptionDrafter — generate 5 platform captions in one Claude call

**Files:**
- Create: `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/CaptionDrafter.swift`
- Create: `VideoEditor/Packages/AIServices/Tests/AIServicesTests/CaptionDrafterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CaptionDrafterTests.swift`:

```swift
import Testing
@testable import AIServices

@Suite("CaptionDrafter tests")
struct CaptionDrafterTests {
    @Test("parseCaptions extracts 5 platforms from JSON response")
    func parseCaptions() throws {
        let raw = """
        {
          "youtube_shorts": {"title": "YT Title", "body": "yt body", "hashtags": ["#a"]},
          "tiktok": {"title": null, "body": "tt body", "hashtags": ["#b"]},
          "instagram_reels": {"title": null, "body": "ig body", "hashtags": ["#c"]},
          "twitter": {"title": null, "body": "x body", "hashtags": ["#d"]},
          "linkedin": {"title": null, "body": "li body", "hashtags": ["#e"]}
        }
        """
        let captions = try CaptionDrafter.parseCaptions(from: raw)
        #expect(captions.count == 5)
        #expect(captions["youtube_shorts"]?.title == "YT Title")
        #expect(captions["tiktok"]?.title == nil)
        #expect(captions["linkedin"]?.body == "li body")
    }

    @Test("parseCaptions strips markdown code fence wrapping")
    func parseCaptionsWithFence() throws {
        let raw = """
        ```json
        {
          "youtube_shorts": {"title": "T", "body": "B", "hashtags": []},
          "tiktok": {"title": null, "body": "B", "hashtags": []},
          "instagram_reels": {"title": null, "body": "B", "hashtags": []},
          "twitter": {"title": null, "body": "B", "hashtags": []},
          "linkedin": {"title": null, "body": "B", "hashtags": []}
        }
        ```
        """
        let captions = try CaptionDrafter.parseCaptions(from: raw)
        #expect(captions.count == 5)
    }
}
```

- [ ] **Step 2: Run — should fail**

```bash
cd VideoEditor/Packages/AIServices && swift test --filter CaptionDrafterTests 2>&1 | tail -5
```

Expected: FAIL, "Cannot find 'CaptionDrafter'".

- [ ] **Step 3: Write CaptionDrafter**

Create `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/CaptionDrafter.swift`:

```swift
import Foundation

/// Draft JSON shape for one platform's caption.
public struct CaptionDraft: Codable, Sendable, Equatable {
    public let title: String?
    public let body: String
    public let hashtags: [String]

    public init(title: String?, body: String, hashtags: [String]) {
        self.title = title
        self.body = body
        self.hashtags = hashtags
    }
}

/// Generates one draft caption per platform by calling Claude once with all 5 platforms.
/// Platform keys: "youtube_shorts", "tiktok", "instagram_reels", "twitter", "linkedin".
public struct CaptionDrafter: Sendable {
    public static let platforms: [String] = [
        "youtube_shorts", "tiktok", "instagram_reels", "twitter", "linkedin"
    ]

    private let provider: any AIProvider

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    /// Generate all 5 captions. Returns dictionary keyed by platform.
    public func draftCaptions(
        hook: String,
        reasoning: String,
        label: String,
        duration: Double
    ) async throws -> [String: CaptionDraft] {
        let prompt = Self.buildPrompt(hook: hook, reasoning: reasoning, label: label, duration: duration)
        let response = try await provider.complete(
            messages: [AIMessage(role: "user", content: prompt)],
            tools: []
        )
        return try Self.parseCaptions(from: response.content)
    }

    /// Build the Claude prompt. Exposed for testing.
    static func buildPrompt(hook: String, reasoning: String, label: String, duration: Double) -> String {
        return """
        You are writing one social-media caption for EACH of 5 platforms for a short-form video clip.

        The clip:
        - Hook: "\(hook)"
        - Label: "\(label)"
        - Why it's viral: \(reasoning)
        - Duration: \(Int(duration)) seconds

        Platform rules:
        - youtube_shorts: title ≤100 chars (curiosity-driving), body up to 500 words, 3-5 hashtags
        - tiktok: title=null, body up to 150 words with inline hashtags, 5-10 hashtags total, casual
        - instagram_reels: title=null, body up to 150 words, 10-15 hashtags at the very end, lifestyle tone
        - twitter: title=null, body under 240 chars, 1-3 hashtags, punchy
        - linkedin: title=null, body 200-400 words in 2-4 paragraphs, 3-5 hashtags at end, professional but human

        Return ONLY a JSON object — no prose before or after, no markdown fence.
        Shape (exact keys):
        {
          "youtube_shorts": {"title": "string", "body": "string", "hashtags": ["#tag1", "#tag2"]},
          "tiktok": {"title": null, "body": "string", "hashtags": ["#tag1"]},
          "instagram_reels": {"title": null, "body": "string", "hashtags": []},
          "twitter": {"title": null, "body": "string", "hashtags": []},
          "linkedin": {"title": null, "body": "string", "hashtags": []}
        }

        Every hashtag must start with #. All 5 keys must be present.
        """
    }

    /// Parse Claude's response. Handles optional ```json ... ``` wrapping.
    public static func parseCaptions(from rawText: String) throws -> [String: CaptionDraft] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip optional markdown fence
        let stripped: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: "\n")
            stripped = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            stripped = trimmed
        }
        guard let data = stripped.data(using: .utf8) else {
            throw CaptionDrafterError.invalidJSON("not utf-8")
        }
        let decoded = try JSONDecoder().decode([String: CaptionDraft].self, from: data)
        return decoded
    }
}

public enum CaptionDrafterError: Error, LocalizedError {
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): "Caption JSON parse failed: \(detail)"
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd VideoEditor/Packages/AIServices && swift test --filter CaptionDrafterTests 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/CaptionDrafter.swift \
       VideoEditor/Packages/AIServices/Tests/AIServicesTests/CaptionDrafterTests.swift
git commit -m "feat(publishing): add CaptionDrafter for 5-platform drafts via Claude"
```

---

## Task 3: PendingUploadsQueue — persistent retry queue

**Files:**
- Create: `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/PendingUploadsQueue.swift`
- Create: `VideoEditor/Packages/AIServices/Tests/AIServicesTests/PendingUploadsQueueTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PendingUploadsQueueTests.swift`:

```swift
import Testing
import Foundation
@testable import AIServices

@Suite("PendingUploadsQueue tests")
struct PendingUploadsQueueTests {
    @Test("append then load roundtrips one entry")
    func appendAndLoad() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("q_\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let queue = PendingUploadsQueue(storagePath: tempFile.path)
        let entry = PendingUpload(
            shortID: UUID(),
            videoLocalPath: "/tmp/a.mp4",
            label: "Label",
            hook: "Hook",
            sourceAssetName: "Asset",
            sourceStart: 10,
            sourceEnd: 40,
            evergreenScore: 8,
            trendingScore: 5,
            platformFit: ["youtube_shorts"],
            reasoning: "r"
        )
        try queue.append(entry)
        let loaded = try queue.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].shortID == entry.shortID)
        #expect(loaded[0].label == "Label")
    }

    @Test("clear removes the file")
    func clear() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("q_\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let queue = PendingUploadsQueue(storagePath: tempFile.path)
        try queue.append(PendingUpload(
            shortID: UUID(),
            videoLocalPath: "/x",
            label: "",
            hook: "",
            sourceAssetName: "",
            sourceStart: 0,
            sourceEnd: 1,
            evergreenScore: 0,
            trendingScore: 0,
            platformFit: [],
            reasoning: ""
        ))
        try queue.clear()
        #expect(!FileManager.default.fileExists(atPath: tempFile.path))
    }
}
```

- [ ] **Step 2: Run — should fail**

```bash
cd VideoEditor/Packages/AIServices && swift test --filter PendingUploadsQueueTests 2>&1 | tail -5
```

- [ ] **Step 3: Write the queue**

Create `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/PendingUploadsQueue.swift`:

```swift
import Foundation

/// Serialized representation of an upload that failed and needs retry.
public struct PendingUpload: Codable, Sendable, Equatable {
    public let shortID: UUID
    public let videoLocalPath: String   // Still on local disk at retry time
    public let label: String
    public let hook: String
    public let sourceAssetName: String
    public let sourceStart: Double
    public let sourceEnd: Double
    public let evergreenScore: Int
    public let trendingScore: Int
    public let platformFit: [String]
    public let reasoning: String

    public init(
        shortID: UUID, videoLocalPath: String, label: String, hook: String,
        sourceAssetName: String, sourceStart: Double, sourceEnd: Double,
        evergreenScore: Int, trendingScore: Int, platformFit: [String], reasoning: String
    ) {
        self.shortID = shortID
        self.videoLocalPath = videoLocalPath
        self.label = label
        self.hook = hook
        self.sourceAssetName = sourceAssetName
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.evergreenScore = evergreenScore
        self.trendingScore = trendingScore
        self.platformFit = platformFit
        self.reasoning = reasoning
    }
}

/// Persistent FIFO queue of failed uploads. File lives in the app's sandbox at storagePath.
public struct PendingUploadsQueue: Sendable {
    public let storagePath: String

    public init(storagePath: String) {
        self.storagePath = storagePath
    }

    public static func defaultQueue() -> PendingUploadsQueue {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("VideoEditor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PendingUploadsQueue(storagePath: dir.appendingPathComponent("pending_uploads.json").path)
    }

    public func load() throws -> [PendingUpload] {
        guard FileManager.default.fileExists(atPath: storagePath) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: storagePath))
        return try JSONDecoder().decode([PendingUpload].self, from: data)
    }

    public func append(_ upload: PendingUpload) throws {
        var current = (try? load()) ?? []
        current.append(upload)
        let data = try JSONEncoder().encode(current)
        try data.write(to: URL(fileURLWithPath: storagePath), options: .atomic)
    }

    public func replace(_ uploads: [PendingUpload]) throws {
        let data = try JSONEncoder().encode(uploads)
        try data.write(to: URL(fileURLWithPath: storagePath), options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: storagePath) {
            try FileManager.default.removeItem(atPath: storagePath)
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd VideoEditor/Packages/AIServices && swift test --filter PendingUploadsQueueTests 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/PendingUploadsQueue.swift \
       VideoEditor/Packages/AIServices/Tests/AIServicesTests/PendingUploadsQueueTests.swift
git commit -m "feat(publishing): add PendingUploadsQueue for retryable uploads"
```

---

## Task 4: ThumbnailCandidates — produce 10 post-composition JPGs

**Files:**
- Create: `VideoEditor/Packages/EditorCore/Sources/EditorCore/Rendering/ThumbnailCandidates.swift`

- [ ] **Step 1: Write the helper**

Create `VideoEditor/Packages/EditorCore/Sources/EditorCore/Rendering/ThumbnailCandidates.swift`:

```swift
import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Produces N post-composition 9:16 JPG frames across a source time range.
/// Uses the same ShortFormLayoutRenderer the final video uses, so frames match
/// exactly what iOS will composite the pill+logo on top of.
public struct ThumbnailCandidates {
    /// Produce `count` JPG frames evenly spaced in [sourceStart, sourceEnd].
    /// Returns an array of (time, jpgData) tuples, index 0 = earliest.
    public static func extract(
        sourceURL: URL,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        shortFormConfig: ShortFormConfig,
        count: Int = 10,
        outputSize: CGSize = CGSize(width: 1080, height: 1920),
        jpegQuality: CGFloat = 0.80
    ) async throws -> [(time: TimeInterval, data: Data)] {
        precondition(count > 0)
        precondition(sourceEnd > sourceStart)

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        let ciContext = CIContext()
        var results: [(TimeInterval, Data)] = []

        for i in 0..<count {
            let fraction = (Double(i) + 0.5) / Double(count)
            let t = sourceStart + (sourceEnd - sourceStart) * fraction
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)

            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
                continue
            }

            // Apply the same 9:16 composition the video uses
            let sourceCI = CIImage(cgImage: cgImage)
            let composed = ShortFormLayoutRenderer.recompose(
                source: sourceCI,
                config: shortFormConfig,
                at: t,
                renderSize: outputSize
            )

            // Render to CGImage at outputSize
            let rect = CGRect(origin: .zero, size: outputSize)
            guard let composedCG = ciContext.createCGImage(composed, from: rect) else { continue }

            // Encode as JPEG
            guard let jpgData = encodeJPEG(composedCG, quality: jpegQuality) else { continue }
            results.append((t, jpgData))
        }

        return results
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
```

- [ ] **Step 2: Verify EditorCore still builds**

```bash
cd VideoEditor/Packages/EditorCore && swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add VideoEditor/Packages/EditorCore/Sources/EditorCore/Rendering/ThumbnailCandidates.swift
git commit -m "feat(rendering): add ThumbnailCandidates for JPG extraction across range"
```

---

## Task 5: SupabaseUploader — orchestrator with retry + rollback

**Files:**
- Create: `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseUploader.swift`

- [ ] **Step 1: Write the orchestrator**

Create `VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseUploader.swift`:

```swift
import Foundation
import EditorCore

public struct UploadResult: Sendable {
    public let shortID: UUID
    public let videoPath: String       // e.g. "videos/<id>.mp4"
    public let thumbnailPath: String   // e.g. "thumbnails/<id>.png"
}

/// High-level orchestrator. Uploads one short's artifacts + metadata to Supabase.
/// On failure, rolls back already-uploaded objects and appends to the pending queue.
public actor SupabaseUploader {
    private let client: SupabaseClient
    private let maxRetries: Int

    public init(client: SupabaseClient, maxRetries: Int = 3) {
        self.client = client
        self.maxRetries = maxRetries
    }

    public struct UploadArtifacts {
        public let shortID: UUID
        public let videoLocalURL: URL
        public let thumbnailPNGData: Data
        public let candidateFrames: [Data]  // JPG, 10 entries
        public let captions: [String: CaptionDraft]  // keyed by platform
        public let metadata: Metadata

        public struct Metadata {
            public let sourceAsset: String
            public let hook: String
            public let label: String
            public let duration: Double
            public let evergreenScore: Int
            public let trendingScore: Int
            public let platformFit: [String]
            public let sourceStart: Double
            public let sourceEnd: Double
            public let videoSize: Int64
            public let reasoning: String

            public init(sourceAsset: String, hook: String, label: String, duration: Double,
                        evergreenScore: Int, trendingScore: Int, platformFit: [String],
                        sourceStart: Double, sourceEnd: Double, videoSize: Int64, reasoning: String) {
                self.sourceAsset = sourceAsset
                self.hook = hook
                self.label = label
                self.duration = duration
                self.evergreenScore = evergreenScore
                self.trendingScore = trendingScore
                self.platformFit = platformFit
                self.sourceStart = sourceStart
                self.sourceEnd = sourceEnd
                self.videoSize = videoSize
                self.reasoning = reasoning
            }
        }

        public init(shortID: UUID, videoLocalURL: URL, thumbnailPNGData: Data,
                    candidateFrames: [Data], captions: [String: CaptionDraft],
                    metadata: Metadata) {
            self.shortID = shortID
            self.videoLocalURL = videoLocalURL
            self.thumbnailPNGData = thumbnailPNGData
            self.candidateFrames = candidateFrames
            self.captions = captions
            self.metadata = metadata
        }
    }

    public func upload(_ artifacts: UploadArtifacts) async throws -> UploadResult {
        let idStr = artifacts.shortID.uuidString.lowercased()
        let videoObjectPath = "\(idStr).mp4"
        let thumbObjectPath = "\(idStr).png"
        var uploadedObjects: [(bucket: String, path: String)] = []

        do {
            // 1. Video
            try await retrying {
                let req = try client.buildStorageUploadRequest(
                    bucket: "videos", objectPath: videoObjectPath, contentType: "video/mp4"
                )
                _ = try await client.uploadFile(req, fileURL: artifacts.videoLocalURL)
            }
            uploadedObjects.append(("videos", videoObjectPath))

            // 2. Thumbnail
            try await retrying {
                let req = try client.buildStorageUploadRequest(
                    bucket: "thumbnails", objectPath: thumbObjectPath, contentType: "image/png"
                )
                _ = try await client.uploadData(req, data: artifacts.thumbnailPNGData)
            }
            uploadedObjects.append(("thumbnails", thumbObjectPath))

            // 3. Candidate frames
            for (i, frameData) in artifacts.candidateFrames.enumerated() {
                let framePath = "\(idStr)/frame_\(i).jpg"
                try await retrying {
                    let req = try client.buildStorageUploadRequest(
                        bucket: "frames", objectPath: framePath, contentType: "image/jpeg"
                    )
                    _ = try await client.uploadData(req, data: frameData)
                }
                uploadedObjects.append(("frames", framePath))
            }

            // 4. shorts row
            try await retrying {
                let body: [String: Any] = [
                    "id": idStr,
                    "source_asset": artifacts.metadata.sourceAsset,
                    "hook": artifacts.metadata.hook,
                    "label": artifacts.metadata.label,
                    "duration": artifacts.metadata.duration,
                    "evergreen_score": artifacts.metadata.evergreenScore,
                    "trending_score": artifacts.metadata.trendingScore,
                    "platform_fit": artifacts.metadata.platformFit,
                    "source_start": artifacts.metadata.sourceStart,
                    "source_end": artifacts.metadata.sourceEnd,
                    "video_path": "videos/\(videoObjectPath)",
                    "thumbnail_path": "thumbnails/\(thumbObjectPath)",
                    "video_size": artifacts.metadata.videoSize,
                    "reasoning": artifacts.metadata.reasoning,
                ]
                let req = try client.buildInsertRequest(table: "shorts", body: body)
                _ = try await client.run(req)
            }

            // 5. thumbnail_settings defaults
            try await retrying {
                let body: [String: Any] = [
                    "short_id": idStr,
                    "label_text": artifacts.metadata.label,
                    "label_color": "#C9A028",
                    "label_position": "bottom-center",
                    "frame_index": 0,
                ]
                let req = try client.buildInsertRequest(table: "thumbnail_settings", body: body)
                _ = try await client.run(req)
            }

            // 6. captions × 5
            for platform in CaptionDrafter.platforms {
                guard let draft = artifacts.captions[platform] else {
                    throw SupabaseError.httpError(status: 0, body: "Missing caption for \(platform)")
                }
                try await retrying {
                    let body: [String: Any] = [
                        "short_id": idStr,
                        "platform": platform,
                        "title": draft.title as Any? ?? NSNull(),
                        "body": draft.body,
                        "hashtags": draft.hashtags,
                        "last_edited_by": "mac",
                    ]
                    let req = try client.buildInsertRequest(table: "captions", body: body)
                    _ = try await client.run(req)
                }
            }

            return UploadResult(
                shortID: artifacts.shortID,
                videoPath: "videos/\(videoObjectPath)",
                thumbnailPath: "thumbnails/\(thumbObjectPath)"
            )
        } catch {
            // Rollback: delete every object we uploaded
            for obj in uploadedObjects {
                let req = client.buildStorageDeleteRequest(bucket: obj.bucket, objectPath: obj.path)
                _ = try? await client.session.data(for: req)
            }
            throw error
        }
    }

    /// Run a throwing closure with up to maxRetries attempts, exponential backoff.
    private func retrying(_ work: @Sendable () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                try await work()
                return
            } catch {
                lastError = error
                if attempt + 1 < maxRetries {
                    let delayNs = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }
        }
        throw lastError ?? SupabaseError.invalidResponse
    }
}
```

- [ ] **Step 2: Verify AIServices builds**

```bash
cd VideoEditor/Packages/AIServices && swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add VideoEditor/Packages/AIServices/Sources/AIServices/Publishing/SupabaseUploader.swift
git commit -m "feat(publishing): add SupabaseUploader orchestrator with retry + rollback"
```

---

## Task 6: Register `upload_short_to_library` tool

**Files:**
- Modify: `VideoEditor/Packages/AIServices/Sources/AIServices/Tools/AIToolRegistry.swift`

- [ ] **Step 1: Add the tool definition**

In `AIToolRegistry.swift`, locate the `allTools` array and add a new static definition near the existing tools (after `findViralMoments` is a good spot):

```swift
public static let uploadShortToLibrary = AIToolDefinition(
    name: "upload_short_to_library",
    description: "Upload an already-exported short (mp4) to the Supabase library so the iOS distribution app can see it. Generates 10 candidate thumbnail frames, writes 5 per-platform caption drafts via Claude, uploads video + thumbnail + frames, and inserts metadata rows. Safe to call multiple times — uses short_id for idempotency.",
    parameters: .object([
        "asset_id": .init(type: "string", description: "UUID of the source asset"),
        "source_start": .init(type: "number", description: "Clip start time in source seconds"),
        "source_end": .init(type: "number", description: "Clip end time in source seconds"),
        "video_path": .init(type: "string", description: "Absolute path to the exported MP4 file on disk"),
        "label": .init(type: "string", description: "Pill label text (short, 2-5 words)"),
        "hook": .init(type: "string", description: "Original hook quote for this moment"),
        "evergreen_score": .init(type: "number", description: "0-10; default 0"),
        "trending_score": .init(type: "number", description: "0-10; default 0"),
        "platform_fit": .init(type: "array", description: "Platforms this duration fits"),
        "reasoning": .init(type: "string", description: "Why-viral explanation"),
        "source_asset_name": .init(type: "string", description: "Display name of source asset (e.g. podcast episode title)"),
    ], required: ["asset_id", "source_start", "source_end", "video_path", "label", "hook"])
)
```

- [ ] **Step 2: Register it in the allTools array**

Find the `public static let allTools: [AIToolDefinition] = [...]` and add `uploadShortToLibrary,` to the list in a sensible place (grouped with other publishing-adjacent tools, or at the end).

- [ ] **Step 3: Verify build**

```bash
cd VideoEditor/Packages/AIServices && swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add VideoEditor/Packages/AIServices/Sources/AIServices/Tools/AIToolRegistry.swift
git commit -m "feat(tools): register upload_short_to_library"
```

---

## Task 7: Handler in MCPServer.swift

**Files:**
- Modify: `VideoEditor/VideoEditor/App/MCPServer.swift`

- [ ] **Step 1: Add the handler method**

In `MCPServer.swift`, add a new section `// MARK: - Upload Short To Library` near `handleFindViralMoments`:

```swift
// MARK: - Upload Short To Library

private func handleUploadShortToLibrary(_ args: [String: Any], appState: AppState) async -> String {
    // Parse arguments
    guard let assetIDStr = args["asset_id"] as? String,
          let assetID = UUID(uuidString: assetIDStr),
          let asset = appState.assets.first(where: { $0.id == assetID }) else {
        return "Error: Invalid asset_id"
    }
    guard let sourceStart = args["source_start"] as? Double,
          let sourceEnd = args["source_end"] as? Double,
          sourceEnd > sourceStart else {
        return "Error: source_start/source_end required and end must be greater than start"
    }
    guard let videoPath = args["video_path"] as? String,
          FileManager.default.fileExists(atPath: videoPath) else {
        return "Error: video_path must point to an existing file on disk"
    }
    guard let label = args["label"] as? String,
          let hook = args["hook"] as? String else {
        return "Error: label and hook are required"
    }

    let evergreen = (args["evergreen_score"] as? Int) ?? (args["evergreen_score"] as? Double).map { Int($0) } ?? 0
    let trending = (args["trending_score"] as? Int) ?? (args["trending_score"] as? Double).map { Int($0) } ?? 0
    let platformFit = (args["platform_fit"] as? [String]) ?? []
    let reasoning = (args["reasoning"] as? String) ?? ""
    let sourceAssetName = (args["source_asset_name"] as? String) ?? asset.name

    // Configure Supabase client
    guard let client = SupabaseClient.fromEnvironment() else {
        return "Error: Supabase not configured. Set SUPABASE_URL and SUPABASE_SERVICE_KEY in .env."
    }

    // Load the pre-generated default thumbnail PNG. We reuse the existing
    // generate_short_thumbnail logic so the stored default matches what the Mac
    // displays; then we upload that PNG as the "default" alongside candidate JPGs.
    let thumbTempPath = NSTemporaryDirectory() + "upload_default_thumb_\(UUID()).png"
    defer { try? FileManager.default.removeItem(atPath: thumbTempPath) }

    // Invoke generate_short_thumbnail inline by calling the same code path
    let thumbArgs: [String: Any] = [
        "asset_id": assetIDStr,
        "source_start": sourceStart,
        "source_end": sourceEnd,
        "hook_text": hook,
        "label_text": label,
        "template": "technologia_talks",
        "output_path": thumbTempPath,
    ]
    _ = await handleGenerateShortThumbnail(thumbArgs, appState: appState)
    guard let thumbnailPNGData = FileManager.default.contents(atPath: thumbTempPath) else {
        return "Error: Thumbnail generation failed — no default PNG"
    }

    // Build the shortFormConfig by running analyze_for_shorts for this range
    _ = await handleAnalyzeForShorts([
        "asset_id": assetIDStr, "start": sourceStart, "end": sourceEnd,
    ], appState: appState)
    guard let shortFormConfig = shortFormConfigs[assetID] else {
        return "Error: Could not build ShortFormConfig for candidate frames"
    }

    // Extract 10 candidate frames
    let candidates: [(time: TimeInterval, data: Data)]
    do {
        candidates = try await ThumbnailCandidates.extract(
            sourceURL: resolvedToolMediaURL(for: asset),
            sourceStart: sourceStart,
            sourceEnd: sourceEnd,
            shortFormConfig: shortFormConfig,
            count: 10
        )
    } catch {
        return "Error: Frame extraction failed — \(error.localizedDescription)"
    }
    guard candidates.count >= 5 else {
        return "Error: Only \(candidates.count) candidate frames could be extracted (need ≥5)"
    }

    // Generate 5 caption drafts via Claude
    guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? loadAnthropicKey() else {
        return "Error: ANTHROPIC_API_KEY not configured"
    }
    let provider = ClaudeProvider(apiKey: apiKey, model: "claude-sonnet-4-6")
    let drafter = CaptionDrafter(provider: provider)
    let duration = sourceEnd - sourceStart
    let captions: [String: CaptionDraft]
    do {
        captions = try await drafter.draftCaptions(
            hook: hook, reasoning: reasoning, label: label, duration: duration
        )
    } catch {
        return "Error: Caption drafting failed — \(error.localizedDescription)"
    }

    // Upload
    let shortID = UUID()
    let videoURL = URL(fileURLWithPath: videoPath)
    let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoPath)[.size] as? Int64) ?? 0

    let artifacts = SupabaseUploader.UploadArtifacts(
        shortID: shortID,
        videoLocalURL: videoURL,
        thumbnailPNGData: thumbnailPNGData,
        candidateFrames: candidates.map(\.data),
        captions: captions,
        metadata: .init(
            sourceAsset: sourceAssetName,
            hook: hook, label: label, duration: duration,
            evergreenScore: evergreen, trendingScore: trending,
            platformFit: platformFit,
            sourceStart: sourceStart, sourceEnd: sourceEnd,
            videoSize: videoSize, reasoning: reasoning
        )
    )

    let uploader = SupabaseUploader(client: client)
    do {
        let result = try await uploader.upload(artifacts)
        return "Uploaded to library. short_id=\(result.shortID.uuidString). video=\(result.videoPath), thumbnail=\(result.thumbnailPath)"
    } catch {
        // Persist to pending queue for retry
        let pending = PendingUpload(
            shortID: shortID,
            videoLocalPath: videoPath,
            label: label, hook: hook, sourceAssetName: sourceAssetName,
            sourceStart: sourceStart, sourceEnd: sourceEnd,
            evergreenScore: evergreen, trendingScore: trending,
            platformFit: platformFit, reasoning: reasoning
        )
        try? PendingUploadsQueue.defaultQueue().append(pending)
        return "Error: Upload failed — \(error.localizedDescription). Queued for retry."
    }
}
```

- [ ] **Step 2: Route the new tool name in `executeToolCall`**

Find the `executeToolCall` method. Near similar `if name == "..."` dispatches for other tools, add:

```swift
if name == "upload_short_to_library" {
    return await handleUploadShortToLibrary(arguments, appState: appState)
}
```

- [ ] **Step 3: Add to tools/list JSON**

Find where `tools/list` builds its JSON array of tool schemas. Add:

```swift
[
    "name": "upload_short_to_library",
    "description": "Upload an exported short (MP4) + generated thumbnail + 10 candidate frames + 5 caption drafts to the Supabase library. Requires Supabase env vars configured.",
    "inputSchema": ["type": "object", "properties": [
        "asset_id": ["type": "string"],
        "source_start": ["type": "number"],
        "source_end": ["type": "number"],
        "video_path": ["type": "string"],
        "label": ["type": "string"],
        "hook": ["type": "string"],
        "evergreen_score": ["type": "number"],
        "trending_score": ["type": "number"],
        "platform_fit": ["type": "array"],
        "reasoning": ["type": "string"],
        "source_asset_name": ["type": "string"],
    ], "required": ["asset_id", "source_start", "source_end", "video_path", "label", "hook"]],
],
```

- [ ] **Step 4: Build the full app**

```bash
cd VideoEditor && xcodebuild -scheme VideoEditor -destination 'platform=macOS' build 2>&1 | grep -E "(BUILD|error:)" | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add VideoEditor/VideoEditor/App/MCPServer.swift
git commit -m "feat(mcp): add upload_short_to_library handler"
```

---

## Task 8: End-to-end smoke test with a real short

**Files:** None — verification only.

- [ ] **Step 1: Ensure Supabase env vars are set**

Confirm `VideoEditor/.env` contains:
```
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_SERVICE_KEY=<service_role_key>
ANTHROPIC_API_KEY=<anthropic_key>
```

And that the file was copied to `~/Library/Containers/com.videoeditor.app/Data/Library/Application Support/VideoEditor/.env`.

- [ ] **Step 2: Restart the app**

```bash
osascript -e 'quit app "VideoEditor"' ; sleep 2
open "$(xcodebuild -project /Users/tadies/Projects/video-editor/VideoEditor/VideoEditor.xcodeproj -scheme VideoEditor -destination 'platform=macOS' -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/VideoEditor.app"
sleep 5
```

- [ ] **Step 3: Upload one of the existing shorts**

Pick the first short from `~/Downloads/shorts_episode1/`. Make sure the asset is imported (asset_id from earlier sessions: `2405B11F-EA09-49B7-A263-B4725315CA17`).

```bash
curl -s http://localhost:8420/mcp -X POST -H "Content-Type: application/json" -d '{
  "jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":"upload_short_to_library","arguments":{
    "asset_id":"2405B11F-EA09-49B7-A263-B4725315CA17",
    "source_start":4566.58,"source_end":4604.88,
    "video_path":"/Users/tadies/Downloads/shorts_episode1/short_1_elons_biggest_fan.mp4",
    "label":"ELONS BIGGEST FAN",
    "hook":"I have always been a big Elon Musk fan until I met Explicit, this guy calls him his dad",
    "evergreen_score":8, "trending_score":7,
    "platform_fit":["youtube_shorts","instagram_reels","tiktok","twitter","linkedin"],
    "reasoning":"Funny roast between hosts about Elon fandom",
    "source_asset_name":"2026-03-14 Podcast Session"
  }}
}' --max-time 300 | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('result',{}).get('content',[{}])[0].get('text',''))"
```

Expected output: `Uploaded to library. short_id=<uuid>. video=videos/<uuid>.mp4, thumbnail=thumbnails/<uuid>.png`.

- [ ] **Step 4: Verify in Supabase dashboard**

- Table Editor → `shorts`: one new row with the metadata
- Table Editor → `captions`: 5 new rows, one per platform
- Table Editor → `thumbnail_settings`: one new row with defaults
- Storage → `videos`: one new MP4
- Storage → `thumbnails`: one new PNG
- Storage → `frames/<short_id>/`: 10 JPGs named frame_0.jpg..frame_9.jpg

- [ ] **Step 5: Test rollback — upload with a broken short**

Call `upload_short_to_library` with a `video_path` that doesn't exist:
```bash
curl -s http://localhost:8420/mcp -X POST -H "Content-Type: application/json" -d '{
  "jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":"upload_short_to_library","arguments":{
    "asset_id":"2405B11F-EA09-49B7-A263-B4725315CA17",
    "source_start":4566.58,"source_end":4604.88,
    "video_path":"/nonexistent.mp4",
    "label":"TEST","hook":"Test"
  }}
}' | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('content',[{}])[0].get('text',''))"
```

Expected: `Error: video_path must point to an existing file on disk`. (Early exit, no partial uploads.)

- [ ] **Step 6: Commit a short "verified end-to-end" note (no code)**

```bash
git commit --allow-empty -m "chore(publishing): verified upload_short_to_library end-to-end"
```

---

## Task 9: Batch-upload existing 14 shorts

- [ ] **Step 1: Write a batch script**

Create `/tmp/batch_upload_shorts.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ASSET="2405B11F-EA09-49B7-A263-B4725315CA17"

# Read moments14.json if it still exists, else re-run find_viral_moments first
python3 <<'PY' > /tmp/upload_calls.txt
import json
with open('/tmp/moments14.json') as f: moments = json.load(f)
for i, m in enumerate(moments, 1):
    label = m.get('thumbnail_label','').replace("'", '').replace('"','')
    hook = m.get('hook','').replace("'", '').replace('"','')[:200]
    slug = label.lower().replace(' ','_').replace("'",'').replace('?','')
    import re
    slug = re.sub(r'[^a-z0-9_]', '', slug)[:40]
    s = m['clip_start_time']; e = m['clip_end_time']
    vid = f"/Users/tadies/Downloads/shorts_episode1/short_{i}_{slug}.mp4"
    pf = json.dumps(m.get('platform_fit', []))
    args = json.dumps({
        "asset_id": ASSET if False else "2405B11F-EA09-49B7-A263-B4725315CA17",
        "source_start": s, "source_end": e,
        "video_path": vid,
        "label": label, "hook": hook,
        "evergreen_score": m.get('evergreen_score', 0),
        "trending_score": m.get('trending_score', 0),
        "platform_fit": m.get('platform_fit', []),
        "reasoning": m.get('reasoning', ''),
        "source_asset_name": "2026-03-14 Podcast Session"
    })
    print(args)
PY

while IFS= read -r ARGS; do
    echo "Uploading..."
    curl -s http://localhost:8420/mcp -X POST -H "Content-Type: application/json" -d \
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"upload_short_to_library\",\"arguments\":$ARGS}}" \
      --max-time 600 | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('result',{}).get('content',[{}])[0].get('text','')[:200])"
done < /tmp/upload_calls.txt
```

- [ ] **Step 2: Run it**

```bash
bash /tmp/batch_upload_shorts.sh
```

Expected: 14 successful upload confirmations.

- [ ] **Step 3: Verify in dashboard**

Table Editor → `shorts` should have 14 rows. Storage counts should match.
