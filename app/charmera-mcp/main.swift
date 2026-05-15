import Foundation
import MCP
import CharmeraCore

// MARK: - Helpers

func text(_ s: String) -> Tool.Content {
    .text(text: s, annotations: nil, _meta: nil)
}

func jsonText(_ object: Any) -> Tool.Content {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return text(String(data: data, encoding: .utf8) ?? "{}")
}

func errText(_ message: String) -> CallTool.Result {
    .init(content: [text(message)], isError: true)
}

/// Read a Keychain item via the `security` CLI. The MCP helper is signed
/// with a different identifier than Charmera.app, so it can't read tokens
/// directly via SecItemCopyMatching (the items live in a different access
/// group, and `keychain-access-groups` entitlements require a provisioning
/// profile that Developer ID signing doesn't bundle). The `security` CLI
/// goes through Security.framework with the user's login keychain — the
/// first read prompts the user, who can click "Always Allow."
func readKeychain(account: String, service: String = "com.charmera.app") -> String? {
    let proc = Process()
    let stdoutPipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    proc.standardOutput = stdoutPipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return nil
    }
    guard proc.terminationStatus == 0 else { return nil }
    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func githubAuth() -> (token: String, username: String)? {
    guard let token = readKeychain(account: "github_token"),
          let username = readKeychain(account: "github_username") else { return nil }
    return (token, username)
}

/// Produce a downscaled JPEG of the photo at `path`, fitting within a
/// `maxDim`x`maxDim` square (sips `-Z`). For orientation/composition
/// decisions a 320px thumbnail is roughly 1/10th the bytes of the full
/// JPEG, which dominates token cost when the model reads many photos
/// in a row.
func thumbnailJPEG(path: String, maxDim: Int) -> Data? {
    let tmpPath = "\(NSTemporaryDirectory())charmera-thumb-\(UUID().uuidString).jpg"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    proc.arguments = ["-Z", String(maxDim), "-s", "format", "jpeg", path, "--out", tmpPath]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch { return nil }
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }
    guard proc.terminationStatus == 0 else { return nil }
    return FileManager.default.contents(atPath: tmpPath)
}

// MARK: - Tool Definitions

