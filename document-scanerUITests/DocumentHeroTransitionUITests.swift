import XCTest

final class DocumentHeroTransitionUITests: XCTestCase {
    func testDocumentOpensAndClosesFromLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        let documentCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-card-"))
        let firstCard = documentCards.firstMatch
        guard firstCard.waitForExistence(timeout: 10) else {
            throw XCTSkip("This device has no library document available for the transition test.")
        }

        let librarySections = app.segmentedControls["library-section-picker"]
        XCTAssertTrue(librarySections.waitForExistence(timeout: 10))
        let closeButton = app.buttons["document-viewer-close"]
        for attempt in 1...4 {
            firstCard.tap()
            XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
            if attempt == 1 {
                let viewerScreenshot = XCTAttachment(screenshot: app.screenshot())
                viewerScreenshot.name = "Document viewer"
                viewerScreenshot.lifetime = .keepAlways
                add(viewerScreenshot)
            }
            closeButton.tap()
            XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
            XCTAssertTrue(librarySections.waitForExistence(timeout: 10), "Library sections disappeared after closing the viewer")
            XCTAssertFalse(closeButton.exists)
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
}
