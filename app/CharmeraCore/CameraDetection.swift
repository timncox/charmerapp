import Foundation
import ImageIO

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
}
