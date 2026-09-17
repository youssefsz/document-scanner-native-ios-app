import XCTest

final class DocumentHeroTransitionUITests: XCTestCase {
    func testDocumentOpensAndClosesFromLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-documentPerformanceFixture")
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()

        let documentCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-card-"))
        let firstCard = documentCards.firstMatch
        guard firstCard.waitForExistence(timeout: 10) else {
            throw XCTSkip("This device has no library document available for the transition test.")
        }

        let librarySections = app.segmentedControls["library-section-picker"]
        XCTAssertTrue(librarySections.waitForExistence(timeout: 10))
        let closeButton = app.buttons["document-viewer-close"]
        let pageViewer = app.otherElements["document-page-pager"]
        for attempt in 1...4 {
            firstCard.tap()
            XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
            XCTAssertTrue(pageViewer.waitForExistence(timeout: 10), "The document's first page did not load")
            if attempt == 1 {
                let viewerScreenshot = XCTAttachment(screenshot: app.screenshot())
                viewerScreenshot.name = "Document viewer"
                viewerScreenshot.lifetime = .keepAlways
                add(viewerScreenshot)
            }
            closeButton.tap()
            XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
            XCTAssertTrue(librarySections.waitForExistence(timeout: 10), "Library sections disappeared after closing the viewer")
            let viewerDismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: closeButton
            )
            XCTAssertEqual(XCTWaiter.wait(for: [viewerDismissed], timeout: 10), .completed)
        }

        let libraryScreenshot = XCTAttachment(screenshot: app.screenshot())
        libraryScreenshot.name = "Library after repeated viewer dismissals"
        libraryScreenshot.lifetime = .keepAlways
        add(libraryScreenshot)

        librarySections.buttons["Folders"].tap()
        XCTAssertTrue(librarySections.buttons["Folders"].isSelected)
        librarySections.buttons["Library"].tap()
        XCTAssertTrue(librarySections.buttons["Library"].isSelected)
    }

    func testDocumentOpensAndClosesFromOrdinaryFolder() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-documentPerformanceFixture")
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()
        let librarySections = app.segmentedControls["library-section-picker"]
        XCTAssertTrue(librarySections.waitForExistence(timeout: 10))
        librarySections.buttons["Folders"].tap()

        let populatedFolders = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label MATCHES %@",
            "folder-card-", ".*, [1-9][0-9]* documents?"
        ))
        let folder = populatedFolders.firstMatch
        guard folder.waitForExistence(timeout: 5) else {
            throw XCTSkip("This device has no populated ordinary folder for the transition test.")
        }
        folder.tap()

        let documentCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-card-"))
        let firstCard = documentCards.firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        let closeButton = app.buttons["document-viewer-close"]
        let pageViewer = app.otherElements["document-page-pager"]
        for _ in 1...2 {
            firstCard.tap()
            XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
            XCTAssertTrue(pageViewer.waitForExistence(timeout: 10))
            closeButton.tap()
            XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        }
    }
}
