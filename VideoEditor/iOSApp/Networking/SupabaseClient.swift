import Foundation
import Supabase

/// Our domain-specific Supabase client. Uses the anon key only; DB access is
/// constrained by RLS and media reads come from public buckets.
final class SupabaseShortsClient {
    let client: SupabaseClient

    init(url: URL, anonKey: String, schema: String = "shorts_app") {
        self.client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                db: .init(schema: schema)
            )
        )
    }

    // MARK: - Shorts

    func listShorts() async throws -> [Short] {
        let response: [Short] = try await client
            .from("shorts")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
        return response
    }

    // MARK: - Episodes

    /// Assign a short to an episode (pass nil to clear).
    func updateEpisode(shortID: UUID, name: String?, order: Int?) async throws {
        struct Patch: Encodable {
            let episode_name: String?
            let episode_order: Int?
        }
        let patch = Patch(episode_name: name, episode_order: order)
        try await client
            .from("shorts")
            .update(patch)
            .eq("id", value: shortID.uuidString.lowercased())
            .execute()
    }

    // MARK: - Captions

    func listCaptions(forShort shortID: UUID) async throws -> [Caption] {
        try await client
            .from("captions")
            .select()
            .eq("short_id", value: shortID.uuidString.lowercased())
            .execute()
            .value
    }

    func updateCaption(shortID: UUID, platform: Platform, title: String?, body: String, hashtags: [String]) async throws {
        struct Patch: Encodable {
            let title: String?
            let body: String
            let hashtags: [String]
            let last_edited_by: String
        }
        let patch = Patch(title: title, body: body, hashtags: hashtags, last_edited_by: "ios")
        try await client
            .from("captions")
            .update(patch)
            .eq("short_id", value: shortID.uuidString.lowercased())
            .eq("platform", value: platform.rawValue)
            .execute()
    }

    // MARK: - Thumbnail settings

    func getThumbnailSettings(forShort shortID: UUID) async throws -> ThumbnailSettings {
        try await client
            .from("thumbnail_settings")
            .select()
            .eq("short_id", value: shortID.uuidString.lowercased())
            .single()
            .execute()
            .value
    }

    func updateThumbnailSettings(_ settings: ThumbnailSettings) async throws {
        struct Patch: Encodable {
            let label_text: String
            let label_color: String
            let label_position: String
            let frame_index: Int
        }
        let patch = Patch(
            label_text: settings.labelText,
            label_color: settings.labelColor,
            label_position: settings.labelPosition.rawValue,
            frame_index: settings.frameIndex
        )
        try await client
            .from("thumbnail_settings")
            .update(patch)
            .eq("short_id", value: settings.shortID.uuidString.lowercased())
            .execute()
    }

    // MARK: - Share intents

    func recordShare(shortID: UUID, platform: Platform) async throws {
        struct Event: Encodable {
            let short_id: String
            let platform: String
        }
        let event = Event(short_id: shortID.uuidString.lowercased(), platform: platform.rawValue)
        try await client
            .from("share_intents")
            .insert(event)
            .execute()
    }

    // MARK: - Storage URLs

    /// Buckets are public-read in v1; build deterministic public URLs.
    func publicObjectURL(bucket: String, path: String) -> URL {
        Config.supabaseURL
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(bucket)
            .appendingPathComponent(path)
    }
}
