import Foundation

/// Configures URLCache for video streaming. Invoked once at app launch.
enum VideoCache {
    static func configure() {
        let memoryCapacity = 100 * 1024 * 1024           // 100 MB RAM
        let diskCapacity = 2 * 1024 * 1024 * 1024        // 2 GB disk
        let cache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("VideoCache")
        )
        URLCache.shared = cache
    }

    static func currentDiskUsage() -> Int {
        URLCache.shared.currentDiskUsage
    }

    static func clear() {
        URLCache.shared.removeAllCachedResponses()
    }
}
