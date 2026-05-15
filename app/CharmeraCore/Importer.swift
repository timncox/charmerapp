import Foundation

public struct ImportCounts {
    public let photos: Int
    public let videos: Int
    public let reviewOnly: Bool
    public let localPaths: [String]

    public init(photos: Int, videos: Int, reviewOnly: Bool = false, localPaths: [String] = []) {
        self.photos = photos
        self.videos = videos
        self.reviewOnly = reviewOnly
        self.localPaths = localPaths
    }
}

public class Importer {

    public var onStatus: ((String) -> Void)?

    public init() {}

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

    private func performImport(
        profile: CameraProfile,
        dcimPath: String,
        reviewOnly: Bool = false,
        skipVideoConversion: Bool = false,
        skipPhotosImport: Bool = false,
        skipOrientation: Bool = false,
        skipUpload: Bool = false
    ) throws -> ImportCounts {
        let fm = FileManager.default
        let backupRootPath = Config.backupRoot(for: profile)
        try fm.createDirectory(atPath: backupRootPath, withIntermediateDirectories: true)

        guard let token = KeychainHelper.githubToken,
              let username = KeychainHelper.githubUsername else {
            throw ImportError.notAuthenticated
        }

        let api = GitHubAPI(token: token)

        // 1. Discover files
        let dcimURL = URL(fileURLWithPath: dcimPath)
        let allFiles = discoverFiles(in: dcimURL, profile: profile)
        onStatus?("Found \(allFiles.count) files")
        print("[Importer] Found \(allFiles.count) files on camera")

        // 2. Filter already-imported by filename+size (fast — no camera reads)
        let importedHashes = loadImportedHashes(profile: profile)
        var newFiles: [(url: URL, hash: String)] = []

        for fileURL in allFiles {
            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? Int64) ?? (attrs[.size] as? Int).map(Int64.init) ?? 0
            let key = "\(fileURL.lastPathComponent):\(size)"
            if !importedHashes.contains(key) {
                newFiles.append((url: fileURL, hash: key))
            }
        }

        onStatus?("\(newFiles.count) new files")
        print("[Importer] \(newFiles.count) new files to import")
        guard !newFiles.isEmpty else {
            return ImportCounts(photos: 0, videos: 0)
        }

        // 3. Copy to local backup
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = dateFormatter.string(from: Date())
        let backupDir = "\(backupRootPath)/\(dateFolderName)"
        try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        var localPhotos: [String] = []
        var localVideos: [String] = []
        var allHashes: [String] = []

        for (index, item) in newFiles.enumerated() {
            onStatus?("Copying \(index + 1)/\(newFiles.count)")
            let originalFilename = item.url.lastPathComponent
            var filename = originalFilename
            var destPath = "\(backupDir)/\(filename)"

            // If file already exists locally with different content, make unique name
            if fm.fileExists(atPath: destPath) {
                let nameOnly = (originalFilename as NSString).deletingPathExtension
                let ext = (originalFilename as NSString).pathExtension
                let timestamp = Int(Date().timeIntervalSince1970)
                filename = "\(nameOnly)_\(timestamp).\(ext)"
                destPath = "\(backupDir)/\(filename)"
            }

            try fm.copyItem(atPath: item.url.path, toPath: destPath)

            let ext = item.url.pathExtension.lowercased()
            if profile.photoExtensions.contains(ext) {
                localPhotos.append(destPath)
            } else if profile.videoExtensions.contains(ext) {
                localVideos.append(destPath)
            }
            allHashes.append(item.hash)
        }

        // 4. Detect orientation and rotate photos
        if skipOrientation {
            print("[Importer] Skipping auto-orientation (caller will curate)")
        } else {
            onStatus?("Fixing orientation...")
            for photoPath in localPhotos {
                let degrees: Int
                switch profile.orientationStrategy {
                case .vision:
                    degrees = OrientationDetector.detectRotation(imagePath: photoPath)
                case .exif:
                    degrees = OrientationDetector.exifOrientationDegrees(imagePath: photoPath)
                }
                if degrees != 0 {
                    print("[Importer] Rotating \(URL(fileURLWithPath: photoPath).lastPathComponent) by \(degrees)")
                    let sipsCommand = "/usr/bin/sips -r \(degrees) \(shellEscape(photoPath)) --out \(shellEscape(photoPath))"
                    _ = runShell(sipsCommand)
                }
            }
        }

