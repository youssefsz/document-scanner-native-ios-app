import ImageIO
import UIKit

actor ThumbnailPipeline {
    nonisolated static let shared = ThumbnailPipeline()

    private nonisolated let cache: ThumbnailMemoryCache
    private var requests: [String: Task<UIImage?, Never>] = [:]
    private var decodeCount = 0

    init(costLimit: Int = 64 * 1_024 * 1_024) {
        cache = ThumbnailMemoryCache(costLimit: costLimit)
    }

    func image(for url: URL, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        let request = Self.cacheRequest(for: url, pointSize: pointSize, scale: scale)

        if let cached = cache.image(forKey: request.key) { return cached }

        let task: Task<UIImage?, Never>
        if let existing = requests[request.key] {
            task = existing
        } else {
            decodeCount += 1
            task = Task.detached(priority: .utility) {
                Self.downsample(url: url, maximumPixelSize: request.maximumPixelSize)
            }
            requests[request.key] = task
        }

        let image = await task.value
        requests[request.key] = nil
        guard !Task.isCancelled, let image else { return nil }

        let pixelsWide = image.cgImage?.width ?? request.maximumPixelSize
        let pixelsHigh = image.cgImage?.height ?? request.maximumPixelSize
        cache.insert(image, forKey: request.key, cost: pixelsWide * pixelsHigh * 4)
        return image
    }

    nonisolated func cachedImage(for url: URL, pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let request = Self.cacheRequest(for: url, pointSize: pointSize, scale: scale)
        return cache.image(forKey: request.key)
    }

    func clearCache() {
        cache.removeAll()
    }

    func diagnosticsDecodeCount() -> Int {
        decodeCount
    }

    nonisolated private static func cacheRequest(
        for url: URL,
        pointSize: CGSize,
        scale: CGFloat
    ) -> ThumbnailCacheRequest {
        let maximumPixelSize = max(1, Int(ceil(max(pointSize.width, pointSize.height) * scale)))
        return ThumbnailCacheRequest(
            key: "\(url.standardizedFileURL.path)|\(maximumPixelSize)",
            maximumPixelSize: maximumPixelSize
        )
    }

    nonisolated private static func downsample(url: URL, maximumPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

nonisolated private struct ThumbnailCacheRequest: Sendable {
    let key: String
    let maximumPixelSize: Int
}

/// NSCache is thread-safe, so cached thumbnails can be read synchronously while
/// the actor continues to own request coalescing and image decoding.
nonisolated private final class ThumbnailMemoryCache: @unchecked Sendable {
    private let storage = NSCache<NSString, UIImage>()

    init(costLimit: Int) {
        storage.totalCostLimit = costLimit
    }

    func image(forKey key: String) -> UIImage? {
        storage.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String, cost: Int) {
        storage.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        storage.removeAllObjects()
    }
}
