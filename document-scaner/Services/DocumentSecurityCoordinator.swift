import CryptoKit
import Foundation
import PDFKit
import UIKit

nonisolated enum SecurityConversionPhase: String, Codable, Sendable {
    case staging
    case verifying
    case preservingOriginals
    case installing
    case committingMetadata
    case cleaningUp
}

nonisolated struct SecurityConversionProgress: Equatable, Sendable {
    let phase: SecurityConversionPhase
    let completedDocuments: Int
    let totalDocuments: Int
}

nonisolated private enum SecurityManifestPhase: String, Codable, Sendable {
    case staging
    case staged
    case recoveryMoved
    case finalInstalled
    case metadataCommitted
}

nonisolated private struct SecurityOperationManifest: Codable, Sendable {
    struct Asset: Codable, Sendable {
        let documentID: UUID
        let kind: VaultAssetKind
        let originalURL: URL
        let stagedURL: URL
        let recoveryURL: URL
        let finalURL: URL
        let expectedPlaintextChecksum: String
    }

    let operationID: UUID
    let folderID: UUID
    let sourceSecurity: FolderSecurity
    let targetSecurity: FolderSecurity
    let documentIDs: [UUID]
    var assets: [Asset]
    var changes: [SecurityMetadataChange]
    var phase: SecurityManifestPhase
}

nonisolated private struct SecureDeletionManifest: Codable, Sendable {
    struct FileMove: Codable, Sendable {
        let originalURL: URL
        let recoveryURL: URL
        let encryptedChecksum: String
    }

    let operationID: UUID
    let folderID: UUID
    let documentIDs: [UUID]
    let moves: [FileMove]
}

nonisolated private struct SecureMoveManifest: Codable, Sendable {
    let operationID: UUID
    let destinationFolderID: UUID?
    let documentIDs: [UUID]
    var assets: [SecurityOperationManifest.Asset]
    var changes: [SecurityMetadataChange]
}

