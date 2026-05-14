import AppKit
import CharmeraCore

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var isImporting = false
    private var importStatus: String = ""
    /// Tracks the previous poll's camera state so we can fire an action on the
    /// rising edge (false → true) without spamming on every 2-second tick.
    private var lastCameraConnected: Bool = false

    private let setupController = SetupWindowController()
    private let prefsController = PreferencesWindowController()
    private let reviewController = ReviewWindowController()

    /// The camera resolved on the most recent scan, or nil when no camera is connected.
    private var activeCamera: Config.DetectedCamera?
    private let cameraMemory = CameraMemory()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // One-time migration: move pre-multi-camera layout into per-profile subdirs.
        Config.migrateLegacyLayoutIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "K"
            button.target = self
            button.action = #selector(statusItemLeftClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshActiveCamera()
        updateIcon()

        lastCameraConnected = isCameraConnected
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshActiveCamera()
            self.updateIcon()
            self.checkCameraConnectTransition()
        }

        // Register for URL scheme callbacks
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Show setup if no token
        if KeychainHelper.githubToken == nil {
            setupController.show()
        }
    }

    // MARK: - URL Scheme Handling

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == Config.githubCallbackScheme,
              url.host == "callback" else {
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            return
        }

        setupController.handleCallback(code: code)
    }

    // MARK: - Status Item

    private var isCameraConnected: Bool { activeCamera != nil }

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

    /// Fires once when the camera transitions from disconnected → connected.
    /// Honors the `cameraConnectAction` user default: "none" (default), "auto"
    /// (run the standard import), or "claude" (open Terminal with a curated
    /// Claude Code session driving the charmera-mcp tools).
    private func checkCameraConnectTransition() {
        let now = isCameraConnected
        defer { lastCameraConnected = now }
        guard now, !lastCameraConnected, !isImporting else { return }
        let action = UserDefaults.standard.string(forKey: "cameraConnectAction") ?? "none"
        switch action {
        case "auto":
            handleImport()
        case "claude":
            importViaClaude()
        default:
            break
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let color: NSColor
        if isImporting {
            color = .systemBlue
        } else if isCameraConnected {
            color = NSColor(red: 1.0, green: 0.718, blue: 0.0, alpha: 1.0)
        } else {
            color = .gray
        }

        let title = isImporting && !importStatus.isEmpty ? "K \(importStatus)" : "K"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: isImporting && !importStatus.isEmpty ? 11 : 14, weight: .bold),
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    private func setImportStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.importStatus = status
            self?.updateIcon()
        }
    }

    // MARK: - Click Handling

    @objc private func statusItemLeftClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            handleImport()
        }
    }

    private func handleImport() {
        guard KeychainHelper.githubToken != nil else {
            setupController.show()
            return
        }

        guard !isImporting else { return }
        guard let camera = activeCamera else {
            showNotification(title: "Charmera", body: "No camera detected. Connect a camera and try again.")
            return
        }

        isImporting = true
        updateIcon()

        let localOnly = UserDefaults.standard.object(forKey: "localOnly") as? Bool ?? false
        let reviewBeforeUpload = localOnly || (UserDefaults.standard.object(forKey: "reviewBeforeUpload") as? Bool ?? false)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let importer = Importer()
            importer.onStatus = { [weak self] status in
                self?.setImportStatus(status)
            }
            let result = importer.run(
                profile: camera.profile,
                dcimPath: camera.dcimPath,
                reviewOnly: reviewBeforeUpload,
                skipVideoConversion: localOnly)

            DispatchQueue.main.async {
                self?.isImporting = false
                self?.importStatus = ""
                self?.updateIcon()

                switch result {
                case .success(let counts):
                    if counts.photos == 0 && counts.videos == 0 {
                        self?.showNotification(
                            title: "Charmera",
                            body: "No new photos or videos found on camera."
                        )
                    } else if counts.reviewOnly {
                        let msg = localOnly
                            ? "\(counts.photos) photo(s) and \(counts.videos) video(s) saved locally. Upload later from Review Photos."
                            : "\(counts.photos) photo(s) ready for review."
                        self?.showNotification(title: "Charmera", body: msg)
                        self?.reviewController.profile = camera.profile
                        self?.reviewController.show()
                    } else {
                        self?.showNotification(
                            title: "Charmera Import Complete",
                            body: "\(counts.photos) photo(s) and \(counts.videos) video(s) imported."
                        )
                        if let username = KeychainHelper.githubUsername {
                            let repo = Config.galleryRepo(for: camera.profile)
                            if let url = URL(string: "https://\(username).github.io/\(repo)/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                case .failure(let error):
                    self?.showNotification(
                        title: "Charmera Import Failed",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        let menu = NSMenu()

        if let username = KeychainHelper.githubUsername {
            let profile = activeCamera?.profile ?? .charmera
            let repo = Config.galleryRepo(for: profile)
            let galleryURL = "https://\(username).github.io/\(repo)/"
            let openGallery = NSMenuItem(title: "Open Gallery", action: #selector(openGalleryAction(_:)), keyEquivalent: "")
            openGallery.target = self
            openGallery.representedObject = galleryURL
            menu.addItem(openGallery)
        }

        let importItem = NSMenuItem(title: "Import", action: #selector(importMenuAction), keyEquivalent: "")
        importItem.target = self
        importItem.isEnabled = !isImporting && isCameraConnected
        menu.addItem(importItem)

        let claudeItem = NSMenuItem(title: "Import via Claude…", action: #selector(importViaClaude), keyEquivalent: "")
        claudeItem.target = self
        claudeItem.isEnabled = !isImporting && isCameraConnected
        claudeItem.toolTip = "Open a Claude Code session that drives the curated import flow via the bundled charmera-mcp server. Claude reviews each photo and video for orientation before pushing to the gallery and Photos.app."
        menu.addItem(claudeItem)

        let review = NSMenuItem(title: "Review Photos", action: #selector(showReview), keyEquivalent: "r")
        review.target = self
        menu.addItem(review)

        if isCameraConnected {
            let eject = NSMenuItem(title: "Eject Camera", action: #selector(ejectCamera), keyEquivalent: "e")
            eject.target = self
            menu.addItem(eject)
        }

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

        menu.addItem(NSMenuItem.separator())

        let prefs = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Charmera", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Reset so left click still works
    }

    @objc private func openGalleryAction(_ sender: NSMenuItem) {
        if let urlString = sender.representedObject as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

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

    @objc private func importMenuAction() {
        handleImport()
    }

    @objc private func importLocalOnlyAction() {
        handleImport()
    }

    /// Open Terminal and start a Claude Code session pre-loaded with a prompt that
    /// drives the curated import flow via the bundled charmera-mcp server. Claude reads
    /// each photo + video, decides orientation, rotates, then pushes to gallery + Photos.
    @objc private func importViaClaude() {
        let prompt = """
        The Charmera camera is plugged in. Run a curated import using the charmera MCP server:
        1. Call detect_camera to confirm the mount.
        2. Call prepare_camera_import to copy new files locally without auto-orienting.
        3. For each returned photo path, call read_photo and decide whether it needs rotation. If yes, call rotate_photo.
        4. For each video path, call read_video_frame and call rotate_video if rotation is needed.
        5. Build the data.json entry list, then call push_to_gallery with adds=[{localPath, galleryFilename}] for each file (use today's date suffix on collisions) and dataJsonEntries set to the merged list.
        6. Call import_to_photos with the same paths.
        Report counts of photos rotated, videos rotated, files pushed.
        """
        // Optional working directory — claude is project-scoped (cwd matters for file
        // refs and project-level config overrides). The charmera-mcp server is at user
        // scope so it's available regardless, but the user usually wants claude launched
        // from their projects root. Empty = Terminal default.
        let workingDir = UserDefaults.standard.string(forKey: "claudeWorkingDir") ?? ""
        let cdPrefix: String
        if workingDir.isEmpty {
            cdPrefix = ""
        } else {
            let expanded = NSString(string: workingDir).expandingTildeInPath
            // Single-quote the path; escape any embedded single quotes via the standard
            // shell-quoting trick. This builds: `cd '<path>' && `
            let escaped = expanded.replacingOccurrences(of: "'", with: "'\\''")
            cdPrefix = "cd '\(escaped)' && "
        }

        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(cdPrefix)claude " & quoted form of "\(prompt.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not launch Claude Code"
            alert.informativeText = "osascript failed to start Terminal: \(error.localizedDescription). Make sure Terminal.app and the `claude` CLI are both installed."
            alert.runModal()
        }
    }

    @objc private func ejectCamera() {
        guard let camera = activeCamera else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: camera.volumeRoot)
            activeCamera = nil
            showNotification(title: "Charmera", body: "Camera ejected safely.")
            updateIcon()
        } catch {
            showNotification(title: "Charmera", body: "Eject failed: \(error.localizedDescription)")
        }
    }

    @objc private func showReview() {
        reviewController.profile = activeCamera?.profile ?? .charmera
        reviewController.show()
    }

    @objc private func showPreferences() {
        if KeychainHelper.githubToken == nil {
            setupController.show()
        } else {
            prefsController.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \"\(safeBody)\" with title \"\(safeTitle)\""]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
