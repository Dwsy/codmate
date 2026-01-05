import SwiftUI

struct HooksSettingsView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .center, spacing: 8) {
        Spacer()
        Image(systemName: "hourglass")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text("Coming Soon")
          .font(.title2)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Text("Hooks configuration will be available in a future update.")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
