import Foundation

enum TerminalCursorStyleOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blinkBlock: return "Blinking Block"
        case .steadyBlock: return "Steady Block"
        case .blinkUnderline: return "Blinking Underline"
        case .steadyUnderline: return "Steady Underline"
        case .blinkBar: return "Blinking Bar"
        case .steadyBar: return "Steady Bar"
        }
    }

    // Ghostty cursor configuration string
    var ghosttyConfigValue: String {
        switch self {
        case .blinkBlock: return "block"
        case .steadyBlock: return "block"
        case .blinkUnderline: return "underline"
        case .steadyUnderline: return "underline"
        case .blinkBar: return "bar"
        case .steadyBar: return "bar"
        }
    }

    var ghosttyBlinkEnabled: Bool {
        switch self {
        case .blinkBlock, .blinkUnderline, .blinkBar:
            return true
        case .steadyBlock, .steadyUnderline, .steadyBar:
            return false
        }
    }
}

