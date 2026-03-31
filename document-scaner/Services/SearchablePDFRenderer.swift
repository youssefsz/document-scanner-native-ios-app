//
//  SearchablePDFRenderer.swift
//  document-scaner
//
//

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import UIKit

struct SearchablePDFRenderResult {
    let containsEmbeddedText: Bool
    let searchableTokens: [String]
}

struct SearchablePDFRenderer {
    nonisolated init() {}

    nonisolated func write(pages: [ScanPageContent], to url: URL) throws -> SearchablePDFRenderResult {
        guard !pages.isEmpty else {
            throw DocumentStoreError.pdfCreationFailed
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        guard let context = makeContext(for: url, pageRect: pages[0].pageRect) else {
            throw DocumentStoreError.pdfCreationFailed
        }

        var searchableTokens: [String] = []

        for page in pages {
            var mediaBox = page.pageRect
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            drawBackground(page.raster, in: page.pageRect, context: context)
            drawInvisibleText(for: page, in: context)
            context.endPDFPage()
            searchableTokens.append(contentsOf: page.searchableTokens)
        }

        context.closePDF()

        return SearchablePDFRenderResult(
            containsEmbeddedText: !searchableTokens.isEmpty,
            searchableTokens: Array(Set(searchableTokens))
        )
    }

    nonisolated static func renderUprightRaster(from page: PDFPage, maxDimension: CGFloat = 2_400) throws -> ScanPageRaster {
        let sourceBounds = page.bounds(for: .mediaBox)
        let fallbackSize = CGSize(width: 1200, height: 1600)
        let pageSize = sourceBounds.isEmpty ? fallbackSize : sourceBounds.size
        let longestSide = max(pageSize.width, pageSize.height, 1)
        let scale = min(1, maxDimension / longestSide)
        let renderSize = CGSize(
            width: max(pageSize.width * scale, 1),
            height: max(pageSize.height * scale, 1)
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: renderSize, format: format).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: renderSize))

            let context = rendererContext.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: renderSize.height)
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }

        return try ScanPageRasterizer.makeUprightRaster(from: image)
    }

    nonisolated private func makeContext(for url: URL, pageRect: CGRect) -> CGContext? {
        var mediaBox = pageRect
        return CGContext(url as CFURL, mediaBox: &mediaBox, nil)
    }

    nonisolated private func drawBackground(_ raster: ScanPageRaster, in pageRect: CGRect, context: CGContext) {
        context.interpolationQuality = .high
        context.draw(raster.cgImage, in: pageRect)
    }

    nonisolated private func drawInvisibleText(for page: ScanPageContent, in context: CGContext) {
        for span in page.preferredSpans {
            drawInvisibleText(span.text, in: span.boundingBox, context: context)
        }
    }

    nonisolated private func drawInvisibleText(_ text: String, in boundingBox: CGRect, context: CGContext) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard boundingBox.width > 1, boundingBox.height > 1 else { return }

        let boxInset = min(1.5, boundingBox.width * 0.04)
        let targetRect = boundingBox.insetBy(dx: boxInset, dy: 0)
        let baseFontSize = max(targetRect.height, 1)
        let fontName = "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, baseFontSize, nil)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.clear.cgColor
        ]

        let baseLine = CTLineCreateWithAttributedString(NSAttributedString(string: trimmedText, attributes: baseAttributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(baseLine, &ascent, &descent, &leading))
        let height = max(ascent + descent, 1)
        let widthScale = width > 0 ? targetRect.width / width : 1
        let heightScale = targetRect.height / height
        let fittedFontSize = max(0.5, baseFontSize * min(widthScale, heightScale))
        let fittedFont = CTFontCreateWithName(fontName as CFString, fittedFontSize, nil)
        let fittedAttributes: [NSAttributedString.Key: Any] = [
            .font: fittedFont,
            .foregroundColor: UIColor.clear.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: trimmedText, attributes: fittedAttributes))

        ascent = 0
        descent = 0
        leading = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let baselineY = targetRect.minY + max((targetRect.height - (ascent + descent)) / 2, 0) + descent

        context.saveGState()
        context.textMatrix = .identity
        context.setTextDrawingMode(.invisible)
        context.textPosition = CGPoint(x: targetRect.minX, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

enum PDFSearchInspector {
    nonisolated static func hasSearchableText(at url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        return hasSearchableText(in: document)
    }

    nonisolated static func hasSearchableText(in document: PDFDocument) -> Bool {
        let documentText = document.selectionForEntireDocument?.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return !(documentText?.isEmpty ?? true)
    }

    nonisolated static func verifySearchableText(at url: URL, expectedTokens: [String]) -> Bool {
        guard let document = PDFDocument(url: url), hasSearchableText(in: document) else {
            return false
        }

        guard let token = expectedTokens.first(where: { $0.count >= 2 }) else {
            return true
        }

        return !document.findString(token, withOptions: .caseInsensitive).isEmpty
    }
}
