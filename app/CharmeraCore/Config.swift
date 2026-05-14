import Foundation

public enum Config {
    /// Reads the volume UUID for `volumeRoot`, or nil if the filesystem has none.
    public static func volumeUUID(for volumeRoot: URL) -> String? {
        let values = try? volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString
    }

    /// One mounted volume that resolved to a known camera profile.
    public struct DetectedCamera {
        public let profile: CameraProfile
        public let dcimPath: String
        public let volumeRoot: URL
        public let volumeUUID: String?
    }

    /// One mounted volume that has a DCIM folder but could not be auto-identified.
    public struct UnidentifiedCamera {
        public let volumeRoot: URL
        public let volumeUUID: String?
    }

    public enum CameraScanResult {
        case found(DetectedCamera)
        case needsUserChoice(UnidentifiedCamera)
        case none
    }

    /// Scans `/Volumes` and resolves the first camera-like volume through the detection chain.
    public static func detectConnectedCamera(memory: CameraMemory = CameraMemory()) -> CameraScanResult {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return .none }
        for volume in volumes {
            let volumeRoot = URL(fileURLWithPath: "/Volumes/\(volume)")
            let dcim = volumeRoot.appendingPathComponent("DCIM")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dcim.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let uuid = volumeUUID(for: volumeRoot)
            let resolution = CameraDetection.resolve(
                volumeRoot: volumeRoot,
                volumeUUID: uuid,
                rememberedProfileID: { memory.profile(forVolumeUUID: $0)?.id })
            switch resolution {
            case .resolved(let profile):
                return .found(DetectedCamera(
                    profile: profile, dcimPath: dcim.path, volumeRoot: volumeRoot, volumeUUID: uuid))
            case .needsUserChoice:
                return .needsUserChoice(UnidentifiedCamera(volumeRoot: volumeRoot, volumeUUID: uuid))
            }
        }
        return .none
    }

    public static let localBackupRoot: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Pictures/Charmera"
    }()

    public static let hashFilePath: String = { "\(localBackupRoot)/.imported-hashes" }()

    public static let appSupportDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/Charmera"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let githubClientID = "Ov23liHp3TaFjD42UIUc"
    public static let authProxyURL = "https://charmera-auth.vercel.app/api/github"
    public static let githubCallbackScheme = "charmera"
    public static let repoName = "charmera-gallery"
}
