import XCTest
@testable import CharmeraCore

final class CameraDetectionTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("camdetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeVolume(_ name: String, folders: [String]) throws -> URL {
        let vol = tmp.appendingPathComponent(name)
        for f in folders {
            try FileManager.default.createDirectory(
                at: vol.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        return vol
    }

    func testCharmeraMarkersMatchCharmeraProfile() throws {
        let vol = try makeVolume("CHARMERA", folders: ["DCIM", "SPIDCIM"])
        XCTAssertEqual(CameraDetection.profileByMarkers(volumeRoot: vol)?.id, "charmera")
    }

    func testPentaxMarkersMatchPentaxProfile() throws {
        let vol = try makeVolume("NO NAME", folders: ["DCIM", "FRAME"])
        XCTAssertEqual(CameraDetection.profileByMarkers(volumeRoot: vol)?.id, "pentax-optio-w90")
    }

    func testBareDcimMatchesNothing() throws {
        let vol = try makeVolume("SDCARD", folders: ["DCIM"])
        XCTAssertNil(CameraDetection.profileByMarkers(volumeRoot: vol))
    }

    func testNoDcimMatchesNothing() throws {
        let vol = try makeVolume("USBSTICK", folders: ["Documents"])
        XCTAssertNil(CameraDetection.profileByMarkers(volumeRoot: vol))
    }

    func testExifPentaxMakeModelMatchesPentax() {
        let p = CameraDetection.profileByEXIF(make: "PENTAX", model: "PENTAX Optio W90")
        XCTAssertEqual(p?.id, "pentax-optio-w90")
    }

    func testExifWrongMakeMatchesNothing() {
        XCTAssertNil(CameraDetection.profileByEXIF(make: "Canon", model: "PowerShot"))
    }

    func testExifNilValuesMatchNothing() {
        XCTAssertNil(CameraDetection.profileByEXIF(make: nil, model: nil))
    }

    func testExifMakeMatchButModelMismatchMatchesNothing() {
        XCTAssertNil(CameraDetection.profileByEXIF(make: "PENTAX", model: "Optio E70"))
    }
}
