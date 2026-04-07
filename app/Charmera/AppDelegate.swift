import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var isImporting = false
    private var importStatus: String = ""

    private let setupController = SetupWindowController()
    private let prefsController = PreferencesWindowController()
    private let reviewController = ReviewWindowController()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "K"
            button.target = self
            button.action = #selector(statusItemLeftClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateIcon()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateIcon()
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

    private var isCameraConnected: Bool {
        Config.cameraVolumePath != nil
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
        guard isCameraConnected else {
            showNotification(title: "Charmera", body: "No camera detected. Connect the Kodak Charmera and try again.")
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
            let result = importer.run(reviewOnly: reviewBeforeUpload, skipVideoConversion: localOnly)

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
                        self?.reviewController.show()
                    } else {
                        self?.showNotification(
                            title: "Charmera Import Complete",
                            body: "\(counts.photos) photo(s) and \(counts.videos) video(s) imported."
                        )
                        if let username = KeychainHelper.githubUsername,
                           let url = URL(string: "https://\(username).github.io/\(Config.repoName)/") {
                            NSWorkspace.shared.open(url)
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
            let galleryURL = "https://\(username).github.io/\(Config.repoName)/"
            let openGallery = NSMenuItem(title: "Open Gallery", action: #selector(openGalleryAction(_:)), keyEquivalent: "")
            openGallery.target = self
            openGallery.representedObject = galleryURL
            menu.addItem(openGallery)
        }

        let importItem = NSMenuItem(title: "Import", action: #selector(importMenuAction), keyEquivalent: "")
        importItem.target = self
        importItem.isEnabled = !isImporting && isCameraConnected
        menu.addItem(importItem)

        let review = NSMenuItem(title: "Review Photos", action: #selector(showReview), keyEquivalent: "r")
        review.target = self
        menu.addItem(review)

        if isCameraConnected {
            let eject = NSMenuItem(title: "Eject Camera", action: #selector(ejectCamera), keyEquivalent: "e")
            eject.target = self
            menu.addItem(eject)
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

    @objc private func importMenuAction() {
        handleImport()
    }

    @objc private func importLocalOnlyAction() {
        handleImport()
    }

    @objc private func ejectCamera() {
        guard let dcimPath = Config.cameraVolumePath else { return }
        // cameraVolumePath returns e.g. "/Volumes/CHARMERA 1/DCIM", go up to volume root
        let volumePath = URL(fileURLWithPath: dcimPath).deletingLastPathComponent()
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumePath)
            showNotification(title: "Charmera", body: "Camera ejected safely.")
            updateIcon()
        } catch {
            showNotification(title: "Charmera", body: "Eject failed: \(error.localizedDescription)")
        }
    }

    @objc private func showReview() {
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
