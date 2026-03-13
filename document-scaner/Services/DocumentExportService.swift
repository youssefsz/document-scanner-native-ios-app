//
//  DocumentExportService.swift
//  document-scaner
//
//  Created by Codex on 13/3/2026.
//

import Foundation
import PDFKit
import UIKit

struct PreparedDocumentExport: Sendable {
    let quality: DocumentExportQuality
    let url: URL
    let fileSizeBytes: Int64

    var filename: String {
        url.lastPathComponent
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

enum DocumentExportError: LocalizedError {
    case sourceFileMissing
    case sourceDocumentUnreadable
    case pageRenderFailed
    case exportCreationFailed

    var errorDescription: String? {
        switch self {
        case .sourceFileMissing:
            "The saved PDF file could not be found."
        case .sourceDocumentUnreadable:
            "The saved PDF could not be opened for export."
        case .pageRenderFailed:
            "The app could not prepare one or more pages for export."
        case .exportCreationFailed:
            "The app could not create the exported PDF."
        }
    }
}

actor DocumentExportService {
    private let fileManager = FileManager.default

    func prepareExport(for document: ScannedDocument, quality: DocumentExportQuality) async throws -> PreparedDocumentExport {
        let sourceURL = document.pdfURL

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DocumentExportError.sourceFileMissing
        }

        guard let pdfDocument = PDFDocument(url: sourceURL), pdfDocument.pageCount > 0 else {
            throw DocumentExportError.sourceDocumentUnreadable
        }

        let exportURL = temporaryExportURL(for: document, quality: quality)
        let pdfData = try await makePDFData(from: pdfDocument, quality: quality)

        try fileManager.createDirectory(
            at: exportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if fileManager.fileExists(atPath: exportURL.path) {
            try fileManager.removeItem(at: exportURL)
        }

        try pdfData.write(to: exportURL, options: .atomic)
        let fileSize = try fileSizeBytes(for: exportURL)
        return PreparedDocumentExport(quality: quality, url: exportURL, fileSizeBytes: fileSize)
    }

    func removeTemporaryExports(for document: ScannedDocument) {
        let directoryURL = temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)

        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        try? fileManager.removeItem(at: directoryURL)
    }

    private func makePDFData(from document: PDFDocument, quality: DocumentExportQuality) async throws -> Data {
        let pages = try await makeExportPages(from: document, quality: quality)
        let fallbackBounds = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
        let renderer = UIGraphicsPDFRenderer(bounds: fallbackBounds)

        let data = renderer.pdfData { context in
            for page in pages {
                context.beginPage(withBounds: page.bounds, pageInfo: [:])
                page.image.draw(in: page.bounds)
            }
        }

        guard !data.isEmpty else {
            throw DocumentExportError.exportCreationFailed
        }

        return data
    }

    private func makeExportPages(from document: PDFDocument, quality: DocumentExportQuality) async throws -> [ExportPage] {
        var pages: [ExportPage] = []
        pages.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()

            guard let page = document.page(at: pageIndex) else {
                throw DocumentExportError.pageRenderFailed
            }

            let renderedImage = render(page: page, quality: quality)
            let compressedImage = try compress(renderedImage, quality: quality)
            let pageBounds = normalizedPageBounds(for: page, fallback: compressedImage.size)
            pages.append(ExportPage(bounds: pageBounds, image: compressedImage))
        }

        guard !pages.isEmpty else {
            throw DocumentExportError.exportCreationFailed
        }

        return pages
    }

    private func render(page: PDFPage, quality: DocumentExportQuality) -> UIImage {
        let sourceBounds = page.bounds(for: .mediaBox)
        let fallbackSize = CGSize(width: 1200, height: 1600)
        let pageSize = sourceBounds.isEmpty ? fallbackSize : sourceBounds.size
        let longestSide = max(pageSize.width, pageSize.height)
        let scale = min(1, quality.maxPageDimension / max(longestSide, 1))
        let renderSize = CGSize(
            width: max(pageSize.width * scale, 1),
            height: max(pageSize.height * scale, 1)
        )
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

    private func compress(_ image: UIImage, quality: DocumentExportQuality) throws -> UIImage {
        guard let data = image.jpegData(compressionQuality: quality.jpegCompressionQuality),
              let compressedImage = UIImage(data: data) else {
            throw DocumentExportError.pageRenderFailed
        }

        return compressedImage
    }

    private func normalizedPageBounds(for page: PDFPage, fallback imageSize: CGSize) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        guard !pageBounds.isEmpty else {
            return CGRect(origin: .zero, size: imageSize)
        }

        return CGRect(origin: .zero, size: pageBounds.size)
    }

    private func temporaryExportURL(for document: ScannedDocument, quality: DocumentExportQuality) -> URL {
        temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(exportFilename(for: document, quality: quality), isDirectory: false)
    }

    private var temporaryExportsDirectory: URL {
        fileManager.temporaryDirectory.appendingPathComponent("DocumentExports", isDirectory: true)
    }

    private func exportFilename(for document: ScannedDocument, quality: DocumentExportQuality) -> String {
        DocumentTitleFormatter.exportFilename(for: document.title, quality: quality)
    }

    private func fileSizeBytes(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

private struct ExportPage {
    let bounds: CGRect
    let image: UIImage
}

enum DocumentFileSizeFormatter {
    static func string(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return nil
        }

        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}
