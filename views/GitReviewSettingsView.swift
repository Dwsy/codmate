import SwiftUI

struct GitReviewSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore

  @State private var draftTemplate: String = ""
  @State private var providerId: String? = nil
  @State private var providersList: [ProvidersRegistryService.Provider] = []
  @State private var modelId: String? = nil
  @State private var modelList: [String] = []
  @State private var builtInModels: [String: [String]] = [:]
  @State private var reroutedProviderModels: [String: [String]] = [:]
  @State private var reroutedProviderNames: [String: String] = [:]
  @State private var showBuiltInProviders: Bool = false
  @State private var showReroutedProviders: Bool = false

  private let rerouteProviderPrefix = "local-reroute:"

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Git Review Settings").font(.title2).fontWeight(.bold)
        Text("Customize Git changes viewer and AI commit generation.")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("Display").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Show Line Numbers", systemImage: "list.number")
                  .font(.subheadline).fontWeight(.medium)
                Text("Show line numbers in diffs.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Toggle("", isOn: $preferences.gitShowLineNumbers)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Wrap Long Lines", systemImage: "text.line.first.and.arrowtriangle.forward")
                  .font(.subheadline).fontWeight(.medium)
                Text("Enable soft wrap in diff viewer.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Toggle("", isOn: $preferences.gitWrapText)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("Generate").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Commit Model", systemImage: "brain")
                  .font(.subheadline).fontWeight(.medium)
                Text("Select an OAuth provider or an API key provider, then choose its model.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              HStack(spacing: 8) {
                Picker(
                  "",
                  selection: Binding(
                    get: { providerId ?? "(auto)" },
                    set: { newVal in
                      providerId = (newVal == "(auto)") ? nil : newVal
                      preferences.commitProviderId = providerId
                      // Update models list when provider changes
                      let models = modelsForCurrentProvider()
                      modelList = models
                      // Reset model when provider changed
                      let nextModel =
                        models.contains(preferences.commitModelId ?? "")
                        ? preferences.commitModelId : nil
                      modelId = nextModel
                      if nextModel == nil {
                        preferences.commitModelId = nil
                      }
                    }
                  )
                ) {
                  Text("Auto").tag("(auto)")
                  if showBuiltInProviders {
                    Section("OAuth Providers") {
                      ForEach(LocalServerBuiltInProvider.allCases) { p in
                        Text(p.displayName).tag(p.id)
                      }
                    }
                  }
                  if showReroutedProviders && !reroutedProviderModels.isEmpty {
                    Section("ReRoute API Key Providers") {
                      ForEach(sortedReroutedProviderIds, id: \.self) { pid in
                        Text(reroutedProviderNames[pid] ?? pid).tag(pid)
                      }
                    }
                  }
                  if !preferences.localServerReroute3P && !providersList.isEmpty {
                    Section("API Key Providers") {
                      ForEach(providersList, id: \.id) { p in
                        Text((p.name?.isEmpty == false ? p.name! : p.id)).tag(p.id)
                      }
                    }
                  }
                }
                .labelsHidden()
                Picker(
                  "",
                  selection: Binding(
                    get: { modelId ?? "(default)" },
                    set: { newVal in
                      modelId = (newVal == "(default)") ? nil : newVal
                      preferences.commitModelId = modelId
                    }
                  )
                ) {
                  Text("(default)").tag("(default)")
                  if let title = modelSectionTitle, !modelList.isEmpty {
                    Section(title) {
                      ForEach(modelList, id: \.self) { mid in Text(mid).tag(mid) }
                    }
                  } else {
                    ForEach(modelList, id: \.self) { mid in Text(mid).tag(mid) }
                  }
                }
                .labelsHidden()
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            // Prompt template placed last
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Commit Message Prompt Template", systemImage: "text.bubble")
                  .font(.subheadline).fontWeight(.medium)
                Text(
                  "Optional preamble used before the diff when generating commit messages. Leave blank to use the built‑in prompt."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
                TextEditor(text: $draftTemplate)
                  .font(.system(.body))
                  .frame(height: 320)
                  .padding(4)
                  .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25))
                  )
                  .onChange(of: draftTemplate) { newVal in
                    preferences.commitPromptTemplate = newVal
                  }
              }
              .gridCellColumns(2)
            }
          }
        }
      }

      // Repository authorization has moved to on-demand prompts in Review.
      // The settings page no longer manages a global list to reduce clutter.
    }
    .onAppear {
      draftTemplate = preferences.commitPromptTemplate
      providerId = preferences.commitProviderId
      updateProviderVisibility()
      Task {
        // Only show user-added providers to avoid confusion
        let list = await ProvidersRegistryService().listProviders()
        providersList = list
        await refreshLocalModels()
        normalizeCommitSelection()
      }
    }
    .onChange(of: preferences.localServerReroute) { _ in
      updateProviderVisibility()
      normalizeCommitSelection()
    }
    .onChange(of: preferences.localServerReroute3P) { _ in
      updateProviderVisibility()
      Task {
        if preferences.localServerReroute3P {
          await CLIProxyService.shared.syncThirdPartyProviders()
        }
        await refreshLocalModels()
        normalizeCommitSelection()
      }
    }
    .onChange(of: CLIProxyService.shared.isRunning) { _ in
      updateProviderVisibility()
      Task {
        await refreshLocalModels()
        normalizeCommitSelection()
      }
    }
  }

  @ViewBuilder
  private var gridDivider: some View {
    Divider()
  }

  @ViewBuilder
  private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(10)
    .background(Color(nsColor: .separatorColor).opacity(0.35))
    .cornerRadius(10)
  }

  private func updateProviderVisibility() {
    // Show providers only if service is running and reroute is enabled
    let isServiceRunning = CLIProxyService.shared.isRunning
    showBuiltInProviders = isServiceRunning && preferences.localServerReroute
    showReroutedProviders = isServiceRunning && preferences.localServerReroute3P
  }

  private var modelSectionTitle: String? {
    if LocalServerBuiltInProvider.from(providerId: providerId) != nil {
      return "OAuth Providers"
    }
    if rerouteProviderName(from: providerId) != nil {
      return "ReRoute API Key Providers"
    }
    if providerId != nil {
      return "API Key Providers"
    }
    return nil
  }

  private func modelsForCurrentProvider() -> [String] {
    if let builtin = LocalServerBuiltInProvider.from(providerId: providerId) {
      return builtInModels[builtin.id] ?? []
    }
    if let pid = providerId, let models = reroutedProviderModels[pid] {
      return models
    }
    guard let pid = providerId, let p = providersList.first(where: { $0.id == pid }) else {
      return []
    }
    let ids = (p.catalog?.models ?? []).map { $0.vendorModelId }
    return ids
  }

  private func refreshLocalModels() async {
    let models = await CLIProxyService.shared.fetchLocalModels()
    let mapped = mapLocalModels(models)
    builtInModels = mapped.builtIns
    reroutedProviderModels = mapped.rerouted
    reroutedProviderNames = mapped.names
  }

  private func mapLocalModels(_ models: [CLIProxyService.LocalModel]) -> (builtIns: [String: [String]], rerouted: [String: [String]], names: [String: String]) {
    var builtIns: [String: [String]] = [:]
    var rerouted: [String: [String]] = [:]
    var names: [String: String] = [:]
    for provider in LocalServerBuiltInProvider.allCases {
      builtIns[provider.id] = []
    }
    for model in models {
      if let provider = builtInProvider(for: model) {
        var list = builtIns[provider.id] ?? []
        if !list.contains(model.id) {
          list.append(model.id)
        }
        builtIns[provider.id] = list
        continue
      }
      guard let label = rerouteProviderLabel(for: model) else { continue }
      let pid = rerouteProviderId(for: label)
      names[pid] = label
      var list = rerouted[pid] ?? []
      if !list.contains(model.id) {
        list.append(model.id)
      }
      rerouted[pid] = list
    }
    return (builtIns, rerouted, names)
  }

  private func builtInProvider(for model: CLIProxyService.LocalModel) -> LocalServerBuiltInProvider? {
    let hint = model.provider ?? model.source ?? model.owned_by
    if let hint, let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesOwnedBy(hint) }) {
      return provider
    }
    let modelId = model.id
    if let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesModelId(modelId) }) {
      return provider
    }
    return nil
  }

  private func rerouteProviderLabel(for model: CLIProxyService.LocalModel) -> String? {
    let hint = model.provider ?? model.source ?? model.owned_by
    let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func rerouteProviderId(for name: String) -> String {
    return rerouteProviderPrefix + name
  }

  private func rerouteProviderName(from providerId: String?) -> String? {
    guard let providerId, providerId.hasPrefix(rerouteProviderPrefix) else { return nil }
    let name = String(providerId.dropFirst(rerouteProviderPrefix.count))
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var sortedReroutedProviderIds: [String] {
    reroutedProviderModels.keys.sorted {
      let a = reroutedProviderNames[$0] ?? $0
      let b = reroutedProviderNames[$1] ?? $1
      return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
  }

  private func normalizeCommitSelection() {
    if let _ = LocalServerBuiltInProvider.from(providerId: providerId), !showBuiltInProviders {
      providerId = nil
      preferences.commitProviderId = nil
      modelId = nil
      preferences.commitModelId = nil
    }

    if let pid = providerId, rerouteProviderName(from: pid) != nil, !showReroutedProviders {
      providerId = nil
      preferences.commitProviderId = nil
      modelId = nil
      preferences.commitModelId = nil
    }

    if showReroutedProviders,
       let pid = providerId,
       providersList.contains(where: { $0.id == pid }) {
      let rawName = providersList.first(where: { $0.id == pid })?.name
      let name = (rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? rawName! : pid
      let rerouteId = rerouteProviderId(for: name)
      if reroutedProviderModels[rerouteId] != nil {
        providerId = rerouteId
        preferences.commitProviderId = rerouteId
      } else {
        providerId = nil
        preferences.commitProviderId = nil
      }
      modelId = nil
      preferences.commitModelId = nil
    }

    modelList = modelsForCurrentProvider()
    let nextModel =
      modelList.contains(preferences.commitModelId ?? "")
      ? preferences.commitModelId : nil
    modelId = nextModel
    if nextModel == nil {
      preferences.commitModelId = nil
    }
  }

}

// Authorized repositories list has been removed from Settings.
