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

nonisolated struct PreparedSecureScan: Sendable {
    let document: ScannedDocument
    let sourcePDFURL: URL
    let sourcePreviewURL: URL
    let operationDirectory: URL
}

actor DocumentStore {
    private let fileManager = FileManager.default
    private let repository: any LibraryRepository
    private let paths: StoragePaths
    private let ocrService: OCRService

    init(
        repository: any LibraryRepository = CoreDataLibraryRepository(),
        paths: StoragePaths = .production,
        ocrService: OCRService = OCRService()
    ) {
        self.repository = repository
        self.paths = paths
        self.ocrService = ocrService
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

        let previewData = try makePreview(from: firstPage)

        _ = try await writeMasterPDF(
            pageCount: pages.count,
            loadPage: { index, includeOCR in
                let raster = try ScanPageRasterizer.makeUprightRaster(from: pages[index])
                let lines = includeOCR ? await self.recognizeTextSafely(in: raster) : []
                return ScanPageContent(raster: raster, lines: lines)
            },
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

    func prepareSecureScan(
        pages: [UIImage],
        title: String,
        folderID: UUID
    ) async throws -> PreparedSecureScan {
        guard let firstPage = pages.first else { throw DocumentStoreError.emptyScan }
        try prepareStorage()
        let timestamp = Date()
        let id = UUID()
        let operationDirectory = paths.sensitiveTemporaryDirectory
            .appendingPathComponent("SecureScan-\(id.uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(
            at: operationDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let pdfURL = operationDirectory.appendingPathComponent("source.pdf")
        let previewURL = operationDirectory.appendingPathComponent("source-preview.jpg")

        do {
            let previewData = try makePreview(from: firstPage)
            _ = try await writeMasterPDF(
                pageCount: pages.count,
                loadPage: { index, includeOCR in
                    let raster = try ScanPageRasterizer.makeUprightRaster(from: pages[index])
                    let lines = includeOCR ? await self.recognizeTextSafely(in: raster) : []
                    return ScanPageContent(raster: raster, lines: lines)
                },
                destinationURL: pdfURL,
                replacingExistingFile: false,
                allowImageOnlyFallback: true,
                sensitiveTemporaryDirectory: operationDirectory
            )
            try previewData.write(to: previewURL, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: pdfURL.path)
            guard PDFDocument(url: pdfURL)?.pageCount == pages.count,
                  UIImage(contentsOfFile: previewURL.path) != nil else {
                throw DocumentStoreError.pdfCreationFailed
            }
            let document = ScannedDocument(
                id: id,
                title: DocumentTitleFormatter.sanitized(title, fallbackDate: timestamp),
                createdAt: timestamp,
                pageCount: pages.count,
                pdfFilename: "source.pdf",
                previewFilename: "source-preview.jpg",
                folderID: folderID
            )
            return PreparedSecureScan(
                document: document,
                sourcePDFURL: pdfURL,
                sourcePreviewURL: previewURL,
                operationDirectory: operationDirectory
            )
        } catch {
            try? fileManager.removeItem(at: operationDirectory)
            throw error
        }
    }

    func discardPreparedSecureScan(_ scan: PreparedSecureScan) {
        try? fileManager.removeItem(at: scan.operationDirectory)
    }

    func ensureSearchablePDFIfNeeded(for document: ScannedDocument) async -> Bool {
        guard !document.isSecure else {
            return false
        }

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
            guard let legacyDocument = PDFDocument(url: sourceURL), legacyDocument.pageCount > 0 else {
                return false
            }
            return try await writeMasterPDF(
                pageCount: legacyDocument.pageCount,
                loadPage: { index, includeOCR in
                    guard let page = legacyDocument.page(at: index) else {
                        throw DocumentStoreError.pdfCreationFailed
                    }
                    let raster = try SearchablePDFRenderer.renderUprightRaster(from: page)
                    let lines = includeOCR ? await self.recognizeTextSafely(in: raster) : []
                    return ScanPageContent(raster: raster, lines: lines)
                },
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
        pageCount: Int,
        loadPage: (Int, Bool) async throws -> ScanPageContent,
        destinationURL: URL,
        replacingExistingFile: Bool,
        allowImageOnlyFallback: Bool,
        sensitiveTemporaryDirectory: URL? = nil
    ) async throws -> Bool {
        guard pageCount > 0 else { throw DocumentStoreError.emptyScan }
        let temporaryURL = temporaryPDFURL(in: sensitiveTemporaryDirectory)

        try fileManager.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let renderResult = try await writePages(
            count: pageCount,
            to: temporaryURL,
            includeOCR: true,
            loadPage: loadPage
        )
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

        if !renderResult.containsEmbeddedText {
            try movePDF(
                from: temporaryURL,
                to: destinationURL,
                replacingExistingFile: replacingExistingFile
            )
            return false
        }

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        _ = try await writePages(
            count: pageCount,
            to: temporaryURL,
            includeOCR: false,
            loadPage: loadPage
        )
        try movePDF(
            from: temporaryURL,
            to: destinationURL,
            replacingExistingFile: replacingExistingFile
        )
        return false
    }

    private func writePages(
        count: Int,
        to url: URL,
        includeOCR: Bool,
        loadPage: (Int, Bool) async throws -> ScanPageContent
    ) async throws -> SearchablePDFRenderResult {
        try Task.checkCancellation()
        let firstPage = try await loadPage(0, includeOCR)
        let writer = try SearchablePDFRenderer.Writer(url: url, firstPageRect: firstPage.pageRect)
        writer.append(firstPage)
        for index in 1..<count {
            try Task.checkCancellation()
            let page = try await loadPage(index, includeOCR)
            writer.append(page)
        }
        return writer.finish()
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

    private func recognizeTextSafely(in raster: ScanPageRaster) async -> [RecognizedTextLine] {
        do {
            return try await ocrService.recognizeText(in: raster)
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private func temporaryPDFURL(in sensitiveDirectory: URL? = nil) -> URL {
        (sensitiveDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("DocumentLibrary", isDirectory: true))
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("pdf")
    }
}

nonisolated struct ScanOperationManifest: Codable, Sendable {
    let documentID: UUID
    let pdfFilename: String
    let previewFilename: String
}
