import Foundation

actor ProjectExtensionsStore {
  struct Paths {
    let root: URL
    let extensionsDir: URL

    static func `default`(fileManager: FileManager = .default) -> Paths {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      let root = home.appendingPathComponent(".codmate", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)
      let extensionsDir = root.appendingPathComponent("extensions", isDirectory: true)
      return Paths(root: root, extensionsDir: extensionsDir)
    }
  }

  private let paths: Paths
  private let fm: FileManager

  init(paths: Paths = .default(), fileManager: FileManager = .default) {
    self.paths = paths
    self.fm = fileManager
  }

  func load(projectId: String) -> ProjectExtensionsConfig? {
    let url = configURL(for: projectId)
    guard fm.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ProjectExtensionsConfig.self, from: data)
  }

  func save(_ config: ProjectExtensionsConfig) {
    let url = configURL(for: config.projectId)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(config) else { return }
    try? fm.createDirectory(at: paths.extensionsDir, withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }

  func delete(projectId: String) {
    let url = configURL(for: projectId)
    if fm.fileExists(atPath: url.path) {
      try? fm.removeItem(at: url)
    }
  }

  private func configURL(for projectId: String) -> URL {
    paths.extensionsDir.appendingPathComponent(projectId + ".json", isDirectory: false)
  }

  static func loadSync(projectId: String) -> ProjectExtensionsConfig? {
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let url = home.appendingPathComponent(".codmate", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("extensions", isDirectory: true)
      .appendingPathComponent(projectId + ".json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ProjectExtensionsConfig.self, from: data)
  }

  static func requiresCodexHome(projectId: String) -> Bool {
    guard let config = loadSync(projectId: projectId) else { return false }
    return config.mcpServers.contains { $0.isSelected && $0.targets.codex }
  }
}
