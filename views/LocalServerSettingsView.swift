import SwiftUI
import Network

struct LocalServerSettingsView: View {
    @StateObject private var service = CLIProxyService.shared
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var localIP: String = "127.0.0.1"
    @State private var authStatus: [LocalAuthProvider: Bool] = [:]
    @State private var loginInProgress: LocalAuthProvider? = nil
    @State private var loginTask: Task<Void, Never>? = nil
    @State private var logoutConfirmProvider: LocalAuthProvider? = nil
    @State private var publicAPIKey: String = ""
    @State private var affected3PProvidersCount: Int = 0
    @State private var showReroute3PHelp: Bool = false
    private let minPublicKeyLength = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Uni-API Proxy")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Unified proxy gateway for AI capabilities")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // 1. Proxy Server Control
                VStack(alignment: .leading, spacing: 10) {
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
                                    Button(action: toggleService) {
                                        Text(service.isRunning ? "Stop" : "Start")
                                            .frame(width: 60)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(service.isRunning ? .red : .blue)
                                    .disabled(!service.isBinaryInstalled)
                                }
                            }
                            
                            Divider()
                            
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                                GridRow {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Label("Upstream Login", systemImage: "person.circle")
                                            .font(.subheadline).fontWeight(.medium)
                                        Text("Authenticate with Codex, Claude, Gemini, Antigravity, or Qwen Code")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    HStack(spacing: 6) {
                                        providerLoginButton(.codex)
                                        providerLoginButton(.claude)
                                        providerLoginButton(.gemini)
                                        providerLoginButton(.antigravity)
                                        providerLoginButton(.qwen)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }

                                GridRow {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Label("Auto Start", systemImage: "play.circle")
                                            .font(.subheadline).fontWeight(.medium)
                                        Text("Start with App / On Demand")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Toggle("", isOn: $preferences.localServerAutoStart)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                
                                GridRow {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Label("Public Access", systemImage: "network")
                                            .font(.subheadline).fontWeight(.medium)
                                        Text("Enable public server access")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Toggle("", isOn: $preferences.localServerEnabled)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                
                                if preferences.localServerEnabled {
                                    GridRow {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Label("Public URL", systemImage: "link")
                                                .font(.subheadline).fontWeight(.medium)
                                            Text("Publicly accessible server URL")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                        HStack(spacing: 4) {
                                            Text("http://\(localIP):")
                                                .font(.system(.caption, design: .monospaced))
                                            TextField("Port", value: $preferences.localServerPort, formatter: NumberFormatter())
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(.caption, design: .monospaced))
                                                .frame(width: 80)
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

                                if preferences.localServerEnabled {
                                    GridRow {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Label("Public Key", systemImage: "key")
                                                .font(.subheadline).fontWeight(.medium)
                                            Text("API key for public access authentication")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                        VStack(alignment: .trailing, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Button(action: regeneratePublicKey) {
                                                    Image(systemName: "arrow.clockwise")
                                                }
                                                .buttonStyle(.plain)
                                                HStack(spacing: 4) {
                                                    TextField("Key", text: $publicAPIKey)
                                                        .textFieldStyle(.roundedBorder)
                                                        .font(.system(.caption, design: .monospaced))
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
                                        VStack(alignment: .leading, spacing: 0) {
                                            Label("Binary", systemImage: "app.badge")
                                                .font(.subheadline).fontWeight(.medium)
                                            Text("Install CLIProxyAPI binary executable")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
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

                // 2. Re-Route Capabilities
                VStack(alignment: .leading, spacing: 10) {
                    Text("Re-Route Capabilities").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Reroute Built-in Providers", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("Use Codex, Claude, Gemini, Antigravity, or Qwen Code OAuth to access model capabilities via standard API")
                                        .font(.caption).foregroundColor(.secondary)
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
                            
                            GridRow {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Label("Reroute 3P Providers", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.subheadline).fontWeight(.medium)

                                        Button {
                                            showReroute3PHelp.toggle()
                                        } label: {
                                            Image(systemName: "questionmark.circle")
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Click for more information")
                                        .popover(isPresented: $showReroute3PHelp) {
                                            VStack(alignment: .leading, spacing: 12) {
                                                Text("Reroute 3P Providers")
                                                    .font(.headline)

                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text("When enabled:")
                                                        .font(.subheadline).fontWeight(.semibold)
                                                    Text("• All 3P providers routed through Uni-API Proxy\n• Centralized API key and configuration management\n• Unified monitoring and logging\n• Smart routing and load balancing support")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)

                                                    Text("When disabled:")
                                                        .font(.subheadline).fontWeight(.semibold)
                                                        .padding(.top, 4)
                                                    Text("• 3P providers called directly (legacy mode)\n• Independent configuration per provider\n• Slightly better performance (one less hop)\n• Suitable for debugging and special needs")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)

                                                    Text("Recommended:")
                                                        .font(.subheadline).fontWeight(.semibold)
                                                        .padding(.top, 4)
                                                    Text("Enable for most use cases to enjoy unified management. Disable temporarily for debugging or performance optimization.")
                                                        .font(.caption)
                                                        .foregroundColor(.blue)
                                                }
                                            }
                                            .padding(16)
                                            .frame(width: 380)
                                        }
                                    }

                                    Text("Route 3P providers through unified proxy endpoint")
                                        .font(.caption).foregroundColor(.secondary)

                                    // Status indicator
                                    if preferences.localServerReroute3P {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.caption2)
                                            Text("3P providers routed through local proxy")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            if affected3PProvidersCount > 0 {
                                                Text("(\(affected3PProvidersCount) provider\(affected3PProvidersCount == 1 ? "" : "s"))")
                                                    .font(.caption2)
                                                    .foregroundColor(.blue)
                                            }
                                        }
                                        .padding(.top, 2)
                                    } else {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.right.circle")
                                                .foregroundColor(.orange)
                                                .font(.caption2)
                                            Text("3P providers called directly")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text("(recommended to enable for unified management)")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                        .padding(.top, 2)
                                    }
                                }

                                Toggle("", isOn: $preferences.localServerReroute3P)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .onChange(of: preferences.localServerReroute3P) { enabled in
                                        Task {
                                            // Sync third-party providers config to CLIProxyAPI
                                            await service.syncThirdPartyProviders()
                                            // Start service if autoStart is enabled and reroute is enabled
                                            if enabled && preferences.localServerAutoStart {
                                                try? await service.start()
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
                
                // 3. Proxy Core
                VStack(alignment: .leading, spacing: 10) {
                    Text("Proxy Core").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Binary Location", systemImage: "app.badge")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("CLIProxyAPI binary executable path")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(service.binaryFilePath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Reinstall") {
                                    Task { try? await service.install() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .frame(width: 80, alignment: .trailing)
                                .disabled(service.isInstalling)
                            }
                            
                            gridDivider
                            
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("GitHub Repository", systemImage: "link")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("CLIProxyAPI source code repository")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Text("router-for-me/CLIProxyAPI")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .opacity(0.6)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                Link(destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!) {
                                    Text("Open")
                                }
                                .buttonStyle(.bordered)
                                .frame(width: 80, alignment: .trailing)
                            }
                            
                            gridDivider
                            
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Documentation", systemImage: "book")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("CLIProxyAPI official documentation")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Text("help.router-for.me")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .opacity(0.6)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                Link(destination: URL(string: "https://help.router-for.me/")!) {
                                    Text("Open")
                                }
                                .buttonStyle(.bordered)
                                .frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                }
                
                // 4. Paths
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paths").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Config File", systemImage: "doc.text")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("CLIProxyAPI configuration file")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(configFilePath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Reveal") { revealConfigInFinder() }
                                    .buttonStyle(.bordered)
                            }
                            
                            gridDivider
                            
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Auth Directory", systemImage: "key")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("OAuth authentication tokens storage")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(authDirPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Reveal") { revealAuthDirInFinder() }
                                    .buttonStyle(.bordered)
                            }
                            
                            gridDivider
                            
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Logs", systemImage: "doc.plaintext")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("CLIProxyAPI log files directory")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(logsPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Reveal") { revealLogsInFinder() }
                                    .buttonStyle(.bordered)
                            }
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
                loadAffectedProvidersCount()
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

    private func providerLoginButton(_ provider: LocalAuthProvider) -> some View {
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
                    LocalAuthProviderIconView(
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
    
    private var configFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configPath = appSupport.appendingPathComponent("CodMate/config.yaml")
        return configPath.path
    }
    
    private var authDirPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codmate/auth").path
    }
    
    private var logsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codmate/auth/logs").path
    }
    
    private var gridDivider: some View {
        Divider()
    }

    private func loadAffectedProvidersCount() {
        Task {
            let registry = ProvidersRegistryService()
            let providers = await registry.listProviders()
            await MainActor.run {
                affected3PProvidersCount = providers.count
            }
        }
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
        authStatus[.antigravity] = service.hasAuthToken(for: .antigravity)
        authStatus[.qwen] = service.hasAuthToken(for: .qwen)
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

    private func loginButtonHelp(provider: LocalAuthProvider, active: Bool, isLoggingIn: Bool) -> String {
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
