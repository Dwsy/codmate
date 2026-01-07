import Foundation
import AppKit
import SwiftUI

/// Manages the CLIProxyAPI binary process and configuration.
/// Integrates the CLI Proxy capability into CodMate.
@MainActor
final class CLIProxyService: ObservableObject {
    static let shared = CLIProxyService()

    // MARK: - Properties

    @Published var isRunning = false
    @Published var isInstalling = false
    @Published var installProgress: Double = 0
    @Published var lastError: String?
    @Published var loginPrompt: LoginPrompt?
    @Published var binarySource: BinarySource = .none
    @Published var detectedBinaryPath: String?
    @Published var conflictWarning: String?

    struct LoginPrompt: Identifiable, Equatable {
        let id = UUID()
        let provider: LocalAuthProvider
        let message: String
    }

    struct OAuthAccount: Identifiable, Equatable, Hashable {
        let id: String
        let provider: LocalAuthProvider
        let email: String?
        let filename: String
        let filePath: String
    }

    struct LocalModelList: Decodable {
        let data: [LocalModel]
    }

    struct LocalModel: Codable, Hashable {
        let id: String
        let owned_by: String?
        let provider: String?
        let source: String?

        enum CodingKeys: String, CodingKey {
            case id
            case owned_by
            case provider
            case source
        }
    }

    enum BinarySource: String, Equatable {
        case none
        case homebrew
        case codmate
        case other
    }

