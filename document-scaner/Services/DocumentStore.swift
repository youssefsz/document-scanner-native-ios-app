//
//  DocumentStore.swift
//  document-scaner
//
//

import Foundation
import PDFKit
import UIKit

enum DocumentStoreError: LocalizedError {
    case emptyScan
    case previewCreationFailed
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptyScan:
            "The scan did not contain any pages."
        case .previewCreationFailed:
            "The app could not create a preview image for this scan."
        case .pdfCreationFailed:
            "The app could not create a PDF for this scan."
        }
    }
}

actor DocumentStore {
    private let fileManager = FileManager.default
    private let repository: any LibraryRepository
    private let paths: StoragePaths
    private let ocrService: OCRService
    private let searchablePDFRenderer: SearchablePDFRenderer

    init(
        repository: any LibraryRepository = CoreDataLibraryRepository(),
        paths: StoragePaths = .production,
        ocrService: OCRService = OCRService(),
        searchablePDFRenderer: SearchablePDFRenderer = SearchablePDFRenderer()
    ) {
        self.repository = repository
        self.paths = paths
        self.ocrService = ocrService
        self.searchablePDFRenderer = searchablePDFRenderer
    }

    func loadDocuments() async throws -> [ScannedDocument] {
        try await repository.bootstrap()
        return try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
    }

    func saveScan(
        pages: [UIImage],
        title: String? = nil,
        folderID: UUID? = nil
    ) async throws -> [ScannedDocument] {
        guard let firstPage = pages.first else {
            throw DocumentStoreError.emptyScan
        }

        try prepareStorage()

        let timestamp = Date()
        let baseName = UUID().uuidString.lowercased()
        let pdfFilename = "\(baseName).pdf"
        let previewFilename = "\(baseName)-preview.jpg"
        let pdfURL = paths.filesDirectory.appendingPathComponent(pdfFilename)
        let previewURL = paths.filesDirectory.appendingPathComponent(previewFilename)
        let operationDirectory = paths.stagingDirectory.appendingPathComponent(baseName, isDirectory: true)
        let stagedPDFURL = operationDirectory.appendingPathComponent(pdfFilename)
        let stagedPreviewURL = operationDirectory.appendingPathComponent(previewFilename)

        try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
        defer {
            if fileManager.fileExists(atPath: operationDirectory.path) {
                try? fileManager.removeItem(at: operationDirectory)
            }
        }
        let manifest = ScanOperationManifest(
            documentID: UUID(uuidString: baseName) ?? UUID(),
            pdfFilename: pdfFilename,
            previewFilename: previewFilename
        )
        try JSONEncoder().encode(manifest)
            .write(to: operationDirectory.appendingPathComponent("operation.json"), options: .atomic)

        let pageContents = try await makePageContents(from: pages)
        let previewData = try makePreview(from: firstPage)

        _ = try await writeMasterPDF(
            pageContents: pageContents,
            destinationURL: stagedPDFURL,
            replacingExistingFile: false,
            allowImageOnlyFallback: true
        )
        try previewData.write(to: stagedPreviewURL, options: .atomic)

        guard fileManager.fileExists(atPath: stagedPDFURL.path),
              fileManager.fileExists(atPath: stagedPreviewURL.path),
              PDFDocument(url: stagedPDFURL)?.pageCount == pages.count,
              !previewData.isEmpty else {
            try? fileManager.removeItem(at: operationDirectory)
            throw DocumentStoreError.pdfCreationFailed
        }

        let document = ScannedDocument(
            id: manifest.documentID,
            title: DocumentTitleFormatter.sanitized(title, fallbackDate: timestamp),
            createdAt: timestamp,
            pageCount: pages.count,
            pdfFilename: pdfFilename,
            previewFilename: previewFilename,
            folderID: folderID
        )
        var metadataCommitted = false
        do {
            try fileManager.moveItem(at: stagedPDFURL, to: pdfURL)
            try fileManager.moveItem(at: stagedPreviewURL, to: previewURL)
            do {
                try await repository.createDocument(document)
                metadataCommitted = true
            } catch {
                try? fileManager.removeItem(at: pdfURL)
                try? fileManager.removeItem(at: previewURL)
                throw error
            }
            try? fileManager.removeItem(at: operationDirectory)
            return try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        } catch {
            if !metadataCommitted {
                if fileManager.fileExists(atPath: pdfURL.path) { try? fileManager.removeItem(at: pdfURL) }
                if fileManager.fileExists(atPath: previewURL.path) { try? fileManager.removeItem(at: previewURL) }
            }
            throw error
        }
    }

    func ensureSearchablePDFIfNeeded(for document: ScannedDocument) async -> Bool {
        let sourceURL = document.pdfURL(in: paths)

        do {
            try prepareStorage()
        } catch {
            return false
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return false
        }

        guard !PDFSearchInspector.hasSearchableText(at: sourceURL) else {
            return false
        }

        do {
            let pageContents = try await makePageContents(fromLegacyPDFAt: sourceURL)
            guard pageContents.contains(where: { $0.containsRecognizedText }) else {
                return false
            }

            return try await writeMasterPDF(
                pageContents: pageContents,
                destinationURL: sourceURL,
                replacingExistingFile: true,
                allowImageOnlyFallback: false
            )
        } catch {
            return false
        }
    }

    func rename(_ document: ScannedDocument, title: String) async throws -> [ScannedDocument] {
        try await repository.renameDocument(id: document.id, title: title)
        return try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
    }

    func delete(_ document: ScannedDocument) async throws -> [ScannedDocument] {
        try await delete([document])
    }

    func delete(_ documents: [ScannedDocument]) async throws -> [ScannedDocument] {
        try await repository.deleteDocuments(ids: Set(documents.map(\.id)))
        return try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
    }

    private func prepareStorage() throws {
        try paths.prepare(fileManager: fileManager)
    }

    private func makePreview(from image: UIImage) throws -> Data {
        let maxDimension: CGFloat = 900
        let largestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / largestSide)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let renderedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let data = renderedImage.jpegData(compressionQuality: 0.82) else {
            throw DocumentStoreError.previewCreationFailed
        }

        return data
    }

    private func writeMasterPDF(
        pageContents: [ScanPageContent],
        destinationURL: URL,
        replacingExistingFile: Bool,
        allowImageOnlyFallback: Bool
    ) async throws -> Bool {
        let temporaryURL = temporaryPDFURL()
        let imageOnlyPageContents = pageContents.map { $0.imageOnly }

        try fileManager.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let renderResult = try searchablePDFRenderer.write(pages: pageContents, to: temporaryURL)
        let didVerifySearchablePDF = renderResult.containsEmbeddedText &&
            PDFSearchInspector.verifySearchableText(at: temporaryURL, expectedTokens: renderResult.searchableTokens)

        if didVerifySearchablePDF {
            try movePDF(
                from: temporaryURL,
                to: destinationURL,
                replacingExistingFile: replacingExistingFile
            )
            return true
        }

        guard allowImageOnlyFallback else {
            return false
        }

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        _ = try searchablePDFRenderer.write(pages: imageOnlyPageContents, to: temporaryURL)
        try movePDF(
            from: temporaryURL,
            to: destinationURL,
            replacingExistingFile: replacingExistingFile
        )
        return false
    }

    private func movePDF(from sourceURL: URL, to destinationURL: URL, replacingExistingFile: Bool) throws {
        if replacingExistingFile, fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
            return
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func makePageContents(from pages: [UIImage]) async throws -> [ScanPageContent] {
        var pageContents: [ScanPageContent] = []
        pageContents.reserveCapacity(pages.count)

        for page in pages {
            try Task.checkCancellation()
            let raster = try ScanPageRasterizer.makeUprightRaster(from: page)
            let recognizedLines = await recognizeTextSafely(in: raster)
            pageContents.append(ScanPageContent(raster: raster, lines: recognizedLines))
        }

        return pageContents
    }

    private func makePageContents(fromLegacyPDFAt url: URL) async throws -> [ScanPageContent] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw DocumentStoreError.pdfCreationFailed
        }

        var pageContents: [ScanPageContent] = []
        pageContents.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()

            guard let page = document.page(at: pageIndex) else {
                throw DocumentStoreError.pdfCreationFailed
            }

            let raster = try SearchablePDFRenderer.renderUprightRaster(from: page)
            let recognizedLines = await recognizeTextSafely(in: raster)
            pageContents.append(ScanPageContent(raster: raster, lines: recognizedLines))
        }

        return pageContents
    }

    private func recognizeTextSafely(in raster: ScanPageRaster) async -> [RecognizedTextLine] {
        do {
            return try await ocrService.recognizeText(in: raster)
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private func temporaryPDFURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("DocumentLibrary", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("pdf")
    }
}

nonisolated struct ScanOperationManifest: Codable, Sendable {
    let documentID: UUID
    let pdfFilename: String
    let previewFilename: String
}
