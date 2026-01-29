import Foundation

actor PiSettingsService {
    struct Paths {
        let directory: URL
        let file: URL
        let skillsDirectory: URL

        init(directory: URL, file: URL, skillsDirectory: URL) {
            self.directory = directory
            self.file = file
            self.skillsDirectory = skillsDirectory
        }

        static func `default`(fileManager: FileManager = .default) -> Paths {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let piDir = home.appendingPathComponent(".pi", isDirectory: true)
            let agentDir = piDir.appendingPathComponent("agent", isDirectory: true)
            let settingsFile = agentDir.appendingPathComponent("settings.json", isDirectory: false)
            let skillsDir = agentDir.appendingPathComponent("skills", isDirectory: true)
            return Paths(directory: piDir, file: settingsFile, skillsDirectory: skillsDir)
        }
    }

    private let paths: Paths
    private let fileManager: FileManager

    init(paths: Paths? = nil, fileManager: FileManager = .default) {
        self.paths = paths ?? .default(fileManager: fileManager)
        self.fileManager = fileManager
    }

    // Load current settings
    func loadSettings() async throws -> [String: Any] {
        guard fileManager.fileExists(atPath: paths.file.path) else {
            return [:]
        }

        let data = try Data(contentsOf: paths.file)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
        return json
    }

    // Save settings
    func saveSettings(_ settings: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: paths.file)
    }

    // Apply Skills configuration (Pi reads skills from ~/.pi/agent/skills/)
    func ensureSkillsDirectoryExists() throws {
        if !fileManager.fileExists(atPath: paths.skillsDirectory.path) {
            try fileManager.createDirectory(at: paths.skillsDirectory, withIntermediateDirectories: true)
        }
    }

    // Check if Pi is installed
    func isPiInstalled() -> Bool {
        fileManager.fileExists(atPath: paths.directory.path)
    }

    // Get Pi version from settings
    func getPiVersion() async throws -> String? {
        let settings = try await loadSettings()
        return settings["lastChangelogVersion"] as? String
    }

    // Get default model
    func getDefaultModel() async throws -> String? {
        let settings = try await loadSettings()
        return settings["defaultModel"] as? String
    }

    // Get default provider
    func getDefaultProvider() async throws -> String? {
        let settings = try await loadSettings()
        return settings["defaultProvider"] as? String
    }

    // Set default model
    func setDefaultModel(_ model: String) async throws {
        var settings = try await loadSettings()
        settings["defaultModel"] = model
        try await saveSettings(settings)
    }

    // Set default provider
    func setDefaultProvider(_ provider: String) async throws {
        var settings = try await loadSettings()
        settings["defaultProvider"] = provider
        try await saveSettings(settings)
    }

    // Fetch all Pi info in one call (optimized for usage status)
    func fetchAllInfo() async -> (isInstalled: Bool, version: String?, defaultProvider: String?, defaultModel: String?) {
        let isInstalled = isPiInstalled()
        guard isInstalled else {
            return (false, nil, nil, nil)
        }

        let settings = (try? await loadSettings()) ?? [:]
        let version = settings["lastChangelogVersion"] as? String
        let defaultProvider = settings["defaultProvider"] as? String
        let defaultModel = settings["defaultModel"] as? String

        return (true, version, defaultProvider, defaultModel)
    }

    // Note: Pi does not use MCP servers like Codex/Claude/Gemini.
    // Pi uses Skills and Extensions instead. This service handles basic
    // configuration management. MCP server configuration is not applicable
    // for Pi.
}