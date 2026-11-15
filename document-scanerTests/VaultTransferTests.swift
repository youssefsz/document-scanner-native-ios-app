import CryptoKit
import LocalAuthentication
import PDFKit
import Security
import UIKit
import XCTest
@testable import DocScanner

private final class TestVaultKeyStorage: VaultKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var legacy: SymmetricKey?
    private var shared: SymmetricKey?
    private var attempts = 0
    private var issue: WriteIssue?
    private let readIssue: VaultAuthenticationError?

    enum WriteIssue {
        case beforeWrite
        case afterWrite
    }

    init(legacy: SymmetricKey? = nil, shared: SymmetricKey? = nil, issue: WriteIssue? = nil,
         readIssue: VaultAuthenticationError? = nil) {
        self.legacy = legacy
        self.shared = shared
        self.issue = issue
        self.readIssue = readIssue
    }

    var writeAttempts: Int { lock.withLock { attempts } }

    func read(_ location: VaultKeyLocation, context: LAContext, reason: String) throws -> SymmetricKey? {
        try lock.withLock {
            if location == .legacy { return legacy }
            if let readIssue { throw readIssue }
            return shared
        }
    }

    func addToAppGroup(_ key: SymmetricKey, context: LAContext) throws {
        try lock.withLock {
            attempts += 1
            let failure = issue
            issue = nil
            if failure == .beforeWrite { throw VaultAuthenticationError.keychain(errSecIO) }
            if shared == nil { shared = key }
            if failure == .afterWrite { throw VaultAuthenticationError.keychain(errSecIO) }
        }
    }

    func hasLegacy(_ expected: SymmetricKey) -> Bool { lock.withLock { legacy == expected } }
    func hasShared(_ expected: SymmetricKey) -> Bool { lock.withLock { shared == expected } }

    func keyStore(
        deviceUnlocked: Bool = true,
        authenticate: @escaping @Sendable () async throws -> Void = {}
    ) -> VaultKeyStore {
        VaultKeyStore(storage: self, makeContext: { LAContext() }, authenticate: { _, _ in try await authenticate() },
                      protectedDataAvailable: { deviceUnlocked })
    }
}

@MainActor
final class VaultTransferTests: XCTestCase {
    func testLegacyMigrationCopiesExactKeyAndNormalUnlockDoesNotWriteAgain() async throws {
        let root = SymmetricKey(size: .bits256)
        let storage = TestVaultKeyStorage(legacy: root)
        let first = try await storage.keyStore().openExisting(folderID: UUID(), reason: "Test")
        XCTAssertEqual(first.transferStatus, .ready)
        XCTAssertTrue(try first.withRootKey { $0 == root })
        XCTAssertTrue(storage.hasLegacy(root))
        XCTAssertTrue(storage.hasShared(root))

        let relaunched = try await storage.keyStore().openExisting(folderID: UUID(), reason: "Test again")
        XCTAssertEqual(relaunched.transferStatus, .ready)
        XCTAssertTrue(try relaunched.withRootKey { $0 == root })
        XCTAssertEqual(storage.writeAttempts, 1)
    }

    func testInterruptedWriteRetriesWithOrWithoutPersistedItem() async throws {
        for issue in [TestVaultKeyStorage.WriteIssue.beforeWrite, .afterWrite] {
            let key = SymmetricKey(size: .bits256)
            let storage = TestVaultKeyStorage(legacy: key, issue: issue)
            let first = try await storage.keyStore().openExisting(folderID: UUID(), reason: "Test")
            XCTAssertEqual(first.transferStatus, .pending(.keychain(errSecIO)))
            XCTAssertTrue(try first.withRootKey { $0 == key })
            XCTAssertTrue(storage.hasLegacy(key))

            let retry = try await storage.keyStore().openExisting(folderID: UUID(), reason: "Retry")
            XCTAssertEqual(retry.transferStatus, .ready)
            XCTAssertTrue(storage.hasShared(key))
            XCTAssertTrue(storage.hasLegacy(key))
            XCTAssertEqual(storage.writeAttempts, issue == .beforeWrite ? 2 : 1)
        }
    }