    // Log streaming
    @Published var logs: String = ""
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "codmate.localserver.port")
        return p > 0 ? UInt16(p) : Self.defaultPort
    }

    private var process: Process?
    private var loginProcess: Process?
    private var loginInputPipe: Pipe?
    private var loginProvider: LocalAuthProvider?
    private var loginCancellationRequested = false
    private var openedLoginURL: URL?
    private let proxyBridge = CLIProxyBridge()

    // Paths
    private let binaryPath: String
    private let configPath: String
    private let authDir: String
    private let managementKey: String
    private var brewCommandPath: String?

    // Default port configuration (nonisolated because it's a constant that can be safely accessed from any context)
    nonisolated static let defaultPort: UInt16 = 8317

    private static let publicAPIKeyDefaultsKey = "CLIProxyPublicAPIKey"
    private static let publicAPIKeyPrefix = "cm"
    private static let publicAPIKeyLength = 36
    private static let localModelsCacheKey = "CLIProxyLocalModelsCache"
    private static let localModelsCacheTimestampKey = "CLIProxyLocalModelsCacheTimestamp"
    private static let localModelsCacheTTL: TimeInterval = 300

    private var cachedLocalModels: [LocalModel] = []
    private var cachedLocalModelsTimestamp: Date?

    // Cache for model -> provider name mapping (built from config.yaml)
    // This compensates for CLIProxyAPI not setting provider field correctly
    private var modelToProviderNameCache: [String: String] = [:]

    // Constants
    private static let githubRepo = "router-for-me/CLIProxyAPIPlus"
    private static let binaryName = "CLIProxyAPI"

    private var internalPort: UInt16 {
        CLIProxyBridge.internalPort(from: port)
    }

    init() {
        // Setup paths in Application Support (for binary only)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let codMateDir = appSupport.appendingPathComponent("CodMate")
        let binDir = codMateDir.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        // Config and auth now live in ~/.codmate/cliproxyapi for easier management
        let cliproxyapiDir = homeDir.appendingPathComponent(".codmate/cliproxyapi", isDirectory: true)
        try? FileManager.default.createDirectory(at: cliproxyapiDir, withIntermediateDirectories: true)

        self.binaryPath = binDir.appendingPathComponent(Self.binaryName).path
        self.configPath = cliproxyapiDir.appendingPathComponent("config.yaml").path
        self.authDir = homeDir.appendingPathComponent(".codmate/auth").path

        // Persistent Management Key
        if let savedKey = UserDefaults.standard.string(forKey: "CLIProxyManagementKey") {
            self.managementKey = savedKey
        } else {
            self.managementKey = UUID().uuidString
            UserDefaults.standard.set(self.managementKey, forKey: "CLIProxyManagementKey")
        }

        try? FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)
        ensureConfigExists()

        // Perform initial detection
        performInitialDetection()
    }

    // MARK: - Binary Detection

    private func performInitialDetection() {
        let path = CLIEnvironment.resolvedPATHForCLI()

        // First, check if CodMate's own installation exists
        if FileManager.default.fileExists(atPath: binaryPath) {
            detectedBinaryPath = binaryPath
            binarySource = .codmate
            appendLog("Using CodMate's built-in installation at: \(binaryPath)\n")
            return
        }

        // Then, detect cliproxyapi binary in PATH
        guard let detectedPath = CLIEnvironment.resolveExecutablePath("cliproxyapi", path: path) else {
            binarySource = .none
            detectedBinaryPath = nil
            appendLog("No cliproxyapi binary detected in PATH or CodMate installation.\n")
            return
        }

        // Verify the detected path actually exists
        guard FileManager.default.fileExists(atPath: detectedPath) else {
            // Path was found in PATH but file doesn't exist (likely uninstalled)
            binarySource = .none
            detectedBinaryPath = nil
            appendLog("cliproxyapi found in PATH but file does not exist. Using CodMate installation path.\n")
            return
        }

        detectedBinaryPath = detectedPath
        appendLog("Detected cliproxyapi at: \(detectedPath)\n")

        // Check if it's a Homebrew installation
        if isHomebrewPath(detectedPath) {
            // Check if brew command is available
            if let brewPath = detectBrewCommand() {
                brewCommandPath = brewPath
                binarySource = .homebrew
                appendLog("Homebrew installation detected. Using brew services for management.\n")
            } else {
                // Path matches Homebrew but brew command not found
                binarySource = .other
                conflictWarning = "cliproxyapi found at Homebrew path but brew command not available. Please install Homebrew or use CodMate's built-in management."
                appendLog("Warning: Homebrew path detected but brew command not found.\n", isError: true)
            }
        } else {
            // Other installation path
            binarySource = .other
            conflictWarning = "cliproxyapi found at non-standard path: \(detectedPath). This may cause port conflicts. Consider using Homebrew (brew install cliproxyapi) or CodMate's built-in management."
            appendLog("Warning: Non-standard installation path detected. Potential conflicts may occur.\n", isError: true)

            // Check for port conflicts
            checkPortConflicts()
        }
    }

    private func isHomebrewPath(_ path: String) -> Bool {
        path == "/opt/homebrew/bin/cliproxyapi" ||
        path == "/usr/local/bin/cliproxyapi"
    }

    private func detectBrewCommand() -> String? {
        let path = CLIEnvironment.resolvedPATHForCLI()
        return CLIEnvironment.resolveExecutablePath("brew", path: path)
    }

    private func checkPortConflicts() {
        // Check if ports are in use
        let portsToCheck = [port, internalPort]
        var conflicts: [UInt16] = []

        for portToCheck in portsToCheck {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-ti", "tcp:\(portToCheck)"]

            let pipe = Pipe()
            task.standardOutput = pipe

            try? task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conflicts.append(portToCheck)
            }
        }

        if !conflicts.isEmpty {
            let portsStr = conflicts.map { String($0) }.joined(separator: ", ")
            appendLog("Warning: Port(s) \(portsStr) may be in use by another process.\n", isError: true)
        }
    }

    var resolvedBinaryPath: String {
        switch binarySource {
        case .homebrew, .other:
            // If detected path exists, use it; otherwise fall back to CodMate path
            if let detected = detectedBinaryPath, FileManager.default.fileExists(atPath: detected) {
                return detected
            }
            return binaryPath
        case .codmate:
            return binaryPath
        case .none:
            return binaryPath
        }
    }

    var isBinaryInstalled: Bool {
        switch binarySource {
        case .homebrew, .other:
            // Verify the detected path actually exists
            if let detected = detectedBinaryPath {
                return FileManager.default.fileExists(atPath: detected)
            }
            return false
        case .codmate:
            return FileManager.default.fileExists(atPath: binaryPath)
        case .none:
            // Even if source is none, check if CodMate has installed it
            return FileManager.default.fileExists(atPath: binaryPath)
        }
    }

    // MARK: - Process Management

    func start() async throws {
        guard isBinaryInstalled else {
            appendLog("Binary not found. Please install it first.\n", isError: true)
            throw ServiceError.binaryNotFound
        }

        guard !isRunning else {
            appendLog("Service is already running.\n")
            return
        }

        lastError = nil

        // Sync third-party providers only on initial startup (when config doesn't exist)
        // During restart, we rely on the existing config that was already synced
        if !FileManager.default.fileExists(atPath: configPath) {
            let enabledProviderIds = loadEnabledAPIKeyProviders()
            await syncThirdPartyProviders(enabledProviderIds: enabledProviderIds)
        }

        // Use Homebrew services if Homebrew installation detected
        if binarySource == .homebrew, brewCommandPath != nil {
            try await brewServicesStart()
            return
        }

        // Cleanup old processes
        cleanupOrphanProcesses()

        // Update config with correct internal port (since we use bridge mode)
        updateConfigPort(internalPort)

        // --- Diagnostic Section ---
        let execPath = resolvedBinaryPath
        appendLog("Inspecting binary at \(execPath)...\n")
        let fileOutput = runShell(command: "/usr/bin/file", args: [execPath])
        appendLog("-> File type: \(fileOutput.trimmingCharacters(in: .whitespacesAndNewlines))\n")

        let lsOutput = runShell(command: "/bin/ls", args: ["-l", execPath])
        appendLog("-> Permissions: \(lsOutput.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        // --- End Diagnostic Section ---

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)

        // Use CodMate's config path for non-Homebrew installations
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: execPath).deletingLastPathComponent()

        // Environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        // Log Capture
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        self.outputPipe = out
        self.errorPipe = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str, isError: true) }
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
                self?.proxyBridge.stop()
                self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.errorPipe?.fileHandleForReading.readabilityHandler = nil

                let reason: String
                switch terminatedProcess.terminationReason {
                case .exit:
                    reason = "Exited with code \(terminatedProcess.terminationStatus)"
                case .uncaughtSignal:
                    reason = "Terminated by signal \(terminatedProcess.terminationStatus)"
                @unknown default:
                    reason = "Unknown reason"
                }
                self?.appendLog("Service stopped. \(reason)\n", isError: terminatedProcess.terminationStatus != 0)
            }
        }

        do {
            appendLog("Starting Local AI Server on port \(internalPort)...\n")
            try process.run()
            self.process = process

            // Wait for startup
            try await Task.sleep(nanoseconds: 1_500_000_000)

            guard process.isRunning else {
                let reason: String
                switch process.terminationReason {
                case .exit:
                    reason = "Exited with code \(process.terminationStatus)"
                case .uncaughtSignal:
                    reason = "Terminated by signal \(process.terminationStatus)"
                @unknown default:
                    reason = "Unknown reason"
                }
                let errText = "Process failed to stay running. \(reason)."
                appendLog(errText + "\n", isError: true)
                throw ServiceError.startupFailed
            }

            // Start Proxy Bridge
            proxyBridge.configure(listenPort: port, targetPort: internalPort)
            proxyBridge.start()

            // Wait for bridge
            try await Task.sleep(nanoseconds: 500_000_000)

            if !proxyBridge.isRunning {
                process.terminate()
                appendLog("Proxy bridge failed to start.\n", isError: true)
                throw ServiceError.startupFailed
            }

            isRunning = true
            appendLog("Service started successfully.\n")

        } catch {
            lastError = error.localizedDescription
            appendLog("Error starting service: \(error.localizedDescription)\n", isError: true)
            throw error
        }
    }

    func stop() {
        // Use Homebrew services if Homebrew installation detected
        if binarySource == .homebrew, brewCommandPath != nil {
            brewServicesStop()
            return
        }

        proxyBridge.stop()

        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil

        cleanupOrphanProcesses()
        isRunning = false
    }

    func clearLogs() {
        logs = ""
    }

    private func appendLog(_ text: String, isError: Bool = false) {
        // Keep last 50k characters to avoid memory issues
        if logs.count > 50000 {
            logs = String(logs.suffix(40000))
        }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(text)")

        // Also output to AppLogger for better visibility in debug mode
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            if isError {
                AppLogger.shared.error(trimmedText, source: "CLIProxyService")
            } else {
                AppLogger.shared.info(trimmedText, source: "CLIProxyService")
            }
        }
    }

    // MARK: - Installation

    var binaryFilePath: String {
        resolvedBinaryPath
    }

    func install() async throws {
        isInstalling = true
        installProgress = 0
        defer { isInstalling = false }

        do {
            appendLog("Fetching latest release...\n")
            installProgress = 0.1
            let release = try await fetchLatestRelease()
            guard let asset = findCompatibleAsset(in: release) else {
                throw ServiceError.noCompatibleBinary
            }

            appendLog("Downloading binary...\n")
            installProgress = 0.3
            let data = try await downloadAsset(url: asset.downloadURL)
            installProgress = 0.6

            appendLog("Extracting and installing...\n")
            installProgress = 0.7
            try await extractAndInstall(data: data, assetName: asset.name)
            installProgress = 0.9

            // Re-detect after installation
            appendLog("Verifying installation...\n")
            performInitialDetection()
            installProgress = 1.0

            appendLog("Installation completed successfully.\n")
        } catch {
            lastError = error.localizedDescription
            appendLog("Installation failed: \(error.localizedDescription)\n", isError: true)
            throw error
        }
    }

    func login(provider: LocalAuthProvider) async throws {
        guard isBinaryInstalled else {
            appendLog("Binary not found. Please install it first.\n", isError: true)
            throw ServiceError.binaryNotFound
        }

        openedLoginURL = nil

        // Qwen: Skip CLI --no-browser mode, use management OAuth directly
        // The CLI device code flow has reliability issues with browser callback detection
        if provider == .qwen {
            appendLog("Starting \(provider.displayName) login via management API...\n")
            try await loginViaManagement(provider: provider)
            return
        }

        let flag = provider.loginFlag

        // Hide existing auth files to force a new login flow
        let hiddenFiles = hideAuthFiles(for: provider)
        defer {
            restoreAuthFiles(hiddenFiles)
        }

        appendLog("Starting \(provider.displayName) login...\n")
        do {
            try await withTaskCancellationHandler {
                try await runCLI(arguments: ["-config", configPath, flag, "-incognito"], loginProvider: provider)
            } onCancel: {
                Task { @MainActor in
                    self.cancelLogin()
                }
            }
            appendLog("\(provider.displayName) login finished.\n")
        } catch is CancellationError {
            appendLog("\(provider.displayName) login cancelled.\n")
            throw CancellationError()
        }
    }

    private func hideAuthFiles(for provider: LocalAuthProvider) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: authDir) else { return [] }
        var hidden: [URL] = []
        let aliases = provider.authAliases.map { $0.lowercased() }

        for name in items {
            guard name.hasSuffix(".json") else { continue }
            let url = URL(fileURLWithPath: authDir).appendingPathComponent(name)

            // Check if this file belongs to the provider
            var belongsToProvider = false
            if aliases.contains(where: { name.lowercased().contains($0) }) {
                belongsToProvider = true
            } else if let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) {
                let lower = text.lowercased()
                let patterns = [
                    "\"type\":\"\(provider)\"",
                    "\"type\": \"\(provider)\"",
                    "\"provider\":\"\(provider)\"",
                    "\"provider\": \"\(provider)\""
                ]
                if patterns.contains(where: { lower.contains($0) }) {
                    belongsToProvider = true
                }
            }

            if belongsToProvider {
                let backupURL = url.appendingPathExtension("bak")
                do {
                    try fm.moveItem(at: url, to: backupURL)
                    hidden.append(backupURL)
                } catch {
                    appendLog("Failed to hide auth file \(name): \(error.localizedDescription)\n", isError: true)
                }
            }
        }
        return hidden
    }

    private func restoreAuthFiles(_ backups: [URL]) {
        let fm = FileManager.default
        for backupURL in backups {
            let originalURL = backupURL.deletingPathExtension()

            // If the original file exists (meaning a new one was created with the same name),
            // we assume the new one is the latest valid session for that account, so we discard the backup.
            if fm.fileExists(atPath: originalURL.path) {
                try? fm.removeItem(at: backupURL)
            } else {
                // Otherwise, restore the old file (different account)
                do {
                    try fm.moveItem(at: backupURL, to: originalURL)
                } catch {
                    appendLog("Failed to restore auth file \(originalURL.lastPathComponent): \(error.localizedDescription)\n", isError: true)
                }
            }
        }
    }

    func cancelLogin() {
        loginCancellationRequested = true
        if let process = loginProcess, process.isRunning {
            process.terminate()
        }
        loginPrompt = nil
        openedLoginURL = nil
    }

    func logout(provider: LocalAuthProvider) {
        let accounts = listOAuthAccounts().filter { $0.provider == provider }
        let fm = FileManager.default
        var removed = 0
        for account in accounts {
            try? fm.removeItem(atPath: account.filePath)
            removed += 1
        }
        if removed > 0 {
            appendLog("Removed \(removed) \(provider.displayName) credential file(s).\n")
        }
    }

    func deleteOAuthAccount(_ account: OAuthAccount) {
        let fm = FileManager.default
        do {
            try fm.removeItem(atPath: account.filePath)
            appendLog("Removed credential file for \(account.provider.displayName) (\(account.email ?? "unknown")).\n")
        } catch {
            appendLog("Failed to delete credential file: \(error.localizedDescription)\n", isError: true)
        }
    }

    func listOAuthAccounts() -> [OAuthAccount] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: authDir) else { return [] }
        var accounts: [OAuthAccount] = []

        for name in items {
            guard name.hasSuffix(".json") else { continue }
            let path = (authDir as NSString).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }

            // Identify provider
            var identifiedProvider: LocalAuthProvider?
            for provider in LocalAuthProvider.allCases {
                let aliases = provider.authAliases.map { $0.lowercased() }

                // Check filename first
                if aliases.contains(where: { name.lowercased().contains($0) }) {
                    identifiedProvider = provider
                    break
                }

                // Check content
                let patterns = [
                    "\"type\":\"\(provider)\"",
                    "\"type\": \"\(provider)\"",
                    "\"provider\":\"\(provider)\"",
                    "\"provider\": \"\(provider)\""
                ]
                if patterns.contains(where: { text.lowercased().contains($0) }) {
                    identifiedProvider = provider
                    break
                }
            }

            guard let provider = identifiedProvider else { continue }

            // Extract email/account info
            var email: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                email = json["email"] as? String
                    ?? json["user_email"] as? String
                    ?? json["account"] as? String
                    ?? json["user"] as? String
                    ?? json["nickname"] as? String
                    ?? json["name"] as? String
            }

            accounts.append(OAuthAccount(
                id: name, // Use filename as ID
                provider: provider,
                email: email,
                filename: name,
                filePath: path
            ))
        }

        return accounts
    }

    func hasAuthToken(for provider: LocalAuthProvider) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: authDir) else { return false }
        let normalized = items.map { $0.lowercased() }
        let aliases = provider.authAliases.map { $0.lowercased() }
        for (idx, name) in normalized.enumerated() {
            guard name.hasSuffix(".json") else { continue }
            if aliases.contains(where: { name.contains($0) }) { return true }
            let original = items[idx]
            let path = (authDir as NSString).appendingPathComponent(original)
            if fileContainsProviderType(path: path, providers: aliases) {
                return true
            }
        }
        return false
    }

    private func fileContainsProviderType(path: String, providers: [String]) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        for provider in providers {
            let patterns = [
                "\"type\":\"\(provider)\"",
                "\"type\": \"\(provider)\"",
                "\"provider\":\"\(provider)\"",
                "\"provider\": \"\(provider)\""
            ]
            if patterns.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    func submitLoginInput(_ input: String) {
        guard let pipe = loginInputPipe else { return }
        let payload = input.hasSuffix("\n") ? input : (input + "\n")
        if let data = payload.data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    func loadPublicAPIKey() -> String? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var inKeys = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api-keys:") {
                inKeys = true
                continue
            }
            if inKeys {
                if trimmed.hasPrefix("-") {
                    var value = trimmed
                    if let range = value.range(of: "-") {
                        value = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    if value.hasPrefix("\"") && value.hasSuffix("\"") {
                        value.removeFirst()
                        value.removeLast()
                    }
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        persistPublicAPIKey(trimmed)
                        return trimmed
                    }
                    return nil
                }
                if !trimmed.isEmpty {
                    inKeys = false
                }
            }
        }
        if let stored = UserDefaults.standard.string(forKey: Self.publicAPIKeyDefaultsKey),
           !stored.isEmpty
        {
            return stored
        }
        return nil
    }

    func resolvePublicAPIKey() -> String {
        if let key = loadPublicAPIKey(), !key.isEmpty {
            return key
        }
        if let stored = UserDefaults.standard.string(forKey: Self.publicAPIKeyDefaultsKey),
           !stored.isEmpty
        {
            return stored
        }
        let generated = generatePublicAPIKey(length: Self.publicAPIKeyLength)
        persistPublicAPIKey(generated)
        return generated
    }

    func fetchLocalModels(forceRefresh: Bool = false) async -> [LocalModel] {
        guard isRunning else { return [] }
        if !forceRefresh, let cached = validCachedModels() {
            return cached
        }
        let fallback = loadAnyCachedModels()

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return fallback ?? []
        }
        var request = URLRequest(url: url)
        if let key = loadPublicAPIKey(), !key.isEmpty {
            let bearer = key.hasPrefix("Bearer ") ? key : "Bearer \(key)"
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return fallback ?? []
            }
            let models = (try? JSONDecoder().decode(LocalModelList.self, from: data))?.data ?? []
            persistCachedModels(models)
            return models
        } catch {
            return fallback ?? []
        }
    }

    /// Get cached provider name for a model ID (from config.yaml mapping)
    /// This compensates for CLIProxyAPI not setting provider field correctly
    func getProviderName(for modelId: String) -> String? {
        return modelToProviderNameCache[modelId]
    }

    private func validCachedModels() -> [LocalModel]? {
        if isCacheValid(cachedLocalModelsTimestamp), !cachedLocalModels.isEmpty {
            return cachedLocalModels
        }
        let persisted = loadCachedModelsFromDefaults()
        if isCacheValid(persisted.timestamp), !persisted.models.isEmpty {
            cachedLocalModels = persisted.models
            cachedLocalModelsTimestamp = persisted.timestamp
            return persisted.models
        }
        return nil
    }

    private func loadAnyCachedModels() -> [LocalModel]? {
        if !cachedLocalModels.isEmpty {
            return cachedLocalModels
        }
        let persisted = loadCachedModelsFromDefaults()
        if !persisted.models.isEmpty {
            cachedLocalModels = persisted.models
            cachedLocalModelsTimestamp = persisted.timestamp
            return persisted.models
        }
        return nil
    }

    private func isCacheValid(_ timestamp: Date?) -> Bool {
        guard let timestamp else { return false }
        return Date().timeIntervalSince(timestamp) < Self.localModelsCacheTTL
    }

    private func loadCachedModelsFromDefaults() -> (models: [LocalModel], timestamp: Date?) {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.localModelsCacheKey) else {
            return ([], nil)
        }
        let models = (try? JSONDecoder().decode([LocalModel].self, from: data)) ?? []
        let timestamp = defaults.object(forKey: Self.localModelsCacheTimestampKey) as? Date
        return (models, timestamp)
    }

    private func persistCachedModels(_ models: [LocalModel]) {
        cachedLocalModels = models
        cachedLocalModelsTimestamp = Date()
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: Self.localModelsCacheKey)
        }
        defaults.set(cachedLocalModelsTimestamp, forKey: Self.localModelsCacheTimestampKey)
    }

    func updatePublicAPIKey(_ key: String) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        var out: [String] = []
        var inKeys = false
        var replaced = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api-keys:") {
                inKeys = true
                out.append(line)
                continue
            }
            if inKeys {
                if trimmed.hasPrefix("-") {
                    if !replaced {
                        let indent = line.prefix { $0 == " " || $0 == "\t" }
                        out.append("\(indent)- \"\(key)\"")
                        replaced = true
                    } else {
                        out.append(line)
                    }
                    continue
                }
                if !trimmed.isEmpty {
                    if !replaced {
                        out.append("  - \"\(key)\"")
                        replaced = true
                    }
                    inKeys = false
                }
            }
            out.append(line)
        }

        if inKeys && !replaced {
            out.append("  - \"\(key)\"")
        }

        content = out.joined(separator: "\n")
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        persistPublicAPIKey(key)
    }

    func generatePublicAPIKey(length: Int = 36) -> String {
        let prefix = Self.publicAPIKeyPrefix
        let required = max(prefix.count + 1, length)
        let bodyLength = required - prefix.count
        var pool = ""
        while pool.count < bodyLength {
            pool += UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        let body = pool.prefix(bodyLength)
        return prefix + body
    }

    private func persistPublicAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.publicAPIKeyDefaultsKey)
    }

    // MARK: - Homebrew Services Management

    private func brewServicesStart() async throws {
        guard let brewPath = brewCommandPath else {
            throw ServiceError.binaryNotFound
        }

        // Check if service is already running
        if await isHomebrewServiceRunning() {
            appendLog("Homebrew service is already running.\n")
            // Start Proxy Bridge if not already running
            if !proxyBridge.isRunning {
                proxyBridge.configure(listenPort: port, targetPort: internalPort)
                proxyBridge.start()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            isRunning = true
            return
        }

        appendLog("Starting cliproxyapi via Homebrew services...\n")

        // Ensure Homebrew config exists
        if getHomebrewConfigPath() == nil {
            appendLog("Creating Homebrew config file...\n")
            createHomebrewConfigIfNeeded()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["services", "start", "cliproxyapi"]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str, isError: true) }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Wait a bit for service to start
                try await Task.sleep(nanoseconds: 1_500_000_000)

                // Verify service is actually running
                if !(await isHomebrewServiceRunning()) {
                    appendLog("Service failed to start (not running after start command).\n", isError: true)
                    throw ServiceError.startupFailed
                }

                // Start Proxy Bridge
                proxyBridge.configure(listenPort: port, targetPort: internalPort)
                proxyBridge.start()

                // Wait for bridge
                try await Task.sleep(nanoseconds: 500_000_000)

                if !proxyBridge.isRunning {
                    appendLog("Proxy bridge failed to start.\n", isError: true)
                    throw ServiceError.startupFailed
                }

                isRunning = true
                appendLog("Service started successfully via Homebrew.\n")
            } else {
                let errText = "brew services start failed with code \(process.terminationStatus)."
                appendLog(errText + "\n", isError: true)
                throw ServiceError.startupFailed
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Error starting service via Homebrew: \(error.localizedDescription)\n", isError: true)
            throw error
        }
    }

    private func brewServicesStop() {
        guard let brewPath = brewCommandPath else { return }

        appendLog("Stopping cliproxyapi via Homebrew services...\n")

        proxyBridge.stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["services", "stop", "cliproxyapi"]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str, isError: true) }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            isRunning = false
            appendLog("Service stopped via Homebrew.\n")
        } catch {
            appendLog("Error stopping service via Homebrew: \(error.localizedDescription)\n", isError: true)
            isRunning = false
        }
    }

    func brewUpgrade() async throws {
        guard let brewPath = brewCommandPath else {
            appendLog("brew command not found. Cannot upgrade.\n", isError: true)
            throw ServiceError.binaryNotFound
        }

        isInstalling = true
        installProgress = 0
        defer { isInstalling = false }

        appendLog("Upgrading cliproxyapi via Homebrew...\n")
        installProgress = 0.3

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["upgrade", "cliproxyapi"]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in
                    self?.appendLog(str)
                    // Update progress based on output
                    if str.contains("Updating") {
                        self?.installProgress = 0.5
                    } else if str.contains("Downloading") {
                        self?.installProgress = 0.7
                    } else if str.contains("Installing") {
                        self?.installProgress = 0.9
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str, isError: true) }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()

            installProgress = 1.0

            if process.terminationStatus == 0 {
                appendLog("cliproxyapi upgraded successfully.\n")
                // Re-detect after upgrade
                performInitialDetection()
            } else {
                let errText = "brew upgrade failed with code \(process.terminationStatus)."
                appendLog(errText + "\n", isError: true)
                throw ServiceError.networkError
            }
        } catch {
            lastError = error.localizedDescription
            appendLog("Error upgrading via Homebrew: \(error.localizedDescription)\n", isError: true)
            throw error
        }
    }

    // MARK: - Helpers

    private func cleanupOrphanProcesses() {
        killProcessOnPort(port)
        killProcessOnPort(internalPort)
    }

    private func killProcessOnPort(_ port: UInt16) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        task.standardOutput = pipe

        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: .newlines) {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private func getHomebrewConfigPath() -> String? {
        // Homebrew installations typically use ~/.cli-proxy-api/config.yaml
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let homebrewConfigPath = homeDir.appendingPathComponent(".cli-proxy-api/config.yaml").path

        if FileManager.default.fileExists(atPath: homebrewConfigPath) {
            return homebrewConfigPath
        }

        // Try alternative location
        let altPath = homeDir.appendingPathComponent(".config/cli-proxy-api/config.yaml").path
        if FileManager.default.fileExists(atPath: altPath) {
            return altPath
        }

        return nil
    }

    private func createHomebrewConfigIfNeeded() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        let configPath = configDir.appendingPathComponent("config.yaml")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Only create if doesn't exist
        guard !FileManager.default.fileExists(atPath: configPath.path) else { return }

        // Use same config as CodMate for consistency
        let apiKey = resolvePublicAPIKey()
        let config = """
host: \"127.0.0.1\"
port: \(internalPort)
auth-dir: \"\(authDir)\"

api-keys:
  - \"\(apiKey)\"

remote-management:
  allow-remote: false
  secret-key: \"\(managementKey)\"

debug: true
logging-to-file: true
usage-statistics-enabled: true

routing:
  strategy: \"round-robin\"
"""

        try? config.write(toFile: configPath.path, atomically: true, encoding: .utf8)
        appendLog("Created Homebrew config at: \(configPath.path)\n")
    }

    private func isHomebrewServiceRunning() async -> Bool {
        guard let brewPath = brewCommandPath else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["services", "list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Check if cliproxyapi service is listed as started
                return output.contains("cliproxyapi") && output.contains("started")
            }
        } catch {
            return false
        }

        return false
    }

    private func loadEnabledAPIKeyProviders() -> Set<String> {
        let defaults = UserDefaults.standard
        let enabled = defaults.array(forKey: "codmate.providers.apikey.enabled") as? [String] ?? []
        return Set(enabled)
    }

    /// Resolve API key from provider configuration
    /// The envKey field can contain either:
    /// 1. The API key itself (if it contains special chars like -, ., etc.)
    /// 2. An environment variable name (if it looks like an env var)
    private func resolveAPIKey(provider: ProvidersRegistryService.Provider) -> String? {
        guard let envKey = provider.envKey, !envKey.isEmpty else {
            return nil
        }

        // Check if envKey looks like an API key (contains special chars)
        // API keys typically contain: -, ., alphanumeric characters
        let looksLikeAPIKey = envKey.contains("-") || envKey.contains(".") || envKey.count > 40

        if looksLikeAPIKey {
            // Treat as direct API key
            return envKey
        } else {
            // Treat as environment variable name
            return ProcessInfo.processInfo.environment[envKey]
        }
    }

    /// Fetch available models from a third-party OpenAI-compatible API
    private func fetchModelsFromProvider(baseURL: String, apiKey: String) async -> [String] {
        guard let url = URL(string: baseURL)?.appendingPathComponent("models") else {
            appendLog("Invalid base URL: \(baseURL)\n")
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                appendLog("Failed to fetch models from \(baseURL): No HTTP response\n")
                return []
            }

            guard httpResponse.statusCode == 200 else {
                appendLog("Failed to fetch models from \(baseURL): HTTP \(httpResponse.statusCode)\n")
                return []
            }

            struct ModelsResponse: Codable {
                struct Model: Codable {
                    let id: String
                }
                let data: [Model]
            }

            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let modelIds = modelsResponse.data.map { $0.id }
            return modelIds
        } catch {
            appendLog("Error fetching models from \(baseURL): \(error.localizedDescription)\n")
            return []
        }
    }

    private func ensureConfigExists() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let apiKey = resolvePublicAPIKey()
        let config = """
host: \"127.0.0.1\"
port: \(internalPort)
auth-dir: \"\(authDir)\"

api-keys:
  - \"\(apiKey)\"

remote-management:
  allow-remote: false
  secret-key: \"\(managementKey)\"

debug: true
logging-to-file: true
usage-statistics-enabled: true

routing:
  strategy: \"round-robin\"
"""

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    func syncThirdPartyProviders(enabledProviderIds: Set<String>) async {
        let registry = ProvidersRegistryService()
        let providers = await registry.listProviders()
        let apiKey = resolvePublicAPIKey()

        // Filter providers based on enabled status
        let enabledProviders = providers.filter { enabledProviderIds.contains($0.id) }

        var config = """
host: \"127.0.0.1\"
port: \(internalPort)
auth-dir: \"\(authDir)\"

api-keys:
  - \"\(apiKey)\"

remote-management:
  allow-remote: false
  secret-key: \"\(managementKey)\"

debug: true
logging-to-file: true
usage-statistics-enabled: true

routing:
  strategy: \"round-robin\"

"""

        // Append third-party providers configuration
        // Collect all OpenAI-compatible providers (only enabled ones)
        var openaiProviders: [(name: String, baseURL: String, apiKey: String, models: [String])] = []

        for provider in enabledProviders {
            // Extract API key (either directly from envKey or from environment variable)
            guard let apiKey = resolveAPIKey(provider: provider), !apiKey.isEmpty else {
                continue
            }

            let providerName = provider.name ?? provider.id

            // Use OpenAI-compatible format for all third-party providers
            if let codexConnector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue],
               let baseURL = codexConnector.baseURL,
               !baseURL.isEmpty {

                // Priority 1: Use catalog models (user-configured in Edit Provider dialog)
                var models: [String] = []
                if let catalog = provider.catalog,
                   let catalogModels = catalog.models,
                   !catalogModels.isEmpty {
                    models = catalogModels.compactMap { $0.vendorModelId }
                    appendLog("Using \(models.count) models from catalog for \(providerName)\n")
                } else {
                    // Priority 2: Fetch from API if catalog is empty (only works for some providers like DeepSeek)
                    models = await fetchModelsFromProvider(baseURL: baseURL, apiKey: apiKey)
                    if !models.isEmpty {
                        appendLog("Fetched \(models.count) models from \(providerName) API (\(baseURL))\n")
                    } else {
                        appendLog("No models available for \(providerName) (no catalog and API fetch failed)\n")
                    }
                }

                if !models.isEmpty {
                    openaiProviders.append((name: providerName, baseURL: baseURL, apiKey: apiKey, models: models))
                }
            }
        }

        // Build openai-compatibility section with models
        if !openaiProviders.isEmpty {
            config += "\nopenai-compatibility:\n"
            for (name, baseURL, apiKey, models) in openaiProviders {
                config += """
  - name: "\(name)"
    base-url: "\(baseURL)"
    api-key-entries:
      - api-key: "\(apiKey)"

"""
                // Add models if available
                if !models.isEmpty {
                    config += "    models:\n"
                    for modelId in models {
                        config += "      - name: \"\(modelId)\"\n"
                    }
                    config += "\n"
                }
            }
        }

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
        appendLog("Synced \(openaiProviders.count) third-party provider(s) to config (openai-compatibility format).\n")

        // Build model -> provider name cache by parsing what we just wrote
        // This is simpler and more reliable than depending on CLIProxyAPI metadata
        var newCache: [String: String] = [:]
        for (name, _, _, models) in openaiProviders {
            for modelId in models {
                newCache[modelId] = name
            }
        }
        modelToProviderNameCache = newCache
        appendLog("Built model-to-provider cache: \(newCache.count) models\n")

        // Poll CLIProxyAPI until config is reloaded (with timeout)
        if isRunning {
            appendLog("Waiting for CLI Proxy API to reload config...\n")
            let expectedModelIds = Set(openaiProviders.flatMap { $0.models })
            await waitForConfigReload(expectedModelIds: expectedModelIds, timeoutSeconds: 5.0)
        }
    }

    /// Poll CLIProxyAPI until the expected models appear (indicating config reload is complete)
    private func waitForConfigReload(expectedModelIds: Set<String>, timeoutSeconds: Double) async {
        let startTime = Date()
        let timeoutInterval = timeoutSeconds
        var attemptCount = 0

        while Date().timeIntervalSince(startTime) < timeoutInterval {
            attemptCount += 1

            // Fetch current models from CLIProxyAPI
            let currentModels = await fetchLocalModels(forceRefresh: true)
            let currentModelIds = Set(currentModels.map { $0.id })

            // Check if all expected models are present
            let missingModels = expectedModelIds.subtracting(currentModelIds)
            if missingModels.isEmpty {
                appendLog("Config reloaded successfully after \(attemptCount) attempt(s) (~\(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)\n")
                return
            }

            // Wait before next poll (100ms intervals)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Timeout reached
        appendLog("Warning: Config reload timeout after \(String(format: "%.1f", timeoutSeconds))s. Some models may not be available yet.\n")
    }

    private func updateConfigPort(_ newPort: UInt16) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        if let range = content.range(of: #"port:\s*\d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "port: \(newPort)")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - GitHub API

    private struct ReleaseInfo: Decodable {
        let assets: [AssetInfo]
    }

    private struct AssetInfo: Decodable {
        let name: String
        let browser_download_url: String
        var downloadURL: String { browser_download_url }
    }

    private struct CompatibleAsset {
        let name: String
        let downloadURL: String
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest")!
        var req = URLRequest(url: url)
        req.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    private func findCompatibleAsset(in release: ReleaseInfo) -> CompatibleAsset? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let target = "darwin_\(arch)"

        for asset in release.assets {
            let name = asset.name.lowercased()
            if name.contains(target) && !name.contains("checksum") {
                return CompatibleAsset(name: asset.name, downloadURL: asset.downloadURL)
            }
        }
        return nil
    }

    private func downloadAsset(url: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: url)!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        return data
    }

    private func extractAndInstall(data: Data, assetName: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archivePath = tempDir.appendingPathComponent(assetName)
        try data.write(to: archivePath)

        // Extract
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archivePath.path, "-C", tempDir.path]
        try tar.run()
        tar.waitUntilExit()

        // Find binary
        let binary = search(tempDir)

        guard let validBinary = binary else {
            throw ServiceError.extractionFailed
        }

        if FileManager.default.fileExists(atPath: binaryPath) {
            try FileManager.default.removeItem(atPath: binaryPath)
        }
        try FileManager.default.copyItem(at: validBinary, to: URL(fileURLWithPath: binaryPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
    }

    private func runShell(command: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "Failed to read output"
        } catch {
            return "Failed to run command: \(error.localizedDescription)"
        }
    }

    private func runCLI(arguments: [String], loginProvider: LocalAuthProvider? = nil) async throws {
        let process = Process()
        let execPath = resolvedBinaryPath
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: execPath).deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if loginProvider != nil {
            let input = Pipe()
            process.standardInput = input
            self.loginInputPipe = input
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in
                    self?.appendLog(str)
                    if let provider = self?.loginProvider {
                        self?.detectLoginURL(in: str, provider: provider)
                        self?.detectLoginPrompt(in: str)
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in
                    self?.appendLog(str, isError: true)
                    if let provider = self?.loginProvider {
                        self?.detectLoginURL(in: str, provider: provider)
                        self?.detectLoginPrompt(in: str)
                    }
                }
            }
        }

        if let provider = loginProvider {
            self.loginProvider = provider
            self.loginProcess = process
            self.loginCancellationRequested = false
        }

        defer {
            if loginProvider != nil {
                self.loginProvider = nil
                self.loginProcess = nil
                self.loginInputPipe = nil
                self.loginPrompt = nil
                self.openedLoginURL = nil
            }
        }

        do {
            try process.run()
        } catch {
            appendLog("Failed to start CLIProxyAPI: \(error.localizedDescription)\n", isError: true)
            throw ServiceError.loginFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: ())
            }
        }

        if loginProvider != nil, loginCancellationRequested {
            loginCancellationRequested = false
            throw CancellationError()
        }

        if process.terminationStatus != 0 {
            appendLog("CLIProxyAPI exited with code \(process.terminationStatus).\n", isError: true)
            throw ServiceError.loginFailed
        }
    }

    private func detectLoginPrompt(in text: String) {
        guard let provider = loginProvider else { return }
        let lower = text.lowercased()
        let prompt: String?
        if lower.contains("paste the codex callback url") || lower.contains("paste the callback url") {
            if provider == .codex {
                submitLoginInput("")
                appendLog("Codex callback prompt detected; continuing to wait.\n")
                return
            }
            if provider == .gemini {
                submitLoginInput("")
                appendLog("Gemini callback prompt detected; continuing to wait.\n")
                return
            }
            prompt = "Paste the callback URL"
        } else if lower.contains("enter project id") {
            if provider == .gemini {
                submitLoginInput("")
                appendLog("Gemini project prompt detected; using default project.\n")
                return
            }
            prompt = "Enter project ID or ALL"
        } else if lower.contains("device code")
                    || lower.contains("verification code")
                    || lower.contains("enter code")
                    || lower.contains("input code")
                    || lower.contains("paste code")
                    || lower.contains("设备码")
                    || lower.contains("验证码")
                    || lower.contains("输入验证码")
                    || lower.contains("输入代码")
                    || lower.contains("输入设备码") {
            prompt = "Enter device or verification code"
        } else if lower.contains("enter email")
                    || lower.contains("enter your email")
                    || lower.contains("enter nickname")
                    || lower.contains("enter a nickname")
                    || lower.contains("enter name")
                    || lower.contains("enter username")
                    || lower.contains("enter alias")
                    || lower.contains("enter account")
                    || lower.contains("enter label")
                    || lower.contains("enter display name")
                    || lower.contains("输入邮箱")
                    || lower.contains("输入昵称")
                    || lower.contains("输入名字")
                    || lower.contains("输入名称")
                    || lower.contains("输入用户名")
                    || lower.contains("输入别名")
                    || lower.contains("输入账号")
                    || lower.contains("输入账户")
                    || lower.contains("输入账号名称")
                    || lower.contains("输入账户名称")
                    || lower.contains("输入账号别名")
                    || lower.contains("输入账户别名") {
            prompt = "Enter email or nickname"
        } else {
            prompt = nil
        }

        guard let message = prompt else { return }
        if loginPrompt?.message == message && loginPrompt?.provider == provider {
            return
        }
        loginPrompt = LoginPrompt(provider: provider, message: message)
    }

    private func detectLoginURL(in text: String, provider: LocalAuthProvider) {
        guard provider == .qwen else { return }
        guard openedLoginURL == nil else { return }
        guard text.contains("http") else { return }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url else { continue }
            openedLoginURL = url
            appendLog("Opening \(provider.displayName) login URL...\n")
            NSWorkspace.shared.open(url)
            break
        }
    }

    private struct ManagementAuthURLResponse: Decodable {
        let status: String?
        let url: String?
        let state: String?
        let error: String?
    }

    private struct ManagementAuthStatusResponse: Decodable {
        let status: String?
        let error: String?
    }

    private struct ManagementAuthFilesResponse: Decodable {
        let files: [AuthFileInfo]
    }

    struct AuthFileInfo: Decodable {
        let id: String?
        let name: String
        let provider: String?
        let status: String?
        let email: String?
        let account: String?
        let plan: String?
        let planType: String?
        let tier: String?
        let subscription: String?
        let organization: String?
        let accountType: String?
        let disabled: Bool?
        let idToken: CodexIDToken?

        struct CodexIDToken: Decodable {
            let chatgptAccountId: String?
            let planType: String?

            enum CodingKeys: String, CodingKey {
                case chatgptAccountId = "chatgpt_account_id"
                case planType = "plan_type"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, provider, status, email, account, plan, planType, tier, subscription
            case organization, accountType, disabled
            case idToken = "id_token"
        }

        var consolidatedPlan: String? {
            plan ?? planType ?? tier ?? subscription ?? idToken?.planType
        }

        var consolidatedAccountType: String? {
            accountType
        }
    }

    private func loginViaManagement(provider: LocalAuthProvider) async throws {
        let shouldStopAfter = !isRunning
        if shouldStopAfter {
            appendLog("Starting local server for \(provider.displayName) login...\n")
            try await start()
        }
        defer {
            if shouldStopAfter {
                stop()
            }
        }

        let (authURL, state) = try await fetchManagementAuthURL(for: provider)
        appendLog("Opening browser for \(provider.displayName) login...\n")
        NSWorkspace.shared.open(authURL)

        guard let state, !state.isEmpty else {
            appendLog("Missing auth state for \(provider.displayName) login.\n", isError: true)
            throw ServiceError.loginFailed
        }

        try await waitForAuthCompletion(state: state, provider: provider)
        appendLog("\(provider.displayName) login finished.\n")
    }

    private func fetchManagementAuthURL(for provider: LocalAuthProvider) async throws -> (URL, String?) {
        guard let endpoint = managementAuthEndpoint(for: provider),
              let request = managementRequest(path: endpoint) else {
            throw ServiceError.networkError
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        let payload = try JSONDecoder().decode(ManagementAuthURLResponse.self, from: data)
        guard payload.status?.lowercased() == "ok",
              let urlText = payload.url,
              let url = URL(string: urlText) else {
            throw ServiceError.loginFailed
        }
        return (url, payload.state)
    }

    private func waitForAuthCompletion(state: String, provider: LocalAuthProvider) async throws {
        let timeoutSeconds: TimeInterval = 180
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try await fetchAuthStatus(state: state)
            switch status {
            case "ok":
                return
            case "error":
                appendLog("\(provider.displayName) login failed.\n", isError: true)
                throw ServiceError.loginFailed
            default:
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        appendLog("\(provider.displayName) login timed out.\n", isError: true)
        throw ServiceError.loginFailed
    }

    private func fetchAuthStatus(state: String) async throws -> String {
        let query = [URLQueryItem(name: "state", value: state)]
        guard let request = managementRequest(path: "get-auth-status", queryItems: query) else {
            throw ServiceError.networkError
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        let payload = try JSONDecoder().decode(ManagementAuthStatusResponse.self, from: data)
        return payload.status?.lowercased() ?? "error"
    }

    private func managementAuthEndpoint(for provider: LocalAuthProvider) -> String? {
        switch provider {
        case .codex: return "codex-auth-url"
        case .claude: return "anthropic-auth-url"
        case .gemini: return "gemini-cli-auth-url"
        case .antigravity: return "antigravity-auth-url"
        case .qwen: return "qwen-auth-url"
        }
    }

    private func managementRequest(path: String, queryItems: [URLQueryItem]? = nil) -> URLRequest? {
        guard var components = URLComponents(string: "http://127.0.0.1:\(internalPort)/v0/management/\(path)") else {
            return nil
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func fetchAuthFileInfo(for filename: String) async -> AuthFileInfo? {
        guard isRunning else {
            appendLog("Cannot fetch auth file info: service not running\n", isError: true)
            return nil
        }
        guard let request = managementRequest(path: "auth-files") else {
            appendLog("Cannot fetch auth file info: failed to create request\n", isError: true)
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode != 200 {
                appendLog("Auth files API returned status \(statusCode)\n", isError: true)
                return nil
            }

            // Debug: print raw response
            if let jsonString = String(data: data, encoding: .utf8) {
                appendLog("Auth files API response: \(jsonString.prefix(500))\n")
            }

            let authFiles: [AuthFileInfo]
            if let wrapped = try? JSONDecoder().decode(ManagementAuthFilesResponse.self, from: data) {
                authFiles = wrapped.files
            } else {
                authFiles = try JSONDecoder().decode([AuthFileInfo].self, from: data)
            }
            appendLog("Successfully decoded \(authFiles.count) auth files\n")

            if let found = authFiles.first(where: { $0.name == filename || $0.id == filename }) {
                appendLog("Found auth file info for \(filename): plan=\(found.consolidatedPlan ?? "nil")\n")
                return found
            } else {
                appendLog("Auth file \(filename) not found in response\n", isError: true)
                return nil
            }
        } catch {
            appendLog("Failed to fetch auth file info: \(error.localizedDescription)\n", isError: true)
            return nil
        }
    }

    /// DEPRECATED: CLI Proxy API's Management API does not provide an endpoint to enable/disable auth files
    /// This function always returns false. Use local oauthAccountsEnabled settings instead.
    ///
    /// According to CLI Proxy API documentation (https://help.router-for.me/management/api),
    /// the Management API only supports: GET, POST, DELETE for auth files, but not PATCH/UPDATE.
    /// CLIProxyAPI loads all auth files, and applications should filter which ones to use locally.
    @available(*, deprecated, message: "CLI Proxy API does not support updating auth file disabled status via Management API")
    func updateAuthFileDisabled(filename: String, disabled: Bool) async -> Bool {
        // CLI Proxy API's Management API does not provide this endpoint
        // Always return false and rely on local oauthAccountsEnabled settings
        return false
    }

    /// DEPRECATED: CLI Proxy API's Management API does not provide an endpoint to enable/disable auth files
    /// This function does nothing. Use local oauthAccountsEnabled settings instead.
    @available(*, deprecated, message: "CLI Proxy API does not support updating auth file disabled status via Management API")
    func updateProviderAuthFilesDisabled(provider: LocalAuthProvider, disabled: Bool) async {
        // CLI Proxy API's Management API does not provide this endpoint
        // No-op - rely on local oauthAccountsEnabled settings
    }

    private func search(_ dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isExecutableKey, .isDirectoryKey]) else { return nil }

        let candidates = ["cliproxyapiplus", "cliproxyapi", "cli-proxy-api", "cli-proxy-api-plus"]

        for item in items {
            if let vals = try? item.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true {
                 if let found = search(item) { return found }
                 continue
            }

            let name = item.lastPathComponent.lowercased()
            if candidates.contains(name) { return item }
            if name.contains("cliproxy") && !name.contains(".txt") && !name.contains(".md") && !name.contains(".gz") {
                return item
            }
        }
        return nil
    }
}

enum ServiceError: LocalizedError {
    case binaryNotFound
    case startupFailed
    case networkError
    case noCompatibleBinary
    case extractionFailed
    case loginFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "CLIProxyAPI binary not found. Please install it first."
        case .startupFailed: return "Failed to start CLIProxyAPI"
        case .networkError: return "Network error"
        case .noCompatibleBinary: return "No compatible binary found"
        case .extractionFailed: return "Extraction failed"
        case .loginFailed: return "Login failed"
        }
    }
}