        // 5. Convert videos from AVI to MP4 via FFmpegManager
        var convertedVideos: [String] = []
        if profile.videoNeedsConversion && !skipVideoConversion {
            FFmpegManager.ensureAvailable()
        }
        for aviPath in localVideos {
            guard profile.videoNeedsConversion else {
                // Profile says no conversion needed — treat original file as the kept file.
                convertedVideos.append(aviPath)
                continue
            }
            if skipVideoConversion {
                // Just keep track for counting purposes
                continue
            }
            // Output is always .mp4 regardless of the source container extension.
            let mp4Path = (aviPath as NSString).deletingPathExtension + ".mp4"
            convertAVItoMP4(input: aviPath, output: mp4Path, autoOrient: !skipOrientation)
            if fm.fileExists(atPath: mp4Path) {
                convertedVideos.append(mp4Path)
            }
        }

        // If review-only mode, stop here — user will review, rotate, delete, then upload from Review window
        if reviewOnly {
            // Still save hashes so they don't re-import
            saveImportedHashes(existing: importedHashes, new: allHashes, profile: profile)

            let deleteFromCamera = UserDefaults.standard.object(forKey: "deleteFromCamera") as? Bool ?? true
            if deleteFromCamera {
                for item in newFiles {
                    try? fm.removeItem(at: item.url)
                }
            }

            return ImportCounts(
                photos: localPhotos.count,
                videos: convertedVideos.count,
                reviewOnly: true,
                localPaths: localPhotos + convertedVideos
            )
        }

        // 6. Import to Photos.app (if enabled)
        let importToPhotos = !skipPhotosImport && (UserDefaults.standard.object(forKey: "importToPhotos") as? Bool ?? true)
        if importToPhotos {
            let semaphore = DispatchSemaphore(value: 0)
            var hasAccess = false
            PhotosImporter.requestAccessIfNeeded { granted in
                hasAccess = granted
                semaphore.signal()
            }
            semaphore.wait()

            if hasAccess {
                let allImportPaths = localPhotos + convertedVideos
                onStatus?("Adding to Photos.app…")
                let imported = PhotosImporter.importFiles(allImportPaths)
                if imported < allImportPaths.count {
                    print("[Importer] Photos.app import partial: \(imported)/\(allImportPaths.count)")
                }
            } else {
                print("[Importer] Photos access denied — skipping Photos.app import")
            }
        }

        // Stop here if the caller wants to drive the upload + Photos.app phase themselves
        // (e.g. charmera-mcp's curated flow: prepare → Claude reviews + rotates → finish).
        // We persist the hashes so a later import_roll call doesn't double-copy these files,
        // and we leave the camera files in place — finish_camera_import handles deletion.
        if skipUpload {
            saveImportedHashes(existing: importedHashes, new: allHashes, profile: profile)
            return ImportCounts(
                photos: localPhotos.count,
                videos: convertedVideos.count,
                reviewOnly: false,
                localPaths: localPhotos + convertedVideos
            )
        }

        // 7. Upload everything in a single commit via the Git Data API.
        // The old loop fired one Contents-API call per file, which created N commits in seconds and
        // overwhelmed the GitHub Pages legacy builder (cascading "Page build failed"). One commit
        // here means one Pages build.
        let isoFormatter = ISO8601DateFormatter()
        let repo = Config.galleryRepo(for: profile)

        var hashByFilename: [String: String] = [:]
        for item in newFiles {
            hashByFilename[item.url.lastPathComponent] = item.hash
            // Output is always .mp4 regardless of the source container extension.
            let mp4Name = (item.url.lastPathComponent as NSString).deletingPathExtension + ".mp4"
            hashByFilename[mp4Name] = item.hash
        }

        let allUploads: [(path: String, type: String)] =
            localPhotos.map { ($0, "photo") } + convertedVideos.map { ($0, "video") }

        // Fetch the remote media listing once to detect filename collisions, instead of one
        // getFileSHA round-trip per file.
        let existingRemoteNames = api.listDirectoryFilenames(owner: username, repo: repo, path: "docs/media") ?? Set<String>()
        var plannedNames = Set<String>()

