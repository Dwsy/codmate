import Foundation

struct ProjectMCPSelection: Identifiable, Hashable {
    var id: String { server.name }
    var server: MCPServer
    var isSelected: Bool
    var targets: MCPServerTargets
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ProjectMCPSelection, rhs: ProjectMCPSelection) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ProjectExtensionsViewModel: ObservableObject {
    private let extensionsStore = ProjectExtensionsStore()
    private let skillsStore = SkillsStore()
    private let mcpStore = MCPServersStore()
    private let applier = ProjectExtensionsApplier()
    private var skillRecords: [SkillRecord] = []
    private var projectId: String?
    private var projectDirectory: URL?

    @Published var skills: [SkillSummary] = []
    @Published var mcpSelections: [ProjectMCPSelection] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    func load(projectId: String?, projectDirectory: String) async {
        isLoading = true
        defer { isLoading = false }

        self.projectId = projectId
        let dir = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectDirectory = dir.isEmpty ? nil : URL(fileURLWithPath: dir, isDirectory: true)

        skillRecords = await skillsStore.list()
        let config: ProjectExtensionsConfig?
        if let projectId {
            config = await extensionsStore.load(projectId: projectId)
        } else {
            config = nil
        }

        let skillConfigMap = config?.skills.reduce(into: [String: ProjectSkillConfig]()) { $0[$1.id] = $1 } ?? [:]
        skills = skillRecords.map { record in
            let cfg = skillConfigMap[record.id]
            return SkillSummary(
                id: record.id,
                name: record.name,
                description: record.description,
                summary: record.summary,
                tags: record.tags,
                source: record.source,
                path: record.path,
                isSelected: cfg?.isSelected ?? false,
                targets: cfg?.targets ?? record.targets
            )
        }

        let servers = await mcpStore.list()
        let mcpConfigMap = config?.mcpServers.reduce(into: [String: ProjectMCPConfig]()) { $0[$1.id] = $1 } ?? [:]
        mcpSelections = servers.map { server in
            let targets = server.targets ?? MCPServerTargets(codex: true, claude: true, gemini: false)
            let cfg = mcpConfigMap[server.name]
            return ProjectMCPSelection(
                server: server,
                isSelected: cfg?.isSelected ?? false,
                targets: cfg?.targets ?? targets
            )
        }
    }

    func updateMCPSelection(id: String, isSelected: Bool) {
        guard let idx = mcpSelections.firstIndex(where: { $0.id == id }) else { return }
        mcpSelections[idx].isSelected = isSelected
        Task { await persistAndApplyIfPossible() }
    }

    func updateMCPTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = mcpSelections.firstIndex(where: { $0.id == id }) else { return }
        mcpSelections[idx].targets.setEnabled(value, for: target)
        Task { await persistAndApplyIfPossible() }
    }

    func updateSkillTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        var updated = skills[idx]
        updated.targets.setEnabled(value, for: target)
        skills[idx] = updated
        Task { await persistAndApplyIfPossible() }
    }

    func updateSkillSelection(id: String, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isSelected = value
        Task { await persistAndApplyIfPossible() }
    }

    func persistSelections(projectId: String, directory: String?) async {
        self.projectId = projectId
        if let dir = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
            self.projectDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        await persistAndApplyIfPossible()
    }

    private func persistAndApplyIfPossible() async {
        guard let projectId else { return }

        let config = ProjectExtensionsConfig(
            projectId: projectId,
            mcpServers: mcpSelections.map { entry in
                ProjectMCPConfig(id: entry.id, isSelected: entry.isSelected, targets: entry.targets)
            },
            skills: skills.map { skill in
                ProjectSkillConfig(id: skill.id, isSelected: skill.isSelected, targets: skill.targets)
            },
            updatedAt: Date()
        )
        await extensionsStore.save(config)

        guard let projectDirectory,
              FileManager.default.fileExists(atPath: projectDirectory.path)
        else { return }
        AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
            directory: projectDirectory,
            purpose: .generalAccess,
            message: "Authorize project directory to update Extensions"
        )
        let selections = skills.map { skill in
            SkillsSyncService.SkillSelection(id: skill.id, isSelected: skill.isSelected, targets: skill.targets)
        }
        await applier.apply(
            projectDirectory: projectDirectory,
            mcpSelections: mcpSelections,
            skillRecords: skillRecords,
            skillSelections: selections
        )
    }
}
