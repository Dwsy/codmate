import Foundation

enum LocalAuthProvider: String, CaseIterable, Identifiable {
  case codex
  case claude
  case gemini
  case antigravity
  case qwen

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .gemini: return "Gemini"
    case .antigravity: return "Antigravity"
    case .qwen: return "Qwen Code"
    }
  }

  var loginFlag: String {
    switch self {
    case .gemini: return "--login"
    case .codex: return "--codex-login"
    case .claude: return "--claude-login"
    case .antigravity: return "--antigravity-login"
    case .qwen: return "--qwen-login"
    }
  }

  var authAliases: [String] {
    switch self {
    case .codex:
      return ["codex", "openai"]
    case .claude:
      return ["claude", "anthropic"]
    case .gemini:
      return ["gemini"]
    case .antigravity:
      return ["antigravity"]
    case .qwen:
      return ["qwen", "qwen-code", "qwen_code"]
    }
  }
}