        var filesToUpload: [(path: String, content: Data)] = []
        var newEntries: [[String: String]] = []

        for (index, item) in allUploads.enumerated() {
            onStatus?("Preparing \(index + 1)/\(allUploads.count)")
            let fileURL = URL(fileURLWithPath: item.path)
            let filename = fileURL.lastPathComponent
            let hash = hashByFilename[filename] ?? filename
            // Use import time, not the camera's file timestamp: neither the Charmera
            // nor the Pentax W90 has a battery-backed clock, so mtime/creationDate is
            // typically a stale default (e.g. 2010-01-01) that would scramble gallery sort.
            let timestamp = isoFormatter.string(from: Date())

            guard let fileData = fm.contents(atPath: item.path) else {
                print("[Importer] Cannot read file: \(item.path)")
                continue
            }

            // Never overwrite an existing remote file: when the camera is reformatted, numbering
            // resets to PICT0000 and would silently clobber unrelated earlier photos. Rename to a
            // date-suffixed variant on collision against either the remote tree or names already
            // claimed earlier in this batch.
            var uploadFilename = filename
            let isTaken: (String) -> Bool = { existingRemoteNames.contains($0) || plannedNames.contains($0) }
            if isTaken(uploadFilename) {
                let nameOnly = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                var counter = 1
                while true {
                    let suffix = counter == 1 ? dateFolderName : "\(dateFolderName)_\(counter)"
                    uploadFilename = ext.isEmpty ? "\(nameOnly)_\(suffix)" : "\(nameOnly)_\(suffix).\(ext)"
                    if !isTaken(uploadFilename) { break }
                    counter += 1
                }
                print("[Importer] \(filename) collides — uploading as \(uploadFilename)")
            }
            plannedNames.insert(uploadFilename)

            filesToUpload.append((path: "docs/media/\(uploadFilename)", content: fileData))
            newEntries.append([
                "type": item.type,
                "filename": uploadFilename,
                "url": "media/\(uploadFilename)",
                "hash": hash,
                "timestamp": timestamp,
            ])
        }

        // Fold the data.json update into the same commit.
        var existingEntries: [[String: String]] = []
        if let data = api.downloadFile(owner: username, repo: repo, path: "docs/data.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            existingEntries = json
        }
        let existingURLs = Set(existingEntries.compactMap { $0["url"] })
        let uniqueNew = newEntries.filter { !existingURLs.contains($0["url"] ?? "") }
        let mergedEntries = existingEntries + uniqueNew
        if let jsonData = try? JSONSerialization.data(withJSONObject: mergedEntries, options: [.prettyPrinted, .sortedKeys]) {
            filesToUpload.append((path: "docs/data.json", content: jsonData))
        }

        let uploadedCount: Int
        if filesToUpload.isEmpty {
            uploadedCount = 0
        } else {
            onStatus?("Uploading \(allUploads.count) files…")
            do {
                _ = try api.uploadFilesAsOneCommit(
                    owner: username,
                    repo: repo,
                    branch: "main",
                    files: filesToUpload,
                    message: "Add \(allUploads.count) media (\(dateFolderName))"
                )
                uploadedCount = allUploads.count
                print("[Importer] Uploaded \(allUploads.count) files + data.json in one commit")
            } catch {
                print("[Importer] Batched upload failed: \(error.localizedDescription)")
                uploadedCount = 0
            }
        }

        // 8. Save hashes + delete from camera ONLY if all uploads succeeded
        if uploadedCount == allUploads.count {
            saveImportedHashes(existing: importedHashes, new: allHashes, profile: profile)

            let deleteFromCamera = UserDefaults.standard.object(forKey: "deleteFromCamera") as? Bool ?? true
            if deleteFromCamera {
                for item in newFiles {
                    do {
                        try fm.removeItem(at: item.url)
                        print("[Importer] Deleted \(item.url.lastPathComponent) from camera")
                    } catch {
                        print("[Importer] Could not delete \(item.url.lastPathComponent): \(error)")
                    }
                }
            }
        } else {
            print("[Importer] Some uploads failed - keeping files on camera and not saving hashes")
        }

