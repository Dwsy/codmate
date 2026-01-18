import Foundation
import GhosttyKit

/// Lightweight Ghostty Terminal session manager
/// Only handles view caching; process management is handled by libghostty
@MainActor
final class GhosttySessionManager {
    static let shared = GhosttySessionManager()

    private var scrollViews: [String: TerminalScrollView] = [:]
    private var accessOrder: [String] = []
    private let maxSessions = 50

    private init() {}

    func getScrollView(for key: String) -> TerminalScrollView? {
        touch(key)
        return scrollViews[key]
    }

    func setScrollView(_ view: TerminalScrollView, for key: String) {
        scrollViews[key] = view
        touch(key)
        evictIfNeeded()
    }

    func removeScrollView(for key: String) {
        scrollViews.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    func removeAll() {
        scrollViews.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        while scrollViews.count > maxSessions, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            scrollViews.removeValue(forKey: oldest)
        }
    }

    /// Check if there is a running process (for close confirmation)
    @MainActor
    func hasRunningProcess(for key: String) -> Bool {
        guard let scrollView = scrollViews[key] else { return false }
        return scrollView.surfaceView.needsConfirmQuit
    }

    /// Check if there are any running processes
    @MainActor
    func hasAnyRunningProcesses() -> Bool {
        for scrollView in scrollViews.values {
            if scrollView.surfaceView.needsConfirmQuit {
                return true
            }
        }
        return false
    }
}
