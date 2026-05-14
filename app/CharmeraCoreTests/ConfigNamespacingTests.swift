import XCTest
@testable import CharmeraCore

final class ConfigNamespacingTests: XCTestCase {
    func testVolumeUUIDIsReadableForRootVolume() {
        // The boot volume always has a UUID; this proves the resource-key read path works.
        let root = URL(fileURLWithPath: "/")
        XCTAssertNotNil(Config.volumeUUID(for: root))
    }

    func testBackupRootIsNamespacedByProfileID() {
        let root = Config.backupRoot(for: .pentaxOptioW90)
        XCTAssertTrue(root.hasSuffix("/Pictures/Charmera/pentax-optio-w90"), root)
    }

    func testHashFilePathIsInsideBackupRoot() {
        let path = Config.hashFilePath(for: .charmera)
        XCTAssertEqual(path, Config.backupRoot(for: .charmera) + "/.imported-hashes")
    }

    func testGalleryRepoDefaultsToProfileDefault() {
        let suite = "galltest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            Config.galleryRepo(for: .pentaxOptioW90, defaults: defaults),
            "optio-w90-gallery")
    }

    func testGalleryRepoReturnsUserOverride() {
        let suite = "galltest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        Config.setGalleryRepo("my-custom-repo", for: .pentaxOptioW90, defaults: defaults)
        XCTAssertEqual(
            Config.galleryRepo(for: .pentaxOptioW90, defaults: defaults),
            "my-custom-repo")
    }
}

final class LegacyMigrationTests: XCTestCase {
    var parent: URL!

    override func setUpWithError() throws {
        parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    func testMovesDateFoldersAndHashFileIntoCharmeraSubdir() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: parent.appendingPathComponent("2026-04-01"), withIntermediateDirectories: true)
        fm.createFile(atPath: parent.appendingPathComponent("2026-04-01/PICT0001.JPG").path, contents: Data())
        fm.createFile(atPath: parent.appendingPathComponent(".imported-hashes").path,
                      contents: "PICT0001.JPG:0\n".data(using: .utf8))

        Config.migrateLegacyLayoutIfNeeded(parent: parent)

        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("charmera/2026-04-01/PICT0001.JPG").path))
        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("charmera/.imported-hashes").path))
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent("2026-04-01").path))
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent(".imported-hashes").path))
    }

    func testIsIdempotentAndLeavesProfileDirsAlone() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: parent.appendingPathComponent("charmera"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appendingPathComponent("pentax-optio-w90"), withIntermediateDirectories: true)

        Config.migrateLegacyLayoutIfNeeded(parent: parent)

        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("charmera").path))
        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("pentax-optio-w90").path))
        // No nested charmera/charmera was created.
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent("charmera/charmera").path))
    }
}
