# Multi-camera support — design

**Date:** 2026-05-14
**Status:** Approved, ready for implementation plan

## Goal

Generalize Charmera from a single-camera app (Kodak Charmera) into a camera-agnostic
app driven by **camera profiles**. The first new camera is the **Pentax Optio W90**.
The Pentax ships in the main release as just another supported camera — this is not a
fork or a private build.

Each camera profile has a user-configurable GitHub Pages gallery target, so two cameras
can publish to two separate galleries (or the same one, the user's choice).

## Non-goals

- No new app, no fork, no separate site or identity.
- No general "import from any SD card" — only known, profiled cameras.
- No change to the gallery template or the published-site format.

## Background — what is camera-specific today

`CharmeraCore` currently hardcodes the Charmera throughout:

| Location | Hardcoded value |
|---|---|
| `Config.cameraMarkerFolders` | `["DCIM", "SPIDCIM"]` |
| `Config.cameraVolumePath` | scans `/Volumes` for those markers, returns `.../DCIM` |
| `Importer.discoverFiles` | `PICT*.JPG` photos, `MOVI*.AVI` videos |
| `Config.repoName` | `"charmera-gallery"` |
| `Config.localBackupRoot` | `~/Pictures/Charmera` |
| `Config.hashFilePath` | `~/Pictures/Charmera/.imported-hashes` |
| `Importer` orientation step | Vision-based rotation (Charmera has no accelerometer) |
| `Importer` video step | always converts AVI → MP4 |

## Verified hardware facts — Pentax Optio W90

Probed directly from a connected W90 card on 2026-05-14:

- **Volume:** mounts as `NO NAME` (label is useless as an identifier). FAT32, but
  `diskutil` reports a stable **Volume UUID** (`93BEF2F7-…`).
- **Root folders:** `DCIM`, `FRAME` (frame-composite templates), plus `RSTRINFO.DAT`.
  `FRAME` is distinctive — a generic SD card won't have it — and slots into the same
  marker-folder mechanism Charmera uses with `SPIDCIM`.
- **DCIM subfolders:** `100_0603`, `101_0514` — format `\d{3}_\d{4}`. Irrelevant to
  import logic; `discoverFiles` recurses the whole DCIM tree anyway.
- **Photos:** `IMGP####.JPG`. EXIF `Make = "PENTAX"`, `Model = "PENTAX Optio W90"`.
  EXIF orientation tag is **absent** on the sample (sensor off or unsupported).
- **Video:** `IMGP####.AVI` — MJPEG in AVI container, 1280×720, ~24 Mbps, PCM audio.
  The W90 uses the `IMGP` prefix for both photos and video; they are disambiguated by
  extension only.

## Architecture

### New file — `CharmeraCore/CameraProfile.swift`

A value type describing one camera, plus a registry of known cameras.

```swift
public enum OrientationStrategy {
    case vision   // Vision-based rotation detection (no orientation metadata available)
    case exif     // honor the EXIF orientation tag if present, else leave as-shot
}

public struct CameraProfile {
    public let id: String                  // "charmera" | "pentax-optio-w90"
    public let displayName: String         // "Charmera" | "Optio W90"
    public let markerFolders: [String]     // all must exist at the volume root
    public let photoNamePrefix: String?    // "PICT" / "IMGP" / nil = any
    public let videoNamePrefix: String?    // "MOVI" / "IMGP" / nil = any
    public let photoExtensions: [String]   // ["jpg", "jpeg"]
    public let videoExtensions: [String]   // ["avi"]
    public let orientationStrategy: OrientationStrategy
    public let videoNeedsConversion: Bool
    public let defaultGalleryRepo: String  // default; overridable per-camera in prefs
    public let exifMakeMatch: String?      // e.g. "PENTAX" — used by the detection chain
    public let exifModelContains: String?  // e.g. "Optio W90"
}

public enum CameraRegistry {
    public static let all: [CameraProfile] = [.charmera, .pentaxOptioW90]
    public static func profile(id: String) -> CameraProfile? { all.first { $0.id == id } }
}
```

**`.charmera`** reproduces today's behavior exactly:
`markerFolders: ["DCIM","SPIDCIM"]`, `photoNamePrefix: "PICT"`, `videoNamePrefix: "MOVI"`,
`photoExtensions: ["jpg","jpeg"]`, `videoExtensions: ["avi"]`,
`orientationStrategy: .vision`, `videoNeedsConversion: true`,
`defaultGalleryRepo: "charmera-gallery"`, no EXIF match needed.

**`.pentaxOptioW90`:**
`markerFolders: ["DCIM","FRAME"]`, `photoNamePrefix: "IMGP"`, `videoNamePrefix: "IMGP"`,
`photoExtensions: ["jpg","jpeg"]`, `videoExtensions: ["avi"]`,
`orientationStrategy: .exif`, `videoNeedsConversion: true`,
`defaultGalleryRepo: "optio-w90-gallery"`,
`exifMakeMatch: "PENTAX"`, `exifModelContains: "Optio W90"`.

### Detection — `Config`

`cameraVolumePath` is replaced by:

```swift
Config.detectConnectedCamera() -> (profile: CameraProfile, dcimPath: String)?
```

It scans `/Volumes` and, for each candidate volume, resolves a profile through a
**layered detection chain** (first hit wins):

1. **Remembered mapping.** Read the volume's `URLResourceKey.volumeUUIDStringKey`.
   A persisted `volumeUUID → profileID` map (UserDefaults) short-circuits detection for
   a card we've seen before.
2. **Folder markers.** `markerFolders.allSatisfy { exists at volume root }`. If exactly
   one profile matches, use it — and persist the mapping against the volume UUID.
3. **EXIF Make/Model.** If markers are ambiguous or match nothing, read `Make`/`Model`
   from the first photo on the volume and match against `exifMakeMatch` /
   `exifModelContains`. On a hit, use and persist.
4. **Ask the user.** If still unresolved, the app prompts "Which camera is this?" with
   the entries from `CameraRegistry.all`. The choice is persisted against the volume
   UUID, so the question is asked at most once per physical card.

**User override.** A menu-bar item — "Camera: <name> ▸" with the other profiles as a
submenu — lets the user correct a wrong guess at any time. Selecting an entry rewrites
the remembered mapping for the currently mounted volume.

This makes the folder markers a fast path, not the sole authority: `FRAME` / `SPIDCIM`
can be missing or wrong and the app still recovers via EXIF, then the user.

### Import — `Importer`

`run(...)` and `performImport(...)` take a `profile: CameraProfile` parameter, threaded
from the detection result.

- **`discoverFiles`** matches against `profile.photoNamePrefix` + `photoExtensions` and
  `profile.videoNamePrefix` + `videoExtensions` instead of the hardcoded `PICT`/`MOVI`
  patterns. A `nil` prefix means "any name with a matching extension".
- **Orientation step** branches on `profile.orientationStrategy`:
  - `.vision` — today's `OrientationDetector` path (Charmera).
  - `.exif` — read the EXIF orientation tag; apply rotation via `sips` if present;
    if absent (the common W90 case), leave the photo as-shot.
- **Video conversion** runs only when `profile.videoNeedsConversion` is true. The W90's
  MJPEG/AVI needs it, so the existing `convertAVItoMP4` path is reused unchanged.
- **Empty camera → no import.** After detection, if `discoverFiles` finds zero matching
  files, the app reports "Nothing to import" and stops before creating a backup dir,
  spinning up `GitHubAPI`, or touching the camera. `Importer` already early-returns
  `ImportCounts(0,0)` on empty `newFiles`; this surfaces it as a clear status instead of
  a silent no-op, and skips the work earlier.

### Per-camera namespacing — `Config`

Backup, dedup, and gallery state are namespaced by `profile.id`:

- **Backup root** → `~/Pictures/Charmera/<profileID>/` (e.g. `.../charmera/`,
  `.../pentax-optio-w90/`).
- **Hash file** → `<backup root>/.imported-hashes`, per profile. Prevents cross-camera
  dedup collisions (both cameras can produce e.g. `IMGP0001.JPG`).
- **Gallery repo** → UserDefaults key `galleryRepo.<profileID>`, defaulting to
  `profile.defaultGalleryRepo`. This is the per-camera, user-configurable gallery target.

**Migration.** On first launch after the upgrade, the existing
`~/Pictures/Charmera/YYYY-MM-DD` date folders and `~/Pictures/Charmera/.imported-hashes`
are moved into `~/Pictures/Charmera/charmera/` so that pre-upgrade imports are not
re-imported and stay attributed to the Charmera profile.

### UI

- **Menu bar:** the menu shows the connected camera's `displayName`
  (e.g. "Optio W90 connected"). Icon behavior (gray/gold/blue) is unchanged.
- **Camera override:** "Camera: <name> ▸" submenu, as described in the detection section.
- **Preferences:** a gallery-repo field per known camera, bound to
  `galleryRepo.<profileID>`.

### MCP — `charmera-mcp`

- `detect_camera` reports which profile was detected (id + display name).
- `import_roll`, `prepare_camera_import`, `push_to_gallery`, etc. operate on the
  detected profile. Once `Importer` and `Config` are profile-driven, the MCP surface is
  largely transparent — it passes the detected profile through rather than assuming the
  Charmera.

## Testing

- **`CameraProfile` matching is pure data.** Point the detection chain at fixture
  directories shaped like `/Volumes/<x>/` (with/without `SPIDCIM`, `FRAME`, EXIF
  fixtures) and assert the resolved profile, including the ambiguous and no-match cases
  that fall through to EXIF and to the user prompt.
- **`Importer` profile branching** is tested with fixture DCIM trees: Charmera-style
  `PICT`/`MOVI` vs W90-style `IMGP` photo+video, empty-camera, and the
  `videoNeedsConversion` on/off paths.
- **Migration** is tested by seeding an old-layout `~/Pictures/Charmera` and asserting
  the date folders and hash file land under `charmera/`.

## Open items

None blocking. All Pentax profile fields are verified against real hardware. The W90's
EXIF orientation tag was absent on the sample; `.exif` strategy handles that gracefully
(leave as-shot), and if some W90 photos do carry the tag it will be honored.
