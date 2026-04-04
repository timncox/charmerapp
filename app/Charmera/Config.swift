import Foundation

enum Config {
    static let cameraVolumePath = "/Volumes/Charmera/DCIM"

    static let localBackupRoot: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Charmera"
    }()

    static let hashFilePath: String = { "\(localBackupRoot)/.imported-hashes" }()

    static let appSupportDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/Charmera"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let githubClientID = "Ov23liHp3TaFjD42UIUc"
    static let authProxyURL = "https://charmera-auth.vercel.app/api/github"
    static let githubCallbackScheme = "charmera"
    static let repoName = "charmera-gallery"
}
