import Foundation
import ImageIO

/// Persists a `volumeUUID → profileID` mapping so a previously-identified card
/// (or a user override) is recognised instantly on the next mount.
public struct CameraMemory {
    private let defaults: UserDefaults
    private let key = "cameraVolumeProfileMap"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func profile(forVolumeUUID uuid: String) -> CameraProfile? {
        guard let map = defaults.dictionary(forKey: key) as? [String: String],
              let profileID = map[uuid] else { return nil }
        return CameraRegistry.profile(id: profileID)
    }

    public func remember(profileID: String, forVolumeUUID uuid: String) {
        var map = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[uuid] = profileID
        defaults.set(map, forKey: key)
    }
}

public enum CameraResolution: Equatable {
    case resolved(CameraProfile)
    /// Markers and EXIF were inconclusive — the caller must ask the user to pick a profile.
    case needsUserChoice
}

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

    /// Reads EXIF `Make`/`Model` from the first photo found anywhere under `volumeRoot`.
    /// Returns `(nil, nil)` if no readable photo is found.
    public static func exifMakeModel(volumeRoot: URL) -> (make: String?, model: String?) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: volumeRoot, includingPropertiesForKeys: nil) else {
            return (nil, nil)
        }
        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else { continue }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            else { continue }
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let make = tiff?[kCGImagePropertyTIFFMake] as? String
            let model = tiff?[kCGImagePropertyTIFFModel] as? String
            return (make, model)
        }
        return (nil, nil)
    }

    /// Returns the first registered profile whose EXIF `Make`/`Model` matchers are satisfied.
    /// A profile with no `exifMakeMatch` is never matched this way.
    public static func profileByEXIF(make: String?, model: String?) -> CameraProfile? {
        guard let make = make else { return nil }
        return CameraRegistry.all.first { profile in
            guard let wantMake = profile.exifMakeMatch else { return false }
            guard make.caseInsensitiveCompare(wantMake) == .orderedSame else { return false }
            if let wantModel = profile.exifModelContains {
                guard let model = model,
                      model.range(of: wantModel, options: .caseInsensitive) != nil else {
                    return false
                }
            }
            return true
        }
    }

    /// Runs the layered detection chain for one mounted volume:
    /// 1. remembered `volumeUUID → profile` mapping,
    /// 2. folder markers,
    /// 3. EXIF Make/Model,
    /// 4. otherwise `.needsUserChoice`.
    /// `rememberedProfileID` is injected so the chain is testable without UserDefaults.
    public static func resolve(
        volumeRoot: URL,
        volumeUUID: String?,
        rememberedProfileID: (String) -> String?
    ) -> CameraResolution {
        if let uuid = volumeUUID,
           let id = rememberedProfileID(uuid),
           let profile = CameraRegistry.profile(id: id) {
            return .resolved(profile)
        }
        if let byMarkers = profileByMarkers(volumeRoot: volumeRoot) {
            return .resolved(byMarkers)
        }
        let exif = exifMakeModel(volumeRoot: volumeRoot)
        if let byEXIF = profileByEXIF(make: exif.make, model: exif.model) {
            return .resolved(byEXIF)
        }
        return .needsUserChoice
    }
}
