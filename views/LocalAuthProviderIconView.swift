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
      if let image = nsImage(for: provider) {
        let scale = iconScale(for: provider)
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: size, height: size)
          .scaleEffect(scale)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
          .modifier(DarkModeInvertModifier(active: provider == .codex && colorScheme == .dark))
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
  }

  private var dotSize: CGFloat {
    max(6, size * 0.75)
  }

  private func nsImage(for provider: LocalAuthProvider) -> NSImage? {
    let name: String
    switch provider {
    case .codex: name = "ChatGPTIcon"
    case .claude: name = "ClaudeIcon"
    case .gemini: name = "GeminiIcon"
    case .antigravity: name = "AntigravityIcon"
    case .qwen: name = "QwenIcon"
    }
    return NSImage(named: name)
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

  private func iconScale(for provider: LocalAuthProvider) -> CGFloat {
    switch provider {
    case .antigravity, .qwen:
      return 0.82
    case .codex, .claude, .gemini:
      return 1.0
    }
  }
}
