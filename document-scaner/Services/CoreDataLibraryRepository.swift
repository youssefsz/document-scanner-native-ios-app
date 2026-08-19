import CoreData
import Foundation
import os

@objc(CDDocument)
nonisolated final class CDDocument: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var normalizedTitle: String
    @NSManaged var createdAt: Date
    @NSManaged var pageCount: Int64
    @NSManaged var pdfFilename: String
    @NSManaged var previewFilename: String
    @NSManaged var protectionKind: Int16
    @NSManaged var protectionFormatVersion: Int16
    @NSManaged var secureTitleBlob: Data?
    @NSManaged var folder: CDFolder?

    @nonobjc class func fetchRequest() -> NSFetchRequest<CDDocument> {
        NSFetchRequest(entityName: "Document")
    }
}

@objc(CDFolder)
nonisolated final class CDFolder: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var normalizedName: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var isSecure: Bool
    @NSManaged var documents: Set<CDDocument>

    @nonobjc class func fetchRequest() -> NSFetchRequest<CDFolder> {
        NSFetchRequest(entityName: "Folder")
    }
}

@objc(CDMigrationState)
nonisolated final class CDMigrationState: NSManagedObject {
    @NSManaged var identifier: String
    @NSManaged var completedAt: Date
    @NSManaged var checksum: String
    @NSManaged var importedCount: Int64
    @NSManaged var status: String

    @nonobjc class func fetchRequest() -> NSFetchRequest<CDMigrationState> {
        NSFetchRequest(entityName: "MigrationState")
    }
}

nonisolated private struct RecoveryManifest: Codable, Sendable {
    nonisolated struct FileMove: Codable, Sendable {
        let original: URL
        let recovery: URL
    }

    let documentIDs: [UUID]
    let moves: [FileMove]
}

