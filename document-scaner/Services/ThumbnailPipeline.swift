import ImageIO
import UIKit

actor ThumbnailPipeline {
    nonisolated static let shared = ThumbnailPipeline()

    private let cache = NSCache<NSString, UIImage>()
    private var requests: [String: Task<UIImage?, Never>] = [:]
    private var decodeCount = 0

    init(costLimit: Int = 64 * 1_024 * 1_024) {
        cache.totalCostLimit = costLimit
    }

    func image(for url: URL, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        let maximumPixelSize = max(1, Int(ceil(max(pointSize.width, pointSize.height) * scale)))
        let key = "\(url.standardizedFileURL.path)|\(maximumPixelSize)"
        let cacheKey = key as NSString

        if let cached = cache.object(forKey: cacheKey) { return cached }

        let task: Task<UIImage?, Never>
        if let existing = requests[key] {
            task = existing
        } else {
            decodeCount += 1
            task = Task.detached(priority: .utility) {
                Self.downsample(url: url, maximumPixelSize: maximumPixelSize)
            }
            requests[key] = task
        }

        let image = await task.value
        requests[key] = nil
        guard !Task.isCancelled, let image else { return nil }

        let pixelsWide = image.cgImage?.width ?? maximumPixelSize
        let pixelsHigh = image.cgImage?.height ?? maximumPixelSize
        cache.setObject(image, forKey: cacheKey, cost: pixelsWide * pixelsHigh * 4)
        return image
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func diagnosticsDecodeCount() -> Int {
        decodeCount
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
