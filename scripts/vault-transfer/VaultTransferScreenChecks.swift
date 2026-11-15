// Installed in the temporary UI test target by screens.sh. No production hooks.
import XCTest

final class VaultTransferScreenChecks: XCTestCase {
    func testMissingKeyOffersRecoveryWithoutPro() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-lastSeenMajorIntroduction", "2"]
        app.launch()

        let sections = app.segmentedControls["library-section-picker"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Unlock Now"].exists)
        sections.buttons["Folders"].tap()
        XCTAssertFalse(app.buttons["vault-transfer-reminder-row"].exists)
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder-card-")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()

        let recover = app.buttons["Restore Vault Backup"]
        XCTAssertTrue(app.staticTexts["Vault recovery needed"].waitForExistence(timeout: 10))
        XCTAssertTrue(recover.exists)
        capture("Missed bridge recovery", app)
        recover.tap()
        XCTAssertTrue(app.buttons["Choose Vault Backup"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Create Encrypted Backup"].exists)
        capture("Restore vault backup", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(recover.waitForExistence(timeout: 5))
    }

    func testSettingsOffersRecoveryWithoutPro() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-lastSeenMajorIntroduction", "2"]
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let entry = app.buttons["Vault Transfer & Backup"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["Choose Vault Backup"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Create Encrypted Backup"].isEnabled)
        capture("Vault transfer and backup", app)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}


final class VaultTransferReminderScreenChecks: XCTestCase {
    func testReminderSnoozesThenUnlocksAndStaysHiddenAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-lastSeenMajorIntroduction", "2", "-vaultTransferReminderDeferredUntil", "0"]
        app.launch()
        let unlock = app.buttons["Unlock Now"]
        let later = app.buttons["Remind Me Later"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 12))
        capture("Bridge reminder", app)

        later.tap()
        let folders = app.segmentedControls["library-section-picker"].buttons["Folders"]
        XCTAssertTrue(folders.waitForExistence(timeout: 8))
        app.terminate()
        app.launchArguments = ["-lastSeenMajorIntroduction", "2"]
        app.launch()
        XCTAssertTrue(folders.waitForExistence(timeout: 8))
        XCTAssertFalse(unlock.exists)
        folders.tap()
        let row = app.buttons["vault-transfer-reminder-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        capture("Folders reminder after snooze", app)

        // Remove the deferral for this launch to exercise Unlock Now.
        app.terminate()
        app.launchArguments += ["-vaultTransferReminderDeferredUntil", "0"]
        app.launch()
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        unlock.tap()
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Vault transfer sample")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))

        app.buttons["Secure Folder Actions"].tap()
        app.buttons["Vault Transfer & Backup"].tap()
        XCTAssertTrue(app.staticTexts["Ready for transfer"].waitForExistence(timeout: 8))
        capture("Verified vault and backup options", app)
        app.buttons["Create Encrypted Backup"].tap()
        let savedCode = app.buttons["vault-backup-code-saved"]
        XCTAssertTrue(savedCode.waitForExistence(timeout: 20))
        savedCode.tap()
        let export = app.descendants(matching: .any)["vault-backup-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        XCTAssertFalse(savedCode.exists)
        capture("Encrypted backup ready to export", app)

        app.terminate()
        app.launch()
        XCTAssertTrue(folders.waitForExistence(timeout: 8))
        XCTAssertFalse(unlock.exists)
        folders.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "folder-card-"
        )).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(row.exists)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

final class VaultReauthenticationScreenChecks: XCTestCase {
    func testSecureFolderRelocksInBackgroundAndReopensAfterVerification() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-lastSeenMajorIntroduction", "2"]
        app.launch()

        let sections = app.segmentedControls["library-section-picker"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        sections.buttons["Folders"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder-card-")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()

        let document = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Vault transfer sample")
        ).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 20))
        XCUIDevice.shared.press(.home)
        app.activate()

        let locked = app.staticTexts["Folder locked"]
        XCTAssertTrue(locked.waitForExistence(timeout: 10))
        XCTAssertFalse(document.exists)
        app.buttons["Unlock Transfer QA"].tap()

        XCTAssertTrue(document.waitForExistence(timeout: 20))
        XCTAssertFalse(locked.exists)
    }
}
