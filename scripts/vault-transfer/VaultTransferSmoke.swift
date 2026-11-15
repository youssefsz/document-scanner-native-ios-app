// Copied into temporary simulator-only builds by smoke.sh.
#if DEBUG && targetEnvironment(simulator)
import CryptoKit
import LocalAuthentication
import PDFKit
import SwiftUI
import UIKit

@MainActor
enum VaultTransferSmoke {
    static let mode = ProcessInfo.processInfo.arguments.last
    static var enabled: Bool { ["seed", "missed-seed", "bridge", "relaunch", "missed"].contains(mode ?? "") }

    private static let paths = StoragePaths.production
    // The simulated apps share the real App Group name. Scope their test
    // items by bundle so a prior test can't lend a key to the missed case.
    private static let service = "DocScanner.Smoke." + (Bundle.main.bundleIdentifier ?? "missing")
    #if !VAULT_SMOKE_LEGACY
    static func keys() -> VaultKeyStore { VaultKeyStore(storage: SystemVaultKeyStorage(service: service)) }
    #endif
    private static let sampleTitle = "Vault transfer sample"
    private static var snapshotURL: URL { paths.rootDirectory.appendingPathComponent("smoke-snapshot") }

    static func run() async {
        let result: String
        do {
            try await test()
            result = "PASS"
        } catch {
            // The script collects a status only. Never print keys or documents.
            if let error = error as? VaultAuthenticationError {
                result = "FAIL VaultAuthenticationError.\(error)"
            } else if let error = error as? Failure {
                result = "FAIL \(error)"
            } else {
                result = "FAIL \((error as NSError).domain) \((error as NSError).code)"
            }
        }
        let marker = URL.documentsDirectory.appendingPathComponent("vault-smoke-result")
        try? Data(result.utf8).write(to: marker, options: .atomic)
    }

    private static func test() async throws {
        let repository = CoreDataLibraryRepository(paths: paths)
        try await repository.bootstrap()
        #if VAULT_SMOKE_LEGACY
        let folder = try await repository.createFolder(name: "Transfer QA", security: .standard)
        let document = ScannedDocument(
            title: sampleTitle, pageCount: 1, pdfFilename: "transfer.pdf", previewFilename: "transfer.jpg", folderID: folder.id
        )
        let area = CGRect(x: 0, y: 0, width: 180, height: 220)
        try UIGraphicsPDFRenderer(bounds: area).writePDF(to: document.pdfURL(in: paths)) { context in
            context.beginPage()
            (sampleTitle as NSString).draw(at: CGPoint(x: 20, y: 20))
        }
        let preview = UIGraphicsImageRenderer(size: area.size).image { context in
            UIColor.systemBlue.setFill()
            context.fill(area)
        }
        guard let jpeg = preview.jpegData(compressionQuality: 0.8) else { throw Failure.fixture }
        try jpeg.write(to: document.previewURL(in: paths))
        try await repository.createDocument(document)
        let keys = VaultKeyStore(service: service)
        let access = try await keys.access(folderID: folder.id, reason: "Create the sample vault")
        try await DocumentSecurityCoordinator(repository: repository, paths: paths)
            .convertFolder(id: folder.id, to: .secure, access: access)
        let snapshot = try await repository.securitySnapshot(folderID: folder.id)
        try await verify(snapshot, access: access, writeSnapshot: true)
        #else
        let library = DocumentLibrary(repository: repository, vaultKeyStore: keys())
        await library.loadIfNeeded()
        guard let folder = library.allFolders.first?.folder, folder.isSecure else { throw Failure.fixture }
        let snapshot = try await repository.securitySnapshot(folderID: folder.id)
        if mode == "missed" {
            do {
                _ = try await library.unlockSecureFolder(folder)
                throw Failure.expectedRecovery
            } catch VaultAuthenticationError.recoveryRequired {
                guard try snapshotData(snapshot) == Data(contentsOf: snapshotURL) else { throw Failure.changedCiphertext }
                // A second unlock, and a fresh-create attempt with the real
                // inventory, must both still report a missing key.
                let keys = keys()
                let recovery = VaultBackupService(repository: repository, paths: paths, keys: keys)
                do {
                    _ = try await keys.prepareForCreation(folderID: UUID(), reason: "Check protected data") {
                        try await recovery.confirmEmpty()
                    }
                    throw Failure.expectedRecovery
                } catch VaultAuthenticationError.recoveryRequired {
                    return
                }
            }
        }
        let access = try await library.unlockSecureFolder(folder)
        guard access.transferStatus == .ready else { throw Failure.notMigrated }
        let context = try LocalAuthenticationService().makeContext()
        let persisted = try SystemVaultKeyStorage(service: service)
            .read(.appGroup, context: context, reason: "Verify the migrated sample key")
        guard try access.withRootKey({ $0 == persisted }) else { throw Failure.notMigrated }
        let scoped = try await library.secureFolderDocuments(folderID: folder.id, access: access)
        guard scoped.map(\.title) == [sampleTitle] else { throw Failure.fixture }
        try await verify(snapshot, access: access, writeSnapshot: false)
        #endif
    }

    private static func verify(_ snapshot: FolderSecuritySnapshot, access: VaultAccess, writeSnapshot: Bool) async throws {
        guard let record = snapshot.documents.first, let title = record.secureTitleBlob else { throw Failure.fixture }
        let provider = DocumentContentProvider(paths: paths)
        let pdf = try await provider.data(for: record.document, kind: .pdf, access: access)
        let preview = try await provider.data(for: record.document, kind: .preview, access: access)
        let decoded = try VaultCryptoService().decryptTitle(title, documentID: record.document.id, access: access)
        guard PDFDocument(data: pdf)?.string?.contains(sampleTitle) == true,
              UIImage(data: preview) != nil, decoded == sampleTitle else { throw Failure.fixture }
        let snapshotData = try snapshotData(snapshot)
        if writeSnapshot {
            try snapshotData.write(to: snapshotURL, options: .atomic)
        } else if try snapshotData != Data(contentsOf: snapshotURL) {
            throw Failure.changedCiphertext
        }
    }

    private static func snapshotData(_ snapshot: FolderSecuritySnapshot) throws -> Data {
        guard let record = snapshot.documents.first, let title = record.secureTitleBlob else { throw Failure.fixture }
        let pdf = try Data(contentsOf: record.document.pdfURL(in: paths))
        let preview = try Data(contentsOf: record.document.previewURL(in: paths))
        return Data(SHA256.hash(data: pdf)) + Data(SHA256.hash(data: preview)) + Data(SHA256.hash(data: title))
    }

    private enum Failure: Error {
        case fixture
        case expectedRecovery
        case changedCiphertext
        case notMigrated
    }
}
#endif
