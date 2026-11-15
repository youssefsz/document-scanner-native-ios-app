import CryptoKit
import XCTest
@testable import DocScanner

@MainActor
final class SecureFolderPresentationTests: XCTestCase {
    func testAuthenticationCanFinishBeforeSceneBecomesActive() {
        let access = VaultAccess(folderID: UUID(), rootKey: SymmetricKey(size: .bits256))
        guard case .opening = SecureFolderPresentation(
            access: access, isAuthenticating: false, scenePhase: .inactive
        ) else {
            return XCTFail("Show progress while iOS returns control to the scene")
        }

        guard case .documents(let visibleAccess) = SecureFolderPresentation(
            access: access, isAuthenticating: false, scenePhase: .active
        ) else {
            return XCTFail("The active scene should open directly with the verified access")
        }
        XCTAssertTrue(visibleAccess === access)
    }

    func testActiveSceneWaitsForAuthenticationAndInvalidatedAccessStaysLocked() {
        guard case .opening = SecureFolderPresentation(
            access: nil, isAuthenticating: true, scenePhase: .active
        ) else {
            return XCTFail("Show progress if the app becomes active before authentication finishes")
        }

        let access = VaultAccess(folderID: UUID(), rootKey: SymmetricKey(size: .bits256))
        guard case .opening = SecureFolderPresentation(
            access: access, isAuthenticating: false, scenePhase: .background
        ) else {
            return XCTFail("An authorized folder cannot display documents in the background")
        }

        access.invalidate()
        guard case .locked = SecureFolderPresentation(
            access: access, isAuthenticating: false, scenePhase: .active
        ) else {
            return XCTFail("An invalidated session must display the lock screen")
        }
    }
}
