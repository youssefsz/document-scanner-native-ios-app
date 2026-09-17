import AVFoundation
import PDFKit
import UIKit

nonisolated enum DocumentPageSource: Sendable {
    case url(URL)
    case data(Data)
}

nonisolated enum DocumentPageLoadError: LocalizedError {
    case unreadable
    case pageUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable: "The PDF file exists, but the app could not read it."
        case .pageUnavailable: "This PDF page could not be displayed."
        }
    }
}

nonisolated struct DocumentPageSessionDiagnostics: Sendable {
    let renderCount: Int
    let cachedPageCount: Int
    let cachedBytes: Int
}

/// Owns a PDFDocument on one actor and renders only requested pages.
actor DocumentPageSession {
    nonisolated let pageCount: Int
    private let document: PDFDocument
    private var cachedPages: [Int: DocumentPageSnapshot] = [:]
    private var recentPages: [Int] = []
    private var cachedBytes = 0
    private var renderCount = 0
    private let cacheLimitBytes = 48 * 1024 * 1024

    private init(document: PDFDocument) {
        self.document = document
        self.pageCount = document.pageCount
    }

    nonisolated static func open(from source: DocumentPageSource) async throws -> DocumentPageSession {
        let openingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let document: PDFDocument?
            switch source {
            case .url(let url): document = PDFDocument(url: url)
            case .data(let data): document = PDFDocument(data: data)
            }
            guard let document, document.pageCount > 0 else {
                throw DocumentPageLoadError.unreadable
            }
            return DocumentPageSession(document: document)
        }
        return try await withTaskCancellationHandler {
            try await openingTask.value
        } onCancel: {
            openingTask.cancel()
        }
    }

    func page(at index: Int) throws -> DocumentPageSnapshot {
        try Task.checkCancellation()
        guard (0..<pageCount).contains(index), let pdfPage = document.page(at: index) else {
            throw DocumentPageLoadError.pageUnavailable
        }
        if let cached = cachedPages[index] {
            markRecentlyUsed(index)
            return cached
        }
        let snapshot = DocumentPageSnapshot(id: index, image: DocumentPageRenderer.render(page: pdfPage))
        try Task.checkCancellation()
        renderCount += 1
        cachedPages[index] = snapshot
        cachedBytes += Self.cost(of: snapshot.image)
        markRecentlyUsed(index)
        trimCache(protecting: index)
        return snapshot
    }

    func removeCachedPages(except retainedIndices: Set<Int>) {
        for index in Array(cachedPages.keys) where !retainedIndices.contains(index) {
            remove(index)
        }
    }

    func diagnostics() -> DocumentPageSessionDiagnostics {
        DocumentPageSessionDiagnostics(
            renderCount: renderCount,
            cachedPageCount: cachedPages.count,
            cachedBytes: cachedBytes
        )
    }

    private func markRecentlyUsed(_ index: Int) {
        recentPages.removeAll { $0 == index }
        recentPages.append(index)
    }

    private func trimCache(protecting index: Int) {
        while cachedBytes > cacheLimitBytes,
              let oldest = recentPages.first(where: { $0 != index }) {
            remove(oldest)
        }
    }

    private func remove(_ index: Int) {
        if let old = cachedPages.removeValue(forKey: index) {
            cachedBytes -= Self.cost(of: old.image)
        }
        recentPages.removeAll { $0 == index }
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

nonisolated enum DocumentPageRenderer {
    static func render(page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let fallbackSize = CGSize(width: 1200, height: 1600)
        let pageSize = bounds.isEmpty ? fallbackSize : bounds.size
        let maxDimension: CGFloat = 2200
        let scale = maxDimension / max(pageSize.width, pageSize.height)
        let renderSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1

        return UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))
            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: renderSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }
    }
}
