import CoreGraphics
import Foundation

@MainActor
final class StatusBarLogStore: ObservableObject {
  static let shared = StatusBarLogStore()

  @Published private(set) var entries: [StatusBarLogEntry] = []
  @Published private(set) var isAutoVisible: Bool = false
  @Published var isExpanded: Bool = false {
    didSet {
      if isExpanded {
        autoHideTask?.cancel()
        autoHideTask = nil
      }
    }
  }
  @Published var expandedHeight: CGFloat = 200
  @Published private(set) var activeTaskCount: Int = 0
  @Published private(set) var isInteracting: Bool = false

  let collapsedHeight: CGFloat = 26
  private let minExpandedHeight: CGFloat = 120
  private let maxExpandedHeight: CGFloat = 520
  private var autoCollapseEnabled: Bool = true

  private let maxEntries = 200
  private let autoHideSeconds: TimeInterval = 6
  private var autoHideTask: Task<Void, Never>?
  private var activeTaskTokens: Set<String> = []

  private init() {}

  func post(
    _ message: String,
    level: StatusBarLogLevel = .info,
    source: String? = nil
  ) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    entries.append(StatusBarLogEntry(message: trimmed, level: level, source: source))
    if entries.count > maxEntries {
      entries.removeFirst(entries.count - maxEntries)
    }
    isAutoVisible = true
    scheduleAutoHide()
  }

  func beginTask(
    _ message: String,
    level: StatusBarLogLevel = .info,
    source: String? = nil
  ) -> String {
    let token = UUID().uuidString
    activeTaskTokens.insert(token)
    activeTaskCount = activeTaskTokens.count
    post(message, level: level, source: source)
    return token
  }

  func endTask(
    _ token: String,
    message: String? = nil,
    level: StatusBarLogLevel = .info,
    source: String? = nil
  ) {
    if activeTaskTokens.remove(token) != nil {
      activeTaskCount = activeTaskTokens.count
    }
    if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      post(message, level: level, source: source)
    } else {
      isAutoVisible = true
      scheduleAutoHide()
    }
  }

  func clear() {
    entries.removeAll()
    isAutoVisible = false
    autoHideTask?.cancel()
    autoHideTask = nil
  }

  func setExpandedHeight(_ height: CGFloat) {
    let clamped = min(max(height, minExpandedHeight), maxExpandedHeight)
    if abs(Double(clamped - expandedHeight)) > 0.5 {
      expandedHeight = clamped
    }
  }

  func setAutoCollapseEnabled(_ isEnabled: Bool) {
    autoCollapseEnabled = isEnabled
    if !isEnabled {
      autoHideTask?.cancel()
      autoHideTask = nil
    }
  }

  func setInteracting(_ isInteracting: Bool) {
    guard self.isInteracting != isInteracting else { return }
    self.isInteracting = isInteracting
    if isInteracting {
      autoHideTask?.cancel()
      autoHideTask = nil
    } else {
      scheduleAutoHide()
    }
  }

  func reveal(expanded: Bool = false) {
    isAutoVisible = true
    if expanded {
      isExpanded = true
    }
    scheduleAutoHide()
  }

  private func scheduleAutoHide() {
    guard autoCollapseEnabled else { return }
    if isExpanded { return }
    autoHideTask?.cancel()
    let delay = autoHideSeconds
    autoHideTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      await MainActor.run {
        guard self.autoCollapseEnabled else { return }
        guard self.activeTaskCount == 0 else { return }
        if self.isExpanded {
          return
        }
        if self.isInteracting {
          self.scheduleAutoHide()
          return
        }
        self.isAutoVisible = false
        self.isExpanded = false
      }
    }
  }
}
