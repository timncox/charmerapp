import XCTest
@testable import CharmeraCore

final class SmokeTests: XCTestCase {
    func testCharmeraCoreIsImportable() {
        XCTAssertEqual(Config.repoName, "charmera-gallery")
    }
}
