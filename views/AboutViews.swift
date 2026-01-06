import AppKit
import SwiftUI

struct OpenSourceLicensesView: View {
    let repoURL: URL
    @State private var content: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open Source Licenses")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Open on GitHub") { openOnGitHub() }
            }
            .padding(.bottom, 4)

            if content.isEmpty {
                ProgressView()
                    .task { await loadContent() }
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openOnGitHub() {
        // Point to the file in the default branch
        let url = URL(string: repoURL.absoluteString + "/blob/main/THIRD-PARTY-NOTICES.md")!
        NSWorkspace.shared.open(url)
    }

    private func candidateLocalURLs() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") {
            urls.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("THIRD-PARTY-NOTICES.md"))
        // When running from Xcode/DerivedData, try a few parents
        let execDir = Bundle.main.bundleURL
        urls.append(execDir.appendingPathComponent("Contents/Resources/THIRD-PARTY-NOTICES.md"))
        return urls
    }

    private func loadContent() async {
        for url in candidateLocalURLs() {
            if FileManager.default.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            {
                await MainActor.run { self.content = text }
                return
            }
        }
        // Fallback to remote raw file on GitHub if local not found
        if let remote = URL(
            string: "https://raw.githubusercontent.com/loocor/CodMate/main/THIRD-PARTY-NOTICES.md")
        {
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run { self.content = text }
                }
            } catch {
                await MainActor.run {
                    self.content =
                        "Unable to load licenses. Please see THIRD-PARTY-NOTICES.md in the repository."
                }
            }
        }
    }
}

struct UpdateSection: View {
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Version") {
                Text(versionString)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if AppDistribution.isAppStore {
                Text("Updates are managed by the App Store.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Group {
                    if case .upToDate(let current, _) = viewModel.state {
                        VStack(alignment: .leading, spacing: 8) {
                            if let lastCheckedAt = viewModel.lastCheckedAt {
                                Text(
                                    "Up to date (\(current)), Last checked \(Self.lastCheckedFormatter.string(from: lastCheckedAt))"
                                )
                                .font(.subheadline)
                            } else {
                                Text("Up to date (\(current)).")
                                    .font(.subheadline)
                            }
                            Button("Check Now") { viewModel.checkNow() }
                                .controlSize(.small)
                        }
                    } else {
                        content
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .alert("Install", isPresented: $viewModel.showInstallInstructions) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.installInstructions)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var buildTimestampString: String {
        guard let executableURL = Bundle.main.executableURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
            let date = attrs[.modificationDate] as? Date
        else { return "Unavailable" }
        return Self.buildDateFormatter.string(from: date)
    }

    private static let buildDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                Text("Check for updates.")
                    .font(.subheadline)
                Button("Check Now") { viewModel.checkNow() }
                    .controlSize(.small)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking...")
                    .font(.subheadline)
            }
        case .upToDate(let current, _):
            Text("Up to date (\(current)).")
                .font(.subheadline)
        case .updateAvailable(let info):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New version available: \(info.latestVersion)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(info.assetName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if viewModel.isDownloading {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Downloading...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Download & Install") { viewModel.downloadIfNeeded() }
                            .controlSize(.small)
                    }
                }
                if let lastError = viewModel.lastError {
                    Text("Download failed: \(lastError)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        case .error(let message):
            HStack {
                Text("Update check failed: \(message)")
                    .font(.subheadline)
                    .foregroundColor(.red)
                Spacer()
                Button("Retry") { viewModel.checkNow() }
                    .controlSize(.small)
            }
        }
    }

    private static let lastCheckedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

struct AboutSettingsView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @State private var showLicensesSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About CodMate")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(
                        "CodMate is a macOS SwiftUI app for managing CLI AI sessions: browse, search, organize, resume, and review work produced by Codex, Claude Code, and Gemini CLI."
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    UpdateSection(viewModel: updateViewModel)
                        .onAppear {
                            updateViewModel.loadCached()
                            updateViewModel.checkIfNeeded(trigger: .aboutAuto)
                        }

                    LabeledContent("Repository") {
                        Link(repoURL.absoluteString, destination: repoURL)
                    }
                    LabeledContent("Project URL") {
                        Link(projectURL.absoluteString, destination: projectURL)
                    }
                    LabeledContent("Open Source Licenses") {
                        Button("View…") { showLicensesSheet = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Discord Community
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Join our Discord community")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Get help, share feedback, and connect with other users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Join Discord", destination: discordURL)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.top, 2)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 24)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showLicensesSheet) {
            OpenSourceLicensesView(repoURL: repoURL)
                .frame(minWidth: 600, minHeight: 480)
        }
    }

    private var projectURL: URL { URL(string: "https://umate.ai/codmate")! }
    private var repoURL: URL { URL(string: "https://github.com/loocor/CodMate")! }
    private var discordURL: URL { URL(string: "https://discord.gg/5AcaTpVCcx")! }
}
