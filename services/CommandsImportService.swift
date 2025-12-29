import Foundation

enum CommandsImportService {
  struct SourceDescriptor {
    let label: String
    let directory: URL
    let fileExtension: String
    let format: CommandSourceFormat
  }

  enum CommandSourceFormat {
    case markdown
    case toml
  }

  static func scan(scope: ExtensionsImportScope, fileManager: FileManager = .default) -> [CommandImportCandidate] {
    let home: URL
    switch scope {
    case .home:
      home = SessionPreferencesStore.getRealUserHomeURL()
    case .project:
      return []
    }
    let sources: [SourceDescriptor] = [
      SourceDescriptor(
        label: "Codex",
        directory: home.appendingPathComponent(".codex", isDirectory: true)
          .appendingPathComponent("prompts", isDirectory: true),
        fileExtension: "md",
        format: .markdown
      ),
      SourceDescriptor(
        label: "Claude",
        directory: home.appendingPathComponent(".claude", isDirectory: true)
          .appendingPathComponent("commands", isDirectory: true),
        fileExtension: "md",
        format: .markdown
      ),
      SourceDescriptor(
        label: "Gemini",
        directory: home.appendingPathComponent(".gemini", isDirectory: true)
          .appendingPathComponent("commands", isDirectory: true),
        fileExtension: "toml",
        format: .toml
      ),
    ]

    var merged: [String: CommandImportCandidate] = [:]

    for source in sources {
      guard fileManager.fileExists(atPath: source.directory.path) else { continue }
      guard let entries = try? fileManager.contentsOfDirectory(
        at: source.directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { continue }

      for entry in entries where entry.pathExtension.lowercased() == source.fileExtension {
        let id = entry.deletingPathExtension().lastPathComponent
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let marker = source.directory.appendingPathComponent(".\(id).codmate")
        if fileManager.fileExists(atPath: marker.path) { continue }

        guard let candidate = parseCommandCandidate(id: id, url: entry, source: source.label, format: source.format) else { continue }

        if var existing = merged[id] {
          if !existing.sources.contains(source.label) {
            existing.sources.append(source.label)
          }
          existing.sourcePaths[source.label] = entry.path
          merged[id] = existing
        } else {
          merged[id] = candidate
        }
      }
    }

    return merged.values.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  private static func parseCommandCandidate(
    id: String,
    url: URL,
    source: String,
    format: CommandSourceFormat
  ) -> CommandImportCandidate? {
    switch format {
    case .markdown:
      guard let record = CommandsStore.parseMarkdownFile(at: url, id: id, source: "import") else { return nil }
      return CommandImportCandidate(
        id: record.id,
        name: record.name,
        description: record.description,
        prompt: record.prompt,
        metadata: record.metadata,
        sources: [source],
        sourcePaths: [source: url.path],
        isSelected: true,
        hasConflict: false,
        resolution: .overwrite,
        renameId: record.id
      )
    case .toml:
      guard let record = parseTOMLCommand(at: url, id: id) else { return nil }
      return CommandImportCandidate(
        id: record.id,
        name: record.name,
        description: record.description,
        prompt: record.prompt,
        metadata: record.metadata,
        sources: [source],
        sourcePaths: [source: url.path],
        isSelected: true,
        hasConflict: false,
        resolution: .overwrite,
        renameId: record.id
      )
    }
  }

  private static func parseTOMLCommand(at url: URL, id: String) -> CommandRecord? {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

    let parsedPrompt = extractTOMLBlock(named: "prompt", from: content)
    let prompt = parsedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? content.trimmingCharacters(in: .whitespacesAndNewlines)

    let description = extractTOMLString(named: "description", from: content) ?? ""

    return CommandRecord(
      id: id,
      name: id,
      description: description,
      prompt: prompt,
      metadata: CommandMetadata(),
      targets: CommandTargets(codex: true, claude: true, gemini: true),
      isEnabled: true,
      source: "import",
      path: "",
      installedAt: Date()
    )
  }

  private static func extractTOMLBlock(named key: String, from text: String) -> String? {
    let pattern = "^\\s*\(key)\\s*=\\s*\"\"\""
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
      return nil
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

    guard let startRange = Range(match.range, in: text) else { return nil }
    let afterStart = text[startRange.upperBound...]

    if let endRange = afterStart.range(of: "\"\"\"") {
      return String(afterStart[..<endRange.lowerBound])
    }
    return nil
  }

  private static func extractTOMLString(named key: String, from text: String) -> String? {
    let pattern = "^\\s*\(key)\\s*=\\s*\"(.*)\"\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
      return nil
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[valueRange])
  }
}
