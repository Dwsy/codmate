import SwiftUI
import AppKit

struct LocalAuthProviderIconView: View {
  let provider: LocalAuthProvider
  var size: CGFloat = 12
  var cornerRadius: CGFloat = 2
  var saturation: Double = 1.0
  var opacity: Double = 1.0

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
          .saturation(saturation)
          .opacity(opacity)
      } else {
        Circle()
          .fill(accent(for: provider))
          .frame(width: dotSize, height: dotSize)
          .saturation(saturation)
          .opacity(opacity)
      }
    }
    .frame(width: size, height: size, alignment: .center)
    .id(colorScheme) // Force refresh when colorScheme changes
  }

  private var dotSize: CGFloat {
    max(6, size * 0.75)
  }

  /// Computed property that depends on colorScheme, ensuring real-time theme updates
  private var processedIcon: NSImage? {
    let name = iconName(for: provider)
    
    // Use unified resource processing with theme adaptation
    // This computed property depends on colorScheme, so SwiftUI will recompute it when theme changes
    let isDarkMode = colorScheme == .dark
    return ProviderIconResource.processedImage(
      named: name,
      size: NSSize(width: size, height: size),
      isDarkMode: isDarkMode
    )
  }

  private func iconName(for provider: LocalAuthProvider) -> String {
    switch provider {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    case .gemini: return "GeminiIcon"
    case .antigravity: return "AntigravityIcon"
    case .qwen: return "QwenIcon"
    }
  }

  private func accent(for provider: LocalAuthProvider) -> Color {
    switch provider {
    case .codex: return Color.accentColor
    case .claude: return Color(nsColor: .systemPurple)
    case .gemini: return Color(nsColor: .systemTeal)
    case .antigravity: return Color(nsColor: .systemIndigo)
    case .qwen: return Color(nsColor: .systemOrange)
    }
  }

}
