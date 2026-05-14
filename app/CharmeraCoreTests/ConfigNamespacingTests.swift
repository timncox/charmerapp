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
