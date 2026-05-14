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

    /// Per-camera local backup directory, e.g. `~/Pictures/Charmera/pentax-optio-w90`.
    public static func backupRoot(for profile: CameraProfile) -> String {
        "\(localBackupRoot)/\(profile.id)"
    }

    /// Per-camera dedup hash file.
    public static func hashFilePath(for profile: CameraProfile) -> String {
        "\(backupRoot(for: profile))/.imported-hashes"
    }

    /// Per-camera GitHub Pages repo. Returns the user override if set, else the profile default.
    public static func galleryRepo(for profile: CameraProfile, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "galleryRepo.\(profile.id)") ?? profile.defaultGalleryRepo
    }

    /// Stores a user-chosen gallery repo for a camera.
    public static func setGalleryRepo(_ repo: String, for profile: CameraProfile, defaults: UserDefaults = .standard) {
        defaults.set(repo, forKey: "galleryRepo.\(profile.id)")
    }

    public static let githubClientID = "Ov23liHp3TaFjD42UIUc"
    public static let authProxyURL = "https://charmera-auth.vercel.app/api/github"
    public static let githubCallbackScheme = "charmera"
    public static let repoName = "charmera-gallery"
}
