import ImageIO
import UIKit

actor SecureThumbnailPipeline {
    static let shared = SecureThumbnailPipeline()

    private let cache = NSCache<NSString, UIImage>()

    init(costLimit: Int = 32 * 1_024 * 1_024) {
        cache.totalCostLimit = costLimit
        cache.countLimit = 160
    }

    func cachedImage(documentID: UUID, sessionID: UUID, pointSize: CGSize, scale: CGFloat) -> UIImage? {
        cache.object(forKey: key(documentID: documentID, sessionID: sessionID, pointSize: pointSize, scale: scale))
    }

    func image(
        from data: Data,
        documentID: UUID,
        sessionID: UUID,
        pointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        let cacheKey = key(documentID: documentID, sessionID: sessionID, pointSize: pointSize, scale: scale)
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let maximumPixels = max(pointSize.width, pointSize.height) * max(scale, 1)
        guard maximumPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(ceil(maximumPixels)),
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ) else { return nil }
        let result = UIImage(cgImage: image, scale: scale, orientation: .up)
        cache.setObject(result, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return result
    }

    func clearAll() {
        cache.removeAllObjects()
    }

    private func key(documentID: UUID, sessionID: UUID, pointSize: CGSize, scale: CGFloat) -> NSString {
        let width = Int((pointSize.width * scale).rounded())
        let height = Int((pointSize.height * scale).rounded())
        return "\(sessionID.uuidString)|\(documentID.uuidString)|\(width)x\(height)" as NSString
    }
}
