import XCTest
import UIKit
import CryptoKit
import PDFKit
@testable import DocScanner

final class LibraryRepositoryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var paths: StoragePaths!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentScannerTests-\(UUID().uuidString)", isDirectory: true)
        paths = StoragePaths(rootDirectory: temporaryDirectory)
        try paths.prepare()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testLegacyMigrationPreservesEveryFieldAndFile() async throws {
        let id = UUID()
        let document = ScannedDocument(
            id: id,
            title: "Café Notes",
            createdAt: Date(timeIntervalSince1970: 1_725_000_000),
            pageCount: 3,
            pdfFilename: "original.pdf",
            previewFilename: "original.jpg"
        )
        let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31])
        let previewBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try pdfBytes.write(to: document.pdfURL(in: paths))
        try previewBytes.write(to: document.previewURL(in: paths))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([document]).write(to: paths.legacyMetadataURL, options: .atomic)

        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        let neededMigration = try await repository.needsLegacyMigration()
        XCTAssertTrue(neededMigration)
        try await repository.bootstrap()
        try await repository.bootstrap()

        let imported = try await repository.fetchDocuments(scope: .all, query: "cafe", sort: .newestFirst)
        XCTAssertEqual(imported, [document])
        XCTAssertNil(imported.first?.folderID)
        XCTAssertEqual(try Data(contentsOf: document.pdfURL(in: paths)), pdfBytes)
        XCTAssertEqual(try Data(contentsOf: document.previewURL(in: paths)), previewBytes)

        let backups = try FileManager.default.contentsOfDirectory(at: paths.migrationBackupsDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.filter { $0.pathExtension == "json" }.count, 1)
        let stillNeedsMigration = try await repository.needsLegacyMigration()
        XCTAssertFalse(stillNeedsMigration)
    }

    func testFrozenVersion106FixtureImportsAsStandardUnfiledMetadata() async throws {
        let bundle = Bundle(for: LibraryRepositoryTests.self)
        let fixtureURL = bundle.url(forResource: "library-v1.0.6", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "library-v1.0.6", withExtension: "json")
        let fixture = try Data(contentsOf: XCTUnwrap(fixtureURL))
        try fixture.write(to: paths.legacyMetadataURL, options: .atomic)

        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        try await repository.bootstrap()
        let documents = try await repository.fetchDocuments(scope: .all, query: "cafe", sort: .newestFirst)

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0].title, "Café receipts")
        XCTAssertNil(documents[0].folderID)
        XCTAssertEqual(documents[0].protection, .standard)
        XCTAssertEqual(documents[0].protectionFormatVersion, 0)
        XCTAssertEqual(try Data(contentsOf: paths.legacyMetadataURL), fixture)
    }

    func testMalformedLegacyJSONDoesNotMarkMigrationComplete() async throws {
        try Data("not-json".utf8).write(to: paths.legacyMetadataURL)
        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)

        do {
            try await repository.bootstrap()
            XCTFail("Malformed JSON should fail migration")
        } catch {
            let stillNeedsMigration = try await repository.needsLegacyMigration()
            XCTAssertTrue(stillNeedsMigration)
            XCTAssertEqual(try Data(contentsOf: paths.legacyMetadataURL), Data("not-json".utf8))
        }
    }

    func testFoldersSearchMoveAndKeepDocumentsDeletion() async throws {
        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        try await repository.bootstrap()
        let first = makeDocument(title: "Résumé", offset: 2)
        let second = makeDocument(title: "Alpha", offset: 1)
        try await repository.createDocument(first)
        try await repository.createDocument(second)

        let folder = try await repository.createFolder(name: "  Work  ")
        XCTAssertEqual(folder.name, "Work")
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.createFolder(name: "wörk")
        }

        try await repository.moveDocuments(ids: [first.id, second.id], to: folder.id)
        let filed = try await repository.fetchDocuments(scope: .folder(folder.id), query: "resume", sort: .newestFirst)
        XCTAssertEqual(filed.map(\.id), [first.id])
        let allDocuments = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        XCTAssertEqual(allDocuments.count, 2)

        try await repository.deleteFolder(id: folder.id, mode: .keepDocuments)
        let unfiledDocuments = try await repository.fetchDocuments(scope: .unfiled, query: "", sort: .newestFirst)
        XCTAssertEqual(unfiledDocuments.count, 2)
    }

    func testOwnedFolderNamesSurviveAsyncRepositoryHop() async throws {
        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        try await repository.bootstrap()

        var textFieldValue = "Planning"
        let submittedName = LibraryTextNormalizer.ownedCopy(textFieldValue)
        textFieldValue.removeAll(keepingCapacity: false)

        let created = try await repository.createFolder(name: submittedName)
        XCTAssertEqual(created.name, "Planning")
        XCTAssertEqual(created.normalizedName, "planning")
    }

    func testDocumentDeletionRemovesFilesOnlyAfterMetadataMutation() async throws {
        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        try await repository.bootstrap()
        let document = makeDocument(title: "Delete Me", offset: 0)
        try Data([1, 2, 3]).write(to: document.pdfURL(in: paths))
        try Data([4, 5, 6]).write(to: document.previewURL(in: paths))
        try await repository.createDocument(document)

        try await repository.deleteDocuments(ids: [document.id])

        XCTAssertFalse(FileManager.default.fileExists(atPath: document.pdfURL(in: paths).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.previewURL(in: paths).path))
        let remaining = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSecureDocumentsAreAbsentFromGlobalFetchAndFolderCoverData() async throws {
        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        try await repository.bootstrap()
        let folder = try await repository.createFolder(name: "Private", security: .secure)
        let id = UUID()
        let secureDocument = ScannedDocument(
            id: id,
            title: "",
            pageCount: 1,
            pdfFilename: "\(id).vault",
            previewFilename: "\(id)-preview.vault",
            folderID: folder.id,
            protection: .vaultV1,
            protectionFormatVersion: 1
        )
        try await repository.createSecureDocumentMetadata(
            SecurityMetadataChange(
                documentID: id,
                title: "",
                pdfFilename: secureDocument.pdfFilename,
                previewFilename: secureDocument.previewFilename,
                protection: .vaultV1,
                protectionFormatVersion: 1,
                secureTitleBlob: Data("encrypted-title".utf8),
                folderID: folder.id
            ),
            createdAt: secureDocument.createdAt,
            pageCount: secureDocument.pageCount
        )

        let global = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        let insideFolder = try await repository.fetchDocuments(scope: .folder(folder.id), query: "", sort: .newestFirst)
        let summaries = try await repository.fetchFolders(query: "private")

        XCTAssertTrue(global.isEmpty)
        XCTAssertEqual(insideFolder, [secureDocument])
        XCTAssertEqual(summaries.first?.folder.security, .secure)
        XCTAssertEqual(summaries.first?.documentCount, 1)
        XCTAssertTrue(summaries.first?.newestDocuments.isEmpty == true)
    }

    func testFolderSecurityConversionRoundTripsFilesTitlesAndMetadata() async throws {
        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        try await repository.bootstrap()
        let folder = try await repository.createFolder(name: "Archive", security: .standard)
        let id = UUID()
        let document = ScannedDocument(
            id: id,
            title: "Tax return",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            pageCount: 1,
            pdfFilename: "\(id).pdf",
            previewFilename: "\(id).jpg",
            folderID: folder.id
        )
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        try pdfRenderer.writePDF(to: document.pdfURL(in: paths)) { context in
            context.beginPage()
            ("Searchable text" as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let preview = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }
        try XCTUnwrap(preview.jpegData(compressionQuality: 0.8)).write(to: document.previewURL(in: paths))
        try await repository.createDocument(document)

        let access = VaultAccess(folderID: folder.id, rootKey: SymmetricKey(size: .bits256))
        let coordinator = DocumentSecurityCoordinator(repository: repository, paths: paths)
        try await coordinator.convertFolder(id: folder.id, to: .secure, access: access)

        let secured = try await repository.securitySnapshot(folderID: folder.id)
        XCTAssertEqual(secured.folder.security, .secure)
        XCTAssertEqual(secured.documents.first?.document.title, "")
        XCTAssertEqual(secured.documents.first?.document.protection, .vaultV1)
        XCTAssertNotNil(secured.documents.first?.secureTitleBlob)
        XCTAssertTrue(secured.documents.first.map { FileManager.default.fileExists(atPath: $0.document.pdfURL(in: paths).path) } == true)
        let globallyVisibleDocuments = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        XCTAssertTrue(globallyVisibleDocuments.isEmpty)

        try await coordinator.convertFolder(id: folder.id, to: .standard, access: access)
        let restored = try await repository.fetchDocuments(scope: .folder(folder.id), query: "tax", sort: .newestFirst)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].title, "Tax return")
        XCTAssertEqual(restored[0].protection, .standard)
        XCTAssertEqual(PDFDocument(url: restored[0].pdfURL(in: paths))?.pageCount, 1)
        XCTAssertNotNil(UIImage(contentsOfFile: restored[0].previewURL(in: paths).path))
    }

    private func makeDocument(title: String, offset: TimeInterval) -> ScannedDocument {
        let id = UUID()
        return ScannedDocument(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            pageCount: 1,
            pdfFilename: "\(id).pdf",
            previewFilename: "\(id).jpg"
        )
    }
}

