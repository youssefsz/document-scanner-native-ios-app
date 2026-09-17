import XCTest

final class DocumentHeroTransitionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPreviewActionsAndPageNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-documentPerformanceFixture")
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Performance 20 photo pages")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 120), "Run with the isolated performance bundle to seed documents.")
        card.tap()
        let count = app.staticTexts["document-viewer-page-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertEqual(count.label, "Page 1 of 20")
        let share = app.buttons["document-viewer-share"]
        XCTAssertTrue(share.isHittable)
        XCTAssertLessThan(count.frame.maxX, share.frame.minX)
        attachPreview(app, name: "Native preview toolbar")

        let more = app.buttons["document-viewer-more"]
        let close = app.buttons["document-viewer-close"]
        XCTAssertEqual(close.frame.width, more.frame.width, accuracy: 1)
        XCTAssertEqual(close.frame.height, more.frame.height, accuracy: 1)
        let pager = app.otherElements["document-page-pager"]
        let pageCenter = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        pageCenter.tap()
        attachPreview(app, name: "Immediately after document tap")
        let controlsHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: more)
        XCTAssertEqual(XCTWaiter.wait(for: [controlsHidden], timeout: 5), .completed)
        attachPreview(app, name: "Preview with controls hidden")
        pageCenter.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        pager.swipeUp()
        XCTAssertTrue(app.staticTexts["Page 2 of 20"].waitForExistence(timeout: 10))

        more.tap()
        let rename = app.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete Document"].exists)
        attachPreview(app, name: "Native document menu")
        rename.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "Performance 20 photo pages")
        app.buttons["Cancel"].tap()

        more.tap()
        app.buttons["Delete Document"].tap()
        XCTAssertTrue(app.staticTexts["Delete this document?"].waitForExistence(timeout: 5))
        attachPreview(app, name: "Native delete confirmation")
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // Newer systems use a popover dismissed by tapping outside it.
            pager.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        }
        attachPreview(app, name: "Preview after cancelling deletion")
        let confirmationDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == false"),
            object: app.buttons["Delete Document"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [confirmationDismissed], timeout: 5), .completed)
        if !share.isHittable { pageCenter.tap() }
        XCTAssertTrue(share.isHittable)

        share.tap()
        XCTAssertTrue(app.navigationBars["Share PDF"].waitForExistence(timeout: 10))
        attachPreview(app, name: "PDF export options")
        app.buttons["Cancel"].tap()

        app.buttons["document-viewer-close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
    }

    func testPreviewActionsAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-documentPerformanceFixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Performance 20 photo pages")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 120))
        card.tap()
        let count = app.staticTexts["document-viewer-page-count"]
        let share = app.buttons["document-viewer-share"]
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertTrue(share.isHittable)
        XCTAssertLessThan(count.frame.maxY, share.frame.minY)
        XCTAssertLessThanOrEqual(share.frame.maxX, app.frame.maxX)
        attachPreview(app, name: "Preview with accessibility text")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share PDF"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.buttons["document-viewer-close"].tap()
    }

    private func attachPreview(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
