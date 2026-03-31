//
//  DocumentStore.swift
//  document-scaner
//
//

import Foundation
import PDFKit
import UIKit

enum DocumentStorage {
    nonisolated static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocumentLibrary", isDirectory: true)
    }

    nonisolated static var filesDirectory: URL {
        rootDirectory.appendingPathComponent("Files", isDirectory: true)
    }

    nonisolated static var metadataURL: URL {
        rootDirectory.appendingPathComponent("library.json", isDirectory: false)
    }
}

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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ocrService: OCRService
    private let searchablePDFRenderer: SearchablePDFRenderer

    init(
        ocrService: OCRService = OCRService(),
        searchablePDFRenderer: SearchablePDFRenderer = SearchablePDFRenderer()
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.ocrService = ocrService
        self.searchablePDFRenderer = searchablePDFRenderer
    }

    func loadDocuments() throws -> [ScannedDocument] {
        try prepareStorage()

        guard fileManager.fileExists(atPath: DocumentStorage.metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: DocumentStorage.metadataURL)
        let documents = try decoder.decode([ScannedDocument].self, from: data)
        return documents.sorted { $0.createdAt > $1.createdAt }
    }

    func saveScan(pages: [UIImage], title: String? = nil) async throws -> [ScannedDocument] {
        guard let firstPage = pages.first else {
            throw DocumentStoreError.emptyScan
        }

        try prepareStorage()

        let timestamp = Date()
        let baseName = UUID().uuidString.lowercased()
        let pdfFilename = "\(baseName).pdf"
        let previewFilename = "\(baseName)-preview.jpg"
        let pdfURL = DocumentStorage.filesDirectory.appendingPathComponent(pdfFilename)
        let previewURL = DocumentStorage.filesDirectory.appendingPathComponent(previewFilename)

        let pageContents = try await makePageContents(from: pages)
        let previewData = try makePreview(from: firstPage)

        _ = try await writeMasterPDF(
            pageContents: pageContents,
            destinationURL: pdfURL,
            replacingExistingFile: false,
            allowImageOnlyFallback: true
        )
        try previewData.write(to: previewURL, options: .atomic)

        var documents = try loadDocuments()
        let document = ScannedDocument(
            title: DocumentTitleFormatter.sanitized(title, fallbackDate: timestamp),
            createdAt: timestamp,
            pageCount: pages.count,
            pdfFilename: pdfFilename,
            previewFilename: previewFilename
        )
        documents.insert(document, at: 0)

        try persist(documents)
        return documents
    }

    func ensureSearchablePDFIfNeeded(for document: ScannedDocument) async -> Bool {
        let sourceURL = document.pdfURL

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

    func rename(_ document: ScannedDocument, title: String) throws -> [ScannedDocument] {
        try prepareStorage()

        var documents = try loadDocuments()

        guard let index = documents.firstIndex(where: { $0.id == document.id }) else {
            return documents
        }

        documents[index].title = DocumentTitleFormatter.sanitized(title, fallbackDate: documents[index].createdAt)
        try persist(documents)
        return documents
    }

    func delete(_ document: ScannedDocument) throws -> [ScannedDocument] {
        try delete([document])
    }

    func delete(_ documents: [ScannedDocument]) throws -> [ScannedDocument] {
        try prepareStorage()

        let identifiers = Set(documents.map(\.id))

        for document in documents {
            let pdfURL = document.pdfURL
            let previewURL = document.previewURL

            if fileManager.fileExists(atPath: pdfURL.path) {
                try fileManager.removeItem(at: pdfURL)
            }

            if fileManager.fileExists(atPath: previewURL.path) {
                try fileManager.removeItem(at: previewURL)
            }
        }

        let updatedDocuments = try loadDocuments().filter { !identifiers.contains($0.id) }
        try persist(updatedDocuments)
        return updatedDocuments
    }

    private func prepareStorage() throws {
        try fileManager.createDirectory(at: DocumentStorage.rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: DocumentStorage.filesDirectory, withIntermediateDirectories: true)
    }

    private func persist(_ documents: [ScannedDocument]) throws {
        let data = try encoder.encode(documents.sorted { $0.createdAt > $1.createdAt })
        try data.write(to: DocumentStorage.metadataURL, options: .atomic)
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
