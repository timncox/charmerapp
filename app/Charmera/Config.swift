import Foundation

enum Config {
    static let cameraVolumePath = "/Volumes/Charmera/DCIM"

    static let localBackupRoot: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Charmera"
    }()

    static let hashFilePath: String = {
        return "\(localBackupRoot)/.imported-hashes"
    }()

    // Loaded from ~/.charmera-config
    static let blobToken: String = loadConfig("BLOB_TOKEN")
    static let importSecret: String = loadConfig("IMPORT_SECRET")
    static let importAPIURL: String = loadConfig("IMPORT_API_URL", default: "https://charmera.vercel.app/api/import")
    static let blobUploadBase = "https://blob.vercel-storage.com"

    private static func loadConfig(_ key: String, default defaultValue: String = "") -> String {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".charmera-config").path
        guard let data = FileManager.default.contents(atPath: configPath),
              let content = String(data: data, encoding: .utf8) else {
            print("[Config] Warning: ~/.charmera-config not found. Create it with BLOB_TOKEN and IMPORT_SECRET.")
            return defaultValue
        }
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return defaultValue
    }
}
