//
//  ScanPageContent.swift
//  document-scaner
//
//

import CoreGraphics
import Foundation
import UIKit

struct RecognizedTextSpan: Hashable, Sendable {
    enum Kind: String, Sendable {
        case line
        case word
    }

    let text: String
    let boundingBox: CGRect
    let kind: Kind

    nonisolated var searchableToken: String? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        let token = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return token.count >= 2 ? token : nil
    }
}

struct RecognizedTextLine: Hashable, Sendable {
    let text: String
    let boundingBox: CGRect
    let words: [RecognizedTextSpan]

    nonisolated var lineSpan: RecognizedTextSpan {
        RecognizedTextSpan(text: text, boundingBox: boundingBox, kind: .line)
    }

    nonisolated var preferredSpans: [RecognizedTextSpan] {
        words.isEmpty ? [lineSpan] : words
    }
}

struct ScanPageRaster: @unchecked Sendable {
    let image: UIImage
    let cgImage: CGImage
    let size: CGSize

    nonisolated init(image: UIImage, cgImage: CGImage) {
        self.image = image
        self.cgImage = cgImage
        self.size = CGSize(width: cgImage.width, height: cgImage.height)
    }

    nonisolated var pageRect: CGRect {
        CGRect(origin: .zero, size: size)
    }
}

struct ScanPageContent {
    let raster: ScanPageRaster
    let lines: [RecognizedTextLine]

    nonisolated var pageRect: CGRect {
        raster.pageRect
    }

    nonisolated var preferredSpans: [RecognizedTextSpan] {
        lines.flatMap { $0.preferredSpans }
    }

    nonisolated var searchableTokens: [String] {
        preferredSpans.compactMap { $0.searchableToken }
    }

    nonisolated var containsRecognizedText: Bool {
        !preferredSpans.isEmpty
    }

    nonisolated var imageOnly: ScanPageContent {
        ScanPageContent(raster: raster, lines: [])
    }
}

enum ScanPageRasterizer {
    nonisolated static func makeUprightRaster(from image: UIImage) throws -> ScanPageRaster {
        let normalizedImage = image.normalizedForPDF()

        guard let cgImage = normalizedImage.cgImage else {
            throw DocumentStoreError.pdfCreationFailed
        }

        return ScanPageRaster(image: normalizedImage, cgImage: cgImage)
    }
}

private extension UIImage {
    nonisolated func normalizedForPDF() -> UIImage {
        guard imageOrientation != .up || cgImage == nil else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
