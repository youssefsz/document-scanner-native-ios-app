import XCTest
import UIKit
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
