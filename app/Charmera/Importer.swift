import Foundation
import CryptoKit

struct ImportCounts {
    let photos: Int
    let videos: Int
}

class Importer {

    func run() -> Result<ImportCounts, Error> {
        do {
            let counts = try performImport()
            return .success(counts)
        } catch {
            return .failure(error)
        }
    }

    private func performImport() throws -> ImportCounts {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Config.localBackupRoot, withIntermediateDirectories: true)

        guard let token = KeychainHelper.githubToken,
              let username = KeychainHelper.githubUsername else {
            throw ImportError.notAuthenticated
        }

        let api = GitHubAPI(token: token)

        // 1. Discover files
        let dcimURL = URL(fileURLWithPath: Config.cameraVolumePath)
        let allFiles = try discoverFiles(in: dcimURL)
        print("[Importer] Found \(allFiles.count) files on camera")

        // 2. Hash and filter already-imported
        let importedHashes = loadImportedHashes()
        var newFiles: [(url: URL, hash: String)] = []

        for fileURL in allFiles {
            let data = try Data(contentsOf: fileURL)
            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            if !importedHashes.contains(hash) {
                newFiles.append((url: fileURL, hash: hash))
            }
        }

        print("[Importer] \(newFiles.count) new files to import")
        guard !newFiles.isEmpty else {
            return ImportCounts(photos: 0, videos: 0)
        }

        // 3. Copy to local backup
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateFolderName = dateFormatter.string(from: Date())
        let backupDir = "\(Config.localBackupRoot)/\(dateFolderName)"
        try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        var localPhotos: [String] = []
        var localVideos: [String] = []
        var allHashes: [String] = []

        for item in newFiles {
            let filename = item.url.lastPathComponent
            let destPath = "\(backupDir)/\(filename)"

            if !fm.fileExists(atPath: destPath) {
                try fm.copyItem(atPath: item.url.path, toPath: destPath)
            }

            let ext = item.url.pathExtension.lowercased()
            if ext == "jpg" || ext == "jpeg" {
                localPhotos.append(destPath)
            } else if ext == "avi" {
                localVideos.append(destPath)
            }
            allHashes.append(item.hash)
        }

        // 4. Detect orientation and rotate photos
        for photoPath in localPhotos {
            let degrees = OrientationDetector.detectRotation(imagePath: photoPath)
            if degrees != 0 {
                print("[Importer] Rotating \(URL(fileURLWithPath: photoPath).lastPathComponent) by \(degrees)")
                let sipsCommand = "/usr/bin/sips -r \(degrees) \(shellEscape(photoPath)) --out \(shellEscape(photoPath))"
                _ = runShell(sipsCommand)
            }
        }

        // 5. Convert videos from AVI to MP4 via FFmpegManager
        FFmpegManager.ensureAvailable()
        var convertedVideos: [String] = []
        for aviPath in localVideos {
            let mp4Path = aviPath.replacingOccurrences(of: ".avi", with: ".mp4")
                .replacingOccurrences(of: ".AVI", with: ".mp4")
            convertAVItoMP4(input: aviPath, output: mp4Path)
            if fm.fileExists(atPath: mp4Path) {
                convertedVideos.append(mp4Path)
            }
        }

        // 6. Import to Photos.app (if enabled)
        let importToPhotos = UserDefaults.standard.object(forKey: "importToPhotos") as? Bool ?? true
        if importToPhotos {
            let allImportPaths = localPhotos + convertedVideos
            PhotosImporter.importFiles(allImportPaths)
        }

        // 7. Upload to GitHub repo
        let isoFormatter = ISO8601DateFormatter()
        var uploadedCount = 0

        // Build hash map by filename
        var hashByFilename: [String: String] = [:]
        for item in newFiles {
            hashByFilename[item.url.lastPathComponent] = item.hash
            let mp4Name = item.url.lastPathComponent
                .replacingOccurrences(of: ".avi", with: ".mp4")
                .replacingOccurrences(of: ".AVI", with: ".mp4")
            hashByFilename[mp4Name] = item.hash
        }

        let allUploads: [(path: String, type: String)] =
            localPhotos.map { ($0, "photo") } + convertedVideos.map { ($0, "video") }

        var newEntries: [[String: String]] = []

