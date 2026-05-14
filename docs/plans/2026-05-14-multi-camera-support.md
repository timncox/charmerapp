# Multi-Camera Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize Charmera into a camera-agnostic app driven by `CameraProfile` values, adding the Pentax Optio W90 as a second supported camera with its own user-configurable gallery.

**Architecture:** A new `CameraProfile` value type plus a registry of known cameras. `Config` gains a layered detection chain (remembered volume UUID → folder markers → EXIF Make/Model → ask user) and per-camera namespacing for backup dirs, dedup files, and gallery repos. `Importer` is threaded with a `CameraProfile` and reads file patterns, orientation strategy, and video handling from it. The menu bar, Preferences, Review/Setup windows, and `charmera-mcp` are updated to be profile-aware.

**Tech Stack:** Swift 6 tools (language mode v5), Swift Package Manager, AppKit, ImageIO, swift-sdk MCP. Package manifest at `app/Package.swift`; all `swift` commands run from `app/`.

**Spec:** `docs/specs/2026-05-14-multi-camera-support-design.md`

---

## File Structure

**New files:**
- `app/CharmeraCore/CameraProfile.swift` — the `CameraProfile` struct, `OrientationStrategy` enum, `CameraRegistry`, and the two concrete profiles.
- `app/CharmeraCore/CameraDetection.swift` — pure detection helpers: folder-marker matching, EXIF-string matching, and the `CameraMemory` UserDefaults-backed `volumeUUID → profileID` store.
- `app/CharmeraCoreTests/CameraProfileTests.swift` — registry + profile field tests.
- `app/CharmeraCoreTests/CameraDetectionTests.swift` — marker matching, EXIF matching, memory store, detection-chain tests.
- `app/CharmeraCoreTests/ImporterDiscoveryTests.swift` — `discoverFiles` profile-pattern tests.
- `app/CharmeraCoreTests/ConfigNamespacingTests.swift` — per-camera path + migration tests.
- `app/CharmeraCoreTests/Fixtures/` — fixture directory trees built by test code at runtime (no binary fixtures committed).

**Modified files:**
- `app/Package.swift` — add the `CharmeraCoreTests` test target.
- `app/CharmeraCore/Config.swift` — replace `cameraVolumePath` with `detectConnectedCamera()`; add per-profile `backupRoot(for:)`, `hashFilePath(for:)`, `galleryRepo(for:)`, `setGalleryRepo(_:for:)`, and `migrateLegacyLayoutIfNeeded()`.
- `app/CharmeraCore/Importer.swift` — `run`/`performImport` take a `CameraProfile`; `discoverFiles` uses profile patterns; orientation + video steps branch on the profile.
- `app/CharmeraCore/OrientationDetector.swift` — add `exifOrientationDegrees(imagePath:)`.
- `app/Charmera/AppDelegate.swift` — connection + menu + import driven by `detectConnectedCamera()`; add camera-override submenu.
- `app/Charmera/PreferencesWindow.swift` — gallery-repo field per known camera.
- `app/Charmera/ReviewWindow.swift` — use the active profile's gallery repo + backup root.
- `app/Charmera/SetupWindow.swift` — create/push/enable Pages for each profile's gallery repo.
- `app/charmera-mcp/main.swift` — `detect_camera` reports the profile; import tools use the detected profile.

---

## Task 1: Add the test target

**Files:**
- Modify: `app/Package.swift`
- Test: `app/CharmeraCoreTests/SmokeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `app/CharmeraCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import CharmeraCore

