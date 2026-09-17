#if DEBUG
import Foundation
import UIKit

/// Disposable documents for the separately installed performance build only.
enum PerformanceFixture {
    static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "tn.document-scaner.performance" &&
        ProcessInfo.processInfo.arguments.contains("-documentPerformanceFixture")
    }

    static func seedIfNeeded() async throws {
        guard isEnabled else { return }
        let paths = StoragePaths.production
        let marker = paths.rootDirectory.appendingPathComponent("performance-fixture-v3")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        try paths.prepare()
        let repository = CoreDataLibraryRepository(paths: paths)
        try await repository.bootstrap()
        let existing = try await repository.fetchDocuments(scope: .all, query: "", sort: .newestFirst)
        var titles = Set(existing.map(\.title))

        let fixtures: [(String, Int, Bool)] = [
            ("Performance 100 pages", 100, false),
            ("Performance 20 photo pages", 20, true),
            ("Performance 1 photo page", 1, true),
        ]
        for (offset, fixture) in fixtures.enumerated() {
            guard !titles.contains(fixture.0) else { continue }
            let filename = "performance-\(fixture.1)-\(fixture.2 ? "photo" : "vector")"
            let pdfURL = paths.filesDirectory.appendingPathComponent(filename + ".pdf")
            let previewURL = paths.filesDirectory.appendingPathComponent(filename + "-preview.jpg")
            try writePDF(to: pdfURL, pageCount: fixture.1, photoPages: fixture.2)
            try writePreview(to: previewURL, photoPages: fixture.2)
            try await repository.createDocument(ScannedDocument(
                title: fixture.0,
                createdAt: Date().addingTimeInterval(Double(100 - offset)),
                pageCount: fixture.1,
                pdfFilename: pdfURL.lastPathComponent,
                previewFilename: previewURL.lastPathComponent
            ))
            titles.insert(fixture.0)
        }

        // Refresh the image-heavy fixture when an earlier test build seeded it.
        let photoPDF = paths.filesDirectory.appendingPathComponent("performance-20-photo.pdf")
        try writePDF(to: photoPDF, pageCount: 20, photoPages: true)

        let sourcePDF = paths.filesDirectory.appendingPathComponent("performance-1-photo.pdf")
        let sourcePreview = paths.filesDirectory.appendingPathComponent("performance-1-photo-preview.jpg")
        for index in 0..<150 {
            try Task.checkCancellation()
            let title = String(format: "Performance archive %03d", index)
            guard !titles.contains(title) else { continue }
            let stem = String(format: "performance-archive-%03d", index)
            let pdfURL = paths.filesDirectory.appendingPathComponent(stem + ".pdf")
            let previewURL = paths.filesDirectory.appendingPathComponent(stem + "-preview.jpg")
            try FileManager.default.copyItem(at: sourcePDF, to: pdfURL)
            try FileManager.default.copyItem(at: sourcePreview, to: previewURL)
            try await repository.createDocument(ScannedDocument(
                title: title,
                createdAt: Date().addingTimeInterval(Double(-index - 1)),
                pageCount: 1,
                pdfFilename: pdfURL.lastPathComponent,
                previewFilename: previewURL.lastPathComponent
            ))
            titles.insert(title)
        }
        let folderName = "Performance folder"
        let folders = try await repository.fetchFolders(query: folderName)
        let folder: DocumentFolder
        if let existing = folders.first(where: { $0.folder.name == folderName }) {
            folder = existing.folder
        } else {
            folder = try await repository.createFolder(name: folderName)
        }
        let documents = try await repository.fetchDocuments(scope: .all, query: "Performance 1 photo page", sort: .newestFirst)
        if let document = documents.first(where: { $0.title == "Performance 1 photo page" }),
           document.folderID != folder.id {
            try await repository.moveDocuments(ids: [document.id], to: folder.id)
        }
        try Data("ready".utf8).write(to: marker, options: .atomic)
    }

    private static func writePDF(to url: URL, pageCount: Int, photoPages: Bool) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for index in 0..<pageCount {
                context.beginPage()
                if photoPages {
                    let image = sampleImage(seed: UInt32(index + 1))
                    image.draw(in: bounds)
                } else {
                    UIColor.white.setFill()
                    context.fill(bounds)
                    UIColor.darkGray.setStroke()
                    for row in 0..<38 {
                        let y = CGFloat(50 + row * 18)
                        let width = CGFloat(430 + (row % 5) * 18)
                        UIBezierPath(rect: CGRect(x: 55, y: y, width: width, height: 1)).stroke()
                    }
                }
                let label = "Test document · page \(index + 1) of \(pageCount)"
                (label as NSString).draw(at: CGPoint(x: 55, y: 25), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: UIColor.black,
                ])
            }
        }
    }

    private static func writePreview(to url: URL, photoPages: Bool) throws {
        let image = sampleImage(seed: photoPages ? 1 : 0)
        let size = CGSize(width: 450, height: 600)
        let preview = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = preview.jpegData(compressionQuality: 0.7) else {
            throw DocumentStoreError.previewCreationFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func sampleImage(seed initialSeed: UInt32) -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            var seed = initialSeed
            for row in 0..<70 {
                for column in 0..<52 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let component = CGFloat(seed & 0xff) / 255
                    UIColor(red: component, green: 0.3 + component * 0.35, blue: 0.35 + component * 0.25, alpha: 1).setFill()
                    context.fill(CGRect(x: column * 24, y: row * 24, width: 24, height: 24))
                }
            }
            UIColor.white.withAlphaComponent(0.88).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            for row in 0..<52 {
                let y = CGFloat(95 + row * 27)
                let width = CGFloat(920 + (row % 7) * 25)
                UIBezierPath(rect: CGRect(x: 110, y: y, width: width, height: 2)).stroke()
            }
            ("PERFORMANCE SCAN" as NSString).draw(at: CGPoint(x: 110, y: 40), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 30),
                .foregroundColor: UIColor.black,
            ])
        }
    }
}
#endif
