import SwiftUI

struct SessionPathRow: View {
    @Binding var config: SessionPathConfig
    @ObservedObject var preferences: SessionPreferencesStore
    let diagnostics: SessionsDiagnostics.Probe?
    let canDelete: Bool
    var onDelete: (() -> Void)? = nil
    @State private var showingDiagnostics = false
    @State private var showingAddIgnore = false
    @State private var newIgnorePath = ""
    
    var body: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                // Header: Toggle + Name + Delete
                HStack {
                    Toggle("", isOn: $config.enabled)
                        .labelsHidden()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.displayName ?? config.kind.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(config.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospaced()
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    
                    Spacer()
                    
                    if canDelete, let onDelete = onDelete {
                        Button {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
                // Diagnostics Summary
                if let diagnostics = diagnostics {
                    DisclosureGroup(isExpanded: $showingDiagnostics) {
                        VStack(alignment: .leading, spacing: 8) {
                            if diagnostics.exists {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                    GridRow {
                                        Text("Exists").font(.caption)
                                        Text(diagnostics.exists ? "Yes" : "No")
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                    if diagnostics.isDirectory {
                                        GridRow {
                                            Text("Files").font(.caption)
                                            Text("\(diagnostics.enumeratedCount)")
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                        }
                                    }
                                    if let error = diagnostics.enumeratorError {
                                        GridRow {
                                            Text("Error").font(.caption)
                                            Text(error)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                        }
                                    }
                                }
                                
                                if !diagnostics.sampleFiles.isEmpty {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Sample Files")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        ForEach(diagnostics.sampleFiles.prefix(5), id: \.self) { file in
                                            Text(file)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospaced()
                                                .lineLimit(1)
                                        }
                                        if diagnostics.sampleFiles.count > 5 {
                                            Text("(\(diagnostics.sampleFiles.count - 5) more...)")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            } else {
                                Text("Directory does not exist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Text("Diagnostics")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            if diagnostics.exists {
                                Text("\(diagnostics.enumeratedCount) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                // Ignored Subpaths
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Ignored Subpaths")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            showingAddIgnore = true
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    
                    if config.ignoredSubpaths.isEmpty {
                        Text("No ignored paths")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(config.ignoredSubpaths, id: \.self) { subpath in
                            HStack {
                                Text(subpath)
                                    .font(.caption2)
                                    .monospaced()
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    removeIgnorePath(subpath)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .alert("Add Ignored Path", isPresented: $showingAddIgnore) {
            TextField("Path substring", text: $newIgnorePath)
            Button("Cancel", role: .cancel) {
                newIgnorePath = ""
            }
            Button("Add") {
                addIgnorePath()
            }
            .disabled(newIgnorePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a path substring to ignore. Files containing this substring will be skipped during scanning.")
        }
    }
    
    private func addIgnorePath() {
        let trimmed = newIgnorePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = config
        if !updated.ignoredSubpaths.contains(trimmed) {
            updated.ignoredSubpaths.append(trimmed)
            config = updated
        }
        newIgnorePath = ""
    }
    
    private func removeIgnorePath(_ subpath: String) {
        var updated = config
        updated.ignoredSubpaths.removeAll { $0 == subpath }
        config = updated
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
}