actor DocumentSecurityCoordinator {
    typealias ProgressHandler = @Sendable (SecurityConversionProgress) -> Void

    private let repository: any DocumentSecurityRepository
    private let paths: StoragePaths
    private let fileManager: FileManager
    private let crypto: VaultCryptoService

    init(
        repository: any DocumentSecurityRepository,
        paths: StoragePaths = .production,
        fileManager: FileManager = .default,
        crypto: VaultCryptoService = VaultCryptoService()
    ) {
        self.repository = repository
        self.paths = paths
        self.fileManager = fileManager
        self.crypto = crypto
    }

    func convertFolder(
        id folderID: UUID,
        to targetSecurity: FolderSecurity,
        access: VaultAccess,
        progress: ProgressHandler? = nil
    ) async throws {
        guard access.folderID == folderID, access.isValid else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        try paths.prepare(fileManager: fileManager)
        let snapshot = try await repository.securitySnapshot(folderID: folderID)
        guard snapshot.folder.security != targetSecurity else { return }

        let operationID = UUID()
        let operationDirectory = paths.securityOperationsDirectory
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let stagingDirectory = operationDirectory.appendingPathComponent("Staging", isDirectory: true)
        let recoveryDirectory = operationDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let verificationDirectory = operationDirectory.appendingPathComponent("Verification", isDirectory: true)
        for directory in [operationDirectory, stagingDirectory, recoveryDirectory, verificationDirectory] {
            try createProtectedDirectory(directory)
        }

        var manifest = SecurityOperationManifest(
            operationID: operationID,
            folderID: folderID,
            sourceSecurity: snapshot.folder.security,
            targetSecurity: targetSecurity,
            documentIDs: snapshot.documents.map(\.document.id),
            assets: [],
            changes: [],
            phase: .staging
        )
        try writeManifest(manifest, in: operationDirectory)

        var metadataCommitted = false
        do {
            for (index, record) in snapshot.documents.enumerated() {
                try Task.checkCancellation()
                let prepared = try prepareDocument(
                    record,
                    targetSecurity: targetSecurity,
                    access: access,
                    stagingDirectory: stagingDirectory,
                    recoveryDirectory: recoveryDirectory,
                    verificationDirectory: verificationDirectory
                )
                manifest.assets.append(contentsOf: prepared.assets)
                manifest.changes.append(prepared.change)
                try writeManifest(manifest, in: operationDirectory)
                progress?(.init(phase: .staging, completedDocuments: index + 1, totalDocuments: snapshot.documents.count))
            }

            manifest.phase = .staged
            try writeManifest(manifest, in: operationDirectory)
            progress?(.init(phase: .verifying, completedDocuments: snapshot.documents.count, totalDocuments: snapshot.documents.count))

            for asset in manifest.assets {
                try Task.checkCancellation()
                guard try checksum(of: plaintextURL(for: asset, targetSecurity: targetSecurity, verificationDirectory: verificationDirectory)) == asset.expectedPlaintextChecksum else {
                    throw LibraryRepositoryError.storageFailed("A staged secure file failed checksum verification.")
                }
            }

            progress?(.init(phase: .preservingOriginals, completedDocuments: 0, totalDocuments: snapshot.documents.count))
            for asset in manifest.assets {
                try Task.checkCancellation()
                guard fileManager.fileExists(atPath: asset.originalURL.path) else {
                    throw LibraryRepositoryError.missingFile(asset.originalURL.lastPathComponent)
                }
                try fileManager.moveItem(at: asset.originalURL, to: asset.recoveryURL)
                try protectFile(at: asset.recoveryURL)
            }
            manifest.phase = .recoveryMoved
            try writeManifest(manifest, in: operationDirectory)

            progress?(.init(phase: .installing, completedDocuments: 0, totalDocuments: snapshot.documents.count))
            for asset in manifest.assets {
                try Task.checkCancellation()
                try fileManager.moveItem(at: asset.stagedURL, to: asset.finalURL)
                try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: asset.finalURL.path)
            }
            manifest.phase = .finalInstalled
            try writeManifest(manifest, in: operationDirectory)

            progress?(.init(phase: .committingMetadata, completedDocuments: snapshot.documents.count, totalDocuments: snapshot.documents.count))
            try await repository.commitSecurityChanges(
                folderID: folderID,
                targetSecurity: targetSecurity,
                changes: manifest.changes
            )
            metadataCommitted = true
            manifest.phase = .metadataCommitted
            try writeManifest(manifest, in: operationDirectory)

            progress?(.init(phase: .cleaningUp, completedDocuments: snapshot.documents.count, totalDocuments: snapshot.documents.count))
            try? fileManager.removeItem(at: operationDirectory)
        } catch {
            if !metadataCommitted {
                rollbackFiles(in: manifest)
                try? fileManager.removeItem(at: operationDirectory)
            }
            throw error
        }
    }

    func recoverInterruptedOperations() async throws {
        try paths.prepare(fileManager: fileManager)
        let sensitiveItems = (try? fileManager.contentsOfDirectory(
            at: paths.sensitiveTemporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        sensitiveItems.forEach { try? fileManager.removeItem(at: $0) }
        let directories = (try? fileManager.contentsOfDirectory(
            at: paths.securityOperationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for directory in directories {
            let deletionURL = directory.appendingPathComponent("secure-delete.json")
            if let data = try? Data(contentsOf: deletionURL),
               let manifest = try? JSONDecoder().decode(SecureDeletionManifest.self, from: data) {
                let metadataExists = (try? await repository.secureDocumentMetadataExists(ids: Set(manifest.documentIDs))) == true
                if metadataExists { rollbackDeletion(manifest) }
                try? fileManager.removeItem(at: directory)
                continue
            }
            let moveURL = directory.appendingPathComponent("secure-move.json")
            if let data = try? Data(contentsOf: moveURL),
               let manifest = try? JSONDecoder().decode(SecureMoveManifest.self, from: data) {
                let changesMatch = (try? await repository.documentSecurityChangesMatch(manifest.changes)) == true
                let committed = !manifest.changes.isEmpty && changesMatch
                if !committed {
                    rollbackFiles(assets: manifest.assets)
                }
                try? fileManager.removeItem(at: directory)
                continue
            }
            let manifestURL = directory.appendingPathComponent("operation.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SecurityOperationManifest.self, from: data) else {
                continue
            }
            let committed = (try? await repository.securityCommitMatches(
                folderID: manifest.folderID,
                targetSecurity: manifest.targetSecurity,
                changes: manifest.changes
            )) == true
            if !committed { rollbackFiles(in: manifest) }
            try? fileManager.removeItem(at: directory)
        }
    }

    func moveNormalDocumentsToSecure(
        _ documents: [ScannedDocument],
        destination: DocumentFolder,
        access: VaultAccess,
        progress: ProgressHandler? = nil
    ) async throws {
        guard !documents.isEmpty,
              destination.isSecure,
              access.folderID == destination.id,
              access.isValid,
              documents.allSatisfy({ !$0.isSecure }) else {
            throw LibraryRepositoryError.invalidSecurityState
        }
        try paths.prepare(fileManager: fileManager)
        let operationID = UUID()
        let operationDirectory = paths.securityOperationsDirectory
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let stagingDirectory = operationDirectory.appendingPathComponent("Staging", isDirectory: true)
        let recoveryDirectory = operationDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let verificationDirectory = operationDirectory.appendingPathComponent("Verification", isDirectory: true)
        for directory in [operationDirectory, stagingDirectory, recoveryDirectory, verificationDirectory] {
            try createProtectedDirectory(directory)
        }
        var manifest = SecureMoveManifest(
            operationID: operationID,
            destinationFolderID: destination.id,
            documentIDs: documents.map(\.id),
            assets: [],
            changes: []
        )
        try writeMoveManifest(manifest, in: operationDirectory)

        var metadataCommitted = false
        do {
            for (index, document) in documents.enumerated() {
                try Task.checkCancellation()
                let prepared = try prepareDocument(
                    SecurityDocumentRecord(document: document, secureTitleBlob: nil),
                    targetSecurity: .secure,
                    access: access,
                    stagingDirectory: stagingDirectory,
                    recoveryDirectory: recoveryDirectory,
                    verificationDirectory: verificationDirectory
                )
                manifest.assets.append(contentsOf: prepared.assets)
                manifest.changes.append(SecurityMetadataChange(
                    documentID: prepared.change.documentID,
                    title: prepared.change.title,
                    pdfFilename: prepared.change.pdfFilename,
                    previewFilename: prepared.change.previewFilename,
                    protection: prepared.change.protection,
                    protectionFormatVersion: prepared.change.protectionFormatVersion,
                    secureTitleBlob: prepared.change.secureTitleBlob,
                    folderID: destination.id
                ))
                try writeMoveManifest(manifest, in: operationDirectory)
                progress?(.init(phase: .staging, completedDocuments: index + 1, totalDocuments: documents.count))
            }

            for asset in manifest.assets {
                try Task.checkCancellation()
                let verifiedURL = plaintextURL(for: asset, targetSecurity: .secure, verificationDirectory: verificationDirectory)
                guard try checksum(of: verifiedURL) == asset.expectedPlaintextChecksum else {
                    throw LibraryRepositoryError.storageFailed("A staged secure file failed checksum verification.")
                }
            }
            for asset in manifest.assets {
                try Task.checkCancellation()
                try fileManager.moveItem(at: asset.originalURL, to: asset.recoveryURL)
                try protectFile(at: asset.recoveryURL)
            }
            for asset in manifest.assets {
                try Task.checkCancellation()
                try fileManager.moveItem(at: asset.stagedURL, to: asset.finalURL)
                try protectFile(at: asset.finalURL)
            }
            try await repository.commitMovedSecurityChanges(manifest.changes, to: destination.id)
            metadataCommitted = true
            try? fileManager.removeItem(at: operationDirectory)
            await SecureThumbnailPipeline.shared.clearAll()
        } catch {
            if !metadataCommitted { rollbackFiles(assets: manifest.assets) }
            try? fileManager.removeItem(at: operationDirectory)
            throw error
        }
    }

    func importPreparedSecureScan(
        _ scan: PreparedSecureScan,
        destination: DocumentFolder,
        access: VaultAccess
    ) async throws {
        guard destination.isSecure,
              scan.document.folderID == destination.id,
              access.folderID == destination.id,
              access.isValid else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        try paths.prepare(fileManager: fileManager)
        let operationID = UUID()
        let operationDirectory = paths.securityOperationsDirectory
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let stagingDirectory = operationDirectory.appendingPathComponent("Staging", isDirectory: true)
        let recoveryDirectory = operationDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let verificationDirectory = operationDirectory.appendingPathComponent("Verification", isDirectory: true)
        for directory in [operationDirectory, stagingDirectory, recoveryDirectory, verificationDirectory] {
            try createProtectedDirectory(directory)
        }
        var manifest = SecureMoveManifest(
            operationID: operationID,
            destinationFolderID: destination.id,
            documentIDs: [scan.document.id],
            assets: [],
            changes: []
        )
        try writeMoveManifest(manifest, in: operationDirectory)
        var metadataCommitted = false

        do {
            let prepared = try prepareDocument(
                SecurityDocumentRecord(document: scan.document, secureTitleBlob: nil),
                targetSecurity: .secure,
                access: access,
                stagingDirectory: stagingDirectory,
                recoveryDirectory: recoveryDirectory,
                verificationDirectory: verificationDirectory,
                sourcePDFURL: scan.sourcePDFURL,
                sourcePreviewURL: scan.sourcePreviewURL
            )
            manifest.assets = prepared.assets
            manifest.changes = [prepared.change]
            try writeMoveManifest(manifest, in: operationDirectory)
            for asset in manifest.assets {
                let verifiedURL = plaintextURL(for: asset, targetSecurity: .secure, verificationDirectory: verificationDirectory)
                guard try checksum(of: verifiedURL) == asset.expectedPlaintextChecksum else {
                    throw LibraryRepositoryError.storageFailed("A staged secure scan failed checksum verification.")
                }
            }
            for asset in manifest.assets {
                try fileManager.moveItem(at: asset.originalURL, to: asset.recoveryURL)
                try protectFile(at: asset.recoveryURL)
            }
            for asset in manifest.assets {
                try fileManager.moveItem(at: asset.stagedURL, to: asset.finalURL)
                try protectFile(at: asset.finalURL)
            }
            try await repository.createSecureDocumentMetadata(
                prepared.change,
                createdAt: scan.document.createdAt,
                pageCount: scan.document.pageCount
            )
            metadataCommitted = true
            try? fileManager.removeItem(at: operationDirectory)
        } catch {
            if !metadataCommitted { rollbackFiles(assets: manifest.assets) }
            try? fileManager.removeItem(at: operationDirectory)
            throw error
        }
    }

    func moveSecureDocuments(
        ids: Set<UUID>,
        sourceFolderID: UUID,
        destination: DocumentFolder?,
        access: VaultAccess,
        progress: ProgressHandler? = nil
    ) async throws {
        guard !ids.isEmpty, access.folderID == sourceFolderID, access.isValid else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        let snapshot = try await repository.securitySnapshot(folderID: sourceFolderID)
        let records = snapshot.documents.filter { ids.contains($0.document.id) }
        guard records.count == ids.count,
              records.allSatisfy({ $0.document.protection == .vaultV1 }) else {
            throw LibraryRepositoryError.invalidSecurityState
        }

        if destination?.isSecure == true {
            let changes = records.map { record in
                SecurityMetadataChange(
                    documentID: record.document.id,
                    title: "",
                    pdfFilename: record.document.pdfFilename,
                    previewFilename: record.document.previewFilename,
                    protection: .vaultV1,
                    protectionFormatVersion: record.document.protectionFormatVersion,
                    secureTitleBlob: record.secureTitleBlob,
                    folderID: destination?.id
                )
            }
            try await repository.commitMovedSecurityChanges(changes, to: destination?.id)
            await SecureThumbnailPipeline.shared.clearAll()
            return
        }

        try paths.prepare(fileManager: fileManager)
        let operationID = UUID()
        let operationDirectory = paths.securityOperationsDirectory
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let stagingDirectory = operationDirectory.appendingPathComponent("Staging", isDirectory: true)
        let recoveryDirectory = operationDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let verificationDirectory = operationDirectory.appendingPathComponent("Verification", isDirectory: true)
        for directory in [operationDirectory, stagingDirectory, recoveryDirectory, verificationDirectory] {
            try createProtectedDirectory(directory)
        }
        var manifest = SecureMoveManifest(
            operationID: operationID,
            destinationFolderID: destination?.id,
            documentIDs: records.map(\.document.id),
            assets: [],
            changes: []
        )
        try writeMoveManifest(manifest, in: operationDirectory)
        var metadataCommitted = false

        do {
            for (index, record) in records.enumerated() {
                try Task.checkCancellation()
                let prepared = try prepareDocument(
                    record,
                    targetSecurity: .standard,
                    access: access,
                    stagingDirectory: stagingDirectory,
                    recoveryDirectory: recoveryDirectory,
                    verificationDirectory: verificationDirectory
                )
                manifest.assets.append(contentsOf: prepared.assets)
                manifest.changes.append(SecurityMetadataChange(
                    documentID: prepared.change.documentID,
                    title: prepared.change.title,
                    pdfFilename: prepared.change.pdfFilename,
                    previewFilename: prepared.change.previewFilename,
                    protection: .standard,
                    protectionFormatVersion: 0,
                    secureTitleBlob: nil,
                    folderID: destination?.id
                ))
                try writeMoveManifest(manifest, in: operationDirectory)
                progress?(.init(phase: .staging, completedDocuments: index + 1, totalDocuments: records.count))
            }
            for asset in manifest.assets {
                guard try checksum(of: asset.stagedURL) == asset.expectedPlaintextChecksum else {
                    throw LibraryRepositoryError.storageFailed("A staged document failed checksum verification.")
                }
            }
            for asset in manifest.assets {
                try Task.checkCancellation()
                try fileManager.moveItem(at: asset.originalURL, to: asset.recoveryURL)
                try protectFile(at: asset.recoveryURL)
            }
            for asset in manifest.assets {
                try Task.checkCancellation()
                try fileManager.moveItem(at: asset.stagedURL, to: asset.finalURL)
                try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: asset.finalURL.path)
            }
            try await repository.commitMovedSecurityChanges(manifest.changes, to: destination?.id)
            metadataCommitted = true
            try? fileManager.removeItem(at: operationDirectory)
            await SecureThumbnailPipeline.shared.clearAll()
        } catch {
            if !metadataCommitted { rollbackFiles(assets: manifest.assets) }
            try? fileManager.removeItem(at: operationDirectory)
            throw error
        }
    }

    func renameSecureDocument(
        _ document: ScannedDocument,
        title: String,
        access: VaultAccess
    ) async throws {
        guard document.isSecure,
              let folderID = document.folderID,
              access.folderID == folderID,
              access.isValid else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        let sanitized = DocumentTitleFormatter.sanitized(title, fallbackDate: document.createdAt)
        let blob = try crypto.encryptTitle(sanitized, documentID: document.id, access: access)
        try await repository.renameSecureDocument(id: document.id, folderID: folderID, secureTitleBlob: blob)
        await SecureThumbnailPipeline.shared.clearAll()
    }

    func deleteSecureDocuments(
        _ documents: [ScannedDocument],
        folderID: UUID,
        access: VaultAccess
    ) async throws {
        guard !documents.isEmpty,
              access.folderID == folderID,
              access.isValid,
              documents.allSatisfy({ $0.isSecure && $0.folderID == folderID }) else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        try paths.prepare(fileManager: fileManager)
        let operationID = UUID()
        let operationDirectory = paths.securityOperationsDirectory
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let recoveryDirectory = operationDirectory.appendingPathComponent("Recovery", isDirectory: true)
        try createProtectedDirectory(recoveryDirectory)

        var moves: [SecureDeletionManifest.FileMove] = []
        for document in documents {
            for (index, originalURL) in [document.pdfURL(in: paths), document.previewURL(in: paths)].enumerated() {
                guard fileManager.fileExists(atPath: originalURL.path) else {
                    throw LibraryRepositoryError.missingFile(originalURL.lastPathComponent)
                }
                moves.append(.init(
                    originalURL: originalURL,
                    recoveryURL: recoveryDirectory.appendingPathComponent("\(document.id)-\(index)"),
                    encryptedChecksum: try checksum(of: originalURL)
                ))
            }
        }
        let manifest = SecureDeletionManifest(
            operationID: operationID,
            folderID: folderID,
            documentIDs: documents.map(\.id),
            moves: moves
        )
        let manifestURL = operationDirectory.appendingPathComponent("secure-delete.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])

        var metadataCommitted = false
        do {
            for move in moves {
                try Task.checkCancellation()
                try fileManager.moveItem(at: move.originalURL, to: move.recoveryURL)
                try protectFile(at: move.recoveryURL)
            }
            try await repository.deleteSecureDocumentMetadata(ids: Set(documents.map(\.id)), folderID: folderID)
            metadataCommitted = true
            try? fileManager.removeItem(at: operationDirectory)
            await SecureThumbnailPipeline.shared.clearAll()
        } catch {
            if !metadataCommitted { rollbackDeletion(manifest) }
            try? fileManager.removeItem(at: operationDirectory)
            throw error
        }
    }

    func deleteSecureFolderAndDocuments(
        folder: DocumentFolder,
        documents: [ScannedDocument],
        access: VaultAccess
    ) async throws {
        if !documents.isEmpty {
            try await deleteSecureDocuments(documents, folderID: folder.id, access: access)
        }
        try await repository.deleteAuthenticatedSecureFolder(id: folder.id)
    }

    private func prepareDocument(
        _ record: SecurityDocumentRecord,
        targetSecurity: FolderSecurity,
        access: VaultAccess,
        stagingDirectory: URL,
        recoveryDirectory: URL,
        verificationDirectory: URL,
        sourcePDFURL: URL? = nil,
        sourcePreviewURL: URL? = nil
    ) throws -> (assets: [SecurityOperationManifest.Asset], change: SecurityMetadataChange) {
        let document = record.document
        let sourcePDF = sourcePDFURL ?? document.pdfURL(in: paths)
        let sourcePreview = sourcePreviewURL ?? document.previewURL(in: paths)
        let pdfChecksum: String
        let previewChecksum: String
        let stagedPDF: URL
        let stagedPreview: URL
        let finalPDF: URL
        let finalPreview: URL
        let title: String
        let secureTitleBlob: Data?
        let protection: DocumentProtection
        let formatVersion: Int16

        switch targetSecurity {
        case .secure:
            guard document.protection == .standard else { throw LibraryRepositoryError.invalidSecurityState }
            pdfChecksum = try checksum(of: sourcePDF)
            previewChecksum = try checksum(of: sourcePreview)
            let pdfFilename = "\(UUID().uuidString.lowercased()).vault"
            let previewFilename = "\(UUID().uuidString.lowercased()).vault"
            stagedPDF = stagingDirectory.appendingPathComponent(pdfFilename)
            stagedPreview = stagingDirectory.appendingPathComponent(previewFilename)
            finalPDF = paths.vaultDirectory.appendingPathComponent(pdfFilename)
            finalPreview = paths.vaultDirectory.appendingPathComponent(previewFilename)
            try crypto.encryptFile(at: sourcePDF, to: stagedPDF, documentID: document.id, kind: .pdf, access: access)
            try crypto.encryptFile(at: sourcePreview, to: stagedPreview, documentID: document.id, kind: .preview, access: access)
            title = ""
            secureTitleBlob = try crypto.encryptTitle(document.title, documentID: document.id, access: access)
            protection = .vaultV1
            formatVersion = Int16(VaultCryptoService.formatVersion)

            let verifyPDF = verificationDirectory.appendingPathComponent("\(document.id)-pdf")
            let verifyPreview = verificationDirectory.appendingPathComponent("\(document.id)-preview")
            try crypto.decryptFile(at: stagedPDF, to: verifyPDF, documentID: document.id, kind: .pdf, access: access)
            try crypto.decryptFile(at: stagedPreview, to: verifyPreview, documentID: document.id, kind: .preview, access: access)
            try verifyPDFAndPreview(pdfURL: verifyPDF, previewURL: verifyPreview, expectedPageCount: document.pageCount)

        case .standard:
            guard document.protection == .vaultV1,
                  document.protectionFormatVersion == Int16(VaultCryptoService.formatVersion),
                  let encryptedTitle = record.secureTitleBlob else {
                throw LibraryRepositoryError.invalidSecurityState
            }
            let pdfFilename = "\(UUID().uuidString.lowercased()).pdf"
            let previewFilename = "\(UUID().uuidString.lowercased())-preview.jpg"
            stagedPDF = stagingDirectory.appendingPathComponent(pdfFilename)
            stagedPreview = stagingDirectory.appendingPathComponent(previewFilename)
            finalPDF = paths.filesDirectory.appendingPathComponent(pdfFilename)
            finalPreview = paths.filesDirectory.appendingPathComponent(previewFilename)
            try crypto.decryptFile(at: sourcePDF, to: stagedPDF, documentID: document.id, kind: .pdf, access: access)
            try crypto.decryptFile(at: sourcePreview, to: stagedPreview, documentID: document.id, kind: .preview, access: access)
            try verifyPDFAndPreview(pdfURL: stagedPDF, previewURL: stagedPreview, expectedPageCount: document.pageCount)
            pdfChecksum = try checksum(of: stagedPDF)
            previewChecksum = try checksum(of: stagedPreview)
            title = try crypto.decryptTitle(encryptedTitle, documentID: document.id, access: access)
            secureTitleBlob = nil
            protection = .standard
            formatVersion = 0
        }

        let pdfAsset = SecurityOperationManifest.Asset(
            documentID: document.id,
            kind: .pdf,
            originalURL: sourcePDF,
            stagedURL: stagedPDF,
            recoveryURL: recoveryDirectory.appendingPathComponent("\(document.id)-pdf"),
            finalURL: finalPDF,
            expectedPlaintextChecksum: pdfChecksum
        )
        let previewAsset = SecurityOperationManifest.Asset(
            documentID: document.id,
            kind: .preview,
            originalURL: sourcePreview,
            stagedURL: stagedPreview,
            recoveryURL: recoveryDirectory.appendingPathComponent("\(document.id)-preview"),
            finalURL: finalPreview,
            expectedPlaintextChecksum: previewChecksum
        )
        let change = SecurityMetadataChange(
            documentID: document.id,
            title: title,
            pdfFilename: finalPDF.lastPathComponent,
            previewFilename: finalPreview.lastPathComponent,
            protection: protection,
            protectionFormatVersion: formatVersion,
            secureTitleBlob: secureTitleBlob,
            folderID: document.folderID
        )
        return ([pdfAsset, previewAsset], change)
    }

    private func plaintextURL(
        for asset: SecurityOperationManifest.Asset,
        targetSecurity: FolderSecurity,
        verificationDirectory: URL
    ) -> URL {
        if targetSecurity == .secure {
            return verificationDirectory.appendingPathComponent("\(asset.documentID)-\(asset.kind == .pdf ? "pdf" : "preview")")
        }
        return asset.stagedURL
    }

    private func verifyPDFAndPreview(pdfURL: URL, previewURL: URL, expectedPageCount: Int) throws {
        guard PDFDocument(url: pdfURL)?.pageCount == expectedPageCount else {
            throw LibraryRepositoryError.storageFailed("A staged PDF failed page-count verification.")
        }
        guard UIImage(contentsOfFile: previewURL.path) != nil else {
            throw LibraryRepositoryError.storageFailed("A staged preview could not be read.")
        }
    }

    private func rollbackFiles(in manifest: SecurityOperationManifest) {
        rollbackFiles(assets: manifest.assets)
    }

    private func rollbackFiles(assets: [SecurityOperationManifest.Asset]) {
        for asset in assets.reversed() {
            if fileManager.fileExists(atPath: asset.finalURL.path) {
                try? fileManager.removeItem(at: asset.finalURL)
            }
            if fileManager.fileExists(atPath: asset.recoveryURL.path),
               !fileManager.fileExists(atPath: asset.originalURL.path) {
                try? fileManager.moveItem(at: asset.recoveryURL, to: asset.originalURL)
            }
        }
    }

    private func rollbackDeletion(_ manifest: SecureDeletionManifest) {
        for move in manifest.moves.reversed() {
            guard fileManager.fileExists(atPath: move.recoveryURL.path),
                  !fileManager.fileExists(atPath: move.originalURL.path),
                  (try? checksum(of: move.recoveryURL)) == move.encryptedChecksum else { continue }
            try? fileManager.moveItem(at: move.recoveryURL, to: move.originalURL)
        }
    }

    private func writeManifest(_ manifest: SecurityOperationManifest, in directory: URL) throws {
        let url = directory.appendingPathComponent("operation.json")
        try JSONEncoder().encode(manifest).write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func writeMoveManifest(_ manifest: SecureMoveManifest, in directory: URL) throws {
        let url = directory.appendingPathComponent("secure-move.json")
        try JSONEncoder().encode(manifest).write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func protectFile(at url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func checksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
