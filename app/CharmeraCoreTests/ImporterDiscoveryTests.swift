import XCTest
@testable import CharmeraCore

final class ImporterDiscoveryTests: XCTestCase {
    var dcim: URL!

    override func setUpWithError() throws {
        dcim = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dcim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dcim)
    }

    private func touch(_ relativePath: String) throws {
        let url = dcim.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func testCharmeraDiscoversPictAndMovi() throws {
        try touch("100CHARM/PICT0001.JPG")
        try touch("100CHARM/MOVI0001.AVI")
        try touch("100CHARM/NOTES.TXT")
        let found = Importer().discoverFiles(in: dcim, profile: .charmera)
            .map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["MOVI0001.AVI", "PICT0001.JPG"])
    }

    func testPentaxDiscoversImgpJpgAndAvi() throws {
        try touch("101_0514/IMGP0002.JPG")
        try touch("101_0514/IMGP0013.AVI")
        try touch("100_0603/IMGP0009.JPG")
        let found = Importer().discoverFiles(in: dcim, profile: .pentaxOptioW90)
            .map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["IMGP0002.JPG", "IMGP0009.JPG", "IMGP0013.AVI"])
    }

    func testPentaxProfileIgnoresCharmeraNamedFiles() throws {
        try touch("100CHARM/PICT0001.JPG")
        let found = Importer().discoverFiles(in: dcim, profile: .pentaxOptioW90)
        XCTAssertTrue(found.isEmpty)
    }

    func testEmptyDcimDiscoversNothing() {
        let found = Importer().discoverFiles(in: dcim, profile: .pentaxOptioW90)
        XCTAssertTrue(found.isEmpty)
    }
}
