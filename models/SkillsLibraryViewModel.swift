import Foundation
import UniformTypeIdentifiers

struct SkillSummary: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String
    var summary: String
    var tags: [String]
    var source: String
    var path: String?
    var isSelected: Bool
    var targets: MCPServerTargets

    var displayName: String { name.isEmpty ? id : name }
}

@MainActor
final class SkillsLibraryViewModel: ObservableObject {
    private let store = SkillsStore()
    private let syncer = SkillsSyncService()

    @Published var skills: [SkillSummary] = []
    @Published var selectedSkillId: String?
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var installStatusMessage: String?

    @Published var showInstallSheet: Bool = false
    @Published var installMode: SkillInstallMode = .folder
    @Published var pendingInstallURL: URL?
    @Published var pendingInstallText: String = ""
    @Published var installConflict: SkillInstallConflict?

    var filteredSkills: [SkillSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skills }
        return skills.filter { skill in
            let hay = [skill.displayName, skill.summary, skill.tags.joined(separator: " "), skill.source]
                .joined(separator: " ")
                .lowercased()
            return hay.contains(trimmed.lowercased())
        }
    }

    var selectedSkill: SkillSummary? {
        guard let id = selectedSkillId else { return nil }
        return skills.first(where: { $0.id == id })
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let records = await store.list()
        skills = records.map { record in
            SkillSummary(
                id: record.id,
                name: record.name,
                description: record.description,
                summary: record.summary,
                tags: record.tags,
                source: record.source,
                path: record.path,
                isSelected: record.isEnabled,
                targets: record.targets
            )
        }
        if selectedSkillId == nil || !skills.contains(where: { $0.id == selectedSkillId }) {
            selectedSkillId = skills.first?.id
        }
    }

    func prepareInstall(mode: SkillInstallMode, url: URL? = nil, text: String? = nil) {
        installMode = mode
        pendingInstallURL = url
        pendingInstallText = text ?? ""
        installStatusMessage = nil
        installConflict = nil
        showInstallSheet = true
    }

    func cancelInstall() {
        showInstallSheet = false
        pendingInstallURL = nil
        pendingInstallText = ""
        installStatusMessage = nil
    }

    func testInstall() {
        installStatusMessage = "Validating…"
        Task {
            let request = installRequest()
            let ok = await store.validate(request: request)
            await MainActor.run {
                installStatusMessage = ok ? "Looks good. Ready to install." : "Unable to validate this source."
            }
        }
    }

    func finishInstall() {
        installStatusMessage = "Installing…"
        Task {
            let request = installRequest()
            let outcome = await store.install(request: request, resolution: nil)
            await MainActor.run {
                handleInstallOutcome(outcome)
            }
        }
    }

    func updateSkillTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        var updated = skills[idx]
        updated.targets.setEnabled(value, for: target)
        skills[idx] = updated
        Task { await persistAndSync() }
    }

    func updateSkillSelection(id: String, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isSelected = value
        Task { await persistAndSync() }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    let isZip = url.pathExtension.lowercased() == "zip"
                    self.prepareInstall(mode: isZip ? .zip : .folder, url: url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        self.prepareInstall(mode: .url, text: url.absoluteString)
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String?
                if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = item as? String
                }
                guard let text, !text.isEmpty else { return }
                Task { @MainActor in
                    self.prepareInstall(mode: .url, text: text)
                }
            }
            return true
        }
        return false
    }

    func resolveInstallConflict(_ resolution: SkillConflictResolution) {
        installStatusMessage = "Installing…"
        Task {
            let request = installRequest()
            let outcome = await store.install(request: request, resolution: resolution)
            await MainActor.run {
                handleInstallOutcome(outcome)
            }
        }
    }

    func reinstall(id: String) {
        Task {
            guard let record = await store.record(id: id) else { return }
            if let request = reinstallRequest(from: record) {
                let outcome = await store.install(request: request, resolution: .overwrite)
                await MainActor.run {
                    handleInstallOutcome(outcome)
                }
            } else if let _ = await store.refreshMetadata(id: id) {
                await MainActor.run { installStatusMessage = "Updated." }
                await load()
                await persistAndSync()
            } else {
                await MainActor.run { errorMessage = "Unable to reinstall skill." }
            }
        }
    }

    func uninstall(id: String) {
        Task {
            await store.uninstall(id: id)
            await load()
            await persistAndSync()
        }
    }

    private func installRequest() -> SkillInstallRequest {
        SkillInstallRequest(mode: installMode, url: pendingInstallURL, text: pendingInstallText)
    }

    private func reinstallRequest(from record: SkillRecord) -> SkillInstallRequest? {
        if let url = URL(string: record.source),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return SkillInstallRequest(mode: .url, url: nil, text: record.source)
        }
        let sourcePath = record.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourcePath.isEmpty {
            let srcURL = URL(fileURLWithPath: sourcePath)
            if FileManager.default.fileExists(atPath: srcURL.path) {
                if srcURL.pathExtension.lowercased() == "zip" {
                    return SkillInstallRequest(mode: .zip, url: srcURL, text: nil)
                }
                let isDir = (try? srcURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    return SkillInstallRequest(mode: .folder, url: srcURL, text: nil)
                }
            }
        }
        return nil
    }

    private func handleInstallOutcome(_ outcome: SkillInstallOutcome) {
        switch outcome {
        case .installed:
            installStatusMessage = "Installed."
            showInstallSheet = false
            pendingInstallURL = nil
            pendingInstallText = ""
            Task { await reloadAfterInstall() }
        case .conflict(let conflict):
            installStatusMessage = "Skill already exists."
            installConflict = conflict
        case .skipped:
            installStatusMessage = "Install skipped."
        }
    }

    private func reloadAfterInstall() async {
        await load()
        await persistAndSync()
    }

    private func persistAndSync() async {
        var records = await store.list()
        for idx in records.indices {
            if let summary = skills.first(where: { $0.id == records[idx].id }) {
                records[idx].name = summary.name
                records[idx].description = summary.description
                records[idx].summary = summary.summary
                records[idx].tags = summary.tags
                records[idx].source = summary.source
                if let path = summary.path { records[idx].path = path }
                records[idx].isEnabled = summary.isSelected
                records[idx].targets = summary.targets
            }
        }
        await store.saveAll(records)
        let home = SessionPreferencesStore.getRealUserHomeURL()
        AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
            directory: home.appendingPathComponent(".codex", isDirectory: true),
            purpose: .generalAccess,
            message: "Authorize ~/.codex to sync Codex skills"
        )
        AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
            directory: home.appendingPathComponent(".claude", isDirectory: true),
            purpose: .generalAccess,
            message: "Authorize ~/.claude to sync Claude skills"
        )
        let warnings = await syncer.syncGlobal(skills: records)
        if let warning = warnings.first {
            errorMessage = warning.message
        } else {
            errorMessage = nil
        }
    }
}
