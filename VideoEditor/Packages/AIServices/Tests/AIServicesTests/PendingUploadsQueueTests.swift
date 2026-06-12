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
            reasoning: "r",
            episodeName: "Episode 42",
            episodeOrder: 2
        )
        try queue.append(entry)
        let loaded = try queue.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].shortID == entry.shortID)
        #expect(loaded[0].label == "Label")
        #expect(loaded[0].episodeName == "Episode 42")
        #expect(loaded[0].episodeOrder == 2)
    }

    @Test("append on corrupt file preserves original and writes fresh entry")
    func appendOnCorruptFilePreservesOriginal() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("q_\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: tempFile)
            // Also clean any .corrupt- siblings
            let dir = tempFile.deletingLastPathComponent()
            let prefix = tempFile.lastPathComponent + ".corrupt-"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for name in entries where name.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(name).path)
                }
            }
        }

        try "not json at all".data(using: .utf8)!.write(to: tempFile)

        let queue = PendingUploadsQueue(storagePath: tempFile.path)
        try queue.append(PendingUpload(
            shortID: UUID(), videoLocalPath: "/x", label: "L", hook: "H",
            sourceAssetName: "A", sourceStart: 0, sourceEnd: 1,
            evergreenScore: 0, trendingScore: 0, platformFit: [], reasoning: ""
        ))

        let loaded = try queue.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].label == "L")

        // Original corrupt file was preserved with .corrupt-<ts> suffix
        let dir = tempFile.deletingLastPathComponent()
        let prefix = tempFile.lastPathComponent + ".corrupt-"
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries.contains(where: { $0.hasPrefix(prefix) }))
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
