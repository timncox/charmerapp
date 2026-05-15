import Foundation

public enum OrientationStrategy: Equatable {
    /// Vision-based rotation detection — used when the camera writes no orientation metadata.
    case vision
    /// Honor the EXIF orientation tag if present, otherwise leave the photo as-shot.
    case exif
}

public struct CameraProfile: Equatable {
    public let id: String
    public let displayName: String
    /// Folder names that must all exist at the volume root for a marker match.
    public let markerFolders: [String]
    /// Required filename prefix for photos, or nil to match any name with a photo extension.
    public let photoNamePrefix: String?
    /// Required filename prefix for videos, or nil to match any name with a video extension.
    public let videoNamePrefix: String?
    public let photoExtensions: [String]
    public let videoExtensions: [String]
    public let orientationStrategy: OrientationStrategy
    public let videoNeedsConversion: Bool
    /// Default GitHub Pages repo for this camera; overridable per-camera in Preferences.
    public let defaultGalleryRepo: String
    /// Name of the bundled gallery-template directory for this camera (under the app's
    /// Resources). Each camera ships a template styled to match the camera itself.
    public let templateDirName: String
    /// EXIF `Make` value that identifies this camera, or nil if EXIF detection is not used.
    public let exifMakeMatch: String?
    /// Substring expected in EXIF `Model` for this camera, or nil.
    public let exifModelContains: String?

    public init(
        id: String,
        displayName: String,
        markerFolders: [String],
        photoNamePrefix: String?,
        videoNamePrefix: String?,
        photoExtensions: [String],
        videoExtensions: [String],
        orientationStrategy: OrientationStrategy,
        videoNeedsConversion: Bool,
        defaultGalleryRepo: String,
        templateDirName: String,
        exifMakeMatch: String?,
        exifModelContains: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.markerFolders = markerFolders
        self.photoNamePrefix = photoNamePrefix
        self.videoNamePrefix = videoNamePrefix
        self.photoExtensions = photoExtensions
        self.videoExtensions = videoExtensions
        self.orientationStrategy = orientationStrategy
        self.videoNeedsConversion = videoNeedsConversion
        self.defaultGalleryRepo = defaultGalleryRepo
        self.templateDirName = templateDirName
        self.exifMakeMatch = exifMakeMatch
        self.exifModelContains = exifModelContains
    }
}

extension CameraProfile {
    public static let charmera = CameraProfile(
        id: "charmera",
        displayName: "Charmera",
        markerFolders: ["DCIM", "SPIDCIM"],
        photoNamePrefix: "PICT",
        videoNamePrefix: "MOVI",
        photoExtensions: ["jpg", "jpeg"],
        videoExtensions: ["avi"],
        orientationStrategy: .vision,
        videoNeedsConversion: true,
        defaultGalleryRepo: "charmera-gallery",
        templateDirName: "template",
        exifMakeMatch: nil,
        exifModelContains: nil
    )

    public static let pentaxOptioW90 = CameraProfile(
        id: "pentax-optio-w90",
        displayName: "Optio W90",
        markerFolders: ["DCIM", "FRAME"],
        photoNamePrefix: "IMGP",
        videoNamePrefix: "IMGP",
        photoExtensions: ["jpg", "jpeg"],
        videoExtensions: ["avi"],
        // The Optio W90 does not write an EXIF orientation tag (verified across every
        // sample from the hardware), so `.exif` would be a no-op — use the same
        // Vision-based detection the Charmera relies on for the same reason.
        orientationStrategy: .vision,
        videoNeedsConversion: true,
        defaultGalleryRepo: "optio-w90-gallery",
        templateDirName: "template-optio-w90",
        exifMakeMatch: "PENTAX",
        exifModelContains: "Optio W90"
    )
}

public enum CameraRegistry {
    public static let all: [CameraProfile] = [.charmera, .pentaxOptioW90]

    public static func profile(id: String) -> CameraProfile? {
        all.first { $0.id == id }
    }
}