    func testCancellationAndSigningErrorsAreNotEmpty() async throws {
        for issue in [VaultAuthenticationError.cancelled, .signing] {
            let storage = TestVaultKeyStorage(readIssue: issue)
            await expectVaultError(issue) {
                _ = try await storage.keyStore().prepareForCreation(folderID: UUID(), reason: "Test") {
                    XCTFail("A failed lookup is not an empty vault")
                    return true
                }
            }
            XCTAssertEqual(storage.writeAttempts, 0)
        }

        let storage = TestVaultKeyStorage()
        let keys = storage.keyStore { throw VaultAuthenticationError.cancelled }
        await expectVaultError(.cancelled) {
            _ = try await keys.prepareForCreation(folderID: UUID(), reason: "Test") { true }
        }
        XCTAssertEqual(storage.writeAttempts, 0)
    }

    func testLockedDeviceAndUnavailableLibraryDoNotCreateKey() async throws {
        let storage = TestVaultKeyStorage()
        let locked = storage.keyStore(deviceUnlocked: false)
        await expectVaultError(.deviceLocked) {
            _ = try await locked.openExisting(folderID: UUID(), reason: "Test")
        }
        let library = DocumentLibrary(vaultKeyStore: storage.keyStore())
        let folder = DocumentFolder(
            id: UUID(), name: "Sample", normalizedName: "sample", createdAt: .now, updatedAt: .now, security: .secure
        )
        await expectVaultError(.libraryUnavailable) { _ = try await library.unlockSecureFolder(folder) }
        XCTAssertEqual(storage.writeAttempts, 0)
    }

    func testConflictingKeysArePreserved() async throws {
        let legacy = SymmetricKey(size: .bits256)
        let shared = SymmetricKey(size: .bits256)
        let storage = TestVaultKeyStorage(legacy: legacy, shared: shared)
        await expectVaultError(.keyConflict) {
            _ = try await storage.keyStore().openExisting(folderID: UUID(), reason: "Test")
        }
        XCTAssertTrue(storage.hasLegacy(legacy))
        XCTAssertTrue(storage.hasShared(shared))
        XCTAssertEqual(storage.writeAttempts, 0)
    }

    func testFirstCreationRechecksEvidenceAfterAuthentication() async throws {
        let location = try makePaths()
        let repository = CoreDataLibraryRepository(paths: location)
        try await repository.bootstrap()
        let orphan = location.vaultDirectory.appendingPathComponent("encrypted.vault")
        let storage = TestVaultKeyStorage()
        let keys = storage.keyStore {
            try Data([1, 2, 3]).write(to: orphan)
        }
        let service = VaultBackupService(repository: repository, paths: location, keys: keys)
        await expectVaultError(.recoveryRequired) {
            _ = try await keys.prepareForCreation(folderID: UUID(), reason: "Test") {
                try await service.confirmEmpty()
            }
        }
        XCTAssertEqual(storage.writeAttempts, 0)
        XCTAssertEqual(try Data(contentsOf: orphan), Data([1, 2, 3]))

        try FileManager.default.removeItem(at: orphan)
        let pending = location.securityOperationsDirectory.appendingPathComponent("pending")
        try Data([42]).write(to: pending)
        let emptyWhilePending = try await service.confirmEmpty()
        XCTAssertFalse(emptyWhilePending)
        try FileManager.default.removeItem(at: pending)

        let fresh = try await storage.keyStore().prepareForCreation(folderID: UUID(), reason: "Test") {
            try await service.confirmEmpty()
        }
        XCTAssertEqual(fresh.transferStatus, .ready)
        XCTAssertTrue(try fresh.withRootKey { storage.hasShared($0) })
        XCTAssertEqual(storage.writeAttempts, 1)
    }

