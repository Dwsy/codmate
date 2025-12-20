import SwiftUI

struct GeminiSettingsView: View {
  @ObservedObject var vm: GeminiVM
  @ObservedObject var preferences: SessionPreferencesStore

  private let docsURL = URL(string: "https://geminicli.com/docs/cli/settings/")!

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Group {
        if #available(macOS 15.0, *) {
          TabView {
            Tab("General", systemImage: "gearshape") { generalTab }
            Tab("Runtime", systemImage: "gauge") { runtimeTab }
            Tab("Model", systemImage: "cpu") { modelTab }
            Tab("Raw Config", systemImage: "doc.text") { rawTab }
          }
        } else {
          TabView {
            generalTab
              .tabItem { Label("General", systemImage: "gearshape") }
            runtimeTab
              .tabItem { Label("Runtime", systemImage: "gauge") }
            modelTab
              .tabItem { Label("Model", systemImage: "cpu") }
            rawTab
              .tabItem { Label("Raw Config", systemImage: "doc.text") }
          }
        }
      }
      .controlSize(.regular)
    }
    .padding(.bottom, 16)
    .task { await vm.loadIfNeeded() }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Gemini CLI Settings")
          .font(.title2)
          .fontWeight(.bold)
        Text("Configure Gemini CLI defaults: features, models, and raw settings.json.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Link(destination: docsURL) {
        Label("Docs", systemImage: "questionmark.circle")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
    }
  }

  private var generalTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
        GridRow {
          settingLabel(title: "Preview Features", details: "Enable experimental features like preview models.")
          Toggle("", isOn: $vm.previewFeatures)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.previewFeatures) { _ in vm.applyPreviewFeaturesChange() }
        }
        dividerRow
        GridRow {
          settingLabel(title: "Prompt Completion", details: "Show inline command suggestions while typing.")
          Toggle("", isOn: $vm.enablePromptCompletion)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.enablePromptCompletion) { _ in vm.applyPromptCompletionChange() }
        }
        dividerRow
        GridRow {
          settingLabel(title: "Vim Mode", details: "Use Vim keybindings inside Gemini CLI.")
          Toggle("", isOn: $vm.vimMode)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.vimMode) { _ in vm.applyVimModeChange() }
        }
        dividerRow
        GridRow {
          settingLabel(title: "Disable Auto Update", details: "Prevent Gemini CLI from auto-updating itself.")
          Toggle("", isOn: $vm.disableAutoUpdate)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.disableAutoUpdate) { _ in vm.applyDisableAutoUpdateChange() }
        }
        dividerRow
        GridRow {
          settingLabel(title: "Session Retention", details: "Automatically clean up old sessions when enabled.")
          Toggle("", isOn: $vm.sessionRetentionEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.sessionRetentionEnabled) { _ in vm.applySessionRetentionChange() }
        }
        if let error = vm.lastError {
          dividerRow
          GridRow {
            Text("")
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
    }
  }

  private var runtimeTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
        GridRow {
          settingLabel(title: "Sandbox Mode", details: "Controls Gemini CLI sandbox defaults for new sessions.")
          Picker("", selection: $preferences.defaultResumeSandboxMode) {
            ForEach(SandboxMode.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        dividerRow
        GridRow {
          settingLabel(title: "Approval Policy", details: "Set the default automation level when launching Gemini CLI.")
          Picker("", selection: $preferences.defaultResumeApprovalPolicy) {
            ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
  }

  private var modelTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
        GridRow {
          settingLabel(title: "Model", details: "Choose the model alias to use when launching Gemini CLI.")
          Picker("", selection: $vm.selectedModelId) {
            ForEach(vm.modelOptions) { option in
              Text(option.title).tag(option.value)
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: vm.selectedModelId) { _ in vm.applyModelSelectionChange() }
        }
        if let selection = vm.selectedModelId,
          let descriptor = vm.modelOptions.first(where: { $0.value == selection })?.subtitle
        {
          GridRow {
            Text("")
            Text(descriptor)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        } else if let descriptor = vm.modelOptions.first(where: { $0.value == nil })?.subtitle {
          GridRow {
            Text("")
            Text(descriptor)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
        dividerRow
        GridRow {
          settingLabel(title: "Max Session Turns", details: "Number of turns kept in memory (-1 keeps everything).")
          Stepper(value: $vm.maxSessionTurns, in: -1...10_000, step: 1) {
            Text(vm.maxSessionTurns < 0 ? "Unlimited (-1)" : "\(vm.maxSessionTurns)")
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: vm.maxSessionTurns) { _ in vm.applyMaxSessionTurnsChange() }
        }
        dividerRow
        GridRow {
          settingLabel(title: "Compression Threshold", details: "Fraction of context usage that triggers compression.")
          VStack(alignment: .trailing, spacing: 6) {
            Slider(value: $vm.compressionThreshold, in: 0...1, step: 0.05)
              .frame(maxWidth: 240)
              .onChange(of: vm.compressionThreshold) { _ in vm.applyCompressionThresholdChange() }
            Text("\(vm.compressionThreshold, format: .number.precision(.fractionLength(2)))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        dividerRow
        GridRow {
          settingLabel(title: "Skip Next Speaker Check", details: "Bypass the next speaker role verification step.")
          Toggle("", isOn: $vm.skipNextSpeakerCheck)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.skipNextSpeakerCheck) { _ in vm.applySkipNextSpeakerChange() }
        }
        if let error = vm.lastError {
          dividerRow
          GridRow {
            Text("")
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
    }
  }

  private var rawTab: some View {
    SettingsTabContent {
      ZStack(alignment: .topTrailing) {
        ScrollView {
          Text(vm.rawSettingsText.isEmpty ? "(settings.json not found or empty)" : vm.rawSettingsText)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        HStack(spacing: 8) {
          Button {
            Task { await vm.refreshSettings(); await vm.reloadRawSettings() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("Reload settings")
          .buttonStyle(.borderless)
          Button {
            vm.openSettingsInEditor()
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .help("Reveal settings.json")
          .buttonStyle(.borderless)
        }
      }
    }
  }

  private func settingLabel(title: String, details: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.subheadline)
        .fontWeight(.medium)
      Text(details)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var dividerRow: some View {
    GridRow { Divider().gridCellColumns(2) }
  }
}