        return ImportCounts(
            photos: localPhotos.count,
            videos: convertedVideos.count,
            localPaths: localPhotos + convertedVideos
        )
    }

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

    // MARK: - Hash Management

    private func loadImportedHashes(profile: CameraProfile) -> Set<String> {
        var keys = Set<String>()
        let hashFile = Config.hashFilePath(for: profile)
        let backupRoot = Config.backupRoot(for: profile)

        if let data = FileManager.default.contents(atPath: hashFile),
           let content = String(data: data, encoding: .utf8) {
            keys.formUnion(content.components(separatedBy: .newlines).filter { !$0.isEmpty })
        }

        // Migration: seed filename:size keys from existing local backups so files
        // imported under the old content-hash scheme don't re-import.
        let fm = FileManager.default
        if let dateDirs = try? fm.contentsOfDirectory(atPath: backupRoot) {
            for entry in dateDirs {
                let dirPath = "\(backupRoot)/\(entry)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue,
                      let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
                for file in files {
                    let upper = file.uppercased()
                    let allExts = (profile.photoExtensions + profile.videoExtensions).map { $0.uppercased() }
                    guard allExts.contains(where: { upper.hasSuffix(".\($0)") }) else { continue }
                    guard let attrs = try? fm.attributesOfItem(atPath: "\(dirPath)/\(file)") else { continue }
                    let size = (attrs[.size] as? Int64) ?? (attrs[.size] as? Int).map(Int64.init) ?? 0
                    keys.insert("\(stripCollisionSuffix(file)):\(size)")
                }
            }
        }

        return keys
    }

    private func stripCollisionSuffix(_ filename: String) -> String {
        let ns = filename as NSString
        let nameOnly = ns.deletingPathExtension
        let ext = ns.pathExtension
        let range = (nameOnly as NSString).range(of: "_\\d{9,11}$", options: .regularExpression)
        guard range.location != NSNotFound else { return filename }
        let stripped = (nameOnly as NSString).substring(to: range.location)
        return ext.isEmpty ? stripped : "\(stripped).\(ext)"
    }

    private func saveImportedHashes(existing: Set<String>, new: [String], profile: CameraProfile) {
        var all = existing
        for h in new { all.insert(h) }
        let content = all.sorted().joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: Config.hashFilePath(for: profile), contents: content.data(using: .utf8))
    }

    // MARK: - Video Conversion

    private func convertAVItoMP4(input: String, output: String, autoOrient: Bool = true) {
        let ffmpeg = FFmpegManager.resolvedPath

        var transposeFilter = ""
        if autoOrient {
            // The Charmera has no accelerometer, so the MP4 ships in whatever sensor
            // orientation the camera was held. Sample the first frame, run the same
            // Vision-based detector we use for stills, and bake the rotation into the
            // re-encode via ffmpeg's transpose filter. Skipped when the caller is
            // about to curate (e.g. charmera-mcp's prepare_camera_import).
            let framePath = "\(NSTemporaryDirectory())charmera-frame-\(UUID().uuidString).jpg"
            _ = runShell("\(shellEscape(ffmpeg)) -y -i \(shellEscape(input)) -vframes 1 \(shellEscape(framePath))")
            let degrees = OrientationDetector.detectRotation(imagePath: framePath)
            try? FileManager.default.removeItem(atPath: framePath)
            switch degrees {
            case 90:  transposeFilter = "-vf transpose=1 "
            case 180: transposeFilter = "-vf transpose=2,transpose=2 "
            case 270: transposeFilter = "-vf transpose=2 "
            default:  break
            }
            if degrees != 0 {
                print("[Importer] Rotating video by \(degrees)° during convert")
            }
        }

        print("[Importer] Converting \(input) to MP4")
        let command = "\(shellEscape(ffmpeg)) -i \(shellEscape(input)) \(transposeFilter)-c:v h264_videotoolbox -b:v 2M -c:a aac -b:a 128k -movflags +faststart -y \(shellEscape(output))"
        _ = runShell(command)
    }

    // MARK: - Shell Helpers

    private func runShell(_ command: String) -> String {
        let proc = Process()
        let stdoutPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            print("[Importer] Shell error: \(error)")
            return ""
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func shellEscape(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Import Errors

public enum ImportError: Error, LocalizedError {
    case notAuthenticated
    case noCameraFound

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to GitHub. Open Charmera preferences to sign in."
        case .noCameraFound:
            return "No Charmera camera found."
        }
    }
}
