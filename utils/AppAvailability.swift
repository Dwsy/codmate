import AppKit

enum AppAvailability {
  static func isInstalled(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
  }

  static func isInstalled(bundleIdentifiers: [String]) -> Bool {
    for identifier in bundleIdentifiers {
      if isInstalled(bundleIdentifier: identifier) { return true }
    }
    return false
  }

  static func firstInstalledBundleIdentifier(in identifiers: [String]) -> String? {
    for identifier in identifiers {
      if isInstalled(bundleIdentifier: identifier) { return identifier }
    }
    return nil
  }
}
