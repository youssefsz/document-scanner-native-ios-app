import XCTest
@testable import DocScanner

final class DocumentHeroTransitionTests: XCTestCase {
    func testZoomIsUsedWhenAvailableAndMotionIsAllowed() {
        XCTAssertTrue(DocumentHeroTransition.usesZoom(supportsZoom: true, reduceMotion: false))
    }

    func testReduceMotionKeepsTheStandardPresentation() {
        XCTAssertFalse(DocumentHeroTransition.usesZoom(supportsZoom: true, reduceMotion: true))
    }

    func testOlderSystemsKeepTheStandardPresentation() {
        XCTAssertFalse(DocumentHeroTransition.usesZoom(supportsZoom: false, reduceMotion: false))
    }
}
