import Foundation

enum LocalServerBuiltInProvider: String, CaseIterable, Identifiable {
    case anthropic
    case gemini
    case openai
    case antigravity
    case qwen

    var id: String { "local-builtin-\(rawValue)" }

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (OAuth)"
        case .gemini: return "Gemini (OAuth)"
        case .openai: return "Codex (OAuth)"
        case .antigravity: return "Antigravity (OAuth)"
        case .qwen: return "Qwen Code (OAuth)"
        }
    }

    var ownedByHints: [String] {
        switch self {
        case .anthropic: return ["anthropic", "claude"]
        case .gemini: return ["google", "gemini"]
        case .openai: return ["openai", "codex", "gpt"]
        case .antigravity: return ["antigravity"]
        case .qwen: return ["qwen"]
        }
    }

    var modelIdHints: [String] {
        switch self {
        case .anthropic: return ["claude-"]
        case .gemini: return ["gemini-"]
        case .openai: return ["gpt-"]
        case .antigravity: return ["gemini-3", "gemini-3-"]
        case .qwen: return ["qwen-"]
        }
    }

    func matchesOwnedBy(_ value: String?) -> Bool {
        let lower = (value ?? "").lowercased()
        return ownedByHints.contains { lower.contains($0) }
    }

    func matchesModelId(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return modelIdHints.contains { lower.hasPrefix($0) }
    }

    static func from(providerId: String?) -> LocalServerBuiltInProvider? {
        guard let providerId else { return nil }
        return LocalServerBuiltInProvider.allCases.first(where: { $0.id == providerId })
    }
}
