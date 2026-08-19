import CoreData
import CryptoKit
import Foundation
import os

nonisolated struct LegacyJSONLibraryImporter: Sendable {
    static let migrationIdentifier = "legacy-json-v1"

    let paths: StoragePaths
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DocumentScanner", category: "Migration")

    func fallbackDocuments(fileManager: FileManager = .default) -> [ScannedDocument] {
        guard fileManager.fileExists(atPath: paths.legacyMetadataURL.path),
              let data = try? Data(contentsOf: paths.legacyMetadataURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScannedDocument].self, from: data))?
            .sorted { $0.createdAt > $1.createdAt } ?? []
    }

    /// Imports metadata only. PDF and preview URLs are never opened or rewritten here.
    func importIfNeeded(in context: NSManagedObjectContext, fileManager: FileManager = .default) throws {
        if try migrationMarker(in: context) != nil { return }

        let sourceData: Data
        let legacyDocuments: [ScannedDocument]

        if fileManager.fileExists(atPath: paths.legacyMetadataURL.path) {
            sourceData = try Data(contentsOf: paths.legacyMetadataURL)
            try makeBackup(of: sourceData, fileManager: fileManager)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                legacyDocuments = try decoder.decode([ScannedDocument].self, from: sourceData)
            } catch {
                context.rollback()
                throw LibraryRepositoryError.migrationFailed("The legacy catalog is not valid JSON.")
            }
        } else {
            sourceData = Data()
            legacyDocuments = []
        }

        let ids = Set(legacyDocuments.map(\.id))
        guard ids.count == legacyDocuments.count else {
            context.rollback()
            throw LibraryRepositoryError.migrationFailed("The legacy catalog contains duplicate document identifiers.")
        }

        for document in legacyDocuments {
            let request = CDDocument.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", document.id as CVarArg)
            let object = try context.fetch(request).first ?? CDDocument(context: context)
            object.id = document.id
            object.title = document.title
            object.normalizedTitle = LibraryTextNormalizer.normalize(document.title)
            object.createdAt = document.createdAt
            object.pageCount = Int64(document.pageCount)
            object.pdfFilename = document.pdfFilename
            object.previewFilename = document.previewFilename
            object.folder = nil
        }

        let validation = CDDocument.fetchRequest()
        validation.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
        let importedIDs = Set(try context.fetch(validation).map(\.id))
        guard importedIDs == ids else {
            context.rollback()
            throw LibraryRepositoryError.migrationFailed("Not every legacy record could be prepared for import.")
        }

        let marker = CDMigrationState(context: context)
        marker.identifier = Self.migrationIdentifier
        marker.completedAt = .now
        marker.checksum = Self.checksum(sourceData)
        marker.importedCount = Int64(legacyDocuments.count)
        marker.status = "complete"

        // Records and completion marker are committed by one context save.
        try context.save()
        logger.info("Legacy metadata migration completed with \(legacyDocuments.count, privacy: .public) records")
    }

    func migrationMarker(in context: NSManagedObjectContext) throws -> CDMigrationState? {
        let request = CDMigrationState.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "identifier == %@ AND status == %@", Self.migrationIdentifier, "complete")
        return try context.fetch(request).first
    }

    private func makeBackup(of data: Data, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: paths.migrationBackupsDirectory, withIntermediateDirectories: true)
        let checksum = Self.checksum(data)
        let backupURL = paths.migrationBackupsDirectory
            .appendingPathComponent("library-\(checksum).json", isDirectory: false)
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        // `.atomic` and `.withoutOverwriting` cannot be combined: Foundation traps
        // before throwing. The checksum-derived destination plus the existence check
        // makes this idempotent, while `.atomic` prevents a partial backup.
        try data.write(to: backupURL, options: .atomic)
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
