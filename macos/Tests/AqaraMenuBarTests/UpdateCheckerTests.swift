import XCTest
@testable import AqaraMenuBar

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0", than: "0.0.0-dev"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
    }
}
