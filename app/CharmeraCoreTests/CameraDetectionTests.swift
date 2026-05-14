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

final class CameraMemoryTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        suiteName = "cammemtest-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUnknownVolumeReturnsNil() {
        let mem = CameraMemory(defaults: defaults)
        XCTAssertNil(mem.profile(forVolumeUUID: "ABC-123"))
    }

    func testRememberThenRecall() {
        let mem = CameraMemory(defaults: defaults)
        mem.remember(profileID: "pentax-optio-w90", forVolumeUUID: "ABC-123")
        XCTAssertEqual(mem.profile(forVolumeUUID: "ABC-123")?.id, "pentax-optio-w90")
    }

    func testRememberOverwrites() {
        let mem = CameraMemory(defaults: defaults)
        mem.remember(profileID: "charmera", forVolumeUUID: "ABC-123")
        mem.remember(profileID: "pentax-optio-w90", forVolumeUUID: "ABC-123")
        XCTAssertEqual(mem.profile(forVolumeUUID: "ABC-123")?.id, "pentax-optio-w90")
    }

    func testRememberUnknownProfileIDRecallsNil() {
        let mem = CameraMemory(defaults: defaults)
        mem.remember(profileID: "bogus", forVolumeUUID: "ABC-123")
        XCTAssertNil(mem.profile(forVolumeUUID: "ABC-123"))
    }
}

final class DetectionChainTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chain-\(UUID().uuidString)")
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

    func testRememberedMappingWins() throws {
        let vol = try makeVolume("NO NAME", folders: ["DCIM", "FRAME"])
        let result = CameraDetection.resolve(
            volumeRoot: vol,
            volumeUUID: "UUID-1",
            rememberedProfileID: { _ in "charmera" })
        // Remembered mapping ("charmera") beats the folder markers ("pentax").
        XCTAssertEqual(result, .resolved(.charmera))
    }

    func testFolderMarkersUsedWhenNoMemory() throws {
        let vol = try makeVolume("NO NAME", folders: ["DCIM", "FRAME"])
        let result = CameraDetection.resolve(
            volumeRoot: vol,
            volumeUUID: "UUID-1",
            rememberedProfileID: { _ in nil })
        XCTAssertEqual(result, .resolved(.pentaxOptioW90))
    }

    func testUnknownVolumeNeedsUser() throws {
        let vol = try makeVolume("SDCARD", folders: ["DCIM"])
        let result = CameraDetection.resolve(
            volumeRoot: vol,
            volumeUUID: "UUID-2",
            rememberedProfileID: { _ in nil })
        XCTAssertEqual(result, .needsUserChoice)
    }
}
