import XCTest
@testable import CharmeraCore

final class ConfigNamespacingTests: XCTestCase {
    func testVolumeUUIDIsReadableForRootVolume() {
        // The boot volume always has a UUID; this proves the resource-key read path works.
        let root = URL(fileURLWithPath: "/")
        XCTAssertNotNil(Config.volumeUUID(for: root))
    }
}