    func testReminderPersistsOnlyAfterVerifiedTransfer() async throws {
        let sample = try await makeSampleVault()
        let suite = "VaultTransferTests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let storage = TestVaultKeyStorage(legacy: sample.key, issue: .beforeWrite)

        func makeLibrary() -> DocumentLibrary {
            DocumentLibrary(
                repository: sample.repository, securityCoordinator: sample.coordinator,
                vaultKeyStore: storage.keyStore(), vaultPaths: sample.paths,
                proAccess: FreeProAccessProvider(), preferences: preferences
            )
        }

        let library = makeLibrary()
        XCTAssertNil(library.secureFolderForTransferReminder)
        await library.loadIfNeeded()
        XCTAssertEqual(library.secureFolderForTransferReminder?.id, sample.folder.id)
        _ = try await library.unlockSecureFolder(sample.folder)
        XCTAssertFalse(library.hasVerifiedVaultTransfer)
        XCTAssertEqual(library.secureFolderForTransferReminder?.id, sample.folder.id)
        library.lockSecureFolder(id: sample.folder.id)

        _ = try await library.unlockSecureFolder(sample.folder)
        XCTAssertTrue(library.hasVerifiedVaultTransfer)
        XCTAssertNil(library.secureFolderForTransferReminder)

        let reopened = makeLibrary()
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.secureFolderForTransferReminder)
        XCTAssertNil(reopened.vaultTransferStatus)
    }

    func testBackupImportsIntoEmptyVaultAndRestoresMissingKeyWithProUnavailable() async throws {
        let sample = try await makeSampleVault()
        let sellerStorage = TestVaultKeyStorage(legacy: sample.key)
        let seller = DocumentLibrary(
            repository: sample.repository, securityCoordinator: sample.coordinator,
            vaultKeyStore: sellerStorage.keyStore(), vaultPaths: sample.paths, proAccess: FreeProAccessProvider()
        )
        await seller.loadIfNeeded()
        let backup = try await seller.makeVaultBackup()
        // Simulate Save to Files. Library bootstrap clears app-owned temporary exports.
        let exported = sample.paths.rootDirectory.appendingPathComponent("exported.dsvaultbackup")
        try FileManager.default.copyItem(at: backup.url, to: exported)
        XCTAssertTrue(sellerStorage.hasShared(sample.key))
        let originalPDF = try Data(contentsOf: sample.document.pdfURL(in: sample.paths))
        let originalPreview = try Data(contentsOf: sample.document.previewURL(in: sample.paths))
        let originalMetadata = try await sample.repository.vaultInventory()

        // A buyer who skipped the bridge must see recovery, even when backed
        // by the real on-disk library and with no paid access.
        let buyerStorage = TestVaultKeyStorage()
        let buyer = DocumentLibrary(
            repository: sample.repository, securityCoordinator: sample.coordinator,
            vaultKeyStore: buyerStorage.keyStore(), vaultPaths: sample.paths, proAccess: FreeProAccessProvider()
        )
        await buyer.loadIfNeeded()
        await expectVaultError(.recoveryRequired) { _ = try await buyer.unlockSecureFolder(sample.folder) }
        let protectedData = try await sample.repository.vaultInventory()
        XCTAssertFalse(protectedData.isEmpty)
        XCTAssertEqual(buyerStorage.writeAttempts, 0)
        guard case .existingVaultUnlocked = try await buyer.restoreVault(from: exported, code: backup.recoveryCode) else {
            return XCTFail("Restore should recover the local vault key")
        }
        let restoredAccess = try await buyer.unlockSecureFolder(sample.folder)
        let documents = try await buyer.secureFolderDocuments(folderID: sample.folder.id, access: restoredAccess)
        XCTAssertEqual(documents.map(\.title), ["Sample invoice"])
        XCTAssertTrue(buyerStorage.hasShared(sample.key))
        XCTAssertEqual(try Data(contentsOf: sample.document.pdfURL(in: sample.paths)), originalPDF)
        XCTAssertEqual(try Data(contentsOf: sample.document.previewURL(in: sample.paths)), originalPreview)
        let restoredMetadata = try await sample.repository.vaultInventory()
        XCTAssertEqual(restoredMetadata.documents.first?.secureTitleBlob, originalMetadata.documents.first?.secureTitleBlob)

        let newPaths = try makePaths()
        let newRepository = CoreDataLibraryRepository(paths: newPaths)
        try await newRepository.bootstrap()
        let newStorage = TestVaultKeyStorage()
        let newKeys = newStorage.keyStore()
        let service = VaultBackupService(repository: newRepository, paths: newPaths, keys: newKeys)
        guard case .backupImported = try await service.restore(from: exported, recoveryCode: backup.recoveryCode) else {
            return XCTFail("An empty vault should import the whole backup")
        }
        let reopened = try await newKeys.openExisting(folderID: sample.folder.id, reason: "Verify restored vault")
        let inventory = try await newRepository.vaultInventory()
        let record = try XCTUnwrap(inventory.documents.first)
        XCTAssertEqual(inventory.folders.map(\.id), [sample.folder.id])
        let title = try VaultCryptoService().decryptTitle(
            XCTUnwrap(record.secureTitleBlob), documentID: record.document.id, access: reopened
        )
        XCTAssertEqual(title, "Sample invoice")
        XCTAssertEqual(try Data(contentsOf: record.document.pdfURL(in: newPaths)), originalPDF)
        XCTAssertEqual(try Data(contentsOf: record.document.previewURL(in: newPaths)), originalPreview)
        let provider = DocumentContentProvider(paths: newPaths)
        let restoredPDF = try await provider.data(for: record.document, kind: .pdf, access: reopened)
        XCTAssertEqual(PDFDocument(data: restoredPDF)?.pageCount, 1)
        let restoredPreview = try await provider.data(for: record.document, kind: .preview, access: reopened)
        XCTAssertNotNil(UIImage(data: restoredPreview))
    }

    func testWrongCodeDamageAndRestoreConflictsLeaveFilesAndKeysIntact() async throws {
        let source = try await makeSampleVault()
        let sourceService = VaultBackupService(
            repository: source.repository, paths: source.paths, keys: TestVaultKeyStorage(shared: source.key).keyStore()
        )
        let backup = try await sourceService.makeBackup()
        let target = try await makeSampleVault()
        let targetStorage = TestVaultKeyStorage(shared: target.key)
        let targetService = VaultBackupService(repository: target.repository, paths: target.paths, keys: targetStorage.keyStore())
        let original = try Data(contentsOf: target.document.pdfURL(in: target.paths))
        let originalPreview = try Data(contentsOf: target.document.previewURL(in: target.paths))
        let wrongCode = Data(repeating: 17, count: 32).base64EncodedString()

        do {
            _ = try await targetService.restore(from: backup.url, recoveryCode: wrongCode)
            XCTFail("Incorrect code was accepted")
        } catch VaultBackupError.authenticationFailed {}

        let corrupt = source.paths.rootDirectory.appendingPathComponent("damaged.dsvaultbackup")
        var bytes = try Data(contentsOf: backup.url)
        bytes[bytes.count - 1] ^= 1 // Damage an inner authenticated chunk.
        try bytes.write(to: corrupt)
        do {
            _ = try await targetService.restore(from: corrupt, recoveryCode: backup.recoveryCode)
            XCTFail("Damaged ciphertext was accepted")
        } catch VaultBackupError.invalidArchive {}

        do {
            _ = try await targetService.restore(from: backup.url, recoveryCode: backup.recoveryCode)
            XCTFail("Accepted a backup for a different vault")
        } catch VaultBackupError.conflict {}

        let targetInventory = try await target.repository.vaultInventory()
        XCTAssertEqual(targetInventory.documents.map { $0.document.id }, [target.document.id])
        XCTAssertEqual(try Data(contentsOf: target.document.pdfURL(in: target.paths)), original)
        XCTAssertEqual(try Data(contentsOf: target.document.previewURL(in: target.paths)), originalPreview)
        XCTAssertTrue(targetStorage.hasShared(target.key))
        XCTAssertEqual(targetStorage.writeAttempts, 0)
    }

    func testFailedJournalReadPreservesPendingVaultEvidence() async throws {
        let paths = try makePaths()
        let repository = CoreDataLibraryRepository(paths: paths)
        try await repository.bootstrap()
        let pending = paths.securityOperationsDirectory.appendingPathComponent("interrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let manifest = pending.appendingPathComponent("operation.json")
        let original = Data([1, 2, 3])
        try original.write(to: manifest)

        let coordinator = DocumentSecurityCoordinator(repository: repository, paths: paths)
        do {
            try await coordinator.recoverInterruptedOperations()
            XCTFail("Unreadable journal was treated as complete")
        } catch is DecodingError {}
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        let service = VaultBackupService(repository: repository, paths: paths, keys: TestVaultKeyStorage().keyStore())
        let empty = try await service.confirmEmpty()
        XCTAssertFalse(empty)
    }

    func testFreshRestoreResumesAfterAnInterruptedFileInstall() async throws {
        let source = try await makeSampleVault()
        let sourceKeys = TestVaultKeyStorage(shared: source.key).keyStore()
        let service = VaultBackupService(repository: source.repository, paths: source.paths, keys: sourceKeys)
        let backup = try await service.makeBackup()
        let targetPaths = try makePaths()
        let targetRepository = CoreDataLibraryRepository(paths: targetPaths)
        try await targetRepository.bootstrap()
        let targetStorage = TestVaultKeyStorage(shared: source.key)
        // Simulate termination after the first verified file was linked but
        // before Core Data committed the new folders and documents.
        let installed = source.document.pdfURL(in: targetPaths)
        try FileManager.default.copyItem(at: source.document.pdfURL(in: source.paths), to: installed)
        let target = VaultBackupService(repository: targetRepository, paths: targetPaths, keys: targetStorage.keyStore())
        guard case .backupImported = try await target.restore(from: backup.url, recoveryCode: backup.recoveryCode) else {
            return XCTFail("Expected restore to continue the import")
        }
        XCTAssertTrue(targetStorage.hasShared(source.key))
        XCTAssertEqual(targetStorage.writeAttempts, 0)
        let documents = try await targetRepository.vaultInventory().documents
        XCTAssertEqual(documents.map { $0.document.id }, [source.document.id])
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: source.document.pdfURL(in: source.paths)))
    }

    private func makePaths() throws -> StoragePaths {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = StoragePaths(rootDirectory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try paths.prepare()
        return paths
    }

    private func makeSampleVault() async throws -> (
        paths: StoragePaths, repository: CoreDataLibraryRepository, coordinator: DocumentSecurityCoordinator,
        key: SymmetricKey, folder: DocumentFolder, document: ScannedDocument
    ) {
        let paths = try makePaths()
        let repository = CoreDataLibraryRepository(paths: paths)
        let coordinator = DocumentSecurityCoordinator(repository: repository, paths: paths)
        try await repository.bootstrap()
        let folder = try await repository.createFolder(name: "Sample vault", security: .standard)
        let document = ScannedDocument(
            title: "Sample invoice", pageCount: 1, pdfFilename: "sample.pdf", previewFilename: "sample.jpg",
            folderID: folder.id
        )
        let area = CGRect(x: 0, y: 0, width: 180, height: 220)
        try UIGraphicsPDFRenderer(bounds: area).writePDF(to: document.pdfURL(in: paths)) { context in
            context.beginPage()
            ("Sample PDF" as NSString).draw(at: CGPoint(x: 20, y: 20))
        }
        let preview = UIGraphicsImageRenderer(size: area.size).image { context in
            UIColor.systemBlue.setFill()
            context.fill(area)
        }
        try XCTUnwrap(preview.jpegData(compressionQuality: 0.8)).write(to: document.previewURL(in: paths))
        try await repository.createDocument(document)
        let key = SymmetricKey(size: .bits256)
        try await coordinator.convertFolder(id: folder.id, to: .secure, access: VaultAccess(folderID: folder.id, rootKey: key))
        let secured = try await repository.securitySnapshot(folderID: folder.id)
        return (paths, repository, coordinator, key, secured.folder, try XCTUnwrap(secured.documents.first?.document))
    }

    private func expectVaultError(_ expected: VaultAuthenticationError, _ action: () async throws -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VaultAuthenticationError, expected, file: file, line: line)
        }
    }
}
