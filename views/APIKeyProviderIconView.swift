import SwiftUI
import AppKit

struct APIKeyProviderIconView: View {
  let provider: ProvidersRegistryService.Provider
  var size: CGFloat = 16
  var cornerRadius: CGFloat = 4
  var isSelected: Bool = false

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image = processedIcon {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
          .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
              .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
          )
      } else {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(Color.accentColor)
          .frame(width: size, height: size)
      }
    }
    .frame(width: size, height: size, alignment: .center)
    .id(colorScheme) // Force refresh when colorScheme changes
  }

  /// Computed property that depends on colorScheme, ensuring real-time theme updates
  private var processedIcon: NSImage? {
    // Use unified icon resource library
    let codexBaseURL = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL
    let claudeBaseURL = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL
    let baseURL = codexBaseURL ?? claudeBaseURL
    
    guard let iconName = ProviderIconResource.iconName(
      forProviderId: provider.id,
      name: provider.name,
      baseURL: baseURL
    ) else { return nil }
    
    // Use unified resource processing with theme adaptation
    // This computed property depends on colorScheme, so SwiftUI will recompute it when theme changes
    let isDarkMode = colorScheme == .dark
    return ProviderIconResource.processedImage(
      named: iconName,
      size: NSSize(width: size, height: size),
      isDarkMode: isDarkMode
    )
  }

  private func iconNameForProvider(_ provider: ProvidersRegistryService.Provider) -> String? {
    let codexBaseURL = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL
    let claudeBaseURL = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL
    let baseURL = codexBaseURL ?? claudeBaseURL
    
    return ProviderIconResource.iconName(
      forProviderId: provider.id,
      name: provider.name,
      baseURL: baseURL
    )
  }
}
