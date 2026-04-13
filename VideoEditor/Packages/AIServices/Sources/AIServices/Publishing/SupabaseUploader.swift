import Foundation
import os
import EditorCore

public enum SupabaseUploaderError: Error, CustomStringConvertible {
    case missingCaption(platform: String)

    public var description: String {
        switch self {
        case .missingCaption(let p): return "Missing caption draft for platform: \(p)"
        }
    }
}

public struct UploadResult: Sendable {
    public let shortID: UUID
    public let videoPath: String       // e.g. "shorts-videos/<id>.mp4"
    public let thumbnailPath: String   // e.g. "shorts-thumbnails/<id>.png"
}

/// High-level orchestrator. Uploads one short's artifacts + metadata to Supabase.
/// On failure, rolls back already-uploaded objects and appends to the pending queue.
public actor SupabaseUploader {
    private let client: SupabaseClient
    private let maxRetries: Int

    private static let log = Logger(subsystem: "com.videoeditor.app", category: "SupabaseUploader")

    public init(client: SupabaseClient, maxRetries: Int = 3) {
        self.client = client
        self.maxRetries = maxRetries
    }

    public struct UploadArtifacts: Sendable {
        public let shortID: UUID
        public let videoLocalURL: URL
        public let thumbnailPNGData: Data
        public let candidateFrames: [Data]  // JPG, 10 entries
        public let captions: [String: CaptionDraft]  // keyed by platform
        public let metadata: Metadata

        public struct Metadata: Sendable {
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
        var shortsRowInserted = false

        do {
            // 1. Video
            try await retrying {
                let req = try self.client.buildStorageUploadRequest(
                    bucket: "shorts-videos", objectPath: videoObjectPath, contentType: "video/mp4"
                )
                _ = try await self.client.uploadFile(req, fileURL: artifacts.videoLocalURL)
            }
            uploadedObjects.append(("shorts-videos", videoObjectPath))

            // 2. Thumbnail
            try await retrying {
                let req = try self.client.buildStorageUploadRequest(
                    bucket: "shorts-thumbnails", objectPath: thumbObjectPath, contentType: "image/png"
                )
                _ = try await self.client.uploadData(req, data: artifacts.thumbnailPNGData)
            }
            uploadedObjects.append(("shorts-thumbnails", thumbObjectPath))

            // 3. Candidate frames
            for (i, frameData) in artifacts.candidateFrames.enumerated() {
                let framePath = "\(idStr)/frame_\(i).jpg"
                try await retrying {
                    let req = try self.client.buildStorageUploadRequest(
                        bucket: "shorts-frames", objectPath: framePath, contentType: "image/jpeg"
                    )
                    _ = try await self.client.uploadData(req, data: frameData)
                }
                uploadedObjects.append(("shorts-frames", framePath))
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
                    "video_path": "shorts-videos/\(videoObjectPath)",
                    "thumbnail_path": "shorts-thumbnails/\(thumbObjectPath)",
                    "video_size": artifacts.metadata.videoSize,
                    "reasoning": artifacts.metadata.reasoning,
                ]
                let req = try self.client.buildInsertRequest(table: "shorts", body: body)
                _ = try await self.client.run(req)
            }
            shortsRowInserted = true

            // 5. thumbnail_settings defaults
            try await retrying {
                let body: [String: Any] = [
                    "short_id": idStr,
                    "label_text": artifacts.metadata.label,
                    "label_color": "#C9A028",
                    "label_position": "bottom-center",
                    "frame_index": 0,
                ]
                let req = try self.client.buildInsertRequest(table: "thumbnail_settings", body: body)
                _ = try await self.client.run(req)
            }

            // 6. captions × 5
            for platform in CaptionDrafter.platforms {
                guard let draft = artifacts.captions[platform] else {
                    throw SupabaseUploaderError.missingCaption(platform: platform)
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
                    let req = try self.client.buildInsertRequest(table: "captions", body: body)
                    _ = try await self.client.run(req)
                }
            }

            return UploadResult(
                shortID: artifacts.shortID,
                videoPath: "shorts-videos/\(videoObjectPath)",
                thumbnailPath: "shorts-thumbnails/\(thumbObjectPath)"
            )
        } catch {
            // Rollback: delete every object we uploaded
            for obj in uploadedObjects {
                let req = self.client.buildStorageDeleteRequest(bucket: obj.bucket, objectPath: obj.path)
                do {
                    _ = try await self.client.session.data(for: req)
                } catch {
                    Self.log.error("Rollback delete failed bucket=\(obj.bucket, privacy: .public) path=\(obj.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
            // If the shorts row was inserted before failure, delete it so cascades clean up
            // any partially-inserted thumbnail_settings or captions children.
            if shortsRowInserted {
                await bestEffortDeleteShortRow(idStr: idStr)
            }
            throw error
        }
    }

    /// Best-effort DELETE of the shorts row by id. Used during rollback; `ON DELETE CASCADE`
    /// on `thumbnail_settings.short_id` and `captions.short_id` cleans up any child rows.
    private func bestEffortDeleteShortRow(idStr: String) async {
        guard var components = URLComponents(string: "\(client.baseURL)/rest/v1/shorts") else { return }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(idStr)")]
        guard let url = components.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(client.serviceKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(client.serviceKey)", forHTTPHeaderField: "Authorization")
        if let schema = client.schema {
            req.setValue(schema, forHTTPHeaderField: "Content-Profile")
        } else {
            req.setValue("shorts_app", forHTTPHeaderField: "Content-Profile")
        }
        do {
            _ = try await client.session.data(for: req)
        } catch {
            Self.log.error("Rollback shorts-row delete failed id=\(idStr, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