nonisolated private final class PersistentStoreLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(
        error: Error?,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

actor CoreDataLibraryRepository: DocumentSecurityRepository {
    private let paths: StoragePaths
    private let fileManager: FileManager
    private let container: NSPersistentContainer
    private let importer: LegacyJSONLibraryImporter
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DocumentScanner", category: "Database")
    private var storeLoaded = false

    init(paths: StoragePaths = .production, inMemory: Bool = false, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.importer = LegacyJSONLibraryImporter(paths: paths)

        let model = LibraryManagedObjectModel.makeFinalV2()
        model.versionIdentifiers = ["LibraryModelFinalV2"]
        let container = NSPersistentContainer(name: "LibraryModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
            description.url = URL(fileURLWithPath: "/dev/null")
        } else {
            description.type = NSSQLiteStoreType
            description.url = paths.sqliteURL
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        self.container = container
    }

    func needsLegacyMigration() async throws -> Bool {
        try await ensureStoreLoaded()
        return try await perform { context in
            try self.importer.migrationMarker(in: context) == nil
        }
    }

    func bootstrap() async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            try self.importer.importIfNeeded(in: context, fileManager: self.fileManager)
        }
        try await recoverInterruptedScanOperations()
        try await recoverInterruptedDeletions()
    }

    func loadLegacyFallback() async -> [ScannedDocument] {
        importer.fallbackDocuments(fileManager: fileManager)
    }

    func fetchDocuments(scope: DocumentScope, query: String, sort: LibrarySortOrder) async throws -> [ScannedDocument] {
        try await ensureStoreLoaded()
        return try await perform { context in
            let request = CDDocument.fetchRequest()
            request.fetchBatchSize = 50

            var predicates: [NSPredicate] = []
            switch scope {
            case .all:
                predicates.append(NSPredicate(format: "protectionKind == %d", DocumentProtection.standard.rawValue))
            case .unfiled:
                predicates.append(NSPredicate(format: "folder == nil"))
                predicates.append(NSPredicate(format: "protectionKind == %d", DocumentProtection.standard.rawValue))
            case .folder(let id):
                predicates.append(NSPredicate(format: "folder.id == %@", id as CVarArg))
            }

            let normalizedQuery = LibraryTextNormalizer.normalize(query)
            if !normalizedQuery.isEmpty {
                predicates.append(NSPredicate(format: "normalizedTitle CONTAINS %@", normalizedQuery))
            }
            if !predicates.isEmpty { request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }

            let ascending = sort == .oldestFirst
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: ascending),
                NSSortDescriptor(key: "id", ascending: ascending)
            ]
            return try context.fetch(request).map(Self.document(from:))
        }
    }

    func fetchFolders(query: String) async throws -> [FolderSummary] {
        try await ensureStoreLoaded()
        return try await perform { context in
            let request = CDFolder.fetchRequest()
            let normalizedQuery = LibraryTextNormalizer.normalize(query)
            if !normalizedQuery.isEmpty {
                request.predicate = NSPredicate(format: "normalizedName CONTAINS %@", normalizedQuery)
            }

            let folders = try context.fetch(request)
            return folders.map { folder in
                let newest = (folder.isSecure ? [] : folder.documents)
                    .sorted {
                        if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                        return $0.createdAt > $1.createdAt
                    }
                    .prefix(4)
                    .map(Self.document(from:))
                return FolderSummary(
                    folder: Self.folder(from: folder),
                    documentCount: folder.documents.count,
                    newestDocuments: Array(newest)
                )
            }
            .sorted { $0.folder.name.localizedStandardCompare($1.folder.name) == .orderedAscending }
        }
    }

    func createDocument(_ document: ScannedDocument) async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            guard document.protection == .standard else {
                throw LibraryRepositoryError.secureAccessRequired
            }
            let request = CDDocument.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", document.id as CVarArg)
            let object = try context.fetch(request).first ?? CDDocument(context: context)
            Self.apply(document, to: object)
            if let folderID = document.folderID {
                guard let folder = try Self.fetchFolder(id: folderID, context: context) else {
                    throw LibraryRepositoryError.missingFolder
                }
                guard !folder.isSecure else {
                    throw LibraryRepositoryError.secureAccessRequired
                }
                object.folder = folder
            } else {
                object.folder = nil
            }
            try context.save()
        }
    }

    func renameDocument(id: UUID, title: String) async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            guard let object = try Self.fetchDocument(id: id, context: context) else {
                throw LibraryRepositoryError.missingDocument
            }
            guard object.protectionKind == DocumentProtection.standard.rawValue else {
                throw LibraryRepositoryError.secureAccessRequired
            }
            let sanitized = DocumentTitleFormatter.sanitized(title, fallbackDate: object.createdAt)
            object.title = sanitized
            object.normalizedTitle = LibraryTextNormalizer.normalize(sanitized)
            try context.save()
        }
    }

    func deleteDocuments(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        try await ensureStoreLoaded()
        let documents = try await fetchDocuments(ids: ids)
        guard documents.allSatisfy({ !$0.isSecure }) else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        let recovery = try stageFilesForRecovery(documents: documents)

        do {
            try await perform { context in
                let request = CDDocument.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
                try context.fetch(request).forEach(context.delete)
                try context.save()
            }
            try? fileManager.removeItem(at: recovery)
        } catch {
            try? restoreRecoveryDirectory(recovery)
            throw error
        }
    }

    func createFolder(name: String, security: FolderSecurity) async throws -> DocumentFolder {
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        let value = try LibraryTextNormalizer.validatedFolderName(submittedName)
        try await ensureStoreLoaded()
        do {
            return try await perform { context in
                try Self.ensureFolderNameAvailable(value.normalized, excluding: nil, context: context)
                let object = CDFolder(context: context)
                object.id = UUID()
                object.name = value.display
                object.normalizedName = value.normalized
                object.createdAt = .now
                object.updatedAt = .now
                object.isSecure = security == .secure
                try context.save()
                return Self.folder(from: object)
            }
        } catch {
            throw Self.mapConstraintError(error)
        }
    }

    func renameFolder(id: UUID, name: String) async throws {
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        let value = try LibraryTextNormalizer.validatedFolderName(submittedName)
        try await ensureStoreLoaded()
        do {
            try await perform { context in
                guard let folder = try Self.fetchFolder(id: id, context: context) else {
                    throw LibraryRepositoryError.missingFolder
                }
                try Self.ensureFolderNameAvailable(value.normalized, excluding: id, context: context)
                folder.name = value.display
                folder.normalizedName = value.normalized
                folder.updatedAt = .now
                try context.save()
            }
        } catch {
            throw Self.mapConstraintError(error)
        }
    }

    func deleteFolder(id: UUID, mode: FolderDeletionMode) async throws {
        try await ensureStoreLoaded()
        let securitySnapshot = try await securitySnapshot(folderID: id)
        guard !securitySnapshot.folder.isSecure else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        switch mode {
        case .keepDocuments:
            try await perform { context in
                guard let folder = try Self.fetchFolder(id: id, context: context) else {
                    throw LibraryRepositoryError.missingFolder
                }
                folder.documents.forEach { $0.folder = nil }
                context.delete(folder)
                try context.save()
            }
        case .deleteDocuments:
            let documents = try await fetchDocuments(scope: .folder(id), query: "", sort: .newestFirst)
            let recovery = try stageFilesForRecovery(documents: documents)
            do {
                try await perform { context in
                    guard let folder = try Self.fetchFolder(id: id, context: context) else {
                        throw LibraryRepositoryError.missingFolder
                    }
                    folder.documents.forEach(context.delete)
                    context.delete(folder)
                    try context.save()
                }
                try? fileManager.removeItem(at: recovery)
            } catch {
                try? restoreRecoveryDirectory(recovery)
                throw error
            }
        }
    }

    func moveDocuments(ids: Set<UUID>, to folderID: UUID?) async throws {
        guard !ids.isEmpty else { return }
        try await ensureStoreLoaded()
        try await perform { context in
            let destination: CDFolder?
            if let folderID {
                guard let folder = try Self.fetchFolder(id: folderID, context: context) else {
                    throw LibraryRepositoryError.missingFolder
                }
                destination = folder
            } else {
                destination = nil
            }

            let request = CDDocument.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
            let documents = try context.fetch(request)
            guard documents.count == ids.count else { throw LibraryRepositoryError.missingDocument }
            guard !documents.contains(where: { $0.protectionKind != DocumentProtection.standard.rawValue }),
                  destination?.isSecure != true else {
                throw LibraryRepositoryError.secureAccessRequired
            }
            documents.forEach { $0.folder = destination }
            try context.save()
        }
    }

    func securitySnapshot(folderID: UUID) async throws -> FolderSecuritySnapshot {
        try await ensureStoreLoaded()
        return try await perform { context in
            guard let folder = try Self.fetchFolder(id: folderID, context: context) else {
                throw LibraryRepositoryError.missingFolder
            }
            let records = folder.documents
                .sorted {
                    if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                    return $0.createdAt < $1.createdAt
                }
                .map { SecurityDocumentRecord(document: Self.document(from: $0), secureTitleBlob: $0.secureTitleBlob) }
            return FolderSecuritySnapshot(folder: Self.folder(from: folder), documents: records)
        }
    }

    func commitSecurityChanges(
        folderID: UUID,
        targetSecurity: FolderSecurity,
        changes: [SecurityMetadataChange]
    ) async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            guard let folder = try Self.fetchFolder(id: folderID, context: context) else {
                throw LibraryRepositoryError.missingFolder
            }
            let expectedIDs = Set(folder.documents.map(\.id))
            guard expectedIDs == Set(changes.map(\.documentID)) else {
                throw LibraryRepositoryError.invalidSecurityState
            }

            for change in changes {
                guard let document = try Self.fetchDocument(id: change.documentID, context: context) else {
                    throw LibraryRepositoryError.missingDocument
                }
                document.title = change.title
                document.normalizedTitle = LibraryTextNormalizer.normalize(change.title)
                document.pdfFilename = change.pdfFilename
                document.previewFilename = change.previewFilename
                document.protectionKind = change.protection.rawValue
                document.protectionFormatVersion = change.protectionFormatVersion
                document.secureTitleBlob = change.secureTitleBlob
                document.folder = folder
            }
            folder.isSecure = targetSecurity == .secure
            folder.updatedAt = .now
            try context.save()
        }
    }

    func securityCommitMatches(
        folderID: UUID,
        targetSecurity: FolderSecurity,
        changes: [SecurityMetadataChange]
    ) async throws -> Bool {
        let snapshot = try await securitySnapshot(folderID: folderID)
        guard snapshot.folder.security == targetSecurity,
              snapshot.documents.count == changes.count else { return false }
        let records = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.document.id, $0) })
        return changes.allSatisfy { change in
            guard let record = records[change.documentID] else { return false }
            return record.document.title == change.title &&
                record.document.pdfFilename == change.pdfFilename &&
                record.document.previewFilename == change.previewFilename &&
                record.document.protection == change.protection &&
                record.document.protectionFormatVersion == change.protectionFormatVersion &&
                record.secureTitleBlob == change.secureTitleBlob &&
                record.document.folderID == change.folderID
        }
    }

    func renameSecureDocument(id: UUID, folderID: UUID, secureTitleBlob: Data) async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            guard let document = try Self.fetchDocument(id: id, context: context) else {
                throw LibraryRepositoryError.missingDocument
            }
            guard document.folder?.id == folderID,
                  document.folder?.isSecure == true,
                  document.protectionKind == DocumentProtection.vaultV1.rawValue else {
                throw LibraryRepositoryError.invalidSecurityState
            }
            document.title = ""
            document.normalizedTitle = ""
            document.secureTitleBlob = secureTitleBlob
            try context.save()
        }
    }

    func deleteSecureDocumentMetadata(ids: Set<UUID>, folderID: UUID) async throws {
        guard !ids.isEmpty else { return }
        try await ensureStoreLoaded()
        try await perform { context in
            let request = CDDocument.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
            let documents = try context.fetch(request)
            guard documents.count == ids.count,
                  documents.allSatisfy({
                      $0.folder?.id == folderID &&
                      $0.folder?.isSecure == true &&
                      $0.protectionKind == DocumentProtection.vaultV1.rawValue
                  }) else {
                throw LibraryRepositoryError.invalidSecurityState
            }
            documents.forEach(context.delete)
            try context.save()
        }
    }

    func secureDocumentMetadataExists(ids: Set<UUID>) async throws -> Bool {
        guard !ids.isEmpty else { return false }
        try await ensureStoreLoaded()
        return try await perform { context in
            let request = CDDocument.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
            return try context.fetch(request).first != nil
        }
    }

    func deleteAuthenticatedSecureFolder(id: UUID) async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            guard let folder = try Self.fetchFolder(id: id, context: context), folder.isSecure else {
                throw LibraryRepositoryError.missingFolder
            }
            guard folder.documents.isEmpty else { throw LibraryRepositoryError.invalidSecurityState }
            context.delete(folder)
            try context.save()
        }
    }

    func commitMovedSecurityChanges(_ changes: [SecurityMetadataChange], to folderID: UUID?) async throws {
        try await ensureStoreLoaded()
        try await perform { context in
            let destination: CDFolder?
            if let folderID {
                guard let folder = try Self.fetchFolder(id: folderID, context: context) else {
                    throw LibraryRepositoryError.missingFolder
                }
                destination = folder
            } else {
                destination = nil
            }
            for change in changes {
                guard let document = try Self.fetchDocument(id: change.documentID, context: context) else {
                    throw LibraryRepositoryError.missingDocument
                }
                document.title = change.title
                document.normalizedTitle = LibraryTextNormalizer.normalize(change.title)
                document.pdfFilename = change.pdfFilename
                document.previewFilename = change.previewFilename
                document.protectionKind = change.protection.rawValue
                document.protectionFormatVersion = change.protectionFormatVersion
                document.secureTitleBlob = change.secureTitleBlob
                document.folder = destination
            }
            try context.save()
        }
    }

    func documentSecurityChangesMatch(_ changes: [SecurityMetadataChange]) async throws -> Bool {
        try await ensureStoreLoaded()
        return try await perform { context in
            try changes.allSatisfy { change in
                guard let document = try Self.fetchDocument(id: change.documentID, context: context) else { return false }
                return document.title == change.title &&
                    document.pdfFilename == change.pdfFilename &&
                    document.previewFilename == change.previewFilename &&
                    document.protectionKind == change.protection.rawValue &&
                    document.protectionFormatVersion == change.protectionFormatVersion &&
                    document.secureTitleBlob == change.secureTitleBlob &&
                    document.folder?.id == change.folderID
            }
        }
    }

    func createSecureDocumentMetadata(
        _ change: SecurityMetadataChange,
        createdAt: Date,
        pageCount: Int
    ) async throws {
        guard change.protection == .vaultV1,
              change.title.isEmpty,
              change.secureTitleBlob != nil,
              let folderID = change.folderID else {
            throw LibraryRepositoryError.invalidSecurityState
        }
        try await ensureStoreLoaded()
        try await perform { context in
            guard let folder = try Self.fetchFolder(id: folderID, context: context), folder.isSecure else {
                throw LibraryRepositoryError.missingFolder
            }
            guard try Self.fetchDocument(id: change.documentID, context: context) == nil else {
                throw LibraryRepositoryError.invalidSecurityState
            }
            let document = CDDocument(context: context)
            document.id = change.documentID
            document.title = ""
            document.normalizedTitle = ""
            document.createdAt = createdAt
            document.pageCount = Int64(pageCount)
            document.pdfFilename = change.pdfFilename
            document.previewFilename = change.previewFilename
            document.protectionKind = change.protection.rawValue
            document.protectionFormatVersion = change.protectionFormatVersion
            document.secureTitleBlob = change.secureTitleBlob
            document.folder = folder
            try context.save()
        }
    }

    private func ensureStoreLoaded() async throws {
        guard !storeLoaded else { return }
        if !container.persistentStoreCoordinator.persistentStores.isEmpty {
            storeLoaded = true
            return
        }
        try paths.prepare(fileManager: fileManager)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = PersistentStoreLoadGate()
            container.loadPersistentStores { _, error in
                if let error {
                    gate.finish(
                        error: LibraryRepositoryError.storageFailed(error.localizedDescription),
                        continuation: continuation
                    )
                } else {
                    gate.finish(error: nil, continuation: continuation)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                gate.finish(
                    error: LibraryRepositoryError.storageFailed("Opening the library database timed out. Please retry."),
                    continuation: continuation
                )
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        storeLoaded = true
        logger.info("SQLite library store opened")
    }

    private func perform<T>(_ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            container.performBackgroundTask { context in
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                context.undoManager = nil
                do {
                    continuation.resume(returning: try work(context))
                } catch {
                    context.rollback()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchDocuments(ids: Set<UUID>) async throws -> [ScannedDocument] {
        try await perform { context in
            let request = CDDocument.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids.map { $0 as NSUUID })
            return try context.fetch(request).map(Self.document(from:))
        }
    }

    private func stageFilesForRecovery(documents: [ScannedDocument]) throws -> URL {
        let operationDirectory = paths.recoveryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
        var moves: [RecoveryManifest.FileMove] = []
        var seenPaths: Set<String> = []

        do {
            for document in documents {
                for original in [document.pdfURL(in: paths), document.previewURL(in: paths)] where fileManager.fileExists(atPath: original.path) {
                    guard seenPaths.insert(original.standardizedFileURL.path).inserted else { continue }
                    let recovery = operationDirectory.appendingPathComponent("\(moves.count)-\(original.lastPathComponent)")
                    moves.append(.init(original: original, recovery: recovery))
                }
            }
            let manifest = RecoveryManifest(documentIDs: documents.map(\.id), moves: moves)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: operationDirectory.appendingPathComponent("operation.json"), options: .atomic)
            for move in moves {
                try fileManager.moveItem(at: move.original, to: move.recovery)
            }
            return operationDirectory
        } catch {
            moves.reversed().forEach { try? fileManager.moveItem(at: $0.recovery, to: $0.original) }
            try? fileManager.removeItem(at: operationDirectory)
            throw error
        }
    }

    private func restoreRecoveryDirectory(_ directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("operation.json"))
        let manifest = try JSONDecoder().decode(RecoveryManifest.self, from: data)
        for move in manifest.moves where fileManager.fileExists(atPath: move.recovery.path) {
            try fileManager.moveItem(at: move.recovery, to: move.original)
        }
        try? fileManager.removeItem(at: directory)
    }

    private func recoverInterruptedDeletions() async throws {
        let directories = (try? fileManager.contentsOfDirectory(
            at: paths.recoveryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for directory in directories {
            let manifestURL = directory.appendingPathComponent("operation.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(RecoveryManifest.self, from: data) else {
                continue
            }
            let existing = try await fetchDocuments(ids: Set(manifest.documentIDs))
            if existing.isEmpty {
                try? fileManager.removeItem(at: directory)
            } else {
                try? restoreRecoveryDirectory(directory)
            }
        }
    }

    private func recoverInterruptedScanOperations() async throws {
        let directories = (try? fileManager.contentsOfDirectory(
            at: paths.stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for directory in directories {
            let manifestURL = directory.appendingPathComponent("operation.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ScanOperationManifest.self, from: data) else {
                continue
            }

            let existing = try await fetchDocuments(ids: [manifest.documentID])
            if existing.isEmpty {
                let pdfURL = paths.filesDirectory.appendingPathComponent(manifest.pdfFilename)
                let previewURL = paths.filesDirectory.appendingPathComponent(manifest.previewFilename)
                if fileManager.fileExists(atPath: pdfURL.path) { try? fileManager.removeItem(at: pdfURL) }
                if fileManager.fileExists(atPath: previewURL.path) { try? fileManager.removeItem(at: previewURL) }
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func apply(_ document: ScannedDocument, to object: CDDocument) {
        object.id = document.id
        object.title = document.title
        object.normalizedTitle = LibraryTextNormalizer.normalize(document.title)
        object.createdAt = document.createdAt
        object.pageCount = Int64(document.pageCount)
        object.pdfFilename = document.pdfFilename
        object.previewFilename = document.previewFilename
        object.protectionKind = document.protection.rawValue
        object.protectionFormatVersion = document.protectionFormatVersion
    }

    private static func document(from object: CDDocument) -> ScannedDocument {
        ScannedDocument(
            id: object.id,
            title: object.title,
            createdAt: object.createdAt,
            pageCount: Int(object.pageCount),
            pdfFilename: object.pdfFilename,
            previewFilename: object.previewFilename,
            folderID: object.folder?.id,
            protection: DocumentProtection(rawValue: object.protectionKind) ?? .standard,
            protectionFormatVersion: object.protectionFormatVersion
        )
    }

    private static func folder(from object: CDFolder) -> DocumentFolder {
        DocumentFolder(
            id: object.id,
            name: object.name,
            normalizedName: object.normalizedName,
            createdAt: object.createdAt,
            updatedAt: object.updatedAt,
            security: object.isSecure ? .secure : .standard
        )
    }

    private static func fetchDocument(id: UUID, context: NSManagedObjectContext) throws -> CDDocument? {
        let request = CDDocument.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    private static func fetchFolder(id: UUID, context: NSManagedObjectContext) throws -> CDFolder? {
        let request = CDFolder.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    private static func ensureFolderNameAvailable(_ normalizedName: String, excluding id: UUID?, context: NSManagedObjectContext) throws {
        let request = CDFolder.fetchRequest()
        request.fetchLimit = 1
        var predicates = [NSPredicate(format: "normalizedName == %@", normalizedName)]
        if let id { predicates.append(NSPredicate(format: "id != %@", id as CVarArg)) }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        if try context.fetch(request).first != nil { throw LibraryRepositoryError.duplicateFolderName }
    }

    private static func mapConstraintError(_ error: Error) -> Error {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == NSManagedObjectConstraintMergeError || cocoa.code == NSValidationMultipleErrorsError {
            return LibraryRepositoryError.duplicateFolderName
        }
        return error
    }
}

nonisolated private enum LibraryManagedObjectModel {
    static func makeFinalV2() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let document = NSEntityDescription()
        document.name = "Document"
        document.managedObjectClassName = NSStringFromClass(CDDocument.self)
        let documentID = attribute("id", .UUIDAttributeType, optional: false)
        let title = attribute("title", .stringAttributeType, optional: false, defaultValue: "")
        let normalizedTitle = attribute("normalizedTitle", .stringAttributeType, optional: false, defaultValue: "")
        let createdAt = attribute("createdAt", .dateAttributeType, optional: false)
        let pageCount = attribute("pageCount", .integer64AttributeType, optional: false, defaultValue: 0)
        let pdfFilename = attribute("pdfFilename", .stringAttributeType, optional: false, defaultValue: "")
        let previewFilename = attribute("previewFilename", .stringAttributeType, optional: false, defaultValue: "")
        let protectionKind = attribute("protectionKind", .integer16AttributeType, optional: false, defaultValue: DocumentProtection.standard.rawValue)
        let protectionFormatVersion = attribute("protectionFormatVersion", .integer16AttributeType, optional: false, defaultValue: 0)
        let secureTitleBlob = attribute("secureTitleBlob", .binaryDataAttributeType, optional: true)
        document.properties = [documentID, title, normalizedTitle, createdAt, pageCount, pdfFilename, previewFilename, protectionKind, protectionFormatVersion, secureTitleBlob]
        document.uniquenessConstraints = [["id"]]
        document.indexes = [
            index(name: "DocumentByNormalizedTitle", property: normalizedTitle),
            index(name: "DocumentByCreatedAt", property: createdAt)
        ]

        let folder = NSEntityDescription()
        folder.name = "Folder"
        folder.managedObjectClassName = NSStringFromClass(CDFolder.self)
        let folderID = attribute("id", .UUIDAttributeType, optional: false)
        let name = attribute("name", .stringAttributeType, optional: false, defaultValue: "")
        let normalizedName = attribute("normalizedName", .stringAttributeType, optional: false, defaultValue: "")
        let folderCreatedAt = attribute("createdAt", .dateAttributeType, optional: false)
        let updatedAt = attribute("updatedAt", .dateAttributeType, optional: false)
        let isSecure = attribute("isSecure", .booleanAttributeType, optional: false, defaultValue: false)
        folder.properties = [folderID, name, normalizedName, folderCreatedAt, updatedAt, isSecure]
        folder.uniquenessConstraints = [["id"], ["normalizedName"]]
        folder.indexes = [index(name: "FolderByNormalizedName", property: normalizedName)]

        let documentFolder = NSRelationshipDescription()
        documentFolder.name = "folder"
        documentFolder.destinationEntity = folder
        documentFolder.minCount = 0
        documentFolder.maxCount = 1
        documentFolder.deleteRule = .nullifyDeleteRule

        let folderDocuments = NSRelationshipDescription()
        folderDocuments.name = "documents"
        folderDocuments.destinationEntity = document
        folderDocuments.minCount = 0
        folderDocuments.maxCount = 0
        folderDocuments.isOrdered = false
        folderDocuments.deleteRule = .nullifyDeleteRule
        documentFolder.inverseRelationship = folderDocuments
        folderDocuments.inverseRelationship = documentFolder
        document.properties.append(documentFolder)
        folder.properties.append(folderDocuments)

        let migration = NSEntityDescription()
        migration.name = "MigrationState"
        migration.managedObjectClassName = NSStringFromClass(CDMigrationState.self)
        let identifier = attribute("identifier", .stringAttributeType, optional: false, defaultValue: "")
        let completedAt = attribute("completedAt", .dateAttributeType, optional: false)
        let checksum = attribute("checksum", .stringAttributeType, optional: false, defaultValue: "")
        let importedCount = attribute("importedCount", .integer64AttributeType, optional: false, defaultValue: 0)
        let status = attribute("status", .stringAttributeType, optional: false, defaultValue: "")
        migration.properties = [identifier, completedAt, checksum, importedCount, status]
        migration.uniquenessConstraints = [["identifier"]]

        model.entities = [document, folder, migration]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        return attribute
    }

    private static func index(name: String, property: NSPropertyDescription) -> NSFetchIndexDescription {
        NSFetchIndexDescription(
            name: name,
            elements: [NSFetchIndexElementDescription(property: property, collationType: .binary)]
        )
    }
}
