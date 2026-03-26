//
//  ScannedDocument.swift
//  document-scaner
//
//

import Foundation

struct ScannedDocument: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    let pageCount: Int
    let pdfFilename: String
    let previewFilename: String

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        pageCount: Int,
        pdfFilename: String,
        previewFilename: String
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.pdfFilename = pdfFilename
        self.previewFilename = previewFilename
    }

    nonisolated var pdfURL: URL {
        DocumentStorage.filesDirectory.appendingPathComponent(pdfFilename, isDirectory: false)
    }

    nonisolated var previewURL: URL {
        DocumentStorage.filesDirectory.appendingPathComponent(previewFilename, isDirectory: false)
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