let tools: [Tool] = [
    Tool(
        name: "detect_camera",
        description: "Check whether the Kodak Charmera camera is plugged in. Returns connection status and the path to the camera's DCIM directory if mounted.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    ),
    Tool(
        name: "list_camera_files",
        description: "List photo and video files currently on the camera's SD card. Does not copy or modify anything. Returns filename, size, and kind (photo/video) for each.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    ),
    Tool(
        name: "read_gallery_data",
        description: "Fetch entries from the gallery's data.json on GitHub. Defaults to the last 50 entries (chronological tail) — the full file is ~115KB / ~50K tokens at 600+ entries and dominates context if you don't need it all. Pass `all: true` to get the whole array, or `tail: N` for a specific count, or `filenamePrefix` to filter. Pass `mode: \"filenames\"` for a flat array of filenames only — best for collision checks (drops timestamp/url/type/hash and is ~10x smaller).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tail": .object(["type": .string("integer"), "description": .string("Return the last N entries. Default 50. Ignored if all=true."), "default": .int(50)]),
                "all": .object(["type": .string("boolean"), "description": .string("Return the full array. Use sparingly — large galleries blow past tool-result size limits."), "default": .bool(false)]),
                "filenamePrefix": .object(["type": .string("string"), "description": .string("Return only entries whose filename starts with this string. Combine with all/tail for additional filtering.")]),
                "mode": .object(["type": .string("string"), "enum": .array([.string("full"), .string("filenames")]), "default": .string("full"), "description": .string("'full' (default) returns entry objects. 'filenames' returns a flat array of filenames only — use this for collision checks.")]),
            ]),
        ])
    ),
    Tool(
        name: "rotate_photo",
        description: "Rotate a local photo file in place by 90, 180, or 270 degrees clockwise. Uses /usr/bin/sips. Operates on a local backup file path under ~/Pictures/Charmera. Pass `verify: true` to also receive a 320px thumbnail of the result in the same response — saves a follow-up read_photo round-trip when chasing the right rotation.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Absolute path to the local photo file")]),
                "degrees": .object(["type": .string("integer"), "description": .string("Clockwise rotation in degrees: 90, 180, or 270"), "enum": .array([.int(90), .int(180), .int(270)])]),
                "verify": .object(["type": .string("boolean"), "default": .bool(false), "description": .string("If true, also return a 320px thumbnail of the rotated result so the caller can confirm in one round-trip.")]),
            ]),
            "required": .array([.string("path"), .string("degrees")]),
        ])
    ),
    Tool(
        name: "push_to_gallery",
        description: "Lower-level upload/delete primitive. Prefer `commit_curated_files` for typical curated imports — that tool handles naming, hashing, timestamps, and merging server-side. Use this when you need to override gallery filenames manually or do partial updates. One commit = one Pages build. Adds are local file paths uploaded to docs/media/. Deletes are gallery filenames (the bare name, not docs/media/<name>). Use appendEntries to add new rows to data.json — the server fetches the existing array, merges, and pushes the result, so you don't need to pass the whole gallery back through the tool call. removeEntryFilenames drops matching rows.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "adds": .object(["type": .string("array"), "items": .object(["type": .string("object"), "properties": .object(["localPath": .object(["type": .string("string")]), "galleryFilename": .object(["type": .string("string")])])])]),
                "deletes": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "message": .object(["type": .string("string"), "description": .string("Commit message")]),
                "appendEntries": .object(["type": .string("array"), "description": .string("Recommended for new uploads. New data.json rows to append; the server merges with the existing array. Each entry is {type, filename, url, hash, timestamp}.")]),
                "removeEntryFilenames": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Filenames to drop from data.json during the merge. Independent of `deletes` (which removes the file blob).")]),
            ]),
            "required": .array([.string("message")]),
        ])
    ),
    Tool(
        name: "import_roll",
        description: "Run the full Charmera import pipeline: detect camera, copy new files, fix orientation, convert AVI→MP4, and push to the GitHub gallery in a single commit. By default skips Photos.app integration (the menu-bar Charmera.app handles that). Returns counts and any errors.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "skipPhotosImport": .object(["type": .string("boolean"), "description": .string("Skip the Photos.app step (default true for MCP — the .app handles it)"), "default": .bool(true)]),
                "skipVideoConversion": .object(["type": .string("boolean"), "description": .string("Skip AVI→MP4 conversion (default false)"), "default": .bool(false)]),
            ]),
        ])
    ),
    Tool(
        name: "read_video_frame",
        description: "Extract the first frame of a local video and return it as image content so the model can evaluate orientation. Use before deciding whether to call rotate_video. Path is the absolute filesystem path to an .mp4 (or any ffmpeg-readable video).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Absolute path to a local video")]),
            ]),
            "required": .array([.string("path")]),
        ])
    ),
    Tool(
        name: "rotate_video",
        description: "Rotate a local video file by 90, 180, or 270 degrees clockwise. Re-encodes via ffmpeg with -vf transpose; slower than rotate_photo but rare. Operates in place — the file is replaced atomically on success. Use only when convertAVItoMP4's auto-orient picked the wrong rotation.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Absolute path to a local .mp4")]),
                "degrees": .object(["type": .string("integer"), "description": .string("Clockwise rotation: 90, 180, or 270"), "enum": .array([.int(90), .int(180), .int(270)])]),
            ]),
            "required": .array([.string("path"), .string("degrees")]),
        ])
    ),
    Tool(
        name: "read_photo",
        description: "Read a local photo and return it as image content so the model can see it. Defaults to a 320px thumbnail (`purpose: \"orientation\"`) — sufficient for orientation/composition decisions and ~10x cheaper in tokens than the full JPEG. Use `purpose: \"review\"` for full resolution (blur, fine detail). For multiple photos in one go, prefer `read_photos`.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Absolute path to a local photo")]),
                "purpose": .object(["type": .string("string"), "enum": .array([.string("orientation"), .string("review")]), "default": .string("orientation"), "description": .string("'orientation' (default) returns a 320px thumbnail. 'review' returns the full-resolution file.")]),
            ]),
            "required": .array([.string("path")]),
        ])
    ),
    Tool(
        name: "read_photos",
        description: "Batch version of `read_photo`. Returns one labeled thumbnail per path in a single response so a single tool call covers N orientation decisions. Defaults to 320px thumbnails. For full-resolution access, call `read_photo` per file with `purpose: \"review\"`.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "paths": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute paths to local photos")]),
                "maxDim": .object(["type": .string("integer"), "default": .int(320), "description": .string("Max thumbnail edge in pixels (default 320). Bigger = more tokens.")]),
            ]),
            "required": .array([.string("paths")]),
        ])
    ),
    Tool(
        name: "import_to_photos",
        description: "Import the given local files into the user's Photos.app library, adding them to the 'Charmera' album. Delegates to Charmera.app (which owns the Photos.app TCC scope) — make sure /Applications/Charmera.app is installed. Returns a JSON summary with imported/requested counts.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "paths": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute paths of photos/videos to import")]),
            ]),
            "required": .array([.string("paths")]),
        ])
    ),
    Tool(
        name: "prepare_camera_import",
        description: "Phase 1 of a curated import: copy new photos+videos from the camera to a local backup folder WITHOUT auto-orientation, GitHub upload, or Photos.app import. Returns per-file metadata (path, size, mtime ISO, kind, suggested hash, suggestedRotation) so the caller doesn't re-stat. The `files` array is the full set still needing publication: files copied this run PLUS any tagged `fromPriorRun:true` — files an earlier prepare copied locally but never pushed to the gallery (recovered by diffing the local backup against the gallery's data.json). Always commit every entry in `files`, including fromPriorRun ones, so nothing is stranded. `newThisRun` and `recovered` break down the counts. Each photo also carries a `suggestedRotation` (0/90/180/270 degrees clockwise) from Vision-based detection — apply it via rotate_photo first, then verify visually with read_photo, then correct if wrong. Subsequent flow: for each photo: apply suggestedRotation → read_photo → rotate_photo if still wrong. For each video: read_video_frame → rotate_video if needed. Then commit_curated_files (server handles collision-renaming, hash, timestamp, data.json merge) → import_to_photos.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "skipVideoConversion": .object(["type": .string("boolean"), "description": .string("Skip AVI→MP4 conversion (default false)"), "default": .bool(false)]),
            ]),
        ])
    ),
    Tool(
        name: "commit_curated_files",
        description: "Recommended single-call commit for curated imports. Pass local file paths + a commit message; the server does everything: reads file size + mtime, names each blob with date-suffix collision rename when needed, generates `<filename>:<size>` hashes, builds data.json entries with ISO timestamps from mtime, merges with the existing data.json, and pushes one batched commit (one Pages build). Caller stays out of state management — no array merging, no timestamp guessing, no naming convention to follow. Returns the commit SHA + the per-file resolved {localPath, galleryFilename, hash, timestamp} report so the caller can chain into import_to_photos.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "files": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object(["type": .string("string"), "description": .string("Absolute path to a local file under ~/Pictures/Charmera/<date>/")]),
                            "type": .object(["type": .string("string"), "enum": .array([.string("photo"), .string("video")]), "description": .string("Optional. Inferred from extension when omitted (.mp4/.mov/.m4v → video, else → photo).")]),
                        ]),
                        "required": .array([.string("path")]),
                    ]),
                ]),
                "deletes": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Gallery filenames (no docs/media/ prefix) to delete from both the file blobs and the data.json array.")]),
                "message": .object(["type": .string("string"), "description": .string("Commit message")]),
            ]),
            "required": .array([.string("message")]),
        ])
    ),
    Tool(
        name: "auth_status",
        description: "Check whether the Charmera GitHub credentials are present in the user's Keychain. Returns the GitHub username and gallery repo info if signed in.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    ),
]

