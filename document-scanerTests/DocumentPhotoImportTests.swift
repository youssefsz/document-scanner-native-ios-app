import XCTest
import UIKit
@testable import DocScanner

@MainActor
final class DocumentPhotoImportTests: XCTestCase {
    func testOrderedLoaderPreservesSelectionOrderAndReportsProgress() async throws {
        let firstImage = UIImage()
        let secondImage = UIImage()
        let thirdImage = UIImage()
        let images = [
            "first": firstImage,
            "second": secondImage,
            "third": thirdImage
        ]
        var reportedProgress: [PhotoImportProgress] = []

        let pages = try await OrderedPhotoImportLoader.load(
            ["third", "first", "second"],
            onProgress: { reportedProgress.append($0) },
            loadPhoto: { images[$0] }
        )

        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages[0] === thirdImage)
        XCTAssertTrue(pages[1] === firstImage)
        XCTAssertTrue(pages[2] === secondImage)
        XCTAssertEqual(
            reportedProgress,
            [
                PhotoImportProgress(currentPhoto: 1, totalPhotos: 3),
                PhotoImportProgress(currentPhoto: 2, totalPhotos: 3),
                PhotoImportProgress(currentPhoto: 3, totalPhotos: 3)
            ]
        )
    }

    func testOrderedLoaderStopsWithoutReturningPartialPagesWhenAnItemFails() async {
        var attemptedSelections: [Int] = []

        do {
            _ = try await OrderedPhotoImportLoader.load(
                [1, 2, 3],
                onProgress: { _ in },
                loadPhoto: { selection in
                    attemptedSelections.append(selection)
                    return selection == 2 ? nil : UIImage()
                }
            )
            XCTFail("Expected the second photo to fail")
        } catch {
            XCTAssertEqual(
                error as? DocumentPhotoImportError,
                .couldNotLoadPhoto(position: 2)
            )
        }

        XCTAssertEqual(attemptedSelections, [1, 2])
    }

    func testOrderedLoaderConvertsProviderErrorsIntoAUsefulPhotoPosition() async {
        struct ProviderError: Error {}

        do {
            _ = try await OrderedPhotoImportLoader.load(
                ["first", "second"],
                onProgress: { _ in },
                loadPhoto: { selection in
                    if selection == "second" { throw ProviderError() }
                    return UIImage()
                }
            )
            XCTFail("Expected the provider error to be reported")
        } catch {
            XCTAssertEqual(
                error as? DocumentPhotoImportError,
                .couldNotLoadPhoto(position: 2)
            )
        }
    }
}
