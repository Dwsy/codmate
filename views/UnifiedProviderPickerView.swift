import SwiftUI
import AppKit

struct UnifiedProviderPickerView: View {
  let sections: [UnifiedProviderSection]
  let models: [String]
  let modelSectionTitle: String?
  let includeAuto: Bool
  let autoTitle: String
  let includeDefaultModel: Bool
  let defaultModelTitle: String
  let providerUnavailableHint: String?
  let disableModels: Bool
  let showProviderPicker: Bool
  let showModelPicker: Bool
  let simpleMode: Bool
  let autoProxyTitle: String
  let sanitizeModelNames: Bool
  let onEditModels: (() -> Void)?
  let editModelsHelp: String?

  @Binding var providerId: String?
  @Binding var modelId: String?

  init(
    sections: [UnifiedProviderSection],
    models: [String],
    modelSectionTitle: String?,
    includeAuto: Bool,
    autoTitle: String,
    includeDefaultModel: Bool,
    defaultModelTitle: String,
    providerUnavailableHint: String?,
    disableModels: Bool,
    showProviderPicker: Bool = true,
    showModelPicker: Bool = true,
    simpleMode: Bool = false,
    autoProxyTitle: String = "Auto-Proxy (CliProxyAPI)",
    sanitizeModelNames: Bool = false,
    onEditModels: (() -> Void)? = nil,
    editModelsHelp: String? = nil,
    providerId: Binding<String?>,
    modelId: Binding<String?>
  ) {
    self.sections = sections
    self.models = models
    self.modelSectionTitle = modelSectionTitle
    self.includeAuto = includeAuto
    self.autoTitle = autoTitle
    self.includeDefaultModel = includeDefaultModel
    self.defaultModelTitle = defaultModelTitle
    self.providerUnavailableHint = providerUnavailableHint
    self.disableModels = disableModels
    self.showProviderPicker = showProviderPicker
    self.showModelPicker = showModelPicker
    self.simpleMode = simpleMode
    self.autoProxyTitle = autoProxyTitle
    self.sanitizeModelNames = sanitizeModelNames
    self.onEditModels = onEditModels
    self.editModelsHelp = editModelsHelp
    self._providerId = providerId
    self._modelId = modelId
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 8) {
        if showProviderPicker {
          providerPicker
        }
        if showModelPicker {
          modelPicker
        }
        if showModelPicker, let onEditModels {
          Button {
            onEditModels()
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .buttonStyle(.borderless)
          .help(editModelsHelp ?? "Edit models")
        }
      }
      if showProviderPicker, let hint = providerUnavailableHint, !hint.isEmpty {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var providerPicker: some View {
    Group {
      if simpleMode {
        // Simple mode: custom segmented control with individual tooltips
        HStack(spacing: 0) {
          Button {
            providerId = nil
          } label: {
            Text(autoTitle)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 4)
          }
          .buttonStyle(SegmentButtonStyle(isSelected: providerId == nil))
          .help("Use CLI's built-in provider configuration")

          Button {
            providerId = UnifiedProviderID.autoProxyId
          } label: {
            Text(autoProxyTitle)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 4)
          }
          .buttonStyle(SegmentButtonStyle(isSelected: providerId == UnifiedProviderID.autoProxyId))
          .help("Route all requests through CLI Proxy API for unified provider management")
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        // Full mode: dropdown picker with all providers
        Picker("", selection: $providerId) {
          if includeAuto {
            Text(autoTitle).tag(String?.none)
          }
          ForEach(sections) { section in
            Section(section.title) {
              ForEach(section.providers) { provider in
                providerMenuItem(provider)
                  .tag(String?(provider.id))
                  .disabled(!provider.isAvailable)
              }
            }
          }
        }
        .labelsHidden()
      }
    }
  }

  @ViewBuilder
  private func providerMenuItem(_ provider: UnifiedProviderChoice) -> some View {
    let parsed = UnifiedProviderID.parse(provider.id)
    switch parsed {
    case .oauth(let authProvider, _):
      Label {
        Text(provider.title)
      } icon: {
        // LocalAuthProviderIconView already applies theme handling internally
        LocalAuthProviderIconView(provider: authProvider, size: 14, cornerRadius: 2)
      }
    case .api(let apiId):
      // For API key providers, use unified icon resource library
      if let iconName = ProviderIconResource.iconName(for: apiId) ?? ProviderIconResource.iconName(for: provider.title),
         let processedImage = ProviderIconResource.processedImage(
           named: iconName,
           size: NSSize(width: 14, height: 14),
           isDarkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
         ) {
        Label {
          Text(provider.title)
        } icon: {
          Image(nsImage: processedImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 14, height: 14)
        }
      } else {
        Text(provider.title)
      }
    default:
      Text(provider.title)
    }
  }

  private func iconNameForOAuthProvider(_ provider: LocalAuthProvider) -> String {
    switch provider {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    case .gemini: return "GeminiIcon"
    case .antigravity: return "AntigravityIcon"
    case .qwen: return "QwenIcon"
    }
  }


  private var modelPicker: some View {
    Picker("", selection: $modelId) {
      if includeDefaultModel {
        Text(defaultModelTitle).tag(String?.none)
      }
      if let title = modelSectionTitle, !models.isEmpty {
        Section(title) {
          ForEach(models, id: \.self) { model in
            Text(displayName(for: model)).tag(String?(model))
          }
        }
      } else {
        ForEach(models, id: \.self) { model in
          Text(displayName(for: model)).tag(String?(model))
        }
      }
    }
    .labelsHidden()
    .disabled(disableModels)
  }

  /// Returns the display name for a model (sanitized if enabled, otherwise raw)
  private func displayName(for model: String) -> String {
    if sanitizeModelNames {
      return ModelNameSanitizer.sanitizeSingle(model)
    }
    return model
  }
}

// MARK: - Segment Button Style

private struct SegmentButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11))
      .foregroundColor(isSelected ? .white : .primary)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? Color.accentColor : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5)
      )
      .opacity(configuration.isPressed ? 0.7 : 1.0)
  }
}