final class VaultCryptoServiceTests: XCTestCase {
    func testEmptyAssetRoundTripsAndRepeatedEncryptionIsRandomized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCryptoEmptyTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("empty")
        let first = directory.appendingPathComponent("first.vault")
        let second = directory.appendingPathComponent("second.vault")
        let restored = directory.appendingPathComponent("restored")
        try Data().write(to: source)
        let access = VaultAccess(folderID: UUID(), rootKey: SymmetricKey(size: .bits256))
        let crypto = VaultCryptoService()
        let documentID = UUID()

        try crypto.encryptFile(at: source, to: first, documentID: documentID, kind: .preview, access: access)
        try crypto.encryptFile(at: source, to: second, documentID: documentID, kind: .preview, access: access)
        try crypto.decryptFile(at: first, to: restored, documentID: documentID, kind: .preview, access: access)

        XCTAssertEqual(try Data(contentsOf: restored), Data())
        XCTAssertNotEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertThrowsError(
            try crypto.decryptFile(at: first, to: restored, documentID: documentID, kind: .pdf, access: access)
        )
    }

    func testChunkedAssetAndTitleRoundTripAndTamperRejection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCryptoTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.pdf")
        let encrypted = directory.appendingPathComponent("encrypted.vault")
        let decrypted = directory.appendingPathComponent("decrypted.pdf")
        var plaintext = Data(count: VaultCryptoService.chunkSize * 2 + 731)
        plaintext.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        try plaintext.write(to: source)

        let id = UUID()
        let access = VaultAccess(folderID: UUID(), rootKey: SymmetricKey(size: .bits256))
        let crypto = VaultCryptoService()
        try crypto.encryptFile(at: source, to: encrypted, documentID: id, kind: .pdf, access: access)
        try crypto.decryptFile(at: encrypted, to: decrypted, documentID: id, kind: .pdf, access: access)
        XCTAssertEqual(try Data(contentsOf: decrypted), plaintext)
        XCTAssertThrowsError(
            try crypto.decryptFile(at: encrypted, to: decrypted, documentID: UUID(), kind: .pdf, access: access)
        )

        let validEnvelope = try Data(contentsOf: encrypted)
        var modifiedCiphertext = validEnvelope
        modifiedCiphertext[modifiedCiphertext.index(before: modifiedCiphertext.endIndex)] ^= 0x01
        try modifiedCiphertext.write(to: encrypted)
        XCTAssertThrowsError(
            try crypto.decryptFile(at: encrypted, to: decrypted, documentID: id, kind: .pdf, access: access)
        )

        var unsupportedVersion = validEnvelope
        unsupportedVersion[8] = 0x7f
        try unsupportedVersion.write(to: encrypted)
        XCTAssertThrowsError(
            try crypto.decryptFile(at: encrypted, to: decrypted, documentID: id, kind: .pdf, access: access)
        )

        try validEnvelope.dropLast(10).write(to: encrypted)
        XCTAssertThrowsError(
            try crypto.decryptFile(at: encrypted, to: decrypted, documentID: id, kind: .pdf, access: access)
        )

        let titleBlob = try crypto.encryptTitle("Hidden title", documentID: id, access: access)
        XCTAssertEqual(try crypto.decryptTitle(titleBlob, documentID: id, access: access), "Hidden title")
        var damagedTitle = titleBlob
        damagedTitle[damagedTitle.index(before: damagedTitle.endIndex)] ^= 0x01
        XCTAssertThrowsError(try crypto.decryptTitle(damagedTitle, documentID: id, access: access))

        access.invalidate()
        XCTAssertThrowsError(try crypto.decryptTitle(titleBlob, documentID: id, access: access))
    }

    func testGeneratedPDFPasswordsMatchProductFormat() throws {
        let pair = try PDFPasswordGenerator().generate()
        XCTAssertEqual(pair.userPassword.count, 16)
        XCTAssertEqual(pair.ownerPassword.count, 32)
        XCTAssertEqual(pair.displayedUserPassword.split(separator: "-").map(\.count), [4, 4, 4, 4])
        XCTAssertEqual(pair.pdfPassword, pair.displayedUserPassword)
        XCTAssertEqual(pair.pdfPassword.filter { $0 == "-" }.count, 3)
        XCTAssertNotEqual(pair.userPassword, pair.ownerPassword)
        XCTAssertTrue(pair.userPassword.allSatisfy { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) })
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

