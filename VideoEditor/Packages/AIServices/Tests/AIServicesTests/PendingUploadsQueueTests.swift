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
