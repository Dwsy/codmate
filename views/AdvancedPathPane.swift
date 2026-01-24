import SwiftUI
import AppKit

struct AdvancedPathPane: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @EnvironmentObject private var listViewModel: SessionListViewModel
    @StateObject private var cliVM = CLIPathVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Directories").font(.headline).fontWeight(.semibold)
                settingsCard {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Projects Directory", systemImage: "folder")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Directory where CodMate stores projects data")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(preferences.projectsRoot.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Change…", action: selectProjectsRoot)
                                .buttonStyle(.bordered)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Notes Directory", systemImage: "text.book.closed")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Where session titles and comments are saved")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(preferences.notesRoot.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Change…", action: selectNotesRoot)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CLI Command Paths").font(.headline).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Button {
                        cliVM.refresh()
                    } label: {
                        Label("Refresh Auto-Detect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                settingsCard {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        commandRow(
                            title: "Codex Command",
                            description: "Optional override for codex CLI",
                            override: $preferences.codexCommandPath,
                            autoInfo: cliVM.codex,
                            isDisabled: !preferences.isCLIEnabled(.codex),
                            onChoose: { selectCommandPath(kind: .codex) }
                        )
                        gridDivider
                        commandRow(
                            title: "Claude Command",
                            description: "Optional override for claude CLI",
                            override: $preferences.claudeCommandPath,
                            autoInfo: cliVM.claude,
                            isDisabled: !preferences.isCLIEnabled(.claude),
                            onChoose: { selectCommandPath(kind: .claude) }
                        )
                        gridDivider
                        commandRow(
                            title: "Gemini Command",
                            description: "Optional override for gemini CLI",
                            override: $preferences.geminiCommandPath,
                            autoInfo: cliVM.gemini,
                            isDisabled: !preferences.isCLIEnabled(.gemini),
                            onChoose: { selectCommandPath(kind: .gemini) }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("CLI & PATH").font(.headline).fontWeight(.semibold)
                settingsCard {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("codex").font(.subheadline)
                            Text(statusLabel(for: cliVM.codex))
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("claude").font(.subheadline)
                            Text(statusLabel(for: cliVM.claude))
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("gemini").font(.subheadline)
                            Text(statusLabel(for: cliVM.gemini))
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("PATH").font(.subheadline)
                            Text(cliVM.pathEnv)
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .task {
            await Task.yield()
            cliVM.refresh()
        }
    }

    // MARK: - Helpers
    @ViewBuilder
    private func commandRow(
        title: String,
        description: String,
        override: Binding<String>,
        autoInfo: CLIPathVM.CLIInfo,
        isDisabled: Bool,
        onChoose: @escaping () -> Void
    ) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(placeholderText(for: autoInfo), text: override)
                    .textFieldStyle(.roundedBorder)
                if let warning = overrideWarning(for: override.wrappedValue, autoInfo: autoInfo) {
                    Text(warning)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            HStack(spacing: 8) {
                Button(autoInfo.path == nil ? "Choose…" : "Change…", action: onChoose)
                    .buttonStyle(.bordered)
                Button(clearLabel(for: override.wrappedValue, autoInfo: autoInfo)) {
                    override.wrappedValue = ""
                }
                .buttonStyle(.bordered)
                .disabled(override.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(isDisabled)
    }

    private func placeholderText(for info: CLIPathVM.CLIInfo) -> String {
        if let path = info.path {
            if let version = info.version, !version.isEmpty {
                return "\(path) (\(version))"
            }
            return path
        }
        return "Optional override (absolute path)"
    }

    private func clearLabel(for value: String, autoInfo: CLIPathVM.CLIInfo) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, autoInfo.path != nil {
            return "Reset"
        }
        return "Clear"
    }

    private func statusLabel(for info: CLIPathVM.CLIInfo) -> String {
        if let version = info.version, !version.isEmpty {
            return version
        }
        return info.path == nil ? "N/A" : "Yes"
    }

    private func overrideWarning(for value: String, autoInfo: CLIPathVM.CLIInfo) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = expandHomePath(trimmed)
        if !FileManager.default.isExecutableFile(atPath: expanded) {
            if autoInfo.path == nil {
                return "Override not executable; auto-detect also failed."
            }
            return "Override not executable; auto-detect will be used."
        }
        return nil
    }

    private func expandHomePath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.contains("$HOME") {
            return path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        }
        return path
    }

    private func selectProjectsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.projectsRoot
        panel.message = "Select the directory where CodMate stores projects data"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await listViewModel.updateProjectsRoot(to: url) }
        }
    }

    private func selectNotesRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.notesRoot
        panel.message = "Select the directory where session notes are stored"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await listViewModel.updateNotesRoot(to: url) }
        }
    }

    private func selectCommandPath(kind: SessionSource.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the \(kind.cliExecutableName) executable"
        panel.prompt = "Select"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            switch kind {
            case .codex:
                preferences.codexCommandPath = url.path
            case .claude:
                preferences.claudeCommandPath = url.path
            case .gemini:
                preferences.geminiCommandPath = url.path
            }
        }
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

    @ViewBuilder
    private var gridDivider: some View {
        Divider()
    }
}
