import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var isImporting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "K"
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        updateIcon()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    private var isCameraConnected: Bool {
        FileManager.default.fileExists(atPath: Config.cameraVolumePath)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        if isImporting {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.systemFont(ofSize: 14, weight: .bold)
            ]
            button.attributedTitle = NSAttributedString(string: "K", attributes: attrs)
        } else if isCameraConnected {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(red: 1.0, green: 0.718, blue: 0.0, alpha: 1.0), // #ffb700
                .font: NSFont.systemFont(ofSize: 14, weight: .bold)
            ]
            button.attributedTitle = NSAttributedString(string: "K", attributes: attrs)
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.gray,
                .font: NSFont.systemFont(ofSize: 14, weight: .bold)
            ]
            button.attributedTitle = NSAttributedString(string: "K", attributes: attrs)
        }
    }

    @objc private func statusItemClicked() {
        guard !isImporting else { return }
        guard isCameraConnected else {
            showNotification(title: "Charmera", body: "No camera detected. Connect the Kodak Charmera and try again.")
            return
        }

        isImporting = true
        updateIcon()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let importer = Importer()
            let result = importer.run()

            DispatchQueue.main.async {
                self?.isImporting = false
                self?.updateIcon()

                switch result {
                case .success(let counts):
                    self?.showNotification(
                        title: "Charmera Import Complete",
                        body: "\(counts.photos) photo(s) and \(counts.videos) video(s) imported."
                    )
                case .failure(let error):
                    self?.showNotification(
                        title: "Charmera Import Failed",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func showNotification(title: String, body: String) {
        // Use osascript — works without entitlements for a CLI-built app
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
