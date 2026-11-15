import CryptoKit
import Foundation

nonisolated enum VaultBackupError: LocalizedError {
    case empty
    case pendingOperation
    case invalidArchive
    case authenticationFailed
    case conflict
    case tooLarge
    case storage

    var errorDescription: String? {
        switch self {
        case .empty: "There are no secure folders to back up."
        case .pendingOperation: "A previous secure folder operation needs to finish. Reopen DocScanner and try again."
        case .invalidArchive: "This vault backup is damaged, incomplete, or uses an unsupported format."
        case .authenticationFailed: "The recovery code is incorrect or the backup is damaged."
        case .conflict: "This backup conflicts with the library on this device. Your existing documents and keys were kept."
        case .tooLarge: "This vault backup exceeds the supported metadata size."
        case .storage: "DocScanner couldn’t read or save the vault backup. Check available storage and try again."
        }
    }
}

nonisolated struct VaultBackup: Sendable {
    let url: URL
    let recoveryCode: String
    let transferStatus: VaultTransferStatus
}

nonisolated enum VaultRestoreResult: Sendable {
    case existingVaultUnlocked
    case backupImported
}

actor VaultBackupService {
    private let repository: any VaultRecoveryRepository
    private let paths: StoragePaths
    private let keys: VaultKeyStore
    private let files = FileManager.default
    private let crypto = VaultCryptoService()

    init(repository: any VaultRecoveryRepository, paths: StoragePaths, keys: VaultKeyStore) {
        self.repository = repository
        self.paths = paths
        self.keys = keys
    }

    func confirmEmpty() async throws -> Bool {
        guard try await repository.vaultInventory().isEmpty else { return false }
        return try directoryEntries(paths.vaultDirectory).isEmpty &&
            directoryEntries(paths.securityOperationsDirectory).isEmpty
    }

    func makeBackup() async throws -> VaultBackup {
        try checkPendingOperations()
        let inventory = try await repository.vaultInventory()
        guard let folder = inventory.folders.first else { throw VaultBackupError.empty }
        let access = try await keys.openExisting(folderID: folder.id, reason: "Back up your secure folders")
        defer { access.invalidate() }
        let assets = try validate(inventory)
        try checkLocalFiles(exactly: assets)
        try verify(inventory, assets: assets, in: paths.vaultDirectory, access: access)

        let secret = SymmetricKey(size: .bits256)
        let secretData = secret.withUnsafeBytes { Data($0) }
        let manifest = try access.withRootKey { rootKey in
            Manifest(
                folders: inventory.folders,
                documents: inventory.documents,
                rootKey: rootKey.withUnsafeBytes { Data($0) },
                assetLengths: try assets.map { try fileLength(paths.vaultDirectory.appendingPathComponent($0.filename)) }
            )
        }
        let metadata = try JSONEncoder().encode(manifest)
        guard metadata.count <= Self.maximumMetadata - 28 else { throw VaultBackupError.tooLarge }
        let header = Self.magic + Self.encodeLength(UInt64(metadata.count + 28))
        let box = try AES.GCM.seal(metadata, using: secret, authenticating: header)
        guard let sealed = box.combined else { throw VaultBackupError.storage }

        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("DocScanner Vault.dsvaultbackup")
        do {
            let output = try createFile(at: url)
            defer { try? output.close() }
            try output.write(contentsOf: header)
            try output.write(contentsOf: sealed)
            for (asset, length) in zip(assets, manifest.assetLengths) {
                let input = try FileHandle(forReadingFrom: paths.vaultDirectory.appendingPathComponent(asset.filename))
                defer { try? input.close() }
                try transfer(length, from: input, to: output)
                try checkEnd(of: input)
            }
            try output.synchronize()
            try Task.checkCancellation()
            return VaultBackup(
                url: url, recoveryCode: secretData.base64EncodedString(), transferStatus: access.transferStatus
            )
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func restore(from url: URL, recoveryCode: String) async throws -> VaultRestoreResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try checkPendingOperations()
        let stage = try temporaryDirectory()
        defer { try? files.removeItem(at: stage) }

        // Verify the complete archive before reading or writing a Keychain item.
        let (manifest, archivedAssets) = try readArchive(at: url, code: recoveryCode, stage: stage)
        let rootKey = SymmetricKey(data: manifest.rootKey)
        let access = VaultAccess(folderID: UUID(), rootKey: rootKey)
        defer { access.invalidate() }
        try verify(manifest.inventory, assets: archivedAssets, in: stage, access: access)

        let local = try await repository.vaultInventory()
        try checkPendingOperations()
        if !local.isEmpty {
            let localAssets: [Asset]
            do {
                localAssets = try validate(local)
                try checkLocalFiles(exactly: localAssets)
                try verify(local, assets: localAssets, in: paths.vaultDirectory, access: access)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VaultBackupError.conflict
            }
            // Empty folders provide no ciphertext to prove a candidate key.
            try await keys.installRecoveredKey(rootKey, requireExistingMatch: localAssets.isEmpty)
            return .existingVaultUnlocked
        }

        try await repository.checkVaultImport(manifest.inventory)
        let expected = Set(archivedAssets.map(\.filename))
        let existing = try directoryEntries(paths.vaultDirectory)
        // An interruption after installing files can leave a subset of this
        // exact archive. Reuse identical files and preserve everything else.
        for item in existing {
            guard expected.contains(item.lastPathComponent),
                  try filesMatch(item, stage.appendingPathComponent(item.lastPathComponent)) else {
                throw VaultBackupError.conflict
            }
        }

        try await keys.installRecoveredKey(rootKey)
        try Task.checkCancellation()
        try checkPendingOperations()
        let existingNames = Set(existing.map(\.lastPathComponent))
        var installed = [URL]()
        do {
            for asset in archivedAssets where !existingNames.contains(asset.filename) {
                try Task.checkCancellation()
                let destination = paths.vaultDirectory.appendingPathComponent(asset.filename)
                // A link on the same volume installs an already verified file
                // without replacing anything at the destination.
                try files.linkItem(at: stage.appendingPathComponent(asset.filename), to: destination)
                installed.append(destination)
            }
            try Task.checkCancellation()
            try await repository.importVault(manifest.inventory)
        } catch {
            for item in installed { try? files.removeItem(at: item) }
            throw error
        }
        return .backupImported
    }

    private struct Manifest: Codable {
        let folders: [DocumentFolder]
        let documents: [SecurityDocumentRecord]
        let rootKey: Data
        let assetLengths: [UInt64]

        var inventory: VaultInventory { VaultInventory(folders: folders, documents: documents) }
    }

    private struct Asset {
        let documentID: UUID
        let filename: String
        let kind: VaultAssetKind
    }

    private static let magic = Data("DSBACK01".utf8)
    private static let maximumMetadata = 16 * 1024 * 1024

    private func readArchive(at url: URL, code: String, stage: URL) throws -> (Manifest, [Asset]) {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanCode.utf8.count == 44, let bytes = Data(base64Encoded: cleanCode), bytes.count == 32 else {
            throw VaultBackupError.authenticationFailed
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let magic = try readExactly(Self.magic.count, from: input)
        guard magic == Self.magic else { throw VaultBackupError.invalidArchive }
        let lengthBytes = try readExactly(8, from: input)
        let length = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        guard length >= 28, length <= UInt64(Self.maximumMetadata) else { throw VaultBackupError.invalidArchive }
        let sealed = try readExactly(Int(length), from: input)
        let metadata: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            metadata = try AES.GCM.open(box, using: SymmetricKey(data: bytes), authenticating: magic + lengthBytes)
        } catch {
            throw VaultBackupError.authenticationFailed
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: metadata), manifest.rootKey.count == 32,
              !manifest.folders.isEmpty else { throw VaultBackupError.invalidArchive }
        let assets = try validate(manifest.inventory)
        guard assets.count == manifest.assetLengths.count else { throw VaultBackupError.invalidArchive }

        let archiveLength = try input.seekToEnd()
        let assetOffset = UInt64(magic.count + lengthBytes.count) + length
        guard archiveLength >= assetOffset else { throw VaultBackupError.invalidArchive }
        var remaining = archiveLength - assetOffset
        for size in manifest.assetLengths {
            guard size > 0, size <= remaining else { throw VaultBackupError.invalidArchive }
            remaining -= size
        }
        guard remaining == 0 else { throw VaultBackupError.invalidArchive }
        try input.seek(toOffset: assetOffset)
        for (asset, size) in zip(assets, manifest.assetLengths) {
            let output = try createFile(at: stage.appendingPathComponent(asset.filename))
            defer { try? output.close() }
            try transfer(size, from: input, to: output)
            try output.synchronize()
        }
        try checkEnd(of: input)
        return (manifest, assets)
    }

    private func validate(_ inventory: VaultInventory) throws -> [Asset] {
        var folderIDs = Set<UUID>()
        var folderNames = Set<String>()
        for folder in inventory.folders {
            guard folder.isSecure,
                  let name = try? LibraryTextNormalizer.validatedFolderName(folder.name),
                  name.display == folder.name, name.normalized == folder.normalizedName,
                  folderIDs.insert(folder.id).inserted, folderNames.insert(folder.normalizedName).inserted else {
                throw VaultBackupError.invalidArchive
            }
        }

        var documentIDs = Set<UUID>()
        var filenames = Set<String>()
        return try inventory.documents.flatMap { record in
            let doc = record.document
            guard let folderID = doc.folderID, folderIDs.contains(folderID), doc.protection == .vaultV1,
                  doc.protectionFormatVersion == Int16(VaultCryptoService.formatVersion),
                  doc.title.isEmpty, record.secureTitleBlob != nil, doc.pageCount > 0,
                  documentIDs.insert(doc.id).inserted else { throw VaultBackupError.invalidArchive }
            return try [(doc.pdfFilename, VaultAssetKind.pdf), (doc.previewFilename, .preview)].map { filename, kind in
                let stem = String(filename.dropLast(6))
                guard filename.hasSuffix(".vault"), let id = UUID(uuidString: stem),
                      id.uuidString.lowercased() == stem, filenames.insert(filename).inserted else {
                    throw VaultBackupError.invalidArchive
                }
                return Asset(documentID: doc.id, filename: filename, kind: kind)
            }
        }
    }

    private func verify(_ inventory: VaultInventory, assets: [Asset], in directory: URL, access: VaultAccess) throws {
        do {
            for record in inventory.documents {
                try Task.checkCancellation()
                guard let title = record.secureTitleBlob else { throw VaultBackupError.invalidArchive }
                _ = try crypto.decryptTitle(title, documentID: record.document.id, access: access)
            }
            for asset in assets {
                let url = directory.appendingPathComponent(asset.filename)
                _ = try fileLength(url)
                try crypto.verifyFile(at: url, documentID: asset.documentID, kind: asset.kind, access: access)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VaultBackupError.invalidArchive
        }
    }

    private func checkLocalFiles(exactly assets: [Asset]) throws {
        let expected = Set(assets.map(\.filename))
        guard try Set(directoryEntries(paths.vaultDirectory).map(\.lastPathComponent)) == expected else {
            throw VaultBackupError.conflict
        }
    }

    private func checkPendingOperations() throws {
        guard try directoryEntries(paths.securityOperationsDirectory).isEmpty else {
            throw VaultBackupError.pendingOperation
        }
    }

    private func directoryEntries(_ path: URL) throws -> [URL] {
        try files.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
    }

    private func temporaryDirectory() throws -> URL {
        var url = paths.sensitiveTemporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return url
        } catch {
            try? files.removeItem(at: url)
            throw error
        }
    }

    private func createFile(at url: URL) throws -> FileHandle {
        guard files.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw VaultBackupError.storage
        }
        return try FileHandle(forWritingTo: url)
    }

    private func fileLength(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, size > 0 else { throw VaultBackupError.invalidArchive }
        return UInt64(size)
    }

    private func filesMatch(_ first: URL, _ second: URL) throws -> Bool {
        let length = try fileLength(first)
        guard length == (try fileLength(second)) else { return false }
        let left = try FileHandle(forReadingFrom: first)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: second)
        defer { try? right.close() }
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, UInt64(VaultCryptoService.chunkSize)))
            guard try readExactly(count, from: left) == readExactly(count, from: right) else { return false }
            remaining -= UInt64(count)
        }
        return true
    }

    private func transfer(_ size: UInt64, from input: FileHandle, to output: FileHandle) throws {
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, UInt64(VaultCryptoService.chunkSize)))
            try output.write(contentsOf: readExactly(count, from: input))
            remaining -= UInt64(count)
        }
    }

    private func readExactly(_ size: Int, from input: FileHandle) throws -> Data {
        var data = Data()
        while data.count < size {
            guard let next = try input.read(upToCount: size - data.count), !next.isEmpty else {
                throw VaultBackupError.invalidArchive
            }
            data.append(next)
        }
        return data
    }

    private func checkEnd(of input: FileHandle) throws {
        if let trailing = try input.read(upToCount: 1), !trailing.isEmpty { throw VaultBackupError.invalidArchive }
    }

    private static func encodeLength(_ length: UInt64) -> Data {
        var length = length.bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }
}
