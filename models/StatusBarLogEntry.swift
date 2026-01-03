import Foundation

enum StatusBarLogLevel: String, Codable, CaseIterable, Identifiable {
  case info
  case success
  case warning
  case error

  var id: String { rawValue }
}

struct StatusBarLogEntry: Identifiable, Equatable {
  let id = UUID()
  let timestamp: Date
  let level: StatusBarLogLevel
  let message: String
  let source: String?

  init(message: String, level: StatusBarLogLevel = .info, source: String? = nil, timestamp: Date = Date()) {
    self.message = message
    self.level = level
    self.source = source
    self.timestamp = timestamp
  }
}
