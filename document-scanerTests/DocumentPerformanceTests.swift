import PDFKit
import Darwin
import UIKit
import XCTest
@testable import DocScanner

final class DocumentPerformanceTests: XCTestCase {
    func testHundredPageSessionRendersOnlyRequestedPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hundred-pages.pdf")
        try makePDF(pageCount: 100, at: url)

        let session = try await DocumentPageSession.open(from: .url(url))
        XCTAssertEqual(session.pageCount, 100)
        for index in [0, 50, 99] {
            let page = try await session.page(at: index)
            XCTAssertEqual(page.id, index)
            XCTAssertNotNil(page.image.cgImage)
        }
        let diagnostics = await session.diagnostics()
        XCTAssertEqual(diagnostics.renderCount, 3)
        XCTAssertLessThanOrEqual(diagnostics.cachedBytes, 48 * 1024 * 1024)
        XCTAssertLessThanOrEqual(diagnostics.cachedPageCount, 3)
    }

    func testTwentyPageViewerMemoryFootprint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageMemory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("twenty-pages.pdf")
        try makeStressPDF(pageCount: 20, at: url)
        let before = try physicalFootprint()

        let session = try await DocumentPageSession.open(from: .url(url))
        var visiblePages: [DocumentPageSnapshot] = []
        for index in 0..<3 {
            visiblePages.append(try await session.page(at: index))
        }
        try await Task.sleep(for: .seconds(2))
        let after = try physicalFootprint()
        let stats = await session.diagnostics()
        XCTAssertEqual(visiblePages.count, 3)
        XCTAssertEqual(stats.renderCount, 3)
        attachMemoryMeasurement(before: before, after: after, name: "new-viewer-memory")
        withExtendedLifetime(visiblePages) {}
    }

    func testExportRasterUsesRequestedResolutionForStandardPDFPage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFResolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.pdf")
        try makePDF(pageCount: 1, at: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        defer { withExtendedLifetime(document) {} }
        let page = try XCTUnwrap(document.page(at: 0))

        let low = try SearchablePDFRenderer.renderUprightRaster(from: page, maxDimension: 1280)
        let high = try SearchablePDFRenderer.renderUprightRaster(from: page, maxDimension: 2240)
        XCTAssertEqual(max(low.cgImage.width, low.cgImage.height), 1280)
        XCTAssertEqual(max(high.cgImage.width, high.cgImage.height), 2240)
    }

    @MainActor
    func testRecompressedRasterPreservesPageGeometry() async throws {
        let original = try ScanPageRasterizer.makeUprightRaster(from: makeScanImage())

        for quality in DocumentExportQuality.allCases {
            let decoded = try await ScanPageRasterizer.recompressedRaster(
                from: original,
                compressionQuality: quality.jpegCompressionQuality
            )
            XCTAssertEqual(decoded.size, original.size)
            XCTAssertEqual(decoded.pageRect, original.pageRect)
            XCTAssertEqual(decoded.image.imageOrientation, .up)
        }
    }

    func testScanAndEveryExportQualityProduceReadablePDFs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentPipeline-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(rootDirectory: directory)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = CoreDataLibraryRepository(paths: paths, inMemory: true)
        let store = DocumentStore(repository: repository, paths: paths)
        let service = DocumentExportService(store: store, paths: paths)
        let image = makeScanImage()
        let saved = try await store.saveScan(pages: [image, image, image], title: "Performance scan")
        let document = try XCTUnwrap(saved.first)
        XCTAssertEqual(PDFDocument(url: document.pdfURL(in: paths))?.pageCount, 3)
        XCTAssertTrue(PDFSearchInspector.hasSearchableText(at: document.pdfURL(in: paths)))

        for quality in DocumentExportQuality.allCases {
            let export = try await service.prepareExport(for: document, quality: quality)
            XCTAssertEqual(export.quality, quality)
            XCTAssertGreaterThan(export.fileSizeBytes, 0)
            let fileSize = try XCTUnwrap(
                (FileManager.default.attributesOfItem(atPath: export.url.path)[.size] as? NSNumber)?.int64Value
            )
            XCTAssertEqual(export.fileSizeBytes, fileSize)
            XCTAssertEqual(PDFDocument(url: export.url)?.pageCount, 3)
            XCTAssertTrue(PDFSearchInspector.hasSearchableText(at: export.url))
        }
        await service.removeTemporaryExports(for: document)
        XCTAssertEqual(PDFDocument(url: document.pdfURL(in: paths))?.pageCount, 3)
    }

    func testTwentyPagePhotoExportOnIsolatedDeviceApp() async throws {
        guard Bundle.main.bundleIdentifier == "tn.document-scaner.performance" else {
            throw XCTSkip("Runs only in the separately installed performance app.")
        }
        let repository = CoreDataLibraryRepository()
        try await repository.bootstrap()
        let documents = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        guard let document = documents.first(where: { $0.title == "Performance 20 photo pages" }) else {
            throw XCTSkip("The disposable 20-page fixture has not been generated yet.")
        }
        let service = DocumentExportService()
        do {
            for quality in [DocumentExportQuality.high, .veryHigh] {
                let export = try await service.prepareExport(for: document, quality: quality)
                XCTAssertEqual(PDFDocument(url: export.url)?.pageCount, 20)
                XCTAssertGreaterThan(export.fileSizeBytes, 0)
            }
        } catch {
            await service.removeTemporaryExports(for: document)
            throw error
        }
        await service.removeTemporaryExports(for: document)
    }

    func testCancelledLargeExportDoesNotLeavePartialPDF() async throws {
        guard Bundle.main.bundleIdentifier == "tn.document-scaner.performance" else {
            throw XCTSkip("Runs only in the separately installed performance app.")
        }
        let repository = CoreDataLibraryRepository()
        try await repository.bootstrap()
        let documents = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        guard let document = documents.first(where: { $0.title == "Performance 100 pages" }) else {
            throw XCTSkip("The disposable 100-page fixture has not been generated yet.")
        }
        let service = DocumentExportService()
        await service.removeTemporaryExports(for: document)
        let task = Task {
            try await service.prepareExport(for: document, quality: .high)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The large export completed after cancellation")
        } catch is CancellationError {
            // Expected: the next page boundary stops the export.
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentExports", isDirectory: true)
            .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Cancelled export left temporary files")
    }

    private func makePDF(pageCount: Int, at url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
            for index in 0..<pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24),
                    .foregroundColor: UIColor.black,
                ])
            }
        }
    }

    private func makeStressPDF(pageCount: Int, at url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
            for index in 0..<pageCount {
                context.beginPage()
                let image = randomPageImage(seed: UInt32(index + 1))
                context.cgContext.draw(image, in: bounds)
            }
        }
    }

    private func randomPageImage(seed initialSeed: UInt32) -> CGImage {
        let width = 400
        let height = 560
        var seed = initialSeed
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[offset] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: seed)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    private func makeScanImage() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("SCANNED DOCUMENT" as NSString).draw(at: CGPoint(x: 80, y: 80), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 54),
                .foregroundColor: UIColor.black,
            ])
            ("Performance test page" as NSString).draw(at: CGPoint(x: 80, y: 175), withAttributes: [
                .font: UIFont.systemFont(ofSize: 40),
                .foregroundColor: UIColor.black,
            ])
        }
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw NSError(domain: "MemoryProbe", code: Int(result)) }
        return info.phys_footprint
    }

    private func attachMemoryMeasurement(before: UInt64, after: UInt64, name: String) {
        let values: [String: Int64] = [
            "beforeBytes": Int64(before),
            "afterBytes": Int64(after),
            "deltaBytes": Int64(after) - Int64(before),
        ]
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
