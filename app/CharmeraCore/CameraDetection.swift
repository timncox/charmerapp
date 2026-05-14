import Foundation

/// Pure detection helpers for resolving which `CameraProfile` a mounted volume belongs to.
public enum CameraDetection {
    /// Returns the first registered profile whose `markerFolders` all exist at `volumeRoot`.
    public static func profileByMarkers(volumeRoot: URL) -> CameraProfile? {
        let fm = FileManager.default
        return CameraRegistry.all.first { profile in
            profile.markerFolders.allSatisfy { folder in
                var isDir: ObjCBool = false
                let path = volumeRoot.appendingPathComponent(folder).path
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        }
    }
}
