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
        // Ensure backup root exists
        let fm = FileManager.default
        try fm.createDirectory(atPath: Config.localBackupRoot, withIntermediateDirectories: true)

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

        // 4. Detect orientation and rotate photos (local Vision framework)
        for photoPath in localPhotos {
            let degrees = OrientationDetector.detectRotation(imagePath: photoPath)
            if degrees != 0 {
                print("[Importer] Rotating \(URL(fileURLWithPath: photoPath).lastPathComponent) by \(degrees)°")
                let sipsCommand = "/usr/bin/sips -r \(degrees) \(shellEscape(photoPath)) --out \(shellEscape(photoPath))"
                _ = runShell(sipsCommand)
            }
        }

        // 5. Convert videos from AVI to MP4
        var convertedVideos: [String] = []
        for aviPath in localVideos {
            let mp4Path = aviPath.replacingOccurrences(of: ".avi", with: ".mp4")
                .replacingOccurrences(of: ".AVI", with: ".mp4")
            convertAVItoMP4(input: aviPath, output: mp4Path)
            if FileManager.default.fileExists(atPath: mp4Path) {
                convertedVideos.append(mp4Path)
            }
        }

        // 6. Import to Photos.app
        let allImportPaths = localPhotos + convertedVideos
        PhotosImporter.importFiles(allImportPaths)

        // 7. Upload to Vercel Blob (sequential — reliable)
        let isoFormatter = ISO8601DateFormatter()
        var uploadedItems: [[String: String]] = []

        // Build a map of original file hash by filename
        var hashByFilename: [String: String] = [:]
        for item in newFiles {
            hashByFilename[item.url.lastPathComponent] = item.hash
            // Also map the .mp4 version for videos
            let mp4Name = item.url.lastPathComponent
                .replacingOccurrences(of: ".avi", with: ".mp4")
                .replacingOccurrences(of: ".AVI", with: ".mp4")
            hashByFilename[mp4Name] = item.hash
        }

        let allUploads: [(path: String, type: String)] =
            localPhotos.map { ($0, "photo") } + convertedVideos.map { ($0, "video") }

        for item in allUploads {
            let fileURL = URL(fileURLWithPath: item.path)
            let filename = fileURL.lastPathComponent
            let hash = hashByFilename[filename] ?? filename
            let attrs = try? fm.attributesOfItem(atPath: item.path)
            let created = (attrs?[.creationDate] as? Date) ?? Date()
            let timestamp = isoFormatter.string(from: created)

            if let result = BlobUploader.upload(filePath: item.path, filename: filename) {
                uploadedItems.append([
                    "type": item.type,
                    "filename": result.filename,
                    "url": result.url,
                    "hash": hash,
                    "timestamp": timestamp,
                ])
                print("[Importer] Uploaded \(filename)")
            } else {
                print("[Importer] FAILED to upload \(filename)")
            }
        }

        // 8. POST metadata to API
        if !uploadedItems.isEmpty {
            postMetadata(items: uploadedItems)
        }

        // 9. Save hashes + delete from camera ONLY if upload succeeded
        if uploadedItems.count == allUploads.count {
            saveImportedHashes(existing: importedHashes, new: allHashes)

            // 10. Delete imported files from camera
            for item in newFiles {
                do {
                    try fm.removeItem(at: item.url)
                    print("[Importer] Deleted \(item.url.lastPathComponent) from camera")
                } catch {
                    print("[Importer] Could not delete \(item.url.lastPathComponent): \(error)")
                }
            }
        } else {
            print("[Importer] Some uploads failed — keeping files on camera and not saving hashes")
        }

        return ImportCounts(photos: localPhotos.count, videos: convertedVideos.count)
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
        let command = "/opt/homebrew/bin/ffmpeg -i \(shellEscape(input)) -c:v libx264 -preset fast -crf 23 -c:a aac -b:a 128k -movflags +faststart -y \(shellEscape(output)) 2>/dev/null"
        _ = runShell(command)
    }

    // MARK: - Metadata POST

    private func postMetadata(items: [[String: String]]) {
        guard let url = URL(string: Config.importAPIURL) else { return }

        let body: [String: Any] = ["items": items]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.importSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                print("[Importer] API POST error: \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[Importer] API POST status: \(httpResponse.statusCode)")
            }
        }
        task.resume()
        semaphore.wait()
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
