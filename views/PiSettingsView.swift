import SwiftUI

struct PiSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore
  @EnvironmentObject private var viewModel: SessionListViewModel
  @State private var piInfo: PiUsageStatus?

  var body: some View {
    SettingsTabContent {
      VStack(alignment: .leading, spacing: 24) {
        // CLI Enable/Disable
        GroupBox(label: Text("Pi CLI")) {
          Toggle("Enable Pi CLI", isOn: Binding(
            get: { preferences.isCLIEnabled(.pi) },
            set: { newValue in
              _ = preferences.setCLIEnabled(.pi, enabled: newValue)
            }
          ))
          .toggleStyle(.switch)
        }
        
        .padding(.horizontal, 16)

        // Session Path Configuration
        GroupBox(label: Text("Session Path")) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(preferences.sessionPathConfigs.filter { $0.kind == .pi }, id: \.id) { config in
              HStack {
                Text(config.path)
                  .font(.system(.body, design: .monospaced))
                  .foregroundColor(.secondary)
                Spacer()
                if config.isDefault {
                  Text("Default")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
                }
              }
            }
          }
        }
        
        .padding(.horizontal, 16)

        // Command Path
        GroupBox(label: Text("Command Path")) {
          HStack {
            Text(preferences.piCommandPath)
              .font(.system(.body, design: .monospaced))
              .foregroundColor(.secondary)
            Spacer()
            Button("Change...") {
              // TODO: Implement command path selection
            }
            .buttonStyle(.bordered)
          }
        }
        
        .padding(.horizontal, 16)

        // Pi Info
        GroupBox(label: Text("Pi Information")) {
          VStack(alignment: .leading, spacing: 12) {
            if let info = piInfo {
              InfoRow(label: "Version", value: info.version ?? "Unknown")
              InfoRow(label: "Default Provider", value: info.defaultProvider ?? "Auto")
              InfoRow(label: "Default Model", value: info.defaultModel ?? "Auto")
              InfoRow(label: "Last Updated", value: formatDate(info.updatedAt))
            } else {
              Text("Loading...")
                .foregroundColor(.secondary)
            }
          }
        }
        
        .padding(.horizontal, 16)

        Spacer()
      }
      .task {
        await loadPiInfo()
      }
    }
  }

  private func loadPiInfo() async {
    let service = PiSettingsService()
    let info = await service.fetchAllInfo()
    piInfo = PiUsageStatus(
      updatedAt: Date(),
      version: info.version,
      defaultProvider: info.defaultProvider,
      defaultModel: info.defaultModel
    )
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .foregroundColor(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.medium)
    }
  }
}

#Preview {
  PiSettingsView(preferences: SessionPreferencesStore())
}