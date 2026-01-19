import SwiftUI

struct SessionPathGroup: View {
    @Binding var config: SessionPathConfig
    let diagnostics: SessionsDiagnostics.Probe?
    let canDelete: Bool
    var onDelete: (() -> Void)? = nil
    @State private var showingDiagnostics = false
    @State private var showingAddIgnore = false
    @State private var newIgnorePath = ""
    @State private var disabledSubpaths: Set<String> = []
    
    private var localAuthProvider: LocalAuthProvider? {
        LocalAuthProvider(rawValue: config.kind.rawValue)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Icon + Name + Switch (always visible)
            HStack(alignment: .center, spacing: 12) {
                // Brand icon
                if let provider = localAuthProvider {
                    LocalAuthProviderIconView(provider: provider, size: 16, cornerRadius: 3)
                }
                
                Text(config.displayName ?? config.kind.displayName)
                    .font(.headline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Toggle("", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                
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
            .padding(10)
            
            // Content: Only shown when enabled
            if config.enabled {
                VStack(alignment: .leading, spacing: 0) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        // Path (first item)
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Path")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            Text(config.path)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        
                        Divider()
                        
                        // Ignored Subpaths
                        GridRow {
                            Text("Ignored Subpaths")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            HStack(spacing: 6) {
                                Spacer()
                                
                                ForEach(config.ignoredSubpaths, id: \.self) { subpath in
                                    TagView(
                                        text: subpath,
                                        isEnabled: !disabledSubpaths.contains(subpath),
                                        isClosable: true,
                                        isRemovable: true,
                                        onClose: {
                                            removeIgnorePath(subpath)
                                        },
                                        onToggle: { isEnabled in
                                            if isEnabled {
                                                disabledSubpaths.remove(subpath)
                                            } else {
                                                disabledSubpaths.insert(subpath)
                                            }
                                        }
                                    )
                                }
                                
                                // Add new tag button
                                Button {
                                    showingAddIgnore = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 11))
                                        Text("New Tag")
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(.secondary)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        
                        Divider()
                        
                        // Diagnostics Summary (after Ignored Subpaths)
                        if let diagnostics = diagnostics {
                            GridRow {
                                DisclosureGroup(isExpanded: $showingDiagnostics) {
                                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                        GridRow {
                                            Text("Exists").font(.caption)
                                            Text(diagnostics.exists ? "Yes" : "No")
                                                .font(.caption)
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                        }
                                        if diagnostics.isDirectory {
                                            GridRow {
                                                Text("Files").font(.caption)
                                                Text("\(diagnostics.enumeratedCount)")
                                                    .font(.caption)
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
                                        if !diagnostics.sampleFiles.isEmpty {
                                            GridRow {
                                                Text("Sample Files")
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                VStack(alignment: .trailing, spacing: 4) {
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
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                                } label: {
                                    Text("Diagnostics")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                .gridCellColumns(2)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .cornerRadius(10)
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
}
