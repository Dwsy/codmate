import Foundation
import SwiftUI

@MainActor
class CommandsViewModel: ObservableObject {
  @Published var commands: [CommandRecord] = []
  @Published var selectedCommandId: String? = nil
  @Published var searchText: String = ""
  @Published var showAddSheet = false
  @Published var editingCommand: CommandRecord? = nil
  @Published var syncWarnings: [CommandSyncWarning] = []
  @Published var errorMessage: String? = nil
  @Published var isLoading = false
  @Published var showImportSheet = false
  @Published var importCandidates: [CommandImportCandidate] = []
  @Published var isImporting = false
  @Published var importStatusMessage: String? = nil

  private let store = CommandsStore()
  private let syncService = CommandsSyncService()

  init() {
    Task { await load() }
  }

  var selectedCommand: CommandRecord? {
    guard let id = selectedCommandId else { return nil }
    return commands.first(where: { $0.id == id })
  }

  var filteredCommands: [CommandRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      return commands
    }
    return commands.filter { command in
      command.name.localizedCaseInsensitiveContains(query) ||
      command.description.localizedCaseInsensitiveContains(query) ||
      command.prompt.localizedCaseInsensitiveContains(query)
    }
  }

  // MARK: - Load
  func load() async {
    isLoading = true
    defer { isLoading = false }

    let records = await store.listWithBuiltIns()
    commands = records
  }

  // MARK: - Import (Home)
  func beginImportFromHome() {
    showImportSheet = true
    Task { await loadImportCandidatesFromHome() }
  }

  func loadImportCandidatesFromHome() async {
    isImporting = true
    importStatusMessage = "Scanning…"
    if SecurityScopedBookmarks.shared.isSandboxed {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
        directory: home,
        purpose: .generalAccess,
        message: "Authorize your Home folder to import commands"
      )
    }
    let existing = await store.listWithBuiltIns()
    let existingIds = Set(existing.map(\.id))

    let scanned = await Task.detached(priority: .userInitiated) {
      CommandsImportService.scan(scope: .home)
    }.value
    // CodMate store is the source of truth; provider directories can drift if edited by other tools.
    let candidates = scanned.filter { !existingIds.contains($0.id) }

    await MainActor.run {
      self.importCandidates = candidates
      self.isImporting = false
      self.importStatusMessage = candidates.isEmpty ? "No commands found." : nil
    }
  }

  func cancelImport() {
    showImportSheet = false
    importCandidates = []
    importStatusMessage = nil
  }

  func importSelectedCommands() async {
    let selected = importCandidates.filter { $0.isSelected }
    guard !selected.isEmpty else {
      importStatusMessage = "No commands selected."
      return
    }

    var importedCount = 0
    var importedCandidateIds: Set<String> = []
    for item in selected {
      let resolution = item.hasConflict ? item.resolution : .overwrite
      switch resolution {
      case .skip:
        continue
      case .overwrite, .rename:
        let finalId = resolution == .rename
          ? item.renameId.trimmingCharacters(in: .whitespacesAndNewlines)
          : item.id
        guard !finalId.isEmpty else { continue }
        var name = item.name
        if name == item.id && finalId != item.id {
          name = finalId
        }
        let targets = CommandTargets(
          codex: item.sources.contains("Codex"),
          claude: item.sources.contains("Claude"),
          gemini: item.sources.contains("Gemini")
        )
        let record = CommandRecord(
          id: finalId,
          name: name,
          description: item.description,
          prompt: item.prompt,
          metadata: item.metadata,
          targets: targets,
          isEnabled: true,
          source: "import",
          path: "",
          installedAt: Date()
        )
        await store.upsert(record)
        importedCount += 1
        importedCandidateIds.insert(item.id)
      }
    }

    await load()
    await syncToProviders()
    importStatusMessage = "Imported \(importedCount) command(s)."
    if !importedCandidateIds.isEmpty {
      importCandidates.removeAll { importedCandidateIds.contains($0.id) }
    }
    if importCandidates.isEmpty {
      closeImportSheetAfterDelay()
    }
  }

  private func closeImportSheetAfterDelay(_ delay: TimeInterval = 0.6) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      self.showImportSheet = false
      self.importStatusMessage = nil
    }
  }

  // MARK: - CRUD Operations
  func addCommand(_ command: CommandRecord) async {
    await store.upsert(command)
    await load()
    selectedCommandId = command.id
    await syncToProviders()
  }

  func updateCommand(_ command: CommandRecord) async {
    await store.upsert(command)
    await load()
    await syncToProviders()
  }

  func deleteCommand(id: String) async {
    await store.delete(id: id)
    if selectedCommandId == id {
      selectedCommandId = nil
    }
    await load()
    await syncToProviders()
  }

  func updateCommandEnabled(id: String, value: Bool) {
    updateLocalCommand(id: id) { record in
      record.isEnabled = value
      if !value {
        record.targets.codex = false
        record.targets.claude = false
        record.targets.gemini = false
      } else {
        record.targets.codex = true
        record.targets.claude = true
        record.targets.gemini = true
      }
    }
    Task {
      await store.update(id: id) { record in
        record.isEnabled = value
        if !value {
          record.targets.codex = false
          record.targets.claude = false
          record.targets.gemini = false
        } else {
          record.targets.codex = true
          record.targets.claude = true
          record.targets.gemini = true
        }
      }
      await syncToProviders()
    }
  }

  func updateCommandTarget(id: String, target: CommandTarget, value: Bool) {
    updateLocalCommand(id: id) { record in
      switch target {
      case .codex:
        record.targets.codex = value
      case .claude:
        record.targets.claude = value
      case .gemini:
        record.targets.gemini = value
      case .pi:
        record.targets.pi = value
      }
      if value && !record.isEnabled {
        record.isEnabled = true
      } else if !record.targets.codex && !record.targets.claude && !record.targets.gemini && !record.targets.pi {
        record.isEnabled = false
      }
    }
    Task {
      await store.update(id: id) { record in
        switch target {
        case .codex:
          record.targets.codex = value
        case .claude:
          record.targets.claude = value
        case .gemini:
          record.targets.gemini = value
        case .pi:
          record.targets.pi = value
        }
        if value && !record.isEnabled {
          record.isEnabled = true
        } else if !record.targets.codex && !record.targets.claude && !record.targets.gemini && !record.targets.pi {
          record.isEnabled = false
        }
      }
      await syncToProviders()
    }
  }

  // MARK: - Sync
  func syncToProviders() async {
    let warnings = await syncService.syncGlobal(commands: commands)
    syncWarnings = warnings

    if !warnings.isEmpty {
      errorMessage = "Sync completed with \(warnings.count) warning(s)"
    }
  }

  func manualSync() async {
    isLoading = true
    defer { isLoading = false }

    await syncToProviders()

    if syncWarnings.isEmpty {
      errorMessage = "Successfully synced \(commands.filter { $0.isEnabled }.count) commands"
    }
  }

  // MARK: - Import/Export
  func importFromJSON(url: URL) async {
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let imported = try decoder.decode([CommandRecord].self, from: data)

      for command in imported {
        await store.upsert(command)
      }

      await load()
      await syncToProviders()

      errorMessage = "Successfully imported \(imported.count) commands"
    } catch {
      errorMessage = "Import failed: \(error.localizedDescription)"
    }
  }

  func exportToJSON(url: URL) async {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601

      let data = try encoder.encode(commands)
      try data.write(to: url, options: .atomic)

      errorMessage = "Successfully exported \(commands.count) commands"
    } catch {
      errorMessage = "Export failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Editor
  func openInEditor(_ command: CommandRecord, using editor: EditorApp) {
    let path = command.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      errorMessage = "Command path not available"
      return
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
      errorMessage = "Command file does not exist: \(path)"
      return
    }

    if let executablePath = findExecutableInPath(editor.cliCommand) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = [path]
      process.standardOutput = Pipe()
      process.standardError = Pipe()
      do {
        try process.run()
        return
      } catch {
      }
    }

    if let appURL = editor.appURL {
      let config = NSWorkspace.OpenConfiguration()
      config.activates = true
      NSWorkspace.shared.open(
        [URL(fileURLWithPath: path)],
        withApplicationAt: appURL,
        configuration: config
      ) { _, error in
        if let error = error {
          DispatchQueue.main.async {
            self.errorMessage = "Failed to open \(editor.title): \(error.localizedDescription)"
          }
        }
      }
      return
    }

    errorMessage = "\(editor.title) is not installed. Please install it or try a different editor."
  }

  // MARK: - Helpers
  func canDelete(id: String) -> Bool {
    // All commands can be deleted
    return commands.first(where: { $0.id == id }) != nil
  }

  func enabledCount(for target: CommandTarget) -> Int {
    commands.filter { $0.isEnabled && $0.targets.isEnabled(for: target) }.count
  }

  func isCommandTargetEnabled(id: String, target: CommandTarget) -> Bool {
    guard let command = commands.first(where: { $0.id == id }) else { return false }
    return command.targets.isEnabled(for: target)
  }

  var totalEnabledCount: Int {
    commands.filter { $0.isEnabled }.count
  }

  private func updateLocalCommand(id: String, mutate: (inout CommandRecord) -> Void) {
    guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
    var updated = commands
    mutate(&updated[index])
    commands = updated
  }

  private func findExecutableInPath(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return path?.isEmpty == false ? path : nil
    } catch {
      return nil
    }
  }
}
