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

    init(store: DocumentStore = DocumentStore()) {
        self.store = store
    }

    func prepareExport(for document: ScannedDocument, quality: DocumentExportQuality) async throws -> PreparedDocumentExport {
        _ = await store.ensureSearchablePDFIfNeeded(for: document)
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
        let temporaryURL = temporaryWorkingURL()

        try fileManager.createDirectory(
            at: temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        guard document.write(to: temporaryURL, withOptions: writeOptions(for: quality)) else {
            throw DocumentExportError.exportCreationFailed
        }

        let data = try Data(contentsOf: temporaryURL)
        guard !data.isEmpty else {
            throw DocumentExportError.exportCreationFailed
        }

        return data
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

    private func temporaryWorkingURL() -> URL {
        temporaryExportsDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("pdf")
    }

    private func writeOptions(for quality: DocumentExportQuality) -> [PDFDocumentWriteOption: Any] {
        var options: [PDFDocumentWriteOption: Any] = [:]

        if #available(iOS 16.4, *) {
            switch quality {
            case .veryHigh:
                break
            case .high:
                options[.saveImagesAsJPEGOption] = true
            case .medium:
                options[.optimizeImagesForScreenOption] = true
            case .low:
                options[.saveImagesAsJPEGOption] = true
                options[.optimizeImagesForScreenOption] = true
            }
        }

        return options
    }

    private func fileSizeBytes(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
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
