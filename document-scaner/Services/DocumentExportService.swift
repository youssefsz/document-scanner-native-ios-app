//
//  DocumentExportService.swift
//  document-scaner
//
//

import Foundation
import PDFKit
import UIKit

nonisolated struct PreparedDocumentExport: Sendable {
    let quality: DocumentExportQuality
    let url: URL
    let fileSizeBytes: Int64
    let isPasswordProtected: Bool

    var filename: String {
        url.lastPathComponent
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

enum DocumentExportError: LocalizedError, Equatable {
    case sourceFileMissing
    case sourceDocumentUnreadable
    case pageRenderFailed
    case exportCreationFailed
    case secureSourceRequiresAuthorization
    case invalidPasswordConfiguration
    case encryptedExportVerificationFailed
    case proAccessRequired

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
        case .secureSourceRequiresAuthorization:
            "Unlock the secure folder before exporting this document."
        case .invalidPasswordConfiguration:
            "The generated PDF passwords are invalid."
        case .encryptedExportVerificationFailed:
            "The password-protected PDF failed its security check and was not shared."
        case .proAccessRequired:
            "DocScanner Pro is required to create a password-protected PDF."
        }
    }
}

actor DocumentExportService {
    private let fileManager = FileManager.default
    private let paths: StoragePaths
    private let store: DocumentStore
    private let ocrService: OCRService
    private var cachedExports: [UUID: [DocumentExportQuality: PreparedDocumentExport]] = [:]

    init(
        store: DocumentStore = DocumentStore(),
        paths: StoragePaths = .production,
        ocrService: OCRService = OCRService()
    ) {
        self.store = store
        self.paths = paths
        self.ocrService = ocrService
    }

    func prepareExport(for document: ScannedDocument, quality: DocumentExportQuality) async throws -> PreparedDocumentExport {
        if let cachedExport = cachedExports[document.id]?[quality],
           fileManager.fileExists(atPath: cachedExport.url.path) {
            return cachedExport
        }

        let export = try await prepareRequestedExport(for: document, quality: quality)
        var documentExports = cachedExports[document.id] ?? [:]
        documentExports[quality] = export
        cachedExports[document.id] = documentExports

        return export
    }

    func prepareExport(
        for document: ScannedDocument,
        configuration: PDFExportConfiguration,
        authorizedSourceData: Data? = nil,
        proAccessGranted: Bool
    ) async throws -> PreparedDocumentExport {
        if configuration.requiresPassword, !proAccessGranted {
            throw DocumentExportError.proAccessRequired
        }
        let unprotectedExport: PreparedDocumentExport
        if configuration.sourceProtection == .standard {
            unprotectedExport = try await prepareExport(for: document, quality: configuration.quality)
        } else {
            guard let authorizedSourceData,
                  let sourceDocument = PDFDocument(data: authorizedSourceData),
                  sourceDocument.pageCount > 0 else {
                throw DocumentExportError.secureSourceRequiresAuthorization
            }
            unprotectedExport = try await prepareUncachedSecureSourceExport(
                for: document,
                quality: configuration.quality,
                sourceDocument: sourceDocument
            )
        }

        guard configuration.requiresPassword else { return unprotectedExport }
        return try passwordProtectedExport(
            from: unprotectedExport,
            for: document,
            passwords: configuration.passwords
        )
    }

    func removeTemporaryExports(for document: ScannedDocument) {
        cachedExports.removeValue(forKey: document.id)

        let directoryURL = temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)

        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        try? fileManager.removeItem(at: directoryURL)
    }

    private func prepareRequestedExport(
        for document: ScannedDocument,
        quality: DocumentExportQuality
    ) async throws -> PreparedDocumentExport {
        _ = await store.ensureSearchablePDFIfNeeded(for: document)
        try Task.checkCancellation()
        let sourceURL = document.pdfURL(in: paths)

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DocumentExportError.sourceFileMissing
        }

        guard let pdfDocument = PDFDocument(url: sourceURL), pdfDocument.pageCount > 0 else {
            throw DocumentExportError.sourceDocumentUnreadable
        }

        let exportDirectoryURL = temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)

        try fileManager.createDirectory(
            at: exportDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Task.checkCancellation()

        let exportURL = exportDirectoryURL.appendingPathComponent(
            exportFilename(for: document, quality: quality),
            isDirectory: false
        )

        do {
            try await writeExport(
                quality: quality,
                from: pdfDocument,
                to: exportURL
            )
            try Task.checkCancellation()
            let fileSize = try fileSizeBytes(for: exportURL)
            return PreparedDocumentExport(
                quality: quality,
                url: exportURL,
                fileSizeBytes: fileSize,
                isPasswordProtected: false
            )
        } catch {
            try? fileManager.removeItem(at: exportDirectoryURL)
            throw error
        }
    }

    private func prepareUncachedSecureSourceExport(
        for document: ScannedDocument,
        quality: DocumentExportQuality,
        sourceDocument: PDFDocument
    ) async throws -> PreparedDocumentExport {
        let directory = temporaryExportsDirectory
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = directory.appendingPathComponent(exportFilename(for: document, quality: quality))
        do {
            try await writeExport(quality: quality, from: sourceDocument, to: url)
            try Task.checkCancellation()
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return PreparedDocumentExport(
                quality: quality,
                url: url,
                fileSizeBytes: try fileSizeBytes(for: url),
                isPasswordProtected: false
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func passwordProtectedExport(
        from source: PreparedDocumentExport,
        for document: ScannedDocument,
        passwords: PDFPasswordPair
    ) throws -> PreparedDocumentExport {
        let userPassword = passwords.pdfPassword
        guard !userPassword.isEmpty,
              !passwords.ownerPassword.isEmpty,
              userPassword != passwords.ownerPassword,
              userPassword.utf8.count < 32 else {
            throw DocumentExportError.invalidPasswordConfiguration
        }
        guard let sourceDocument = PDFDocument(url: source.url), sourceDocument.pageCount > 0 else {
            throw DocumentExportError.sourceDocumentUnreadable
        }

        let expectedPageCount = sourceDocument.pageCount
        let expectedText = sourceDocument.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let protectedDirectory = source.url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(
            at: protectedDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let protectedURL = protectedDirectory.appendingPathComponent(
            DocumentTitleFormatter.exportFilename(for: document.title, quality: source.quality)
        )
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: passwords.ownerPassword as NSString,
            .userPasswordOption: userPassword as NSString
        ]
        guard sourceDocument.write(to: protectedURL, withOptions: options) else {
            throw DocumentExportError.exportCreationFailed
        }
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: protectedURL.path)

        do {
            try verifyPasswordProtectedExport(
                at: protectedURL,
                expectedPageCount: expectedPageCount,
                expectedText: expectedText,
                userPassword: userPassword
            )
        } catch {
            try? fileManager.removeItem(at: protectedURL)
            throw error
        }
        return PreparedDocumentExport(
            quality: source.quality,
            url: protectedURL,
            fileSizeBytes: try fileSizeBytes(for: protectedURL),
            isPasswordProtected: true
        )
    }

    private func verifyPasswordProtectedExport(
        at url: URL,
        expectedPageCount: Int,
        expectedText: String?,
        userPassword: String
    ) throws {
        guard let lockedDocument = PDFDocument(url: url),
              lockedDocument.isEncrypted,
              lockedDocument.isLocked else {
            throw DocumentExportError.encryptedExportVerificationFailed
        }
        guard let wrongPasswordDocument = PDFDocument(url: url),
              !wrongPasswordDocument.unlock(withPassword: "WRONG-PASSWORD") else {
            throw DocumentExportError.encryptedExportVerificationFailed
        }
        guard let unlockedDocument = PDFDocument(url: url),
              unlockedDocument.unlock(withPassword: userPassword),
              !unlockedDocument.isLocked,
              unlockedDocument.pageCount == expectedPageCount else {
            throw DocumentExportError.encryptedExportVerificationFailed
        }
        if let expectedText, !expectedText.isEmpty {
            let actualText = unlockedDocument.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard actualText == expectedText else {
                throw DocumentExportError.encryptedExportVerificationFailed
            }
        }
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
            try await writeRenderedExport(
                from: document,
                quality: quality,
                to: exportURL,
                variant: exportVariant(for: quality)
            )
        }
    }

    private func writeRenderedExport(
        from document: PDFDocument,
        quality: DocumentExportQuality,
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

        let renderResult = try await writeRenderedPages(
            from: document,
            quality: quality,
            to: temporaryRenderURL,
            includeOCR: true
        )
        let didVerifySearchablePDF = renderResult.containsEmbeddedText &&
            PDFSearchInspector.verifySearchableText(at: temporaryRenderURL, expectedTokens: renderResult.searchableTokens)

        if !didVerifySearchablePDF && renderResult.containsEmbeddedText {
            if fileManager.fileExists(atPath: temporaryRenderURL.path) {
                try fileManager.removeItem(at: temporaryRenderURL)
            }

            _ = try await writeRenderedPages(
                from: document,
                quality: quality,
                to: temporaryRenderURL,
                includeOCR: false
            )
        }

        guard let renderedDocument = PDFDocument(url: temporaryRenderURL) else {
            throw DocumentExportError.exportCreationFailed
        }

        try writePDF(
            from: renderedDocument,
            variant: variant,
            destinationURL: exportURL
        )
    }

    private func writeRenderedPages(
        from document: PDFDocument,
        quality: DocumentExportQuality,
        to url: URL,
        includeOCR: Bool
    ) async throws -> SearchablePDFRenderResult {
        var writer: SearchablePDFRenderer.Writer?
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
            let pageRect = targetPageRect.isEmpty ? compressedRaster.pageRect : targetPageRect
            let recognizedLines = includeOCR
                ? await recognizeTextSafely(in: compressedRaster, pageRect: pageRect)
                : []
            let content = ScanPageContent(
                raster: compressedRaster,
                lines: recognizedLines,
                pageRect: pageRect
            )
            if writer == nil {
                writer = try SearchablePDFRenderer.Writer(url: url, firstPageRect: pageRect)
            }
            writer?.append(content)
        }
        guard let writer else { throw DocumentExportError.pageRenderFailed }
        return writer.finish()
    }

    private func writePDF(
        from document: PDFDocument,
        variant: ExportVariant,
        destinationURL: URL
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        guard document.write(to: destinationURL, withOptions: variant.writeOptions) else {
            throw DocumentExportError.exportCreationFailed
        }

        guard try fileSizeBytes(for: destinationURL) > 0 else {
            throw DocumentExportError.exportCreationFailed
        }
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
