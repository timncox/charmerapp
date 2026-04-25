import SwiftUI
import AppKit

// MARK: - Review Data Model

class ReviewPhoto: Identifiable, ObservableObject {
    let id = UUID()
    let filePath: String
    let filename: String
    let dateFolder: String
    weak var parent: ReviewViewModel?
    @Published var rotation: Int = 0 { // 0, 90, 180, 270
        didSet { parent?.objectWillChange.send() }
    }
    @Published var markedForDeletion: Bool = false {
        didSet { parent?.objectWillChange.send() }
    }

    var image: NSImage? {
        NSImage(contentsOfFile: filePath)
    }

    init(filePath: String, dateFolder: String) {
        self.filePath = filePath
        self.filename = URL(fileURLWithPath: filePath).lastPathComponent
        self.dateFolder = dateFolder
    }

    func rotate90() {
        rotation = (rotation + 90) % 360
    }
}

// MARK: - ReviewViewModel

class ReviewViewModel: ObservableObject {
    @Published var photos: [ReviewPhoto] = []
    @Published var isSaving = false
    @Published var saveMessage: String?

    init() {
        loadPhotos()
    }

    func loadPhotos() {
        let fm = FileManager.default
        let baseDir = Config.localBackupRoot
        var allPhotos: [ReviewPhoto] = []

        guard let dateFolders = try? fm.contentsOfDirectory(atPath: baseDir) else { return }

        for folder in dateFolders.sorted().reversed() {
            let folderPath = "\(baseDir)/\(folder)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: folderPath) else { continue }
            for file in files.sorted() {
                let ext = (file as NSString).pathExtension.lowercased()
                guard ext == "jpg" || ext == "jpeg" else { continue }
                allPhotos.append(ReviewPhoto(filePath: "\(folderPath)/\(file)", dateFolder: folder))
            }
        }

        // Dedupe by filename — keep the newest version
        var seen: [String: ReviewPhoto] = [:]
        for photo in allPhotos {
            if let existing = seen[photo.filename] {
                // Keep whichever has a newer modification date
                let existingMod = (try? FileManager.default.attributesOfItem(atPath: existing.filePath))?[.modificationDate] as? Date ?? .distantPast
                let newMod = (try? FileManager.default.attributesOfItem(atPath: photo.filePath))?[.modificationDate] as? Date ?? .distantPast
                if newMod > existingMod {
                    seen[photo.filename] = photo
                }
            } else {
                seen[photo.filename] = photo
            }
        }
        let deduped = seen.values.sorted { $0.filename < $1.filename }
        for photo in deduped { photo.parent = self }
        photos = deduped
    }

    var hasChanges: Bool {
        photos.contains { $0.rotation != 0 || $0.markedForDeletion }
    }

    /// Find the actual repo path for a photo — could be flat or in a date subfolder
    private func resolveRepoPath(api: GitHubAPI, owner: String, photo: ReviewPhoto) -> (path: String, sha: String)? {
        // Try flat path first (how the Importer uploads)
        let flatPath = "docs/media/\(photo.filename)"
        if let sha = api.getFileSHA(owner: owner, repo: Config.repoName, path: flatPath) {
            return (flatPath, sha)
        }
        // Try date subfolder (how manual uploads organized them)
        let datePath = "docs/media/\(photo.dateFolder)/\(photo.filename)"
        if let sha = api.getFileSHA(owner: owner, repo: Config.repoName, path: datePath) {
            return (datePath, sha)
        }
        return nil
    }

    /// Re-fetch the docs/media directory and drop any data.json entries whose
    /// referenced file no longer exists. Self-healing — covers per-session deletes
    /// and any orphans left over from prior failed cleanups.
    private func reconcileDataJSON(api: GitHubAPI, owner: String) {
        let dataPath = "docs/data.json"
        guard let mediaFiles = api.listDirectoryFilenames(owner: owner, repo: Config.repoName, path: "docs/media") else {
            print("[Review] Reconcile skipped: failed to list docs/media")
            return
        }
        guard let dataSHA = api.getFileSHA(owner: owner, repo: Config.repoName, path: dataPath),
              let data = api.downloadFile(owner: owner, repo: Config.repoName, path: dataPath),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else {
            print("[Review] Reconcile skipped: could not load data.json")
            return
        }
        let filtered = entries.filter { entry in
            guard let url = entry["url"] else { return false }
            let basename = (url as NSString).lastPathComponent
            return mediaFiles.contains(basename)
        }
        if filtered.count == entries.count {
            print("[Review] Reconcile: data.json already in sync (\(entries.count) entries)")
            return
        }
        let removed = entries.count - filtered.count
        guard let jsonData = try? JSONSerialization.data(withJSONObject: filtered, options: [.prettyPrinted, .sortedKeys]) else {
            print("[Review] Reconcile failed: could not serialize data.json")
            return
        }
        do {
            _ = try api.uploadFile(
                owner: owner,
                repo: Config.repoName,
                path: dataPath,
                content: jsonData,
                message: "Remove deleted photos from gallery",
                sha: dataSHA
            )
            print("[Review] Reconcile: removed \(removed) orphan entries from data.json")
        } catch {
            print("[Review] Reconcile failed: data.json upload error: \(error.localizedDescription)")
        }
    }