final class SmokeTests: XCTestCase {
    func testCharmeraCoreIsImportable() {
        XCTAssertEqual(Config.repoName, "charmera-gallery")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test`
Expected: FAIL — `swift test` reports no test target / cannot find `CharmeraCoreTests`.

- [ ] **Step 3: Add the test target to the manifest**

In `app/Package.swift`, add to the `targets:` array, after the `charmera-mcp` target:

```swift
        .testTarget(
            name: "CharmeraCoreTests",
            dependencies: ["CharmeraCore"],
            path: "CharmeraCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test`
Expected: PASS — `Test Suite 'SmokeTests' passed`, 1 test.

- [ ] **Step 5: Commit**

```bash
git add app/Package.swift app/CharmeraCoreTests/SmokeTests.swift
git commit -m "test: add CharmeraCoreTests target"
```

---

## Task 2: CameraProfile type and registry

**Files:**
- Create: `app/CharmeraCore/CameraProfile.swift`
- Test: `app/CharmeraCoreTests/CameraProfileTests.swift`

- [ ] **Step 1: Write the failing test**

Create `app/CharmeraCoreTests/CameraProfileTests.swift`:

```swift
import XCTest
@testable import CharmeraCore

final class CameraProfileTests: XCTestCase {
    func testRegistryHasCharmeraAndPentax() {
        let ids = CameraRegistry.all.map { $0.id }
        XCTAssertEqual(ids, ["charmera", "pentax-optio-w90"])
    }

    func testCharmeraProfileFields() {
        let p = CameraRegistry.profile(id: "charmera")!
        XCTAssertEqual(p.markerFolders, ["DCIM", "SPIDCIM"])
        XCTAssertEqual(p.photoNamePrefix, "PICT")
        XCTAssertEqual(p.videoNamePrefix, "MOVI")
        XCTAssertEqual(p.orientationStrategy, .vision)
        XCTAssertTrue(p.videoNeedsConversion)
        XCTAssertEqual(p.defaultGalleryRepo, "charmera-gallery")
    }

    func testPentaxProfileFields() {
        let p = CameraRegistry.profile(id: "pentax-optio-w90")!
        XCTAssertEqual(p.markerFolders, ["DCIM", "FRAME"])
        XCTAssertEqual(p.photoNamePrefix, "IMGP")
        XCTAssertEqual(p.videoNamePrefix, "IMGP")
        XCTAssertEqual(p.videoExtensions, ["avi"])
        XCTAssertEqual(p.orientationStrategy, .exif)
        XCTAssertEqual(p.exifMakeMatch, "PENTAX")
        XCTAssertEqual(p.exifModelContains, "Optio W90")
        XCTAssertEqual(p.defaultGalleryRepo, "optio-w90-gallery")
    }

    func testProfileLookupUnknownIsNil() {
        XCTAssertNil(CameraRegistry.profile(id: "nope"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter CameraProfileTests`
Expected: FAIL — `cannot find 'CameraRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `app/CharmeraCore/CameraProfile.swift`:

```swift
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
        orientationStrategy: .exif,
        videoNeedsConversion: true,
        defaultGalleryRepo: "optio-w90-gallery",
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter CameraProfileTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/CameraProfile.swift app/CharmeraCoreTests/CameraProfileTests.swift
git commit -m "feat: add CameraProfile type and registry"
```

---

## Task 3: Folder-marker matching

**Files:**
- Create: `app/CharmeraCore/CameraDetection.swift`
- Test: `app/CharmeraCoreTests/CameraDetectionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `app/CharmeraCoreTests/CameraDetectionTests.swift`:

```swift
import XCTest
@testable import CharmeraCore

final class CameraDetectionTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("camdetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeVolume(_ name: String, folders: [String]) throws -> URL {
        let vol = tmp.appendingPathComponent(name)
        for f in folders {
            try FileManager.default.createDirectory(
                at: vol.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        return vol
    }

    func testCharmeraMarkersMatchCharmeraProfile() throws {
        let vol = try makeVolume("CHARMERA", folders: ["DCIM", "SPIDCIM"])
        XCTAssertEqual(CameraDetection.profileByMarkers(volumeRoot: vol)?.id, "charmera")
    }

    func testPentaxMarkersMatchPentaxProfile() throws {
        let vol = try makeVolume("NO NAME", folders: ["DCIM", "FRAME"])
        XCTAssertEqual(CameraDetection.profileByMarkers(volumeRoot: vol)?.id, "pentax-optio-w90")
    }

    func testBareDcimMatchesNothing() throws {
        let vol = try makeVolume("SDCARD", folders: ["DCIM"])
        XCTAssertNil(CameraDetection.profileByMarkers(volumeRoot: vol))
    }

    func testNoDcimMatchesNothing() throws {
        let vol = try makeVolume("USBSTICK", folders: ["Documents"])
        XCTAssertNil(CameraDetection.profileByMarkers(volumeRoot: vol))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter CameraDetectionTests`
Expected: FAIL — `cannot find 'CameraDetection' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `app/CharmeraCore/CameraDetection.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter CameraDetectionTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/CameraDetection.swift app/CharmeraCoreTests/CameraDetectionTests.swift
git commit -m "feat: folder-marker camera profile matching"
```

---

## Task 4: EXIF Make/Model matching

**Files:**
- Modify: `app/CharmeraCore/CameraDetection.swift`
- Test: `app/CharmeraCoreTests/CameraDetectionTests.swift:1` (add to existing class)

- [ ] **Step 1: Write the failing test**

Append these methods to `CameraDetectionTests` in `app/CharmeraCoreTests/CameraDetectionTests.swift`:

```swift
    func testExifPentaxMakeModelMatchesPentax() {
        let p = CameraDetection.profileByEXIF(make: "PENTAX", model: "PENTAX Optio W90")
        XCTAssertEqual(p?.id, "pentax-optio-w90")
    }

    func testExifWrongMakeMatchesNothing() {
        XCTAssertNil(CameraDetection.profileByEXIF(make: "Canon", model: "PowerShot"))
    }

    func testExifNilValuesMatchNothing() {
        XCTAssertNil(CameraDetection.profileByEXIF(make: nil, model: nil))
    }

    func testExifMakeMatchButModelMismatchMatchesNothing() {
        XCTAssertNil(CameraDetection.profileByEXIF(make: "PENTAX", model: "Optio E70"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter CameraDetectionTests`
Expected: FAIL — `type 'CameraDetection' has no member 'profileByEXIF'`.

- [ ] **Step 3: Write minimal implementation**

Add to `CameraDetection` in `app/CharmeraCore/CameraDetection.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter CameraDetectionTests`
Expected: PASS — 8 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/CameraDetection.swift app/CharmeraCoreTests/CameraDetectionTests.swift
git commit -m "feat: EXIF Make/Model camera profile matching"
```

---

## Task 5: EXIF reader for a JPEG on disk

**Files:**
- Modify: `app/CharmeraCore/CameraDetection.swift`

This wraps ImageIO to read `Make`/`Model` from the first photo on a volume. It is exercised by the integration test in Task 14 (it needs a real JPEG with EXIF), not by a unit test — keep the ImageIO call isolated in this one small function so the testable matching logic (Task 4) stays pure.

- [ ] **Step 1: Add the reader**

Add to the top of `app/CharmeraCore/CameraDetection.swift`, replacing `import Foundation`:

```swift
import Foundation
import ImageIO
```

Add to `CameraDetection`:

```swift
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
```

- [ ] **Step 2: Verify it compiles**

Run: `cd app && swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add app/CharmeraCore/CameraDetection.swift
git commit -m "feat: read EXIF Make/Model from a volume's first photo"
```

---

## Task 6: Volume UUID + remembered-mapping store

**Files:**
- Modify: `app/CharmeraCore/CameraDetection.swift`
- Test: `app/CharmeraCoreTests/CameraDetectionTests.swift:1` (add a new class)

- [ ] **Step 1: Write the failing test**

Append a new class to `app/CharmeraCoreTests/CameraDetectionTests.swift`:

```swift
final class CameraMemoryTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        suiteName = "cammemtest-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUnknownVolumeReturnsNil() {
        let mem = CameraMemory(defaults: defaults)
        XCTAssertNil(mem.profile(forVolumeUUID: "ABC-123"))
    }

    func testRememberThenRecall() {
        let mem = CameraMemory(defaults: defaults)
        mem.remember(profileID: "pentax-optio-w90", forVolumeUUID: "ABC-123")
        XCTAssertEqual(mem.profile(forVolumeUUID: "ABC-123")?.id, "pentax-optio-w90")
    }

    func testRememberOverwrites() {
        let mem = CameraMemory(defaults: defaults)
        mem.remember(profileID: "charmera", forVolumeUUID: "ABC-123")
        mem.remember(profileID: "pentax-optio-w90", forVolumeUUID: "ABC-123")
        XCTAssertEqual(mem.profile(forVolumeUUID: "ABC-123")?.id, "pentax-optio-w90")
    }

    func testRememberUnknownProfileIDRecallsNil() {
        let mem = CameraMemory(defaults: defaults)
        mem.remember(profileID: "bogus", forVolumeUUID: "ABC-123")
        XCTAssertNil(mem.profile(forVolumeUUID: "ABC-123"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter CameraMemoryTests`
Expected: FAIL — `cannot find 'CameraMemory' in scope`.

- [ ] **Step 3: Write minimal implementation**

Add to `app/CharmeraCore/CameraDetection.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter CameraMemoryTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/CameraDetection.swift app/CharmeraCoreTests/CameraDetectionTests.swift
git commit -m "feat: CameraMemory volume-UUID to profile store"
```

---

## Task 7: Detection chain orchestration

**Files:**
- Modify: `app/CharmeraCore/CameraDetection.swift`
- Test: `app/CharmeraCoreTests/CameraDetectionTests.swift:1` (add a new class)

The chain's "ask the user" step is a UI concern, so the core exposes the result as an enum the caller acts on. The volume-UUID lookup is injected as a closure so it is testable without a real disk.

- [ ] **Step 1: Write the failing test**

Append a new class to `app/CharmeraCoreTests/CameraDetectionTests.swift`:

```swift
final class DetectionChainTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeVolume(_ name: String, folders: [String]) throws -> URL {
        let vol = tmp.appendingPathComponent(name)
        for f in folders {
            try FileManager.default.createDirectory(
                at: vol.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        return vol
    }

    func testRememberedMappingWins() throws {
        let vol = try makeVolume("NO NAME", folders: ["DCIM", "FRAME"])
        let result = CameraDetection.resolve(
            volumeRoot: vol,
            volumeUUID: "UUID-1",
            rememberedProfileID: { _ in "charmera" })
        // Remembered mapping ("charmera") beats the folder markers ("pentax").
        XCTAssertEqual(result, .resolved(.charmera))
    }

    func testFolderMarkersUsedWhenNoMemory() throws {
        let vol = try makeVolume("NO NAME", folders: ["DCIM", "FRAME"])
        let result = CameraDetection.resolve(
            volumeRoot: vol,
            volumeUUID: "UUID-1",
            rememberedProfileID: { _ in nil })
        XCTAssertEqual(result, .resolved(.pentaxOptioW90))
    }

    func testUnknownVolumeNeedsUser() throws {
        let vol = try makeVolume("SDCARD", folders: ["DCIM"])
        let result = CameraDetection.resolve(
            volumeRoot: vol,
            volumeUUID: "UUID-2",
            rememberedProfileID: { _ in nil })
        XCTAssertEqual(result, .needsUserChoice)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter DetectionChainTests`
Expected: FAIL — `type 'CameraDetection' has no member 'resolve'`.

- [ ] **Step 3: Write minimal implementation**

Add to `app/CharmeraCore/CameraDetection.swift`:

```swift
public enum CameraResolution: Equatable {
    case resolved(CameraProfile)
    /// Markers and EXIF were inconclusive — the caller must ask the user to pick a profile.
    case needsUserChoice
}

extension CameraDetection {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter DetectionChainTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/CameraDetection.swift app/CharmeraCoreTests/CameraDetectionTests.swift
git commit -m "feat: layered camera detection chain"
```

---

## Task 8: Config — detectConnectedCamera() and DCIM path

**Files:**
- Modify: `app/CharmeraCore/Config.swift`
- Test: `app/CharmeraCoreTests/ConfigNamespacingTests.swift`

`Config.cameraVolumePath` is replaced. The old API returned the `DCIM` path string; the new one returns the profile plus the `DCIM` path. It walks `/Volumes`, gets each volume's UUID via `URLResourceKey.volumeUUIDStringKey`, and runs `CameraDetection.resolve`. The user-choice branch returns `.needsUserChoice` with the volume so `AppDelegate` can prompt.

- [ ] **Step 1: Write the failing test**

Create `app/CharmeraCoreTests/ConfigNamespacingTests.swift`:

```swift
import XCTest
@testable import CharmeraCore

final class ConfigNamespacingTests: XCTestCase {
    func testVolumeUUIDIsReadableForRootVolume() {
        // The boot volume always has a UUID; this proves the resource-key read path works.
        let root = URL(fileURLWithPath: "/")
        XCTAssertNotNil(Config.volumeUUID(for: root))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter ConfigNamespacingTests`
Expected: FAIL — `type 'Config' has no member 'volumeUUID'`.

- [ ] **Step 3: Write minimal implementation**

In `app/CharmeraCore/Config.swift`, delete the `cameraMarkerFolders` constant and the `cameraVolumePath` computed property. Add in their place:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes (CharmeraCore only)**

Run: `cd app && swift test --filter ConfigNamespacingTests`
Expected: PASS — 1 test. (The `Charmera` and `charmera-mcp` targets will not compile yet — that is fixed in Tasks 12–14. `swift test` builds only what the test target needs.)

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/Config.swift app/CharmeraCoreTests/ConfigNamespacingTests.swift
git commit -m "feat: Config.detectConnectedCamera detection-chain entry point"
```

---

## Task 9: Config — per-camera namespaced paths

**Files:**
- Modify: `app/CharmeraCore/Config.swift`
- Test: `app/CharmeraCoreTests/ConfigNamespacingTests.swift:1` (add to existing class)

- [ ] **Step 1: Write the failing test**

Append to `ConfigNamespacingTests` in `app/CharmeraCoreTests/ConfigNamespacingTests.swift`:

```swift
    func testBackupRootIsNamespacedByProfileID() {
        let root = Config.backupRoot(for: .pentaxOptioW90)
        XCTAssertTrue(root.hasSuffix("/Pictures/Charmera/pentax-optio-w90"), root)
    }

    func testHashFilePathIsInsideBackupRoot() {
        let path = Config.hashFilePath(for: .charmera)
        XCTAssertEqual(path, Config.backupRoot(for: .charmera) + "/.imported-hashes")
    }

    func testGalleryRepoDefaultsToProfileDefault() {
        let suite = "galltest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            Config.galleryRepo(for: .pentaxOptioW90, defaults: defaults),
            "optio-w90-gallery")
    }

    func testGalleryRepoReturnsUserOverride() {
        let suite = "galltest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        Config.setGalleryRepo("my-custom-repo", for: .pentaxOptioW90, defaults: defaults)
        XCTAssertEqual(
            Config.galleryRepo(for: .pentaxOptioW90, defaults: defaults),
            "my-custom-repo")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter ConfigNamespacingTests`
Expected: FAIL — `type 'Config' has no member 'backupRoot'`.

- [ ] **Step 3: Write minimal implementation**

In `app/CharmeraCore/Config.swift`, keep `localBackupRoot` (it now names the *shared parent* dir) and add:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter ConfigNamespacingTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/Config.swift app/CharmeraCoreTests/ConfigNamespacingTests.swift
git commit -m "feat: per-camera namespaced backup, hash, and gallery paths"
```

---

## Task 10: Config — legacy layout migration

**Files:**
- Modify: `app/CharmeraCore/Config.swift`
- Test: `app/CharmeraCoreTests/ConfigNamespacingTests.swift:1` (add a new class)

Pre-upgrade installs have date folders and `.imported-hashes` directly under `~/Pictures/Charmera`. They belong to the Charmera profile and must move into `~/Pictures/Charmera/charmera/` so they neither re-import nor get mis-attributed. The migration takes the parent dir as a parameter so it is testable against a temp directory.

- [ ] **Step 1: Write the failing test**

Append a new class to `app/CharmeraCoreTests/ConfigNamespacingTests.swift`:

```swift
final class LegacyMigrationTests: XCTestCase {
    var parent: URL!

    override func setUpWithError() throws {
        parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    func testMovesDateFoldersAndHashFileIntoCharmeraSubdir() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: parent.appendingPathComponent("2026-04-01"), withIntermediateDirectories: true)
        fm.createFile(atPath: parent.appendingPathComponent("2026-04-01/PICT0001.JPG").path, contents: Data())
        fm.createFile(atPath: parent.appendingPathComponent(".imported-hashes").path,
                      contents: "PICT0001.JPG:0\n".data(using: .utf8))

        Config.migrateLegacyLayoutIfNeeded(parent: parent)

        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("charmera/2026-04-01/PICT0001.JPG").path))
        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("charmera/.imported-hashes").path))
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent("2026-04-01").path))
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent(".imported-hashes").path))
    }

    func testIsIdempotentAndLeavesProfileDirsAlone() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: parent.appendingPathComponent("charmera"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appendingPathComponent("pentax-optio-w90"), withIntermediateDirectories: true)

        Config.migrateLegacyLayoutIfNeeded(parent: parent)

        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("charmera").path))
        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("pentax-optio-w90").path))
        // No nested charmera/charmera was created.
        XCTAssertFalse(fm.fileExists(atPath: parent.appendingPathComponent("charmera/charmera").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter LegacyMigrationTests`
Expected: FAIL — `type 'Config' has no member 'migrateLegacyLayoutIfNeeded'`.

- [ ] **Step 3: Write minimal implementation**

Add to `app/CharmeraCore/Config.swift`:

```swift
    /// Moves a pre-multi-camera layout (date folders + `.imported-hashes` directly under
    /// `~/Pictures/Charmera`) into the `charmera/` profile subdir. Idempotent: known profile
    /// directory names are never moved, so re-running does nothing.
    public static func migrateLegacyLayoutIfNeeded(parent: URL = URL(fileURLWithPath: localBackupRoot)) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        let profileDirNames = Set(CameraRegistry.all.map { $0.id })

        let legacyEntries = entries.filter { name in
            if name == ".imported-hashes" { return true }
            if profileDirNames.contains(name) { return false }
            // Legacy date folders look like YYYY-MM-DD.
            return name.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
        }
        guard !legacyEntries.isEmpty else { return }

        let charmeraDir = parent.appendingPathComponent("charmera")
        try? fm.createDirectory(at: charmeraDir, withIntermediateDirectories: true)
        for name in legacyEntries {
            let from = parent.appendingPathComponent(name)
            let to = charmeraDir.appendingPathComponent(name)
            try? fm.moveItem(at: from, to: to)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter LegacyMigrationTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/Config.swift app/CharmeraCoreTests/ConfigNamespacingTests.swift
git commit -m "feat: migrate legacy backup layout into charmera/ subdir"
```

---

## Task 11: OrientationDetector — EXIF orientation degrees

**Files:**
- Modify: `app/CharmeraCore/OrientationDetector.swift`

Like Task 5, the ImageIO call is isolated in one small function and verified by build + Task 14 integration, not a unit test (it needs a real EXIF-tagged JPEG).

- [ ] **Step 1: Add the function**

At the top of `app/CharmeraCore/OrientationDetector.swift`, ensure `import ImageIO` is present (add it if not). Add to the `OrientationDetector` type:

```swift
    /// Returns the clockwise rotation in degrees implied by a photo's EXIF orientation tag.
    /// Returns 0 when the tag is absent (the common Optio W90 case) or already upright.
    public static func exifOrientationDegrees(imagePath: String) -> Int {
        let url = URL(fileURLWithPath: imagePath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? Int else {
            return 0
        }
        // EXIF orientation values: 6 = rotate 90° CW, 3 = 180°, 8 = 270° CW.
        switch raw {
        case 6: return 90
        case 3: return 180
        case 8: return 270
        default: return 0
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd app && swift build --target CharmeraCore`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add app/CharmeraCore/OrientationDetector.swift
git commit -m "feat: read EXIF orientation degrees for .exif strategy cameras"
```

---

## Task 12: Importer — thread CameraProfile through discovery

**Files:**
- Modify: `app/CharmeraCore/Importer.swift`
- Test: `app/CharmeraCoreTests/ImporterDiscoveryTests.swift`

`discoverFiles` becomes profile-driven. Make it `internal` (drop `private`) so the test target can exercise it directly, and have it take a profile.

- [ ] **Step 1: Write the failing test**

Create `app/CharmeraCoreTests/ImporterDiscoveryTests.swift`:

```swift
import XCTest
@testable import CharmeraCore

final class ImporterDiscoveryTests: XCTestCase {
    var dcim: URL!

    override func setUpWithError() throws {
        dcim = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dcim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dcim)
    }

    private func touch(_ relativePath: String) throws {
        let url = dcim.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func testCharmeraDiscoversPictAndMovi() throws {
        try touch("100CHARM/PICT0001.JPG")
        try touch("100CHARM/MOVI0001.AVI")
        try touch("100CHARM/NOTES.TXT")
        let found = Importer().discoverFiles(in: dcim, profile: .charmera)
            .map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["MOVI0001.AVI", "PICT0001.JPG"])
    }

    func testPentaxDiscoversImgpJpgAndAvi() throws {
        try touch("101_0514/IMGP0002.JPG")
        try touch("101_0514/IMGP0013.AVI")
        try touch("100_0603/IMGP0009.JPG")
        let found = Importer().discoverFiles(in: dcim, profile: .pentaxOptioW90)
            .map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(found, ["IMGP0002.JPG", "IMGP0009.JPG", "IMGP0013.AVI"])
    }

    func testPentaxProfileIgnoresCharmeraNamedFiles() throws {
        try touch("100CHARM/PICT0001.JPG")
        let found = Importer().discoverFiles(in: dcim, profile: .pentaxOptioW90)
        XCTAssertTrue(found.isEmpty)
    }

    func testEmptyDcimDiscoversNothing() {
        let found = Importer().discoverFiles(in: dcim, profile: .pentaxOptioW90)
        XCTAssertTrue(found.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter ImporterDiscoveryTests`
Expected: FAIL — `discoverFiles` is private / signature has no `profile:` parameter.

- [ ] **Step 3: Write minimal implementation**

In `app/CharmeraCore/Importer.swift`, replace the existing `discoverFiles` method with:

```swift
    // MARK: - File Discovery

    /// Recurses `directory` and returns files whose name + extension match the profile's
    /// photo or video patterns. A nil name prefix matches any name with a matching extension.
    func discoverFiles(in directory: URL, profile: CameraProfile) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        let matches: (String, String?, [String]) -> Bool = { name, prefix, exts in
            let upper = name.uppercased()
            if let prefix = prefix, !upper.hasPrefix(prefix.uppercased()) { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return exts.contains(ext)
        }

        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let name = fileURL.lastPathComponent
            if matches(name, profile.photoNamePrefix, profile.photoExtensions)
                || matches(name, profile.videoNamePrefix, profile.videoExtensions) {
                results.append(fileURL)
            }
        }
        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter ImporterDiscoveryTests`
Expected: PASS — 4 tests. (`Importer.performImport` still references the old `discoverFiles` call site and other now-changed APIs — that compile error inside `performImport` is fixed in Task 13. `swift test --filter` still builds the whole `CharmeraCore` target, so if `performImport` does not compile, **do Task 13's edits before re-running**. To keep this task self-contained, also apply Step 5 of Task 13's call-site change now if the build fails here.)

> Note for the implementer: Tasks 12 and 13 both edit `Importer.swift` and the target must compile as a whole. If Step 4 here fails to build because `performImport` still calls the old signatures, proceed directly into Task 13 and treat Tasks 12+13 as one commit boundary.

- [ ] **Step 5: Commit**

```bash
git add app/CharmeraCore/Importer.swift app/CharmeraCoreTests/ImporterDiscoveryTests.swift
git commit -m "feat: profile-driven file discovery in Importer"
```

---

## Task 13: Importer — thread CameraProfile through performImport

**Files:**
- Modify: `app/CharmeraCore/Importer.swift`

This propagates the profile into `run`/`performImport` and switches every camera-specific decision to read from it: backup root, hash file, gallery repo, orientation strategy, video conversion. No new unit test — covered by `ImporterDiscoveryTests` (Task 12) and the Task 14 integration run.

- [ ] **Step 1: Change the `run` and `performImport` signatures**

In `app/CharmeraCore/Importer.swift`, change `run(...)` to take a profile as its first parameter and pass it through:

```swift
    public func run(
        profile: CameraProfile,
        reviewOnly: Bool = false,
        skipVideoConversion: Bool = false,
        skipPhotosImport: Bool = false,
        skipOrientation: Bool = false,
        skipUpload: Bool = false
    ) -> Result<ImportCounts, Error> {
        do {
            let counts = try performImport(
                profile: profile,
                reviewOnly: reviewOnly,
                skipVideoConversion: skipVideoConversion,
                skipPhotosImport: skipPhotosImport,
                skipOrientation: skipOrientation,
                skipUpload: skipUpload
            )
            return .success(counts)
        } catch {
            return .failure(error)
        }
    }
```

Change `performImport(...)` to take `profile: CameraProfile` as its first parameter.

- [ ] **Step 2: Replace camera-specific references inside `performImport`**

Apply these substitutions throughout `performImport`:

- `Config.localBackupRoot` → `Config.backupRoot(for: profile)` (the `createDirectory` at the top, and the `backupDir` computation).
- `Config.hashFilePath` → use `Config.hashFilePath(for: profile)` — update `loadImportedHashes` and `saveImportedHashes` to take a `profile` parameter and use it (see Step 3).
- `Config.cameraVolumePath` guard → replace with the passed-in DCIM path. Change the signature to also accept `dcimPath: String` and remove the internal `Config.cameraVolumePath` lookup. The guard becomes:
  ```swift
  let dcimURL = URL(fileURLWithPath: dcimPath)
  let allFiles = discoverFiles(in: dcimURL, profile: profile)
  ```
- `Config.repoName` (every occurrence in the upload section) → `Config.galleryRepo(for: profile)`. Capture it once near the top of the upload section: `let repo = Config.galleryRepo(for: profile)` and use `repo` thereafter.
- The orientation loop — replace the unconditional `OrientationDetector.detectRotation` call with a strategy switch:
  ```swift
  for photoPath in localPhotos {
      let degrees: Int
      switch profile.orientationStrategy {
      case .vision:
          degrees = OrientationDetector.detectRotation(imagePath: photoPath)
      case .exif:
          degrees = OrientationDetector.exifOrientationDegrees(imagePath: photoPath)
      }
      if degrees != 0 {
          let sipsCommand = "/usr/bin/sips -r \(degrees) \(shellEscape(photoPath)) --out \(shellEscape(photoPath))"
          _ = runShell(sipsCommand)
      }
  }
  ```
- The video conversion section — gate on `profile.videoNeedsConversion`:
  ```swift
  if skipVideoConversion || !profile.videoNeedsConversion {
      print("[Importer] Skipping video conversion")
  } else {
      FFmpegManager.ensureAvailable()
  }
  ```
  and inside the `for aviPath in localVideos` loop, also skip conversion when `!profile.videoNeedsConversion` (treat the original as the kept file in that case — for both current profiles `videoNeedsConversion` is `true`, so this branch is defensive for future cameras).

Also update the `dcimPath` parameter: change `performImport` signature to:

```swift
    private func performImport(
        profile: CameraProfile,
        dcimPath: String,
        reviewOnly: Bool = false,
        skipVideoConversion: Bool = false,
        skipPhotosImport: Bool = false,
        skipOrientation: Bool = false,
        skipUpload: Bool = false
    ) throws -> ImportCounts {
```

and update `run(...)` to accept and forward `dcimPath`:

```swift
    public func run(
        profile: CameraProfile,
        dcimPath: String,
        reviewOnly: Bool = false,
        skipVideoConversion: Bool = false,
        skipPhotosImport: Bool = false,
        skipOrientation: Bool = false,
        skipUpload: Bool = false
    ) -> Result<ImportCounts, Error> {
        do {
            let counts = try performImport(
                profile: profile, dcimPath: dcimPath, reviewOnly: reviewOnly,
                skipVideoConversion: skipVideoConversion, skipPhotosImport: skipPhotosImport,
                skipOrientation: skipOrientation, skipUpload: skipUpload)
            return .success(counts)
        } catch {
            return .failure(error)
        }
    }
```

- [ ] **Step 3: Update the hash helpers to be profile-scoped**

Change `loadImportedHashes()` to `loadImportedHashes(profile: CameraProfile)` and `saveImportedHashes(existing:new:)` to `saveImportedHashes(existing:new:profile:)`. Inside them, replace `Config.hashFilePath` with `Config.hashFilePath(for: profile)` and `Config.localBackupRoot` with `Config.backupRoot(for: profile)`. Update the two call sites in `performImport` to pass `profile`.

- [ ] **Step 4: Update `ImportError.noCameraFound` text**

`performImport` no longer looks up the camera itself, so the `noCameraFound` case is now thrown only by callers. Leave the enum as-is (callers in Tasks 14–16 still use it).

- [ ] **Step 5: Verify the whole CharmeraCore target builds and tests pass**

Run: `cd app && swift test`
Expected: PASS — all `CharmeraCoreTests` green; `CharmeraCore` compiles cleanly.

- [ ] **Step 6: Commit**

```bash
git add app/CharmeraCore/Importer.swift
git commit -m "feat: thread CameraProfile through Importer import flow"
```

---

## Task 14: AppDelegate — profile-aware connection, import, and menu

**Files:**
- Modify: `app/Charmera/AppDelegate.swift`

`AppDelegate` is UI code with no unit tests; verify by build + manual run. Every reference to the old `Config.cameraVolumePath` / `Config.repoName` / `Importer().run(...)` must be updated.

- [ ] **Step 1: Add active-camera state and replace the connection check**

Near the other stored properties in `AppDelegate`, add:

```swift
    /// The camera resolved on the most recent scan, or nil when no camera is connected.
    private var activeCamera: Config.DetectedCamera?
    private let cameraMemory = CameraMemory()
```

Replace the `isCameraConnected` computed property:

```swift
    private var isCameraConnected: Bool { activeCamera != nil }
```

Add a scan method and call it wherever the old code polled connection (the same timer/notification path that currently calls `checkCameraConnectTransition`):

```swift
    /// Re-scans for a connected camera and updates `activeCamera`. When a volume has a
    /// DCIM folder but cannot be auto-identified, prompts the user to pick a profile and
    /// remembers the choice against the volume UUID.
    private func refreshActiveCamera() {
        switch Config.detectConnectedCamera(memory: cameraMemory) {
        case .found(let detected):
            activeCamera = detected
        case .needsUserChoice(let unidentified):
            activeCamera = promptForCameraChoice(unidentified)
        case .none:
            activeCamera = nil
        }
    }

    /// Shows a modal asking which camera an unidentified volume is. Returns a
    /// `DetectedCamera` once chosen (and persists the mapping), or nil if cancelled.
    private func promptForCameraChoice(_ volume: Config.UnidentifiedCamera) -> Config.DetectedCamera? {
        let alert = NSAlert()
        alert.messageText = "Which camera is this?"
        alert.informativeText = "Charmera couldn't identify the connected card automatically."
        for profile in CameraRegistry.all {
            alert.addButton(withTitle: profile.displayName)
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < CameraRegistry.all.count else { return nil }
        let profile = CameraRegistry.all[index]
        if let uuid = volume.volumeUUID {
            cameraMemory.remember(profileID: profile.id, forVolumeUUID: uuid)
        }
        return Config.DetectedCamera(
            profile: profile,
            dcimPath: volume.volumeRoot.appendingPathComponent("DCIM").path,
            volumeRoot: volume.volumeRoot,
            volumeUUID: volume.volumeUUID)
    }
```

Find where the existing polling code reads connection state (the timer that calls `checkCameraConnectTransition` / `updateIcon`) and make it call `refreshActiveCamera()` first.

- [ ] **Step 2: Update `handleImport` to use the active profile**

In `handleImport()`, after the `guard isCameraConnected` check, replace the `Importer().run(...)` block. Change the guard and the async block:

```swift
        guard let camera = activeCamera else {
            showNotification(title: "Charmera", body: "No camera detected. Connect a camera and try again.")
            return
        }
```

(Use `camera` in place of the old `isCameraConnected` guard's failure path; keep `isImporting` guard above it.)

Inside the `DispatchQueue.global` block:

```swift
            let importer = Importer()
            importer.onStatus = { [weak self] status in
                self?.setImportStatus(status)
            }
            let result = importer.run(
                profile: camera.profile,
                dcimPath: camera.dcimPath,
                reviewOnly: reviewBeforeUpload,
                skipVideoConversion: localOnly)
```

In the success branch, replace the gallery-open URL:

```swift
                        if let username = KeychainHelper.githubUsername {
                            let repo = Config.galleryRepo(for: camera.profile)
                            if let url = URL(string: "https://\(username).github.io/\(repo)/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
```

- [ ] **Step 3: Update the context menu — camera name, gallery link, override submenu**

In `showContextMenu()`:

Replace the "Open Gallery" URL construction so it uses the active profile (fall back to `.charmera` when nothing is connected, so the item still works):

```swift
        if let username = KeychainHelper.githubUsername {
            let profile = activeCamera?.profile ?? .charmera
            let repo = Config.galleryRepo(for: profile)
            let galleryURL = "https://\(username).github.io/\(repo)/"
            let openGallery = NSMenuItem(title: "Open Gallery", action: #selector(openGalleryAction(_:)), keyEquivalent: "")
            openGallery.target = self
            openGallery.representedObject = galleryURL
            menu.addItem(openGallery)
        }
```

After the import/review items, add a non-clickable status row and a camera-override submenu when a camera is connected:

```swift
        if let camera = activeCamera {
            menu.addItem(NSMenuItem.separator())
            let status = NSMenuItem(title: "\(camera.profile.displayName) connected", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)

            let overrideItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
            let overrideMenu = NSMenu()
            for profile in CameraRegistry.all {
                let item = NSMenuItem(title: profile.displayName, action: #selector(overrideCameraProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = (profile.id == camera.profile.id) ? .on : .off
                overrideMenu.addItem(item)
            }
            overrideItem.submenu = overrideMenu
            menu.addItem(overrideItem)
        }
```

Add the override action:

```swift
    @objc private func overrideCameraProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String,
              let profile = CameraRegistry.profile(id: profileID),
              let camera = activeCamera else { return }
        if let uuid = camera.volumeUUID {
            cameraMemory.remember(profileID: profile.id, forVolumeUUID: uuid)
        }
        activeCamera = Config.DetectedCamera(
            profile: profile,
            dcimPath: camera.dcimPath,
            volumeRoot: camera.volumeRoot,
            volumeUUID: camera.volumeUUID)
        updateIcon()
    }
```

- [ ] **Step 4: Fix the remaining `Config.cameraVolumePath` use**

At `AppDelegate.swift:317` (the eject path), replace the `Config.cameraVolumePath` lookup with `activeCamera?.volumeRoot.path`. The eject logic that derived the volume root from the DCIM path now uses `activeCamera?.volumeRoot` directly.

- [ ] **Step 5: Build and verify**

Run: `cd app && swift build`
Expected: `Charmera` target compiles. (`charmera-mcp` may still fail — fixed in Task 17.)

- [ ] **Step 6: Commit**

```bash
git add app/Charmera/AppDelegate.swift
git commit -m "feat: profile-aware camera detection and menu in AppDelegate"
```

---

## Task 15: PreferencesWindow — per-camera gallery repo fields

**Files:**
- Modify: `app/Charmera/PreferencesWindow.swift`

- [ ] **Step 1: Replace the single gallery reference with per-camera fields**

`PreferencesWindow.swift:19` builds one gallery URL from `Config.repoName`. Replace that with one read-only URL label **and** one editable repo-name text field per `CameraRegistry.all` entry. For each profile, the text field is bound to `Config.galleryRepo(for:)` / `Config.setGalleryRepo(_:for:)`.

Concretely, where the gallery row is currently built, loop instead:

```swift
        for profile in CameraRegistry.all {
            let repo = Config.galleryRepo(for: profile)

            let label = NSTextField(labelWithString: "\(profile.displayName) gallery repo:")
            // ...add `label` to the layout following the file's existing row pattern...

            let field = NSTextField(string: repo)
            field.target = self
            field.action = #selector(galleryRepoChanged(_:))
            field.identifier = NSUserInterfaceItemIdentifier(profile.id)
            // ...add `field` to the layout following the file's existing row pattern...

            if let username = KeychainHelper.githubUsername {
                let urlLabel = NSTextField(labelWithString: "https://\(username).github.io/\(repo)/")
                // ...add `urlLabel` to the layout...
            }
        }
```

Add the action:

```swift
    @objc private func galleryRepoChanged(_ sender: NSTextField) {
        guard let profileID = sender.identifier?.rawValue,
              let profile = CameraRegistry.profile(id: profileID) else { return }
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            sender.stringValue = Config.galleryRepo(for: profile)
            return
        }
        Config.setGalleryRepo(value, for: profile)
    }
```

> Implementer note: match the existing layout idiom in `PreferencesWindow.swift` (the file already lays out rows for other preferences — reuse that exact pattern for stack views / constraints rather than inventing a new one).

- [ ] **Step 2: Build and verify**

Run: `cd app && swift build`
Expected: `Charmera` target compiles.

- [ ] **Step 3: Commit**

```bash
git add app/Charmera/PreferencesWindow.swift
git commit -m "feat: per-camera gallery repo settings in Preferences"
```

---

## Task 16: ReviewWindow and SetupWindow — per-profile gallery repo

**Files:**
- Modify: `app/Charmera/ReviewWindow.swift`
- Modify: `app/Charmera/SetupWindow.swift`

`ReviewWindow` uploads already-imported files; it needs to know which camera's gallery to push to. `SetupWindow` creates the gallery repo(s) at first-run.

- [ ] **Step 1: Give ReviewWindow an active profile**

`ReviewWindow` is opened by `AppDelegate` after an import. Add a stored `profile: CameraProfile` property to the review controller, defaulting to `.charmera`, and have `AppDelegate` set it from `activeCamera?.profile` before calling `reviewController.show()` (in `handleImport`'s `reviewOnly` success branch).

In `ReviewWindow.swift`, replace every `Config.repoName` (lines ~155, ~161, ~165, ~175, ~309, ~330, ~422, ~436) with `Config.galleryRepo(for: profile)`. Replace `Config.localBackupRoot` at line ~94 with `Config.backupRoot(for: profile)`.

- [ ] **Step 2: SetupWindow creates every camera's gallery repo**

In `SetupWindow.swift` (lines ~56–71), the first-run flow currently creates one repo from `Config.repoName`. Wrap that block in a loop over `CameraRegistry.all`, using each profile's gallery repo:

```swift
        for profile in CameraRegistry.all {
            let repo = Config.galleryRepo(for: profile)
            try api.createRepo(name: repo)
            if let templateDir = /* existing templateDir expression */ {
                try api.pushTemplate(owner: username, repo: repo, templateDir: templateDir)
            }
            try api.enablePages(owner: username, repo: repo)
        }
```

Keep the final success message; if it shows a gallery URL, show the Charmera one (`Config.galleryRepo(for: .charmera)`) as the primary, or list all — match the window's existing copy style.

- [ ] **Step 3: Build and verify**

Run: `cd app && swift build`
Expected: `Charmera` target compiles.

- [ ] **Step 4: Commit**

```bash
git add app/Charmera/ReviewWindow.swift app/Charmera/SetupWindow.swift
git commit -m "feat: per-profile gallery repo in Review and Setup windows"
```

---

## Task 17: charmera-mcp — profile-aware detection and import

**Files:**
- Modify: `app/charmera-mcp/main.swift`

- [ ] **Step 1: Make `detect_camera` report the profile**

At `main.swift:260`, the `detect_camera` tool currently checks `Config.cameraVolumePath`. Replace with `Config.detectConnectedCamera()` and return the profile in the response:

```swift
        switch Config.detectConnectedCamera() {
        case .found(let camera):
            return okJSON([
                "connected": true,
                "cameraId": camera.profile.id,
                "cameraName": camera.profile.displayName,
                "dcimPath": camera.dcimPath,
            ])
        case .needsUserChoice(let volume):
            return okJSON([
                "connected": true,
                "cameraId": NSNull(),
                "needsUserChoice": true,
                "volumePath": volume.volumeRoot.path,
            ])
        case .none:
            return okJSON(["connected": false])
        }
```

(Match the file's existing JSON-response helper — `okJSON`/`errText` here are placeholders for whatever the file already uses; reuse the real helpers.)

- [ ] **Step 2: Resolve the profile once per import tool and thread it through**

At `main.swift:266` and the two `Importer()` call sites (`main.swift:469`, `main.swift:636`), the tools assume a camera. Add a shared helper near the top of the tool definitions:

```swift
    /// Resolves the connected camera for an import tool, or returns an MCP error result.
    func requireCamera() -> Result<Config.DetectedCamera, MCPToolError> {
        switch Config.detectConnectedCamera() {
        case .found(let camera):
            return .success(camera)
        case .needsUserChoice:
            return .failure(.message("A camera is connected but could not be identified. Open the Charmera menu bar app and pick the camera."))
        case .none:
            return .failure(.message("No camera found."))
        }
    }
```

(`MCPToolError` / `.message` are placeholders — reuse the file's existing error type and error-returning idiom.)

At each import tool, call `requireCamera()`, then:
- pass `camera.profile` and `camera.dcimPath` into `importer.run(profile:dcimPath:...)`;
- replace every `Config.repoName` (lines ~293, ~295, ~423, ~450, ~460, ~702, ~782, ~808, ~816) with `Config.galleryRepo(for: camera.profile)`.

- [ ] **Step 3: Build the whole package**

Run: `cd app && swift build`
Expected: All three targets (`CharmeraCore`, `Charmera`, `charmera-mcp`) compile.

- [ ] **Step 4: Run the full test suite**

Run: `cd app && swift test`
Expected: PASS — all `CharmeraCoreTests` green.

- [ ] **Step 5: Commit**

```bash
git add app/charmera-mcp/main.swift
git commit -m "feat: profile-aware detection and import in charmera-mcp"
```

---

## Task 18: Integration verification on real hardware

**Files:** none (manual verification + one commit for any fixes)

- [ ] **Step 1: Build a fresh app bundle**

Run: `cd app && ./build.sh` (the existing build script)
Expected: `app/build/Charmera.app` is produced with no errors.

- [ ] **Step 2: Verify Charmera camera still works (regression)**

Connect the Kodak Charmera. Confirm:
- menu bar icon turns gold; right-click menu shows "Charmera connected";
- "Import" imports `PICT*/MOVI*` files, runs Vision orientation, converts AVI→MP4, pushes to the `charmera-gallery` repo;
- local backup lands in `~/Pictures/Charmera/charmera/`.

- [ ] **Step 3: Verify legacy migration**

On a machine (or a copy of `~/Pictures/Charmera`) with a pre-upgrade layout, launch the app once and confirm date folders + `.imported-hashes` moved into `~/Pictures/Charmera/charmera/`, and no photos re-import.

- [ ] **Step 4: Verify Pentax Optio W90**

Connect the W90 (the card used during spec research). Confirm:
- right-click menu shows "Optio W90 connected";
- "Import" discovers `IMGP*.JPG` + `IMGP*.AVI`, converts the MJPEG/AVI to MP4, pushes to `optio-w90-gallery` (auto-created by SetupWindow, or pre-existing);
- local backup lands in `~/Pictures/Charmera/pentax-optio-w90/`;
- a second import with no new files reports "No new photos or videos" and does nothing.

- [ ] **Step 5: Verify the camera-override + memory path**

With the W90 connected, use the menu's "Camera ▸ Charmera" override, confirm the checkmark moves, then unplug and replug the W90 — it should come back identified as Charmera (remembered by volume UUID). Override it back to "Optio W90" to leave the mapping correct.

- [ ] **Step 6: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration fixes from real-hardware verification"
```

(If no fixes were needed, skip this step.)

---

## Self-Review

**Spec coverage:**
- `CameraProfile` struct + registry → Task 2.
- Detection chain: remembered UUID → markers → EXIF → user → Tasks 3, 4, 5, 6, 7; wired into `Config` in Task 8; user prompt in Task 14.
- User override (menu submenu, rewrites memory) → Task 14.
- Profile-threaded `Importer` (discovery, orientation strategy, conditional video conversion, empty-camera) → Tasks 12, 13; empty-camera surfacing already exists in `Importer` and is covered by `testEmptyDcimDiscoversNothing` + Task 18 Step 4.
- Per-camera namespacing (backup root, hash file, gallery repo) → Task 9.
- Legacy migration → Task 10.
- UI (menu shows camera name, override submenu, per-camera gallery prefs) → Tasks 14, 15.
- ReviewWindow/SetupWindow gallery repo → Task 16.
- MCP `detect_camera` + profile-aware import tools → Task 17.
- Testing strategy (pure-data matching, importer branching, migration) → Tasks 2–13 test steps; integration → Task 18.

**Placeholder scan:** The only intentional "match the existing idiom" notes are in Tasks 15 and 17, where the surrounding file's layout/JSON/error helpers must be reused rather than guessed — these are explicit instructions to follow existing patterns, not unfilled TODOs. All code-bearing steps contain complete code.

**Type consistency:** `CameraProfile`, `OrientationStrategy`, `CameraRegistry`, `CameraDetection.{profileByMarkers,profileByEXIF,exifMakeModel,resolve}`, `CameraResolution`, `CameraMemory.{profile(forVolumeUUID:),remember(profileID:forVolumeUUID:)}`, `Config.{volumeUUID,detectConnectedCamera,DetectedCamera,UnidentifiedCamera,CameraScanResult,backupRoot,hashFilePath,galleryRepo,setGalleryRepo,migrateLegacyLayoutIfNeeded}`, `OrientationDetector.exifOrientationDegrees`, `Importer.{discoverFiles(in:profile:),run(profile:dcimPath:...),performImport(profile:dcimPath:...)}` — names are used consistently across all tasks.

**Known cross-task coupling:** Tasks 12 and 13 both edit `Importer.swift`; Task 12's Step 4 note and Task 13's Step 5 acknowledge the target only compiles cleanly after Task 13. This is called out explicitly rather than hidden.
