import XCTest
@testable import DocScanner

final class V2OnboardingPresentationTests: XCTestCase {
    func testPresentsAfterSuccessfulLibraryLoadWhenIntroductionHasNotBeenSeen() {
        XCTAssertTrue(
            V2OnboardingPresentation.shouldPresent(
                lastSeenMajorIntroduction: 0,
                loadState: .loaded
            )
        )
        XCTAssertTrue(
            V2OnboardingPresentation.shouldPresent(
                lastSeenMajorIntroduction: 1,
                loadState: .empty
            )
        )
    }

    func testDoesNotPresentWhileLoadingMigratingOrRecovering() {
        let unavailableStates: [LibraryLoadState] = [
            .initialLoading,
            .migrating,
            .migrationFailed("Migration failed"),
            .failed("Load failed")
        ]

        for state in unavailableStates {
            XCTAssertFalse(
                V2OnboardingPresentation.shouldPresent(
                    lastSeenMajorIntroduction: 0,
                    loadState: state
                )
            )
        }
    }

    func testDoesNotPresentAfterVersionTwoHasBeenSeen() {
        XCTAssertFalse(
            V2OnboardingPresentation.shouldPresent(
                lastSeenMajorIntroduction: 2,
                loadState: .loaded
            )
        )
        XCTAssertFalse(
            V2OnboardingPresentation.shouldPresent(
                lastSeenMajorIntroduction: 3,
                loadState: .empty
            )
        )
    }
}
