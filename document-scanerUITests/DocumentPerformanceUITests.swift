import XCTest

final class DocumentPerformanceUITests: XCTestCase {
    func testTwentyPageMemoryDelta() throws {
        let app = performanceApp()
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()
        let card = documentCard(named: "Performance 20 photo pages", in: app)
        guard card.waitForExistence(timeout: 120) else {
            throw XCTSkip("The isolated performance fixture is not installed on this run destination.")
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            card.tap()
            XCTAssertTrue(app.staticTexts["Page 1 of 20"].waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: 30)
        }
        app.buttons["document-viewer-close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
    }

    func testHundredPageMemoryDelta() throws {
        let app = performanceApp()
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()
        let card = documentCard(named: "Performance 100 pages", in: app)
        guard card.waitForExistence(timeout: 120) else {
            throw XCTSkip("The isolated performance fixture is not installed on this run destination.")
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), XCTClockMetric()], options: options) {
            card.tap()
            XCTAssertTrue(app.staticTexts["Page 1 of 100"].waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: 5)
        }
        app.buttons["document-viewer-close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
    }

    func testHundredPagePreviewCanScrollAndReopen() throws {
        let app = performanceApp()
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()

        let card = documentCard(named: "Performance 100 pages", in: app)
        guard card.waitForExistence(timeout: 120) else {
            throw XCTSkip("The isolated performance fixture is not installed on this run destination.")
        }

        let viewer = app.otherElements["document-page-pager"]
        let close = app.buttons["document-viewer-close"]
        for attempt in 1...3 {
            card.tap()
            XCTAssertTrue(viewer.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["Page 1 of 100"].waitForExistence(timeout: 20))
            if attempt == 1 {
                Thread.sleep(forTimeInterval: 12)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "100-page document after 12 seconds"
                attachment.lifetime = .keepAlways
                add(attachment)
                viewer.swipeUp()
                XCTAssertTrue(app.staticTexts["Page 2 of 100"].waitForExistence(timeout: 10))
            }
            close.tap()
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertTrue(app.segmentedControls["library-section-picker"].waitForExistence(timeout: 10))
        }
    }

    func testShareSheetRemainsUsableForPhotoDocument() throws {
        let app = performanceApp()
        app.launch()
        dismissSystemSignInIfPresent()
        app.activate()

        let card = documentCard(named: "Performance 20 photo pages", in: app)
        guard card.waitForExistence(timeout: 120) else {
            throw XCTSkip("The isolated performance fixture is not installed on this run destination.")
        }
        card.tap()
        XCTAssertTrue(app.staticTexts["Page 1 of 20"].waitForExistence(timeout: 20))
        let share = app.buttons["document-viewer-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        XCTAssertTrue(app.navigationBars["Share PDF"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["document-viewer-close"].waitForExistence(timeout: 10))
    }

    private func performanceApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-documentPerformanceFixture")
        return app
    }

    private func documentCard(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }
}

func dismissSystemSignInIfPresent() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let signIn = springboard.alerts["Sign in to Apple Account"]
    let cancel = signIn.buttons["Cancel"]
    if signIn.waitForExistence(timeout: 2), cancel.exists {
        cancel.tap()
    }
}
