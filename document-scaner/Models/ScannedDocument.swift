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
    let protection: DocumentProtection
    let protectionFormatVersion: Int16

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        pageCount: Int,
        pdfFilename: String,
        previewFilename: String,
        folderID: UUID? = nil,
        protection: DocumentProtection = .standard,
        protectionFormatVersion: Int16 = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.pdfFilename = pdfFilename
        self.previewFilename = previewFilename
        self.folderID = folderID
        self.protection = protection
        self.protectionFormatVersion = protectionFormatVersion
    }

    nonisolated var pdfURL: URL {
        assetDirectory(in: .production).appendingPathComponent(pdfFilename, isDirectory: false)
    }

    nonisolated var previewURL: URL {
        assetDirectory(in: .production).appendingPathComponent(previewFilename, isDirectory: false)
    }

    nonisolated func pdfURL(in paths: StoragePaths) -> URL {
        assetDirectory(in: paths).appendingPathComponent(pdfFilename, isDirectory: false)
    }

    nonisolated func previewURL(in paths: StoragePaths) -> URL {
        assetDirectory(in: paths).appendingPathComponent(previewFilename, isDirectory: false)
    }

    nonisolated var isSecure: Bool { protection != .standard }

    private nonisolated func assetDirectory(in paths: StoragePaths) -> URL {
        isSecure ? paths.vaultDirectory : paths.filesDirectory
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
