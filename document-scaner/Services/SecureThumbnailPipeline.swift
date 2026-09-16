import ImageIO
import UIKit

actor SecureThumbnailPipeline {
    static let shared = SecureThumbnailPipeline()

    private let cache = NSCache<NSString, UIImage>()
    private let previews = NSCache<NSString, UIImage>()

    init(costLimit: Int = 32 * 1_024 * 1_024) {
        cache.totalCostLimit = costLimit
        cache.countLimit = 160
        previews.totalCostLimit = min(costLimit, 8 * 1_024 * 1_024)
    }

    func cachedImage(documentID: UUID, sessionID: UUID, pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let image = cache.object(forKey: key(documentID: documentID, sessionID: sessionID, pointSize: pointSize, scale: scale))
        if let image {
            rememberPreview(image, documentID: documentID, sessionID: sessionID)
        }
        return image
    }

    func cachedPreviewImage(documentID: UUID, sessionID: UUID) -> UIImage? {
        previews.object(forKey: previewKey(documentID: documentID, sessionID: sessionID))
    }

    func image(
        from data: Data,
        documentID: UUID,
        sessionID: UUID,
        pointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        let cacheKey = key(documentID: documentID, sessionID: sessionID, pointSize: pointSize, scale: scale)
        if let cached = cache.object(forKey: cacheKey) {
            rememberPreview(cached, documentID: documentID, sessionID: sessionID)
            return cached
        }
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
        rememberPreview(result, documentID: documentID, sessionID: sessionID)
        return result
    }

    func clearAll() {
        cache.removeAllObjects()
        previews.removeAllObjects()
    }

    private func rememberPreview(_ image: UIImage, documentID: UUID, sessionID: UUID) {
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        previews.setObject(image, forKey: previewKey(documentID: documentID, sessionID: sessionID), cost: cost)
    }

    private func previewKey(documentID: UUID, sessionID: UUID) -> NSString {
        "\(sessionID.uuidString)|\(documentID.uuidString)" as NSString
    }

    private func key(documentID: UUID, sessionID: UUID, pointSize: CGSize, scale: CGFloat) -> NSString {
        let width = Int((pointSize.width * scale).rounded())
        let height = Int((pointSize.height * scale).rounded())
        return "\(sessionID.uuidString)|\(documentID.uuidString)|\(width)x\(height)" as NSString
    }
}
