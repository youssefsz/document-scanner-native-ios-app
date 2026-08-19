//
//  ScannedDocument.swift
//  document-scaner
//
//

import Foundation

nonisolated struct ScannedDocument: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    let pageCount: Int
    let pdfFilename: String
    let previewFilename: String
    let folderID: UUID?

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        pageCount: Int,
        pdfFilename: String,
        previewFilename: String,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.pdfFilename = pdfFilename
        self.previewFilename = previewFilename
        self.folderID = folderID
    }

    nonisolated var pdfURL: URL {
        StoragePaths.production.filesDirectory.appendingPathComponent(pdfFilename, isDirectory: false)
    }

    nonisolated var previewURL: URL {
        StoragePaths.production.filesDirectory.appendingPathComponent(previewFilename, isDirectory: false)
    }

    nonisolated func pdfURL(in paths: StoragePaths) -> URL {
        paths.filesDirectory.appendingPathComponent(pdfFilename, isDirectory: false)
    }

    nonisolated func previewURL(in paths: StoragePaths) -> URL {
        paths.filesDirectory.appendingPathComponent(previewFilename, isDirectory: false)
    }
}

extension ScannedDocument {
    static let previewDocument = ScannedDocument(
        title: "Meeting Notes",
        createdAt: .now,
        pageCount: 2,
        pdfFilename: "preview.pdf",
        previewFilename: "preview.jpg"
    )
}
