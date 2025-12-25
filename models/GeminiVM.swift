import AppKit
import Foundation
import SwiftUI

@MainActor
final class GeminiVM: ObservableObject {
  struct ModelOption: Identifiable {
    let value: String?
    let title: String
    let subtitle: String

    var id: String { value ?? "default" }
  }

  @Published var previewFeatures = false
  @Published var vimMode = false
  @Published var disableAutoUpdate = false
  @Published var enablePromptCompletion = false
  @Published var sessionRetentionEnabled = false

  @Published var selectedModelId: String?
  @Published var maxSessionTurns: Int = -1
  @Published var compressionThreshold: Double = 0.5
  @Published var skipNextSpeakerCheck = true

  @Published var notificationsEnabled = false
  @Published var notificationBridgeHealthy = false
  @Published var notificationSelfTestResult: String? = nil

  @Published var rawSettingsText: String = ""
  @Published var lastError: String?
  @Published private(set) var hasLoadedInitialState = false

  var modelOptions: [ModelOption] {
    [
      ModelOption(value: nil, title: "Auto (Gemini CLI default)", subtitle: "CLI picks the best model depending on task complexity"),
      ModelOption(value: "gemini-3-pro-preview", title: "Gemini 3 Pro Preview", subtitle: "High reasoning depth when preview access is enabled"),
      ModelOption(value: "gemini-2.5-pro", title: "Gemini 2.5 Pro", subtitle: "Deep reasoning with broad tool support"),
      ModelOption(value: "gemini-2.5-flash", title: "Gemini 2.5 Flash", subtitle: "Balanced speed and reasoning"),
      ModelOption(value: "gemini-2.5-flash-lite", title: "Gemini 2.5 Flash Lite", subtitle: "Fastest responses for lightweight tasks"),
    ]
  }

  private let service = GeminiSettingsService()
  private var notificationDebounceTask: Task<Void, Never>? = nil

  func loadIfNeeded() async {
    if hasLoadedInitialState { return }
    await refreshSettings()
    await loadNotificationSettings()
    await reloadRawSettings()
    hasLoadedInitialState = true
  }

  func refreshSettings() async {
    let snapshot = await service.loadSnapshot()
    previewFeatures = snapshot.previewFeatures ?? false
    vimMode = snapshot.vimMode ?? false
    disableAutoUpdate = snapshot.disableAutoUpdate ?? false
    enablePromptCompletion = snapshot.enablePromptCompletion ?? false
    sessionRetentionEnabled = snapshot.sessionRetentionEnabled ?? false
    selectedModelId = snapshot.modelName
    maxSessionTurns = snapshot.maxSessionTurns ?? -1
    compressionThreshold = snapshot.compressionThreshold ?? 0.5
    skipNextSpeakerCheck = snapshot.skipNextSpeakerCheck ?? true
  }

  func reloadRawSettings() async {
    rawSettingsText = await service.loadRawText()
  }

  func openSettingsInEditor() {
    let url = service.settingsFileURL
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  // MARK: - Apply handlers

  func applyPreviewFeaturesChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setBool(self.previewFeatures, at: ["general", "previewFeatures"]) }
  }

  func applyVimModeChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setBool(self.vimMode, at: ["general", "vimMode"]) }
  }

  func applyDisableAutoUpdateChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setBool(self.disableAutoUpdate, at: ["general", "disableAutoUpdate"]) }
  }

  func applyPromptCompletionChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setBool(self.enablePromptCompletion, at: ["general", "enablePromptCompletion"]) }
  }

  func applySessionRetentionChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setBool(self.sessionRetentionEnabled, at: ["general", "sessionRetention", "enabled"]) }
  }

  func applyModelSelectionChange() {
    guard hasLoadedInitialState else { return }
    let value = selectedModelId
    persist { [self] in try await self.service.setOptionalString(value, at: ["model", "name"]) }
  }

  func applyMaxSessionTurnsChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setInt(self.maxSessionTurns, at: ["model", "maxSessionTurns"]) }
  }

  func applyCompressionThresholdChange() {
    guard hasLoadedInitialState else { return }
    let value = compressionThreshold
    persist { [self] in try await self.service.setDouble(value, at: ["model", "compressionThreshold"]) }
  }

  func applySkipNextSpeakerChange() {
    guard hasLoadedInitialState else { return }
    persist { [self] in try await self.service.setBool(self.skipNextSpeakerCheck, at: ["model", "skipNextSpeakerCheck"]) }
  }

  func loadNotificationSettings() async {
    let status = await service.codMateNotificationHooksStatus()
    await MainActor.run {
      self.notificationsEnabled = status.hookInstalled
      self.notificationBridgeHealthy = status.hookInstalled && status.hooksEnabled
      if !self.notificationBridgeHealthy {
        self.notificationSelfTestResult = nil
      }
    }
  }

  private func applyNotificationSettings() async {
    if SecurityScopedBookmarks.shared.isSandboxed {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
        directory: home.appendingPathComponent(".gemini", isDirectory: true),
        purpose: .generalAccess,
        message: "Authorize ~/.gemini to update Gemini notifications"
      )
    }
    do {
      try await service.setCodMateNotificationHooks(enabled: notificationsEnabled)
      await loadNotificationSettings()
    } catch {
      await MainActor.run { self.lastError = "Failed to update Gemini notifications" }
    }
  }

  func runNotificationSelfTest() async {
    notificationSelfTestResult = nil
    var comps = URLComponents()
    comps.scheme = "codmate"
    comps.host = "notify"
    let title = "CodMate"
    let body = "Gemini notifications self-test"
    var items = [
      URLQueryItem(name: "source", value: "gemini"),
      URLQueryItem(name: "event", value: "test")
    ]
    if let titleData = title.data(using: .utf8) {
      items.append(URLQueryItem(name: "title64", value: titleData.base64EncodedString()))
    }
    if let bodyData = body.data(using: .utf8) {
      items.append(URLQueryItem(name: "body64", value: bodyData.base64EncodedString()))
    }
    comps.queryItems = items
    guard let url = comps.url else {
      notificationSelfTestResult = "Invalid test URL"
      return
    }
    let success = NSWorkspace.shared.open(url)
    notificationSelfTestResult = success ? "Sent (check Notification Center)" : "Failed to open codmate:// URL"
  }

  func scheduleApplyNotificationSettingsDebounced(delayMs: UInt64 = 250) {
    notificationDebounceTask?.cancel()
    notificationDebounceTask = Task { [weak self] in
      guard let self else { return }
      do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
      if Task.isCancelled { return }
      await self.applyNotificationSettings()
    }
  }

  private func persist(_ work: @escaping () async throws -> Void) {
    Task { @MainActor in
      do {
        try await work()
        self.lastError = nil
      } catch {
        self.lastError = error.localizedDescription
      }
    }
  }
}