        for item in allUploads {
            let fileURL = URL(fileURLWithPath: item.path)
            let filename = fileURL.lastPathComponent
            let hash = hashByFilename[filename] ?? filename
            let attrs = try? fm.attributesOfItem(atPath: item.path)
            let created = (attrs?[.creationDate] as? Date) ?? Date()
            let timestamp = isoFormatter.string(from: created)

            guard let fileData = fm.contents(atPath: item.path) else {
                print("[Importer] Cannot read file: \(item.path)")
                continue
            }

            // Upload to docs/media/{filename}
            let repoPath = "docs/media/\(filename)"
            do {
                let existingSHA = api.getFileSHA(owner: username, repo: Config.repoName, path: repoPath)
                _ = try api.uploadFile(
                    owner: username,
                    repo: Config.repoName,
                    path: repoPath,
                    content: fileData,
                    message: "Add \(filename)",
                    sha: existingSHA
                )
                uploadedCount += 1
                print("[Importer] Uploaded \(filename)")

                newEntries.append([
                    "type": item.type,
                    "filename": filename,
                    "url": "media/\(filename)",
                    "hash": hash,
                    "timestamp": timestamp,
                ])
            } catch {
                print("[Importer] FAILED to upload \(filename): \(error.localizedDescription)")
            }
        }

        // 8. Update docs/data.json — download existing, append new entries, upload
        if !newEntries.isEmpty {
            updateDataJSON(api: api, owner: username, newEntries: newEntries)
        }

        // 9. Save hashes + delete from camera ONLY if all uploads succeeded
        if uploadedCount == allUploads.count {
            saveImportedHashes(existing: importedHashes, new: allHashes)

            for item in newFiles {
                do {
                    try fm.removeItem(at: item.url)
                    print("[Importer] Deleted \(item.url.lastPathComponent) from camera")
                } catch {
                    print("[Importer] Could not delete \(item.url.lastPathComponent): \(error)")
                }
            }
        } else {
            print("[Importer] Some uploads failed - keeping files on camera and not saving hashes")
        }

        return ImportCounts(photos: localPhotos.count, videos: convertedVideos.count)
    }

    // MARK: - data.json Management

    private func updateDataJSON(api: GitHubAPI, owner: String, newEntries: [[String: String]]) {
        let dataPath = "docs/data.json"

        // Download existing data.json
        var existingEntries: [[String: String]] = []
        let existingSHA = api.getFileSHA(owner: owner, repo: Config.repoName, path: dataPath)

        if let data = api.downloadFile(owner: owner, repo: Config.repoName, path: dataPath) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                existingEntries = json
            }
        }

        // Append new entries
        let allEntries = existingEntries + newEntries

        // Upload updated data.json
        guard let jsonData = try? JSONSerialization.data(withJSONObject: allEntries, options: [.prettyPrinted, .sortedKeys]) else {
            print("[Importer] Failed to serialize data.json")
            return
        }

        do {
            _ = try api.uploadFile(
                owner: owner,
                repo: Config.repoName,
                path: dataPath,
                content: jsonData,
                message: "Update gallery data",
                sha: existingSHA
            )
            print("[Importer] Updated data.json with \(newEntries.count) new entries")
        } catch {
            print("[Importer] Failed to update data.json: \(error.localizedDescription)")
        }
    }

    // MARK: - File Discovery

    private func discoverFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let name = fileURL.lastPathComponent.uppercased()
            if name.hasPrefix("PICT") && name.hasSuffix(".JPG") {
                results.append(fileURL)
            } else if name.hasPrefix("MOVI") && name.hasSuffix(".AVI") {
                results.append(fileURL)
            }
        }

        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Hash Management

    private func loadImportedHashes() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: Config.hashFilePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Set(lines)
    }

    private func saveImportedHashes(existing: Set<String>, new: [String]) {
        var all = existing
        for h in new { all.insert(h) }
        let content = all.sorted().joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: Config.hashFilePath, contents: content.data(using: .utf8))
    }

    // MARK: - Video Conversion

    private func convertAVItoMP4(input: String, output: String) {
        print("[Importer] Converting \(input) to MP4")
        let ffmpeg = FFmpegManager.resolvedPath
        let command = "\(shellEscape(ffmpeg)) -i \(shellEscape(input)) -c:v libx264 -preset fast -crf 23 -c:a aac -b:a 128k -movflags +faststart -y \(shellEscape(output))"
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

enum ImportError: Error, LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to GitHub. Open Charmera preferences to sign in."
        }
    }
}