    func applyChanges() {
        isSaving = true
        let rotated = photos.filter { $0.rotation != 0 && !$0.markedForDeletion }
        let deleted = photos.filter { $0.markedForDeletion }

        guard !rotated.isEmpty || !deleted.isEmpty else {
            saveMessage = "No changes to apply."
            isSaving = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var count = 0
            for photo in rotated {
                let command = "/usr/bin/sips -r \(photo.rotation) '\(photo.filePath)' --out '\(photo.filePath)'"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-c", command]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()

                // Re-upload to GitHub
                if let token = KeychainHelper.githubToken,
                   let username = KeychainHelper.githubUsername {
                    let api = GitHubAPI(token: token)
                    if let fileData = FileManager.default.contents(atPath: photo.filePath),
                       let resolved = self?.resolveRepoPath(api: api, owner: username, photo: photo) {
                        _ = try? api.uploadFile(
                            owner: username,
                            repo: Config.repoName,
                            path: resolved.path,
                            content: fileData,
                            message: "Rotate \(photo.filename)",
                            sha: resolved.sha
                        )
                    }
                }
                count += 1
            }

            // Delete marked photos from GitHub
            var deleteCount = 0
            if let token = KeychainHelper.githubToken,
               let username = KeychainHelper.githubUsername {
                let api = GitHubAPI(token: token)
                for photo in deleted {
                    if let resolved = self?.resolveRepoPath(api: api, owner: username, photo: photo) {
                        do {
                            try api.deleteFile(owner: username, repo: Config.repoName, path: resolved.path, sha: resolved.sha, message: "Delete \(photo.filename)")
                            try? FileManager.default.removeItem(atPath: photo.filePath)
                            deleteCount += 1
                        } catch {
                            print("[Review] Failed to delete \(photo.filename): \(error)")
                        }
                    }
                }

                // Reconcile data.json against the actual docs/media listing. Self-heals
                // orphans left behind by earlier failed cleanups too.
                if deleteCount > 0 || !rotated.isEmpty {
                    self?.reconcileDataJSON(api: api, owner: username)
                }
            }

            let deletedIDs = Set(deleted.map { $0.id })
            DispatchQueue.main.async {
                self?.isSaving = false
                var parts: [String] = []
                if count > 0 { parts.append("Rotated \(count) photo(s)") }
                if deleteCount > 0 { parts.append("Deleted \(deleteCount) photo(s) from gallery") }
                self?.saveMessage = parts.joined(separator: ". ") + "."
                for photo in rotated {
                    photo.rotation = 0
                }
                self?.photos.removeAll { deletedIDs.contains($0.id) }
            }
        }
    }

