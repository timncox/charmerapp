import XCTest
@testable import CharmeraCore

final class CameraProfileTests: XCTestCase {
    func testRegistryHasCharmeraAndPentax() {
        let ids = CameraRegistry.all.map { $0.id }
        XCTAssertEqual(ids, ["charmera", "pentax-optio-w90"])
    }

    func testCharmeraProfileFields() {
        let p = CameraRegistry.profile(id: "charmera")!
        XCTAssertEqual(p.markerFolders, ["DCIM", "SPIDCIM"])
        XCTAssertEqual(p.photoNamePrefix, "PICT")
        XCTAssertEqual(p.videoNamePrefix, "MOVI")
        XCTAssertEqual(p.orientationStrategy, .vision)
        XCTAssertTrue(p.videoNeedsConversion)
        XCTAssertEqual(p.defaultGalleryRepo, "charmera-gallery")
    }

    func testPentaxProfileFields() {
        let p = CameraRegistry.profile(id: "pentax-optio-w90")!
        XCTAssertEqual(p.markerFolders, ["DCIM", "FRAME"])
        XCTAssertEqual(p.photoNamePrefix, "IMGP")
        XCTAssertEqual(p.videoNamePrefix, "IMGP")
        XCTAssertEqual(p.videoExtensions, ["avi"])
        XCTAssertEqual(p.orientationStrategy, .exif)
        XCTAssertEqual(p.exifMakeMatch, "PENTAX")
        XCTAssertEqual(p.exifModelContains, "Optio W90")
        XCTAssertEqual(p.defaultGalleryRepo, "optio-w90-gallery")
    }

    func testProfileLookupUnknownIsNil() {
        XCTAssertNil(CameraRegistry.profile(id: "nope"))
    }
}
