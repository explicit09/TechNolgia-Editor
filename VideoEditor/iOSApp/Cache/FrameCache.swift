import Foundation

/// In-memory cache for candidate frame JPGs. Survives UI churn, evicts on memory pressure.
final class FrameCache {
    static let shared = FrameCache()

    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 50 * 1024 * 1024  // ~50 MB total
        return c
    }()

    func key(shortID: UUID, frameIndex: Int) -> NSString {
        "\(shortID.uuidString.lowercased())_\(frameIndex)" as NSString
    }

    func get(shortID: UUID, frameIndex: Int) -> Data? {
        cache.object(forKey: key(shortID: shortID, frameIndex: frameIndex)) as Data?
    }

    func put(shortID: UUID, frameIndex: Int, data: Data) {
        cache.setObject(data as NSData, forKey: key(shortID: shortID, frameIndex: frameIndex), cost: data.count)
    }
}
