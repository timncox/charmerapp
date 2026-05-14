import SwiftUI
import AppKit
import ServiceManagement
import CharmeraCore

// MARK: - PreferencesView

struct PreferencesView: View {
    @State private var startAtLogin: Bool = LoginItemManager.isEnabled
    @State private var importToPhotos: Bool = UserDefaults.standard.object(forKey: "importToPhotos") as? Bool ?? true
    @State private var deleteFromCamera: Bool = UserDefaults.standard.object(forKey: "deleteFromCamera") as? Bool ?? true
    @State private var reviewBeforeUpload: Bool = UserDefaults.standard.object(forKey: "reviewBeforeUpload") as? Bool ?? false
    @State private var localOnly: Bool = UserDefaults.standard.object(forKey: "localOnly") as? Bool ?? false
    @State private var cameraConnectAction: String = UserDefaults.standard.string(forKey: "cameraConnectAction") ?? "none"
    @State private var claudeWorkingDir: String = UserDefaults.standard.string(forKey: "claudeWorkingDir") ?? ""
    @State private var galleryRepos: [String: String] = Dictionary(
        uniqueKeysWithValues: CameraRegistry.all.map { ($0.id, Config.galleryRepo(for: $0)) }
    )
    private let username = KeychainHelper.githubUsername

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Per-camera gallery repo fields
            ForEach(CameraRegistry.all, id: \.id) { profile in
                GroupBox(label: Text("\(profile.displayName) Gallery").fontWeight(.semibold)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Repo:")
                                .foregroundColor(.secondary)
                            TextField("e.g. my-gallery", text: Binding(
                                get: { galleryRepos[profile.id] ?? Config.galleryRepo(for: profile) },
                                set: { newValue in
                                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        galleryRepos[profile.id] = trimmed
                                        Config.setGalleryRepo(trimmed, for: profile)
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        if let user = username {
                            let repo = galleryRepos[profile.id] ?? Config.galleryRepo(for: profile)
                            let galleryURL = "https://\(user).github.io/\(repo)/"
                            HStack {
                                Text(galleryURL)
                                    .textSelection(.enabled)
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Open") {
                                    if let url = URL(string: galleryURL) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
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

            // Local only mode
            Toggle("Import local only (skip upload)", isOn: $localOnly)
                .onChange(of: localOnly) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "localOnly")
                }

            // Camera-connect behavior
            Picker("On camera connect:", selection: $cameraConnectAction) {
                Text("Do nothing").tag("none")
                Text("Auto-import").tag("auto")
                Text("Open Claude curated import…").tag("claude")
            }
            .pickerStyle(.menu)
            .onChange(of: cameraConnectAction) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "cameraConnectAction")
            }

            // Claude working directory — `claude` is project-scoped (uses cwd for file
            // refs, project-level config overrides, conversation context). The
            // charmera-mcp server is registered at user scope in ~/.claude.json so it's
            // available anywhere, but you usually want claude launched from your projects
            // root. Empty = Terminal's default (home).
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Claude working directory:")
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: NSString(string: claudeWorkingDir.isEmpty ? "~" : claudeWorkingDir).expandingTildeInPath)
                        if panel.runModal() == .OK, let url = panel.url {
                            claudeWorkingDir = url.path
                            UserDefaults.standard.set(claudeWorkingDir, forKey: "claudeWorkingDir")
                        }
                    }
                }
                TextField("e.g. ~/tim-os (empty = Terminal default)", text: $claudeWorkingDir)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        UserDefaults.standard.set(claudeWorkingDir, forKey: "claudeWorkingDir")
                    }
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
