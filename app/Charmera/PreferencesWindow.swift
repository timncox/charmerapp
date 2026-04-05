import SwiftUI
import AppKit
import ServiceManagement

// MARK: - PreferencesView

struct PreferencesView: View {
    @State private var startAtLogin: Bool = LoginItemManager.isEnabled
    @State private var importToPhotos: Bool = UserDefaults.standard.object(forKey: "importToPhotos") as? Bool ?? true
    @State private var deleteFromCamera: Bool = UserDefaults.standard.object(forKey: "deleteFromCamera") as? Bool ?? true
    @State private var reviewBeforeUpload: Bool = UserDefaults.standard.object(forKey: "reviewBeforeUpload") as? Bool ?? false
    private let username = KeychainHelper.githubUsername ?? "unknown"

    private var galleryURL: String {
        "https://\(username).github.io/\(Config.repoName)/"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Gallery URL
            GroupBox(label: Text("Gallery").fontWeight(.semibold)) {
                HStack {
                    Text(galleryURL)
                        .textSelection(.enabled)
                        .font(.callout)
                    Spacer()
                    Button("Open") {
                        if let url = URL(string: galleryURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Start at login
            Toggle("Start at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, newValue in
                    LoginItemManager.setEnabled(newValue)
                }

            // Import to Photos.app
            Toggle("Also import to Photos.app", isOn: $importToPhotos)
                .onChange(of: importToPhotos) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "importToPhotos")
                }

            // Delete from camera after import
            Toggle("Delete photos from camera after import", isOn: $deleteFromCamera)
                .onChange(of: deleteFromCamera) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "deleteFromCamera")
                }

            // Review before upload
            Toggle("Review photos before uploading", isOn: $reviewBeforeUpload)
                .onChange(of: reviewBeforeUpload) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "reviewBeforeUpload")
                }

            Divider()

            // Sign out
            HStack {
                Spacer()
                Button("Sign Out of GitHub") {
                    KeychainHelper.githubToken = nil
                    KeychainHelper.githubUsername = nil
                    NSApp.keyWindow?.close()
                }
                .foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Window Controller

class PreferencesWindowController {
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView()
        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Charmera Preferences"
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}
