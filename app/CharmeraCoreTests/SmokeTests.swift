import Testing
@testable import CharmeraCore

@Suite struct SmokeTests {
    @Test func charmeraCoreIsImportable() {
        #expect(Config.repoName == "charmera-gallery")
    }
}
