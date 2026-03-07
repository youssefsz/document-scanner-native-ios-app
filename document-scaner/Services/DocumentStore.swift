//
//  DocumentStore.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import Foundation
import UIKit

enum DocumentStorage {
    nonisolated static let rootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DocumentLibrary", isDirectory: true)
    nonisolated static let filesDirectory = rootDirectory.appendingPathComponent("Files", isDirectory: true)
    nonisolated static let metadataURL = rootDirectory.appendingPathComponent("library.json", isDirectory: false)
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

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
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

    func saveScan(pages: [UIImage]) throws -> [ScannedDocument] {
        guard let firstPage = pages.first else {
            throw DocumentStoreError.emptyScan
        }

        try prepareStorage()

        let timestamp = Date()
        let baseName = UUID().uuidString.lowercased()
        let pdfFilename = "\(baseName).pdf"
        let previewFilename = "\(baseName)-preview.jpg"

        let pdfData = try makePDF(from: pages)
        let previewData = try makePreview(from: firstPage)

        try pdfData.write(to: DocumentStorage.filesDirectory.appendingPathComponent(pdfFilename), options: .atomic)
        try previewData.write(to: DocumentStorage.filesDirectory.appendingPathComponent(previewFilename), options: .atomic)

        var documents = try loadDocuments()
        let document = ScannedDocument(
            title: defaultTitle(for: timestamp),
            createdAt: timestamp,
            pageCount: pages.count,
            pdfFilename: pdfFilename,
            previewFilename: previewFilename
        )
        documents.insert(document, at: 0)

        try persist(documents)
        return documents
    }

    func delete(_ document: ScannedDocument) throws -> [ScannedDocument] {
        try prepareStorage()

        let pdfURL = document.pdfURL
        let previewURL = document.previewURL

        if fileManager.fileExists(atPath: pdfURL.path) {
            try fileManager.removeItem(at: pdfURL)
        }

        if fileManager.fileExists(atPath: previewURL.path) {
            try fileManager.removeItem(at: previewURL)
        }

        let updatedDocuments = try loadDocuments().filter { $0.id != document.id }
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

    private func defaultTitle(for date: Date) -> String {
        "Scan \(date.formatted(date: .abbreviated, time: .shortened))"
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

    private func makePDF(from pages: [UIImage]) throws -> Data {
        let fallbackBounds = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
        let renderer = UIGraphicsPDFRenderer(bounds: fallbackBounds)

        let data = renderer.pdfData { context in
            for image in pages {
                let pageRect = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: pageRect, pageInfo: [:])
                image.draw(in: pageRect)
            }
        }

        guard !data.isEmpty else {
            throw DocumentStoreError.pdfCreationFailed
        }

        return data
    }
}
