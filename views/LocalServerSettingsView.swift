import SwiftUI
import Network

struct LocalServerSettingsView: View {
    @StateObject private var service = CLIProxyService.shared
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var localIP: String = "127.0.0.1"
    @State private var authStatus: [UsageProviderKind: Bool] = [:]
    @State private var loginInProgress: UsageProviderKind? = nil
    @State private var loginTask: Task<Void, Never>? = nil
    @State private var logoutConfirmProvider: UsageProviderKind? = nil
    @State private var publicAPIKey: String = ""
    private let minPublicKeyLength = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Local AI Server")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Unified proxy gateway for AI capabilities")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // 1. Internal Capability (ReRoute)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Internal Capabilities").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Reroute Built-in Features")
                                        .fontWeight(.medium)
                                    Text("Use local server for Git Review, Title Generation, etc.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Toggle("", isOn: $preferences.localServerReroute)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .onChange(of: preferences.localServerReroute) { enabled in
                                        if enabled && preferences.localServerAutoStart {
                                            Task { try? await service.start() }
                                        }
                                    }
                            }
                        }
                    }
                }
                
                // 2. Public Server / Lifecycle
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server Control").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        VStack(alignment: .leading, spacing: 16) {
                            // Status & Main Toggle
                            HStack {
                                Circle()
                                    .fill(service.isRunning ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(service.isRunning ? "Running" : "Stopped")
                                    .font(.body)
                                    .fontWeight(.medium)
                                
                                Spacer()
                                
                                if service.isInstalling {
                                    ProgressView(value: service.installProgress)
                                        .progressViewStyle(.linear)
                                        .frame(width: 100)
                                } else {
                                    HStack {
                                        Button("Reinstall") {
                                            Task { try? await service.install() }
                                        }
                                        .buttonStyle(.link)
                                        Button(action: toggleService) {
                                            Text(service.isRunning ? "Stop" : "Start")
                                                .frame(width: 60)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(service.isRunning ? .red : .blue)
                                        .disabled(!service.isBinaryInstalled)
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 12) {
                                GridRow {
                                    Text("Upstream Login")
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 6) {
                                        providerLoginButton(.codex)
                                        providerLoginButton(.claude)
                                        providerLoginButton(.gemini)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }

                                GridRow {
                                    Text("Public Access")
                                        .foregroundColor(.secondary)
                                    Toggle("Enable Public Server", isOn: $preferences.localServerEnabled)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                
                                GridRow {
                                    Text("Auto Start")
                                        .foregroundColor(.secondary)
                                    Toggle("Start with App / On Demand", isOn: $preferences.localServerAutoStart)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                
                                if preferences.localServerEnabled {
                                    GridRow {
                                        Text("Public URL")
                                            .foregroundColor(.secondary)
                                        HStack {
                                            Text("http://\(localIP):\(String(preferences.localServerPort))")
                                                .font(.system(.body, design: .monospaced))
                                            Button(action: {
                                                copyToClipboard("http://\(localIP):\(String(preferences.localServerPort))")
                                            }) {
                                                Image(systemName: "doc.on.doc")
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                }

                                GridRow {
                                    Text("Port")
                                        .foregroundColor(.secondary)
                                    TextField("Port", value: $preferences.localServerPort, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                }

                                if preferences.localServerEnabled {
                                    GridRow {
                                        Text("Public Key")
                                            .foregroundColor(.secondary)
                                        VStack(alignment: .trailing, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Button(action: regeneratePublicKey) {
                                                    Image(systemName: "arrow.clockwise")
                                                }
                                                .buttonStyle(.plain)
                                                ZStack(alignment: .trailing) {
                                                    TextField("Key", text: $publicAPIKey)
                                                        .textFieldStyle(.roundedBorder)
                                                        .font(.system(.body, design: .monospaced))
                                                        .padding(.trailing, 26)
                                                        .onChange(of: publicAPIKey) { newValue in
                                                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                                            guard trimmed.count >= minPublicKeyLength else { return }
                                                            service.updatePublicAPIKey(trimmed)
                                                        }
                                                    Button(action: { copyToClipboard(publicAPIKey) }) {
                                                        Image(systemName: "doc.on.doc")
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .frame(width: 320)
                                            }
                                            if publicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).count < minPublicKeyLength {
                                                Text("Minimum \(minPublicKeyLength) characters")
                                                    .font(.caption)
                                                    .foregroundColor(.red)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                }

                                if !service.isBinaryInstalled {
                                    GridRow {
                                        Text("Binary")
                                            .foregroundColor(.secondary)
                                        Button("Install Binary") {
                                            Task { try? await service.install() }
                                        }
                                        .buttonStyle(.link)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                }
                            }
                            
                            if let error = service.lastError {
                                Text(error)
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                        }
                    }
                }

                // 3. Paths
                VStack(alignment: .leading, spacing: 10) {
                    Text("Path").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("Config File")
                                Spacer()
                                Button("Reveal") { revealConfigInFinder() }
                            }
                            .padding(.vertical, 8)
                            
                            Divider()
                            
                            HStack {
                                Image(systemName: "key")
                                Text("Auth Directory")
                                Spacer()
                                Button("Reveal") { revealAuthDirInFinder() }
                            }
                            .padding(.vertical, 8)

                            Divider()

                            HStack {
                                Image(systemName: "doc.plaintext")
                                Text("Logs")
                                Spacer()
                                Button("Reveal") { revealLogsInFinder() }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
            .onAppear {
                getLocalIPAddress()
                refreshAuthStatus()
                loadPublicKey()
            }
        }
        .alert(item: $logoutConfirmProvider) { provider in
            Alert(
                title: Text("Sign out \(provider.displayName)?"),
                message: Text("This will remove stored credentials for \(provider.displayName)."),
                primaryButton: .destructive(Text("Sign Out")) {
                    service.logout(provider: provider)
                    refreshAuthStatus()
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $service.loginPrompt) { prompt in
            LoginPromptSheet(
                prompt: prompt,
                onSubmit: { input in
                    service.submitLoginInput(input)
                    service.loginPrompt = nil
                },
                onCancel: {
                    service.loginPrompt = nil
                },
                onStop: {
                    service.cancelLogin()
                    service.loginPrompt = nil
                }
            )
        }
    }
    
    private func toggleService() {
        Task {
            if service.isRunning {
                service.stop()
            } else {
                try? await service.start()
            }
        }
    }

    private func providerLoginButton(_ provider: UsageProviderKind) -> some View {
        let active = authStatus[provider] == true
        let isLoggingIn = loginInProgress == provider
        return Button {
            if isLoggingIn {
                loginTask?.cancel()
                service.cancelLogin()
                return
            }
            if active {
                logoutConfirmProvider = provider
                return
            }
            guard loginInProgress == nil else { return }
            loginInProgress = provider
            loginTask = Task {
                defer {
                    Task { @MainActor in
                        loginInProgress = nil
                        loginTask = nil
                        refreshAuthStatus()
                    }
                }
                do {
                    try await service.login(provider: provider)
                } catch {
                    if error is CancellationError { return }
                }
            }
        } label: {
            Group {
                if isLoggingIn {
                    RotatingIconView()
                        .frame(width: 16, height: 16)
                } else {
                    ProviderIconView(
                        provider: provider,
                        size: 16,
                        cornerRadius: 4,
                        saturation: active ? 1.0 : 0.0,
                        opacity: active ? 1.0 : 0.25
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!service.isBinaryInstalled || (loginInProgress != nil && loginInProgress != provider))
        .help(loginButtonHelp(provider: provider, active: active, isLoggingIn: isLoggingIn))
    }
    
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .cornerRadius(10)
    }
    
    private func revealConfigInFinder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configPath = appSupport.appendingPathComponent("CodMate/config.yaml")
        NSWorkspace.shared.selectFile(configPath.path, inFileViewerRootedAtPath: configPath.deletingLastPathComponent().path)
    }
    
    private func revealAuthDirInFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authPath = home.appendingPathComponent(".codmate/auth")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: authPath.path)
    }
    
    private func revealLogsInFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsPath = home.appendingPathComponent(".codmate/auth/logs")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsPath.path)
    }

    private func getLocalIPAddress() {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) { // IPv4
                    // Check for Wi-Fi or Ethernet
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0" || name.starts(with: "en") { // en0 is typically Wi-Fi
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        localIP = address ?? "127.0.0.1"
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func refreshAuthStatus() {
        authStatus[.codex] = service.hasAuthToken(for: .codex)
        authStatus[.claude] = service.hasAuthToken(for: .claude)
        authStatus[.gemini] = service.hasAuthToken(for: .gemini)
    }

    private func loadPublicKey() {
        if let key = service.loadPublicAPIKey(), !key.isEmpty {
            publicAPIKey = key
        } else {
            let generated = service.generatePublicAPIKey(minLength: minPublicKeyLength)
            publicAPIKey = generated
            service.updatePublicAPIKey(generated)
        }
    }

    private func regeneratePublicKey() {
        let generated = service.generatePublicAPIKey(minLength: minPublicKeyLength)
        publicAPIKey = generated
        service.updatePublicAPIKey(generated)
    }

    private func loginButtonHelp(provider: UsageProviderKind, active: Bool, isLoggingIn: Bool) -> String {
        if isLoggingIn { return "Cancel \(provider.displayName) login" }
        if active { return "Sign out \(provider.displayName)" }
        return "Login \(provider.displayName)"
    }
}

private struct RotatingIconView: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

private struct LoginPromptSheet: View {
    let prompt: CLIProxyService.LoginPrompt
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    let onStop: () -> Void

    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(prompt.provider.displayName) Login")
                .font(.headline)
            Text(prompt.message)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if prompt.provider == .codex {
                Text("If the browser already shows “Authentication Successful”, you can keep waiting—no paste needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TextField("Paste here", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("Paste") { pasteFromClipboard() }
                Spacer()
                Button("Keep Waiting") { onCancel() }
                Button("Stop Login") { onStop() }
                Button("Submit") { onSubmit(input.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let value = pasteboard.string(forType: .string) {
            input = value
        }
    }
}
