import Foundation

struct SkillRecord: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var description: String
  var summary: String
  var tags: [String]
  var source: String
  var path: String
  var isEnabled: Bool
  var targets: MCPServerTargets
  var installedAt: Date
}

enum SkillInstallMode: String, CaseIterable, Codable {
  case folder
  case zip
  case url

  var title: String {
    switch self {
    case .folder: return "Folder"
    case .zip: return "Zip"
    case .url: return "URL"
    }
  }
}

struct SkillInstallRequest: Hashable, Sendable {
  var mode: SkillInstallMode
  var url: URL?
  var text: String?
}

enum SkillConflictResolution: Hashable, Sendable {
  case overwrite
  case skip
  case rename(String)
}

struct SkillInstallConflict: Identifiable, Hashable {
  let id: UUID = UUID()
  let proposedId: String
  let destination: URL
  let existingIsManaged: Bool
  let suggestedId: String
}

enum SkillInstallOutcome: Hashable {
  case installed(SkillRecord)
  case skipped
  case conflict(SkillInstallConflict)
}

struct SkillSyncWarning: Hashable, Sendable {
  var message: String
}
