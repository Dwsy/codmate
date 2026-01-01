import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService {
  static let shared = LaunchAtLoginService()

  private init() {}

  /// Register or unregister the app to launch at login
  func setLaunchAtLogin(enabled: Bool) {
    if #available(macOS 13.0, *) {
      do {
        if enabled {
          if SMAppService.mainApp.status == .enabled {
            print("[LaunchAtLogin] Already enabled")
            return
          }
          try SMAppService.mainApp.register()
          print("[LaunchAtLogin] Successfully registered for launch at login")
        } else {
          if SMAppService.mainApp.status == .notRegistered {
            print("[LaunchAtLogin] Already disabled")
            return
          }
          try SMAppService.mainApp.unregister()
          print("[LaunchAtLogin] Successfully unregistered from launch at login")
        }
      } catch {
        print("[LaunchAtLogin] Failed to \(enabled ? "register" : "unregister"): \(error)")
      }
    } else {
      print("[LaunchAtLogin] Launch at login requires macOS 13.0 or later")
    }
  }

  /// Check if the app is currently set to launch at login
  var isEnabled: Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    }
    return false
  }

  /// Synchronize the actual system state with preferences
  func syncWithPreferences(_ preferences: SessionPreferencesStore) {
    if #available(macOS 13.0, *) {
      let actuallyEnabled = SMAppService.mainApp.status == .enabled
      if preferences.launchAtLogin != actuallyEnabled {
        print("[LaunchAtLogin] Syncing: preference=\(preferences.launchAtLogin), actual=\(actuallyEnabled)")
        setLaunchAtLogin(enabled: preferences.launchAtLogin)
      }
    }
  }
}