    func uploadAll() {
        isSaving = true
        saveMessage = nil
        let photosToUpload = photos.filter { !$0.markedForDeletion }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let token = KeychainHelper.githubToken,
                  let username = KeychainHelper.githubUsername else {
                DispatchQueue.main.async {
                    self?.isSaving = false
                    self?.saveMessage = "Not signed in."
                }
                return
            }

            let api = GitHubAPI(token: token)
            let isoFormatter = ISO8601DateFormatter()
            let fm = FileManager.default
            var uploadCount = 0
            var newEntries: [[String: String]] = []

            // Import to Photos.app if enabled
            let importToPhotos = UserDefaults.standard.object(forKey: "importToPhotos") as? Bool ?? true
            if importToPhotos {
                let paths = photosToUpload.map { $0.filePath }
                let semaphore = DispatchSemaphore(value: 0)
                PhotosImporter.requestAccessIfNeeded { granted in
                    if granted { PhotosImporter.importFiles(paths) }
                    semaphore.signal()
                }
                semaphore.wait()
            }

            for photo in photosToUpload {
                guard let fileData = fm.contents(atPath: photo.filePath) else { continue }
                let repoPath = "docs/media/\(photo.filename)"
                let existingSHA = api.getFileSHA(owner: username, repo: Config.repoName, path: repoPath)

                do {
                    _ = try api.uploadFile(
                        owner: username,
                        repo: Config.repoName,
                        path: repoPath,
                        content: fileData,
                        message: "Add \(photo.filename)",
                        sha: existingSHA
                    )
                    uploadCount += 1

                    let ext = (photo.filename as NSString).pathExtension.lowercased()
                    let mediaType = (ext == "mp4") ? "video" : "photo"
                    let attrs = try? fm.attributesOfItem(atPath: photo.filePath)
                    let created = (attrs?[.creationDate] as? Date) ?? Date()

                    newEntries.append([
                        "type": mediaType,
                        "filename": photo.filename,
                        "url": "media/\(photo.filename)",
                        "timestamp": isoFormatter.string(from: created),
                    ])
                } catch {
                    print("[Review] Failed to upload \(photo.filename): \(error)")
                }
            }

            // Update data.json
            if !newEntries.isEmpty {
                let dataPath = "docs/data.json"
                var existingEntries: [[String: String]] = []
                let dataSHA = api.getFileSHA(owner: username, repo: Config.repoName, path: dataPath)

                if let data = api.downloadFile(owner: username, repo: Config.repoName, path: dataPath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    existingEntries = json
                }

                // Merge — avoid duplicates by url
                let existingURLs = Set(existingEntries.compactMap { $0["url"] })
                let uniqueNew = newEntries.filter { !existingURLs.contains($0["url"] ?? "") }
                let allEntries = existingEntries + uniqueNew

                if let jsonData = try? JSONSerialization.data(withJSONObject: allEntries, options: [.prettyPrinted, .sortedKeys]) {
                    _ = try? api.uploadFile(
                        owner: username,
                        repo: Config.repoName,
                        path: dataPath,
                        content: jsonData,
                        message: "Update gallery data",
                        sha: dataSHA
                    )
                }
            }

            DispatchQueue.main.async {
                self?.isSaving = false
                self?.saveMessage = "Uploaded \(uploadCount) photo(s) to gallery."
            }
        }
    }
}

// MARK: - ReviewView

struct ReviewView: View {
    @ObservedObject var viewModel: ReviewViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.photos.count) photos")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
                if let msg = viewModel.saveMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundColor(.green)
                }
                Button("Apply Changes") {
                    viewModel.applyChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving || !viewModel.hasChanges)

                Button("Upload to Gallery") {
                    viewModel.uploadAll()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSaving)
            }
            .padding(12)

            if viewModel.isSaving {
                ProgressView("Saving...")
                    .padding()
            }

            // Photo Grid — using VStack+HStack instead of LazyVGrid to fix hit-testing
            ScrollView {
                let cols = 4
                let rows = stride(from: 0, to: viewModel.photos.count, by: cols)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows), id: \.self) { rowStart in
                        HStack(spacing: 8) {
                            ForEach(viewModel.photos[rowStart..<min(rowStart + cols, viewModel.photos.count)]) { photo in
                                PhotoTile(photo: photo)
                            }
                            if viewModel.photos.count - rowStart < cols {
                                Spacer()
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

struct PhotoTile: View {
    @ObservedObject var photo: ReviewPhoto

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image = photo.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 105)
                        .clipped()
                        .rotationEffect(.degrees(Double(photo.rotation)))
                        .allowsHitTesting(false)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 140, height: 105)
                }

                if photo.markedForDeletion {
                    Rectangle()
                        .fill(Color.red.opacity(0.4))
                        .frame(width: 140, height: 105)
                    Image(systemName: "trash.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }

            }
            .frame(width: 140, height: 105)
            .clipped()
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(photo.markedForDeletion ? Color.red : (photo.rotation != 0 ? Color.orange : Color.clear), lineWidth: 2)
            )

            // Buttons row using segmented style for reliable hit testing
            HStack(spacing: 0) {
                Text(photo.markedForDeletion ? "Undo" : "Delete")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(photo.markedForDeletion ? .gray : .red)
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(3)
                    .onTapGesture { photo.markedForDeletion.toggle() }

                if !photo.markedForDeletion {
                    Text("Rotate")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(3)
                        .onTapGesture { photo.rotate90() }
                }
            }
            .frame(width: 140)

            Text(photo.filename)
                .font(.system(size: 9))
                .foregroundColor(photo.markedForDeletion ? .red : .secondary)
                .lineLimit(1)
                .strikethrough(photo.markedForDeletion)

            if photo.rotation != 0 && !photo.markedForDeletion {
                Text("\(photo.rotation)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Window Controller

class ReviewWindowController {
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = ReviewViewModel()
        let view = ReviewView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Review Photos"
        w.contentView = hostingView
        w.contentMinSize = NSSize(width: 400, height: 350)
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}
