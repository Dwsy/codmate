import Foundation
import os.log
import OSLog

/// Unified logging system that outputs to both console (for `make debug` mode)
/// and the Status Bar UI for in-app visibility.
@MainActor
final class AppLogger {
  static let shared = AppLogger()

  private let subsystem = Bundle.main.bundleIdentifier ?? "com.codmate"
  private var loggers: [String: Logger] = [:]

  private init() {}

  private func logger(for category: String) -> Logger {
    if let existing = loggers[category] {
      return existing
    }
    let logger = Logger(subsystem: subsystem, category: category)
    loggers[category] = logger
    return logger
  }

  // MARK: - Public API

  func info(_ message: String, source: String? = nil) {
    log(message, level: .info, source: source)
  }

  func success(_ message: String, source: String? = nil) {
    log(message, level: .success, source: source)
  }

  func warning(_ message: String, source: String? = nil) {
    log(message, level: .warning, source: source)
  }

  func error(_ message: String, source: String? = nil) {
    log(message, level: .error, source: source)
  }

  func log(_ message: String, level: StatusBarLogLevel = .info, source: String? = nil) {
    let category = source ?? "App"

    // Output to console for `make debug` mode
    let prefix: String
    switch level {
    case .info: prefix = "ℹ️"
    case .success: prefix = "✅"
    case .warning: prefix = "⚠️"
    case .error: prefix = "❌"
    }
    let osLog = logger(for: category)
    switch level {
    case .info:
      osLog.info("[\(category)] \(message)")
    case .success:
      osLog.info("[\(category)] \(message)")
    case .warning:
      osLog.warning("[\(category)] \(message)")
    case .error:
      osLog.error("[\(category)] \(message)")
    }

    // Also print to stderr for immediate visibility in debug console
    #if DEBUG
    NSLog("%@ [%@] %@", prefix, category, message)
    #endif

    // Post to Status Bar for in-app visibility
    StatusBarLogStore.shared.post(message, level: level, source: source)
  }

  // MARK: - Task tracking

  func beginTask(_ message: String, source: String? = nil) -> String {
    let category = source ?? "App"
    #if DEBUG
    NSLog("🔄 [%@] %@", category, message)
    #endif
    logger(for: category).info("[\(category)] \(message)")
    return StatusBarLogStore.shared.beginTask(message, level: .info, source: source)
  }

  func endTask(_ token: String, message: String? = nil, level: StatusBarLogLevel = .success, source: String? = nil) {
    if let message {
      let category = source ?? "App"
      let prefix: String
      switch level {
      case .info: prefix = "ℹ️"
      case .success: prefix = "✅"
      case .warning: prefix = "⚠️"
      case .error: prefix = "❌"
      }
      #if DEBUG
      NSLog("%@ [%@] %@", prefix, category, message)
      #endif
    }
    StatusBarLogStore.shared.endTask(token, message: message, level: level, source: source)
  }
}

// MARK: - Convenience global functions

@MainActor
func logInfo(_ message: String, source: String? = nil) {
  AppLogger.shared.info(message, source: source)
}

@MainActor
func logSuccess(_ message: String, source: String? = nil) {
  AppLogger.shared.success(message, source: source)
}

@MainActor
func logWarning(_ message: String, source: String? = nil) {
  AppLogger.shared.warning(message, source: source)
}

@MainActor
func logError(_ message: String, source: String? = nil) {
  AppLogger.shared.error(message, source: source)
}
