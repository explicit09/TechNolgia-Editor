import Testing
import Foundation
@testable import AIServices

@Suite("Supabase uploader metadata tests")
struct SupabaseUploaderMetadataTests {
    @Test("metadata carries explicit episode grouping fields")
    func metadataCarriesEpisodeFields() {
        let metadata = SupabaseUploader.UploadArtifacts.Metadata(
            sourceAsset: "TechNolgia Episode 42",
            hook: "Hook",
            label: "Short label",
            duration: 42,
            evergreenScore: 8,
            trendingScore: 6,
            platformFit: ["youtube_shorts"],
            sourceStart: 120,
            sourceEnd: 162,
            videoSize: 1_024,
            reasoning: "reason",
            episodeName: "Episode 42",
            episodeOrder: 3
        )

        #expect(metadata.episodeName == "Episode 42")
        #expect(metadata.episodeOrder == 3)
    }
}
