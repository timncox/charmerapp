import SwiftUI
import AppKit

// MARK: - Setup State

enum SetupState {
    case idle
    case waitingForAuth
    case provisioning
    case done(galleryURL: String)
    case error(message: String)
}

// MARK: - SetupViewModel

class SetupViewModel: ObservableObject {
    @Published var state: SetupState = .idle
    @Published var startAtLogin: Bool = false

    func beginAuth() {
        state = .waitingForAuth

        // Build GitHub OAuth URL
        let clientID = Config.githubClientID
        let scheme = Config.githubCallbackScheme
        let redirectURI = "\(scheme)://callback"
        let scope = "repo"
        let urlString = "https://github.com/login/oauth/authorize?client_id=\(clientID)&redirect_uri=\(redirectURI)&scope=\(scope)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func handleCallback(code: String) {
        state = .provisioning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // 1. Exchange code for token via auth proxy
                let token = try self?.exchangeCodeForToken(code: code)
                guard let token = token else {
                    throw GitHubError.unexpectedResponse("No token received")
                }

                // 2. Store token in Keychain
                KeychainHelper.githubToken = token

                // 3. Get username
                let api = GitHubAPI(token: token)
                let username = try api.getUsername()
                KeychainHelper.githubUsername = username

                // 4. Create repo
                try api.createRepo(name: Config.repoName)

                // 5. Push template files (check bundle Resources first, then app support)
                let bundleTemplate = Bundle.main.resourcePath.map { "\($0)/template" }
                let appSupportTemplate = "\(Config.appSupportDir)/template"
                let templateDir = [bundleTemplate, appSupportTemplate].compactMap { $0 }.first {
                    FileManager.default.fileExists(atPath: $0)
                }
                if let templateDir = templateDir {
                    try api.pushTemplate(owner: username, repo: Config.repoName, templateDir: templateDir)
                }

                // 6. Enable GitHub Pages
                try api.enablePages(owner: username, repo: Config.repoName)

                let galleryURL = "https://\(username).github.io/\(Config.repoName)/"

                DispatchQueue.main.async {
                    self?.state = .done(galleryURL: galleryURL)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .error(message: error.localizedDescription)
                }
            }
        }
    }

    private func exchangeCodeForToken(code: String) throws -> String {
        guard let url = URL(string: Config.authProxyURL) else {
            throw GitHubError.invalidURL(Config.authProxyURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["code": code]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            responseData = data
            responseError = error
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            throw GitHubError.network(error.localizedDescription)
        }

        guard let data = responseData,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw GitHubError.unexpectedResponse("Could not parse access_token from auth proxy")
        }

        return token
    }
}

// MARK: - SetupView

struct SetupView: View {
    @ObservedObject var viewModel: SetupViewModel

    private let kodakGold = Color(red: 1.0, green: 0.718, blue: 0.0)     // #FFB700
    private let kodakRed = Color(red: 0.85, green: 0.11, blue: 0.11)      // #D91C1C
    private let rainbowColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple,
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Gold header bar
            HStack {
                Text("K")
                    .font(.system(size: 28, weight: .black))
                    .foregroundColor(kodakRed)
                Text("Charmera")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(kodakGold)

            // Rainbow stripe
            HStack(spacing: 0) {
                ForEach(0..<rainbowColors.count, id: \.self) { i in
                    rainbowColors[i]
                        .frame(height: 4)
                }
            }

            // Content
            VStack(spacing: 20) {
                switch viewModel.state {
                case .idle:
                    idleView
                case .waitingForAuth:
                    waitingView
                case .provisioning:
                    provisioningView
                case .done(let galleryURL):
                    doneView(galleryURL: galleryURL)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("Welcome to Charmera")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Import photos from your Kodak Charmera camera and publish them to your own gallery hosted on GitHub Pages.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button(action: { viewModel.beginAuth() }) {
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text("Sign in with GitHub")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Waiting for authorization...")
                .foregroundColor(.secondary)
            Text("Complete the sign-in in your browser.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var provisioningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Setting up your gallery...")
                .foregroundColor(.secondary)
        }
    }

    private func doneView(galleryURL: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("You're all set!")
                .font(.title2)
                .fontWeight(.semibold)

            Link(galleryURL, destination: URL(string: galleryURL)!)
                .font(.callout)

            Toggle("Start at login", isOn: $viewModel.startAtLogin)
                .onChange(of: viewModel.startAtLogin) { _, newValue in
                    LoginItemManager.setEnabled(newValue)
                }

            Button("Done") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Setup Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                viewModel.state = .idle
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Login Item Manager

import ServiceManagement

enum LoginItemManager {
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Window Controller

class SetupWindowController {
    private var window: NSWindow?
    var viewModel = SetupViewModel()

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SetupView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Charmera Setup"
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }

    func handleCallback(code: String) {
        viewModel.handleCallback(code: code)
    }
}
