import Foundation

struct ProjectMCPConfig: Codable, Hashable, Sendable {
  var id: String
  var isSelected: Bool
  var targets: MCPServerTargets
}

struct ProjectSkillConfig: Codable, Hashable, Sendable {
  var id: String
  var isSelected: Bool
  var targets: MCPServerTargets
}

struct ProjectExtensionsConfig: Codable, Hashable, Sendable {
  var projectId: String
  var mcpServers: [ProjectMCPConfig]
  var skills: [ProjectSkillConfig]
  var updatedAt: Date
}