final class ThumbnailPipelineTests: XCTestCase {
    func testDownsamplingIsBoundedAndCached() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 800))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)

        let pipeline = ThumbnailPipeline(costLimit: 8 * 1_024 * 1_024)
        XCTAssertNil(pipeline.cachedImage(for: url, pointSize: CGSize(width: 100, height: 80), scale: 2))
        let loaded = await pipeline.image(for: url, pointSize: CGSize(width: 100, height: 80), scale: 2)
        let first = try XCTUnwrap(loaded)
        XCTAssertNotNil(pipeline.cachedImage(for: url, pointSize: CGSize(width: 100, height: 80), scale: 2))
        _ = await pipeline.image(for: url, pointSize: CGSize(width: 100, height: 80), scale: 2)

        XCTAssertLessThanOrEqual(max(first.size.width * first.scale, first.size.height * first.scale), 200)
        let cachedDecodeCount = await pipeline.diagnosticsDecodeCount()
        XCTAssertEqual(cachedDecodeCount, 1)
        await pipeline.clearCache()
        XCTAssertNil(pipeline.cachedImage(for: url, pointSize: CGSize(width: 100, height: 80), scale: 2))
        _ = await pipeline.image(for: url, pointSize: CGSize(width: 100, height: 80), scale: 2)
        let clearedDecodeCount = await pipeline.diagnosticsDecodeCount()
        XCTAssertEqual(clearedDecodeCount, 2)
    }
}
