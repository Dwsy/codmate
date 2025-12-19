import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case none
    case terminal  // Apple Terminal
    case iterm2
    case warp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .warp: return "Warp"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .terminal:
            return "com.apple.Terminal"
        case .iterm2:
            return "com.googlecode.iterm2"
        case .warp:
            let identifiers = warpBundleIdentifiers
            return AppAvailability.firstInstalledBundleIdentifier(in: identifiers) ?? identifiers.first
        }
    }
}

extension TerminalApp {
    var bundleIdentifiers: [String] {
        switch self {
        case .none:
            return []
        case .terminal:
            return ["com.apple.Terminal"]
        case .iterm2:
            return ["com.googlecode.iterm2"]
        case .warp:
            return warpBundleIdentifiers
        }
    }

    var isInstalled: Bool {
        switch self {
        case .none:
            return false
        case .terminal:
            return true
        case .iterm2, .warp:
            return AppAvailability.isInstalled(bundleIdentifiers: bundleIdentifiers)
        }
    }

    static let availableExternalApps: [TerminalApp] = availableApps(includeNone: false)
    static let availableExternalAppsIncludingNone: [TerminalApp] = availableApps(includeNone: true)

    private static func availableApps(includeNone: Bool) -> [TerminalApp] {
        var apps: [TerminalApp] = includeNone ? [.none, .terminal] : [.terminal]
        if TerminalApp.iterm2.isInstalled { apps.append(.iterm2) }
        if TerminalApp.warp.isInstalled { apps.append(.warp) }
        return apps
    }
}

private let warpBundleIdentifiers = [
    "dev.warp.Warp-Stable",
    "dev.warp.Warp"
]
