//
//  DocumentExportService.swift
//  document-scaner
//
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
    private let store: DocumentStore
    private let ocrService: OCRService
    private let searchablePDFRenderer: SearchablePDFRenderer
    private var cachedExports: [UUID: [DocumentExportQuality: PreparedDocumentExport]] = [:]

    init(
        store: DocumentStore = DocumentStore(),
        ocrService: OCRService = OCRService(),
        searchablePDFRenderer: SearchablePDFRenderer = SearchablePDFRenderer()
    ) {
        self.store = store
        self.ocrService = ocrService
        self.searchablePDFRenderer = searchablePDFRenderer
    }

    func prepareExport(for document: ScannedDocument, quality: DocumentExportQuality) async throws -> PreparedDocumentExport {
        if let cachedExport = cachedExports[document.id]?[quality],
           fileManager.fileExists(atPath: cachedExport.url.path) {
            return cachedExport
        }

        let resolvedExports = try await prepareResolvedExports(for: document)
        cachedExports[document.id] = resolvedExports

        guard let export = resolvedExports[quality] else {
            throw DocumentExportError.exportCreationFailed
        }

        return export
    }

    func removeTemporaryExports(for document: ScannedDocument) {
        cachedExports.removeValue(forKey: document.id)

        let directoryURL = temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)

        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        try? fileManager.removeItem(at: directoryURL)
    }

    private func prepareResolvedExports(for document: ScannedDocument) async throws -> [DocumentExportQuality: PreparedDocumentExport] {
        _ = await store.ensureSearchablePDFIfNeeded(for: document)
        let sourceURL = document.pdfURL

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DocumentExportError.sourceFileMissing
        }

        guard let pdfDocument = PDFDocument(url: sourceURL), pdfDocument.pageCount > 0 else {
            throw DocumentExportError.sourceDocumentUnreadable
        }

        let exportDirectoryURL = temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)

        try fileManager.createDirectory(
            at: exportDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var resolved: [DocumentExportQuality: PreparedDocumentExport] = [:]

        for quality in DocumentExportQuality.allCases {
            try Task.checkCancellation()

            let exportURL = exportDirectoryURL.appendingPathComponent(
                exportFilename(for: document, quality: quality),
                isDirectory: false
            )

            try await writeExport(
                quality: quality,
                from: pdfDocument,
                to: exportURL
            )
            let fileSize = try fileSizeBytes(for: exportURL)
            resolved[quality] = PreparedDocumentExport(quality: quality, url: exportURL, fileSizeBytes: fileSize)
        }

        return resolved
    }

    private func writeExport(
        quality: DocumentExportQuality,
        from document: PDFDocument,
        to exportURL: URL
    ) async throws {
        if fileManager.fileExists(atPath: exportURL.path) {
            try fileManager.removeItem(at: exportURL)
        }

        switch quality {
        case .veryHigh:
            guard document.write(to: exportURL) else {
                throw DocumentExportError.exportCreationFailed
            }
        case .high, .medium, .low:
            let pageContents = try await makePageContents(from: document, quality: quality)
            try await writeRenderedExport(
                pageContents: pageContents,
                to: exportURL,
                variant: exportVariant(for: quality)
            )
        }
    }

    private func writeRenderedExport(
        pageContents: [ScanPageContent],
        to exportURL: URL,
        variant: ExportVariant
    ) async throws {
        let temporaryRenderURL = exportURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("pdf")

        defer {
            if fileManager.fileExists(atPath: temporaryRenderURL.path) {
                try? fileManager.removeItem(at: temporaryRenderURL)
            }
        }

        let renderResult = try searchablePDFRenderer.write(pages: pageContents, to: temporaryRenderURL)
        let didVerifySearchablePDF = renderResult.containsEmbeddedText &&
            PDFSearchInspector.verifySearchableText(at: temporaryRenderURL, expectedTokens: renderResult.searchableTokens)

        if !didVerifySearchablePDF {
            if fileManager.fileExists(atPath: temporaryRenderURL.path) {
                try fileManager.removeItem(at: temporaryRenderURL)
            }

            _ = try searchablePDFRenderer.write(
                pages: pageContents.map(\.imageOnly),
                to: temporaryRenderURL
            )
        }

        guard let renderedDocument = PDFDocument(url: temporaryRenderURL) else {
            throw DocumentExportError.exportCreationFailed
        }

        _ = try await makePDFData(
            from: renderedDocument,
            variant: variant,
            destinationURL: exportURL
        )
    }

    private func makePageContents(
        from document: PDFDocument,
        quality: DocumentExportQuality
    ) async throws -> [ScanPageContent] {
        var pageContents: [ScanPageContent] = []
        pageContents.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()

            guard let page = document.page(at: pageIndex) else {
                throw DocumentExportError.pageRenderFailed
            }

            let targetPageRect = page.bounds(for: .mediaBox)
            let renderedRaster = try SearchablePDFRenderer.renderUprightRaster(
                from: page,
                maxDimension: quality.maxPageDimension
            )
            let compressedRaster = try ScanPageRasterizer.recompressedRaster(
                from: renderedRaster,
                compressionQuality: quality.jpegCompressionQuality
            )
            let recognizedLines = await recognizeTextSafely(
                in: compressedRaster,
                pageRect: targetPageRect.isEmpty ? compressedRaster.pageRect : targetPageRect
            )

            pageContents.append(
                ScanPageContent(
                    raster: compressedRaster,
                    lines: recognizedLines,
                    pageRect: targetPageRect.isEmpty ? compressedRaster.pageRect : targetPageRect
                )
            )
        }

        return pageContents
    }

    private func makePDFData(
        from document: PDFDocument,
        variant: ExportVariant,
        destinationURL: URL
    ) async throws -> Data {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        guard document.write(to: destinationURL, withOptions: variant.writeOptions) else {
            throw DocumentExportError.exportCreationFailed
        }

        let data = try Data(contentsOf: destinationURL)
        guard !data.isEmpty else {
            throw DocumentExportError.exportCreationFailed
        }

        return data
    }

    private func recognizeTextSafely(in raster: ScanPageRaster, pageRect: CGRect) async -> [RecognizedTextLine] {
        do {
            return try await ocrService.recognizeText(in: raster, pageRect: pageRect)
        } catch {
            return []
        }
    }

    private var temporaryExportsDirectory: URL {
        fileManager.temporaryDirectory.appendingPathComponent("DocumentExports", isDirectory: true)
    }

    private func exportFilename(for document: ScannedDocument, quality: DocumentExportQuality) -> String {
        DocumentTitleFormatter.exportFilename(for: document.title, quality: quality)
    }

    private func exportVariant(for quality: DocumentExportQuality) -> ExportVariant {
        switch quality {
        case .veryHigh:
            .original
        case .high:
            .saveImagesAsJPEG
        case .medium:
            .optimizeImagesForScreen
        case .low:
            .saveImagesAsJPEGAndOptimize
        }
    }

    private func fileSizeBytes(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

private enum ExportVariant: String, CaseIterable {
    case original
    case optimizeImagesForScreen
    case saveImagesAsJPEG
    case saveImagesAsJPEGAndOptimize

    nonisolated var lossRank: Int {
        switch self {
        case .original:
            0
        case .optimizeImagesForScreen:
            1
        case .saveImagesAsJPEG:
            2
        case .saveImagesAsJPEGAndOptimize:
            3
        }
    }

    nonisolated var writeOptions: [PDFDocumentWriteOption: Any] {
        guard #available(iOS 16.4, *) else { return [:] as [PDFDocumentWriteOption: Any] }

        switch self {
        case .original:
            return [:]
        case .optimizeImagesForScreen:
            return [PDFDocumentWriteOption.optimizeImagesForScreenOption: true]
        case .saveImagesAsJPEG:
            return [PDFDocumentWriteOption.saveImagesAsJPEGOption: true]
        case .saveImagesAsJPEGAndOptimize:
            return [
                PDFDocumentWriteOption.saveImagesAsJPEGOption: true,
                PDFDocumentWriteOption.optimizeImagesForScreenOption: true
            ]
        }
    }
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