// MARK: - Server

let server = Server(
    name: "charmera-mcp",
    version: "0.2.0",
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: tools)
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {

    case "detect_camera":
        switch Config.detectConnectedCamera() {
        case .found(let camera):
            return .init(content: [jsonText([
                "connected": true,
                "cameraId": camera.profile.id,
                "cameraName": camera.profile.displayName,
                "dcimPath": camera.dcimPath,
            ])], isError: false)
        case .needsUserChoice(let volume):
            return .init(content: [jsonText([
                "connected": true,
                "cameraId": NSNull(),
                "needsUserChoice": true,
                "volumePath": volume.volumeRoot.path,
            ])], isError: false)
        case .none:
            return .init(content: [jsonText(["connected": false])], isError: false)
        }

    case "list_camera_files":
        guard case .found(let detectedCamera) = Config.detectConnectedCamera() else {
            return errText("No camera connected.")
        }
        let fm = FileManager.default
        let dcimURL = URL(fileURLWithPath: detectedCamera.dcimPath)
        let profile = detectedCamera.profile
        // Match semantics of Importer.discoverFiles: prefix match (case-insensitive, nil = any),
        // then extension match (case-insensitive). We keep our own enumerator so we can request
        // fileSizeKey resource values that discoverFiles doesn't fetch.
        let matchesProfile: (String) -> (isPhoto: Bool, isVideo: Bool) = { name in
            let upper = name.uppercased()
            let ext = (name as NSString).pathExtension.lowercased()
            let prefixOK: (String?) -> Bool = { prefix in
                guard let p = prefix else { return true }
                return upper.hasPrefix(p.uppercased())
            }
            let isPhoto = prefixOK(profile.photoNamePrefix) && profile.photoExtensions.contains(ext)
            let isVideo = prefixOK(profile.videoNamePrefix) && profile.videoExtensions.contains(ext)
            return (isPhoto, isVideo)
        }
        var files: [[String: Any]] = []
        let enumerator = fm.enumerator(at: dcimURL, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            let match = matchesProfile(name)
            guard match.isPhoto || match.isVideo else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            files.append([
                "name": name,
                "size": size,
                "kind": match.isPhoto ? "photo" : "video",
            ])
        }
        files.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return .init(content: [jsonText(["files": files, "count": files.count])], isError: false)

    case "read_gallery_data":
        guard let auth = githubAuth() else {
            return errText("Not signed in to GitHub. Open the Charmera menu-bar app to authenticate.")
        }
        guard case .found(let galleryCamera) = Config.detectConnectedCamera() else {
            return errText("No camera connected. Connect the camera so the gallery repo can be determined.")
        }
        let galleryRepo = Config.galleryRepo(for: galleryCamera.profile)
        let api = GitHubAPI(token: auth.token)
        guard let data = api.downloadFile(owner: auth.username, repo: galleryRepo, path: "docs/data.json"),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return errText("Could not download or parse docs/data.json from \(auth.username)/\(galleryRepo).")
        }
        let totalCount = entries.count
        let returnAll = params.arguments?["all"]?.boolValue ?? false
        let tailCount = params.arguments?["tail"]?.intValue ?? 50
        let prefix = params.arguments?["filenamePrefix"]?.stringValue

        var working = entries
        if let p = prefix {
            working = working.filter { ($0["filename"] as? String)?.hasPrefix(p) ?? false }
        }
        if !returnAll {
            let n = max(0, min(tailCount, working.count))
            working = Array(working.suffix(n))
        }
        let mode = params.arguments?["mode"]?.stringValue ?? "full"
        if mode == "filenames" {
            let names = working.compactMap { $0["filename"] as? String }
            return .init(content: [jsonText([
                "totalEntries": totalCount,
                "returned": names.count,
                "truncated": !returnAll && (names.count < totalCount),
                "filenames": names,
            ])], isError: false)
        }
        let payload: [String: Any] = [
            "totalEntries": totalCount,
            "returned": working.count,
            "truncated": !returnAll && (working.count < totalCount),
            "entries": working,
        ]
        return .init(content: [jsonText(payload)], isError: false)

    case "rotate_photo":
        guard let path = params.arguments?["path"]?.stringValue,
              let degrees = params.arguments?["degrees"]?.intValue else {
            return errText("Missing 'path' or 'degrees'.")
        }
        guard [90, 180, 270].contains(degrees) else {
            return errText("'degrees' must be 90, 180, or 270.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return errText("File not found: \(path)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        proc.arguments = ["-r", String(degrees), path, "--out", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                return errText("sips returned non-zero status: \(proc.terminationStatus)")
            }
        } catch {
            return errText("sips failed: \(error.localizedDescription)")
        }
        let verify = params.arguments?["verify"]?.boolValue ?? false
        if verify, let thumb = thumbnailJPEG(path: path, maxDim: 320) {
            return .init(content: [
                jsonText(["rotated": true, "path": path, "degrees": degrees, "verifyThumbnail": true]),
                .image(data: thumb.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil),
            ], isError: false)
        }
        return .init(content: [jsonText(["rotated": true, "path": path, "degrees": degrees])], isError: false)

    case "push_to_gallery":
        guard let auth = githubAuth() else {
            return errText("Not signed in to GitHub.")
        }
        guard let message = params.arguments?["message"]?.stringValue else {
            return errText("Missing 'message'.")
        }
        guard case .found(let pushCamera) = Config.detectConnectedCamera() else {
            return errText("No camera connected. Connect the camera so the gallery repo can be determined.")
        }
        let pushRepo = Config.galleryRepo(for: pushCamera.profile)
        let api = GitHubAPI(token: auth.token)

        // Build adds
        var filesToUpload: [(path: String, content: Data)] = []
        if let addsArray = params.arguments?["adds"]?.arrayValue {
            for entry in addsArray {
                guard let dict = entry.objectValue,
                      let local = dict["localPath"]?.stringValue,
                      let gallery = dict["galleryFilename"]?.stringValue,
                      let data = FileManager.default.contents(atPath: local) else { continue }
                filesToUpload.append((path: "docs/media/\(gallery)", content: data))
            }
        }

        // Build deletes
        var deletes: [String] = []
        if let delArray = params.arguments?["deletes"]?.arrayValue {
            for v in delArray {
                if let s = v.stringValue { deletes.append("docs/media/\(s)") }
            }
        }

        // Helper: flatten an MCP Value array of objects into [[String: Any]] of strings.
        func flattenEntries(_ values: [Value]) -> [[String: Any]] {
            return values.compactMap { v in
                guard let obj = v.objectValue else { return nil }
                var dict: [String: Any] = [:]
                for (k, vv) in obj {
                    if let s = vv.stringValue { dict[k] = s }
                    else if let i = vv.intValue { dict[k] = i }
                    else if let b = vv.boolValue { dict[k] = b }
                }
                return dict
            }
        }

        let appendEntries = params.arguments?["appendEntries"]?.arrayValue.map(flattenEntries) ?? []
        var removeFilenames = Set<String>()
        if let arr = params.arguments?["removeEntryFilenames"]?.arrayValue {
            for v in arr { if let s = v.stringValue { removeFilenames.insert(s) } }
        }

        // Build the new data.json. Two modes:
        //   1. appendEntries / removeEntryFilenames provided → fetch current, merge.
        //   2. neither → don't touch data.json.
        if !appendEntries.isEmpty || !removeFilenames.isEmpty {
            // Fold deleted blobs into the entry-removal set so a single `deletes` arg
            // also drops the corresponding data.json row.
            for path in deletes {
                let basename = (path as NSString).lastPathComponent
                removeFilenames.insert(basename)
            }
            // Pull current array, drop matching filenames, append new ones.
            var existing: [[String: Any]] = []
            if let data = api.downloadFile(owner: auth.username, repo: pushRepo, path: "docs/data.json"),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                existing = arr
            }
            existing.removeAll { entry in
                guard let f = entry["filename"] as? String else { return false }
                return removeFilenames.contains(f)
            }
            // De-dupe new appends against existing filenames so re-runs don't double-list.
            let existingNames = Set(existing.compactMap { $0["filename"] as? String })
            let toAppend = appendEntries.filter {
                guard let f = $0["filename"] as? String else { return false }
                return !existingNames.contains(f)
            }
            let merged = existing + toAppend
            if let json = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
                filesToUpload.append((path: "docs/data.json", content: json))
            }
        }

        guard !filesToUpload.isEmpty || !deletes.isEmpty else {
            return errText("Nothing to push: provide at least one of adds, deletes, appendEntries, or removeEntryFilenames.")
        }

        do {
            let sha = try api.uploadFilesAsOneCommit(
                owner: auth.username,
                repo: pushRepo,
                branch: "main",
                files: filesToUpload,
                deletions: deletes,
                message: message
            )
            return .init(content: [jsonText([
                "commit": sha,
                "uploaded": filesToUpload.count,
                "deleted": deletes.count,
                "pagesUrl": "https://\(auth.username).github.io/\(pushRepo)/",
            ])], isError: false)
        } catch {
            return errText("Push failed: \(error.localizedDescription)")
        }

    case "import_roll":
        guard case .found(let importCamera) = Config.detectConnectedCamera() else {
            return errText("No camera connected.")
        }
        let skipPhotos = params.arguments?["skipPhotosImport"]?.boolValue ?? true
        let skipVideo = params.arguments?["skipVideoConversion"]?.boolValue ?? false
        let importer = Importer()
        var statusLog: [String] = []
        importer.onStatus = { statusLog.append($0) }
        let result = importer.run(profile: importCamera.profile, dcimPath: importCamera.dcimPath, reviewOnly: false, skipVideoConversion: skipVideo, skipPhotosImport: skipPhotos)
        switch result {
        case .success(let counts):
            return .init(content: [jsonText([
                "photos": counts.photos,
                "videos": counts.videos,
                "skippedPhotosApp": skipPhotos,
                "status": statusLog,
            ])], isError: false)
        case .failure(let error):
            return errText("Import failed: \(error.localizedDescription)")
        }

    case "read_video_frame":
        guard let path = params.arguments?["path"]?.stringValue else {
            return errText("Missing 'path'.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return errText("File not found: \(path)")
        }
        let framePath = "\(NSTemporaryDirectory())charmera-frame-\(UUID().uuidString).jpg"
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: FFmpegManager.resolvedPath)
        extract.arguments = ["-y", "-i", path, "-vframes", "1", framePath]
        extract.standardOutput = FileHandle.nullDevice
        extract.standardError = FileHandle.nullDevice
        do {
            try extract.run()
            extract.waitUntilExit()
        } catch {
            return errText("ffmpeg launch failed: \(error.localizedDescription) (try: brew install ffmpeg)")
        }
        defer { try? FileManager.default.removeItem(atPath: framePath) }
        guard extract.terminationStatus == 0,
              let data = FileManager.default.contents(atPath: framePath) else {
            return errText("ffmpeg could not extract a frame from \(path)")
        }
        return .init(content: [.image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)], isError: false)

    case "rotate_video":
        guard let path = params.arguments?["path"]?.stringValue,
              let degrees = params.arguments?["degrees"]?.intValue else {
            return errText("Missing 'path' or 'degrees'.")
        }
        guard [90, 180, 270].contains(degrees) else {
            return errText("'degrees' must be 90, 180, or 270.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return errText("File not found: \(path)")
        }
        let transpose: String
        switch degrees {
        case 90:  transpose = "transpose=1"
        case 180: transpose = "transpose=2,transpose=2"
        case 270: transpose = "transpose=2"
        default:  transpose = "transpose=1"
        }
        let tmpOut = "\(path).rotating-\(UUID().uuidString).mp4"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: FFmpegManager.resolvedPath)
        proc.arguments = ["-y", "-i", path, "-vf", transpose, "-c:v", "h264_videotoolbox", "-b:v", "2M", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", tmpOut]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return errText("ffmpeg launch failed: \(error.localizedDescription)")
        }
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmpOut) else {
            try? FileManager.default.removeItem(atPath: tmpOut)
            return errText("ffmpeg failed (status \(proc.terminationStatus))")
        }
        do {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmpOut))
        } catch {
            try? FileManager.default.removeItem(atPath: tmpOut)
            return errText("Could not replace original: \(error.localizedDescription)")
        }
        return .init(content: [jsonText(["rotated": true, "path": path, "degrees": degrees])], isError: false)

    case "read_photo":
        guard let path = params.arguments?["path"]?.stringValue else {
            return errText("Missing 'path'.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return errText("File not found: \(path)")
        }
        let purpose = params.arguments?["purpose"]?.stringValue ?? "orientation"
        if purpose == "orientation" {
            guard let thumb = thumbnailJPEG(path: path, maxDim: 320) else {
                return errText("Could not generate thumbnail for: \(path)")
            }
            return .init(content: [.image(data: thumb.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)], isError: false)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return errText("Could not read file: \(path)")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "png":         mime = "image/png"
        case "heic":        mime = "image/heic"
        default:            mime = "application/octet-stream"
        }
        return .init(content: [.image(data: data.base64EncodedString(), mimeType: mime, annotations: nil, _meta: nil)], isError: false)

    case "read_photos":
        guard let pathsArr = params.arguments?["paths"]?.arrayValue else {
            return errText("Missing 'paths' array.")
        }
        let paths: [String] = pathsArr.compactMap { $0.stringValue }
        guard !paths.isEmpty else {
            return errText("'paths' is empty.")
        }
        let maxDim = params.arguments?["maxDim"]?.intValue ?? 320
        var content: [Tool.Content] = []
        for (i, path) in paths.enumerated() {
            let label = "[\(i)] \(path)"
            guard FileManager.default.fileExists(atPath: path) else {
                content.append(text("\(label) — file not found"))
                continue
            }
            guard let thumb = thumbnailJPEG(path: path, maxDim: maxDim) else {
                content.append(text("\(label) — could not generate thumbnail"))
                continue
            }
            content.append(text(label))
            content.append(.image(data: thumb.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
        }
        return .init(content: content, isError: false)

    case "import_to_photos":
        guard let pathsArr = params.arguments?["paths"]?.arrayValue else {
            return errText("Missing 'paths' array.")
        }
        let paths: [String] = pathsArr.compactMap { $0.stringValue }
        guard !paths.isEmpty else {
            return errText("'paths' is empty.")
        }
        let charmeraBin = "/Applications/Charmera.app/Contents/MacOS/Charmera"
        guard FileManager.default.isExecutableFile(atPath: charmeraBin) else {
            return errText("Charmera.app not installed at /Applications/Charmera.app — install via `brew install --cask timncox/charmera/charmera` or build locally.")
        }
        let proc = Process()
        let stdoutPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: charmeraBin)
        proc.arguments = ["--import-photos"] + paths
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return errText("Charmera --import-photos failed to launch: \(error.localizedDescription)")
        }
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .init(content: [text(outStr.isEmpty ? "{}" : outStr)], isError: proc.terminationStatus != 0)

    case "prepare_camera_import":
        guard case .found(let prepCamera) = Config.detectConnectedCamera() else {
            return errText("No camera connected.")
        }
        let skipVideo = params.arguments?["skipVideoConversion"]?.boolValue ?? false
        let importer = Importer()
        var statusLog: [String] = []
        importer.onStatus = { statusLog.append($0) }
        let result = importer.run(
            profile: prepCamera.profile,
            dcimPath: prepCamera.dcimPath,
            reviewOnly: false,
            skipVideoConversion: skipVideo,
            skipPhotosImport: true,
            skipOrientation: true,
            skipUpload: true
        )
        switch result {
        case .success(let counts):
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fm = FileManager.default

            // Strip a collision suffix ("_1778802174") so a locally-renamed copy still
            // matches its published gallery name.
            func collisionStrip(_ filename: String) -> String {
                let ns = filename as NSString
                let nameOnly = ns.deletingPathExtension
                let ext = ns.pathExtension
                let r = (nameOnly as NSString).range(of: "_\\d{9,11}$", options: .regularExpression)
                guard r.location != NSNotFound else { return filename }
                let stripped = (nameOnly as NSString).substring(to: r.location)
                return ext.isEmpty ? stripped : "\(stripped).\(ext)"
            }
            func matchKeys(_ name: String) -> [String] {
                [name.lowercased(), collisionStrip(name).lowercased()]
            }
            func enrich(_ path: String, fromPriorRun: Bool) -> [String: Any] {
                let url = URL(fileURLWithPath: path)
                let filename = url.lastPathComponent
                let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
                let size = (attrs[.size] as? Int64) ?? (attrs[.size] as? Int).map(Int64.init) ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? Date()
                let ext = url.pathExtension.lowercased()
                let kind = (ext == "mp4" || ext == "mov" || ext == "m4v") ? "video" : "photo"
                var e: [String: Any] = [
                    "path": path,
                    "filename": filename,
                    "size": size,
                    "mtimeISO": isoFormatter.string(from: mtime),
                    "kind": kind,
                    "suggestedHash": "\(filename):\(size)",
                ]
                if fromPriorRun { e["fromPriorRun"] = true }
                // Automated orientation hint for photos — the curated flow skips
                // auto-rotation by design, but supplying a Vision-based suggestion
                // gives the caller a starting point instead of pure eyeballing.
                // Cameras that don't write EXIF orientation (Charmera, Optio W90)
                // produce sideways stored frames for portrait shots; this catches
                // most of them. 0 means "no rotation needed" or "couldn't decide".
                if kind == "photo" {
                    e["suggestedRotation"] = OrientationDetector.detectRotation(imagePath: path)
                }
                return e
            }

            // Files copied on THIS run.
            var enriched: [[String: Any]] = counts.localPaths.map { enrich($0, fromPriorRun: false) }
            var seenPaths = Set(counts.localPaths)

            // Recovery: an earlier prepare_camera_import may have copied files locally
            // that were never published (the curated flow stopped before commit). Those
            // are invisible to the camera-side dedup — so scan the camera's local backup
            // dir and surface anything not yet in the gallery's data.json. This makes a
            // re-run un-strandable: you always get the full set that still needs pushing.
            var publishedKeys = Set<String>()
            if let auth = githubAuth() {
                let repo = Config.galleryRepo(for: prepCamera.profile)
                if let data = GitHubAPI(token: auth.token).downloadFile(
                        owner: auth.username, repo: repo, path: "docs/data.json"),
                   let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for entry in entries {
                        if let name = entry["filename"] as? String {
                            for k in matchKeys(name) { publishedKeys.insert(k) }
                        }
                    }
                }
            }
            var recovered = 0
            let mediaExts: Set<String> = ["jpg", "jpeg", "png", "mp4", "mov", "m4v"]
            let backupRoot = URL(fileURLWithPath: Config.backupRoot(for: prepCamera.profile))
            let walker = fm.enumerator(at: backupRoot, includingPropertiesForKeys: nil)
            while let fileURL = walker?.nextObject() as? URL {
                let path = fileURL.path
                if seenPaths.contains(path) { continue }
                guard mediaExts.contains(fileURL.pathExtension.lowercased()) else { continue }
                let published = matchKeys(fileURL.lastPathComponent).contains { publishedKeys.contains($0) }
                if published { continue }
                enriched.append(enrich(path, fromPriorRun: true))
                seenPaths.insert(path)
                recovered += 1
            }

            let totalPhotos = enriched.filter { ($0["kind"] as? String) == "photo" }.count
            let totalVideos = enriched.filter { ($0["kind"] as? String) == "video" }.count
            let recoveryNote = recovered > 0
                ? " NOTE: \(recovered) file(s) tagged fromPriorRun were prepared by an earlier run but never published — include them in commit_curated_files too so they aren't stranded."
                : ""
            return .init(content: [jsonText([
                "photos": totalPhotos,
                "videos": totalVideos,
                "newThisRun": counts.localPaths.count,
                "recovered": recovered,
                "files": enriched,
                "status": statusLog,
                "nextSteps": "For each photo: if `suggestedRotation` is non-zero, rotate_photo by that amount → read_photo to verify → rotate_photo again only if still wrong. For each video: read_video_frame → rotate_video (if needed). Then commit_curated_files {files: [{path}], message} — server handles collision rename, hash, timestamp, data.json merge in one commit. Finally import_to_photos with the same paths.\(recoveryNote)",
            ])], isError: false)
        case .failure(let error):
            return errText("prepare_camera_import failed: \(error.localizedDescription)")
        }

    case "commit_curated_files":
        guard let auth = githubAuth() else {
            return errText("Not signed in to GitHub.")
        }
        guard let message = params.arguments?["message"]?.stringValue else {
            return errText("Missing 'message'.")
        }
        guard let filesArr = params.arguments?["files"]?.arrayValue, !filesArr.isEmpty else {
            // Allow deletes-only commits, fall through to deletes path below
            if (params.arguments?["deletes"]?.arrayValue ?? []).isEmpty {
                return errText("Provide either 'files' or 'deletes' (or both).")
            }
            return errText("'files' is required for now in commit_curated_files. For pure deletes use push_to_gallery.")
        }
        guard case .found(let commitCamera) = Config.detectConnectedCamera() else {
            return errText("No camera connected. Connect the camera so the gallery repo can be determined.")
        }
        let commitRepo = Config.galleryRepo(for: commitCamera.profile)
        let api = GitHubAPI(token: auth.token)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default

        // Pull current remote tree once for collision detection.
        let existingRemoteNames = api.listDirectoryFilenames(owner: auth.username, repo: commitRepo, path: "docs/media") ?? Set<String>()
        var plannedNames = Set<String>()
        var filesToUpload: [(path: String, content: Data)] = []
        var newEntries: [[String: Any]] = []
        var report: [[String: Any]] = []
        var skipped: [[String: Any]] = []

        for entry in filesArr {
            guard let dict = entry.objectValue,
                  let localPath = dict["path"]?.stringValue else {
                skipped.append(["reason": "missing path", "entry": String(describing: entry)])
                continue
            }
            guard let data = fm.contents(atPath: localPath) else {
                skipped.append(["path": localPath, "reason": "could not read file"])
                continue
            }
            let url = URL(fileURLWithPath: localPath)
            let filename = url.lastPathComponent
            let size = data.count
            // Use import time, not the camera's file mtime: neither the Charmera
            // nor the Pentax W90 has a battery-backed clock, so mtime is typically a
            // stale default (e.g. 2010-01-01) that would scramble gallery sort.
            let now = Date()
            let timestampISO = isoFormatter.string(from: now)
            let dateFolder = dateFormatter.string(from: now)
            let hash = "\(filename):\(size)"

            let extLower = url.pathExtension.lowercased()
            let inferredType = (extLower == "mp4" || extLower == "mov" || extLower == "m4v") ? "video" : "photo"
            let type = dict["type"]?.stringValue ?? inferredType

            // Collision-rename: append _<dateFolder>, then _<dateFolder>_2, _3, … on
            // further collision against either the live remote tree or names already
            // claimed earlier in this same commit.
            var uploadFilename = filename
            let isTaken: (String) -> Bool = { existingRemoteNames.contains($0) || plannedNames.contains($0) }
            if isTaken(uploadFilename) {
                let nameOnly = (filename as NSString).deletingPathExtension
                let extPart = (filename as NSString).pathExtension
                var counter = 1
                while true {
                    let suffix = counter == 1 ? dateFolder : "\(dateFolder)_\(counter)"
                    uploadFilename = extPart.isEmpty ? "\(nameOnly)_\(suffix)" : "\(nameOnly)_\(suffix).\(extPart)"
                    if !isTaken(uploadFilename) { break }
                    counter += 1
                }
            }
            plannedNames.insert(uploadFilename)

            filesToUpload.append((path: "docs/media/\(uploadFilename)", content: data))
            let newEntry: [String: Any] = [
                "type": type,
                "filename": uploadFilename,
                "url": "media/\(uploadFilename)",
                "hash": hash,
                "timestamp": timestampISO,
            ]
            newEntries.append(newEntry)
            report.append([
                "localPath": localPath,
                "galleryFilename": uploadFilename,
                "hash": hash,
                "timestamp": timestampISO,
                "type": type,
                "size": size,
            ])
        }

        // Optional deletes (file blobs + corresponding data.json rows).
        var deletePaths: [String] = []
        var removedNames = Set<String>()
        if let arr = params.arguments?["deletes"]?.arrayValue {
            for v in arr {
                guard let s = v.stringValue else { continue }
                deletePaths.append("docs/media/\(s)")
                removedNames.insert(s)
            }
        }

        // Merge data.json: drop removed rows, append new entries.
        var existingEntries: [[String: Any]] = []
        if let data = api.downloadFile(owner: auth.username, repo: commitRepo, path: "docs/data.json"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existingEntries = arr
        }
        existingEntries.removeAll { entry in
            guard let f = entry["filename"] as? String else { return false }
            return removedNames.contains(f)
        }
        // Dedupe new entries against existing filenames so retries are idempotent.
        let existingNames = Set(existingEntries.compactMap { $0["filename"] as? String })
        let toAppend = newEntries.filter {
            guard let f = $0["filename"] as? String else { return false }
            return !existingNames.contains(f)
        }
        let merged = existingEntries + toAppend
        if let json = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
            filesToUpload.append((path: "docs/data.json", content: json))
        }

        guard !filesToUpload.isEmpty || !deletePaths.isEmpty else {
            return errText("Nothing to push: no readable files and no deletes.")
        }

        do {
            let sha = try api.uploadFilesAsOneCommit(
                owner: auth.username,
                repo: commitRepo,
                branch: "main",
                files: filesToUpload,
                deletions: deletePaths,
                message: message
            )
            return .init(content: [jsonText([
                "commit": sha,
                "pagesUrl": "https://\(auth.username).github.io/\(commitRepo)/",
                "uploaded": report.count,
                "deleted": deletePaths.count,
                "dataJsonRows": merged.count,
                "files": report,
                "skipped": skipped,
            ])], isError: false)
        } catch {
            return errText("Push failed: \(error.localizedDescription)")
        }

    case "auth_status":
        guard let auth = githubAuth() else {
            return .init(content: [jsonText(["signedIn": false])], isError: false)
        }
        let authRepo: String
        if case .found(let authCamera) = Config.detectConnectedCamera() {
            authRepo = Config.galleryRepo(for: authCamera.profile)
        } else {
            authRepo = Config.repoName
        }
        return .init(content: [jsonText([
            "signedIn": true,
            "username": auth.username,
            "repo": authRepo,
            "galleryUrl": "https://\(auth.username).github.io/\(authRepo)/",
        ])], isError: false)

    default:
        return errText("Unknown tool: \(params.name)")
    }
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
