import SwiftUI
import AppKit

@available(macOS 15.0, *)
struct RemoteHostsSettingsPane: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @EnvironmentObject private var viewModel: SessionListViewModel
    @ObservedObject private var permissionsManager = SandboxPermissionsManager.shared

    @State private var availableRemoteHosts: [SSHHost] = []
    @State private var isRequestingSSHAccess = false
    @State private var selectedHostAlias: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote Hosts").font(.title2).fontWeight(.bold)
            Text("Choose which SSH hosts CodMate should mirror for remote Codex/Claude sessions.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Header controls aligned to the far right (match MCP Servers style)
            HStack {
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Button(role: .none) {
                        DispatchQueue.main.async { preferences.enabledRemoteHosts = [] }
                    } label: { Text("Clear All") }
                    .buttonStyle(.bordered)
                    .disabled(preferences.enabledRemoteHosts.isEmpty)

                    Button { Task { await viewModel.syncRemoteHosts(force: true, refreshAfter: true) } } label: {
                        Label("Sync Hosts", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(preferences.enabledRemoteHosts.isEmpty)

                    Button(action: reloadRemoteHosts) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!permissionsManager.hasPermission(for: .sshConfig))
                }
            }

            // Permission gate
            if !permissionsManager.hasPermission(for: .sshConfig) {
                permissionCard
            } else {
                hostsList
            }

            unavailableSection
            Text("CodMate mirrors only the hosts you enable. Hosts that prompt for passwords will open interactively when needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .onAppear {
            if permissionsManager.hasPermission(for: .sshConfig) && availableRemoteHosts.isEmpty {
                DispatchQueue.main.async { reloadRemoteHosts() }
            }
        }
        .onChange(of: permissionsManager.hasPermission(for: .sshConfig)) { _, granted in
            if granted { reloadRemoteHosts() } else { availableRemoteHosts = [] }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Grant Access to ~/.ssh", systemImage: "lock.square")
                .font(.headline)
            Text("CodMate needs permission to read ~/.ssh/config before it can list your SSH hosts. Grant access once and the app will remember it for future launches.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                guard !isRequestingSSHAccess else { return }
                isRequestingSSHAccess = true
                Task {
                    let granted = await permissionsManager.requestPermission(for: .sshConfig)
                    await MainActor.run {
                        isRequestingSSHAccess = false
                        if granted { reloadRemoteHosts() }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isRequestingSSHAccess { ProgressView().controlSize(.small) }
                    Text(isRequestingSSHAccess ? "Requesting…" : "Grant Access")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(nsColor: .separatorColor).opacity(0.2))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var hostsList: some View {
        let hosts = availableRemoteHosts
        if hosts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No SSH hosts were found in ~/.ssh/config.")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Add host aliases to your SSH config, then refresh to enable remote session mirroring.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Estimate a unified name column width based on the longest alias
            let maxAliasCount = hosts.map { $0.alias.count }.max() ?? 0
            let nameColumnWidth = max(120.0, min(320.0, Double(maxAliasCount) * 8.0))

            List(selection: $selectedHostAlias) {
                ForEach(hosts, id: \.alias) { host in
                    let (statusText, statusColor) = syncStatusDescription(for: host.alias)

                    HStack(alignment: .center, spacing: 0) {
                        Toggle("", isOn: bindingForRemoteHost(alias: host.alias))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .padding(.trailing, 8)

                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(host.alias).font(.body.weight(.medium))
                        }
                        .frame(width: nameColumnWidth, alignment: .leading)

                        Spacer(minLength: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            if let line = connectionLine(for: host), !line.isEmpty {
                                Label(line, systemImage: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 12) {
                                if let pj = host.proxyJump, !pj.isEmpty {
                                    Label("ProxyJump: \(pj)", systemImage: "arrow.triangle.branch")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if let idf = host.identityFile, !idf.isEmpty {
                                    Label(idf, systemImage: "key")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(statusColor)
                            .frame(minWidth: 120, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .tag(host.alias as String?)
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, -8)
        }
    }

    @ViewBuilder
    private var unavailableSection: some View {
        let hostAliases = Set(availableRemoteHosts.map { $0.alias })
        let dangling = preferences.enabledRemoteHosts.subtracting(hostAliases)
        if permissionsManager.hasPermission(for: .sshConfig) && !dangling.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unavailable Hosts")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("The following host aliases are enabled but not present in your current SSH config:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(Array(dangling).sorted(), id: \.self) { alias in
                    Text("• \(alias)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    private func reloadRemoteHosts() {
        let resolver = SSHConfigResolver()
        availableRemoteHosts = []
        let hosts = resolver.resolvedHosts().sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        availableRemoteHosts = hosts
        let hostAliases = Set(hosts.map { $0.alias })
        let filtered = preferences.enabledRemoteHosts.filter { hostAliases.contains($0) }
        if filtered.count != preferences.enabledRemoteHosts.count {
            DispatchQueue.main.async { preferences.enabledRemoteHosts = Set(filtered) }
        }

        // Default-select the first host when entering the page or when selection becomes invalid
        if let current = selectedHostAlias, hostAliases.contains(current) {
            return
        }
        selectedHostAlias = hosts.first?.alias
    }

    private func bindingForRemoteHost(alias: String) -> Binding<Bool> {
        Binding(
            get: { preferences.enabledRemoteHosts.contains(alias) },
            set: { newValue in
                var hosts = preferences.enabledRemoteHosts
                if newValue { hosts.insert(alias) } else { hosts.remove(alias) }
                preferences.enabledRemoteHosts = hosts
            }
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func syncStatusDescription(for alias: String) -> (String, Color) {
        guard let state = viewModel.remoteSyncStates[alias] else {
            return ("Not synced yet", .secondary)
        }
        switch state {
        case .idle:
            return ("Not synced yet", .secondary)
        case .syncing:
            return ("Syncing…", .secondary)
        case .succeeded(let date):
            let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
            return ("Last synced \(relative)", .secondary)
        case .failed(let date, let message):
            let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
            let detail = Self.syncFailureDetail(from: message)
            if detail.isEmpty { return ("Sync failed \(relative)", .red) }
            return ("Sync failed \(relative): \(detail)", .red)
        }
    }

    private static func syncFailureDetail(from rawMessage: String) -> String {
        let firstLine = rawMessage
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty else { return "" }

        let prefix = "sync failed"
        if firstLine.lowercased().hasPrefix(prefix) {
            var separators = CharacterSet.whitespacesAndNewlines
            separators.insert(charactersIn: ":-–—")
            let remainder = firstLine.dropFirst(prefix.count)
            let sanitized = String(remainder).trimmingCharacters(in: separators)
            return sanitized
        }
        return firstLine
    }

    private func connectionLine(for host: SSHHost) -> String? {
        var parts: [String] = []
        if let user = host.user, !user.isEmpty { parts.append(user + "@") }
        let hn = host.hostname ?? host.alias
        var conn = parts.joined() + hn
        if let port = host.port { conn += ":\(port)" }
        return conn
    }
}
