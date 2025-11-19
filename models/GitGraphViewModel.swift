import Foundation
import SwiftUI

@MainActor
final class GitGraphViewModel: ObservableObject {
    @Published private(set) var commits: [GitService.GraphCommit] = []
    @Published var filteredCommits: [GitService.GraphCommit] = []
    @Published var selectedCommit: GitService.GraphCommit? = nil
    @Published var searchQuery: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String? = nil
    // Graph lane layout
    struct LaneInfo: Sendable, Hashable {
        var laneIndex: Int                // index of the commit's own lane
        var parentLaneIndices: [Int]      // lane indices of parents in next row
        var activeLaneCount: Int          // lanes count to consider for verticals this row
        var continuingLanes: Set<Int>     // lanes that should show a vertical line in this row
        var joinLaneIndices: [Int]        // additional lanes carrying the same commit id (branch joins)
    }
    @Published private(set) var laneInfoById: [String: LaneInfo] = [:]
    @Published private(set) var maxLaneCount: Int = 1

    // Pre-computed row data for performance
    struct CommitRowData: Identifiable, Equatable {
        let id: String
        let commit: GitService.GraphCommit
        let index: Int
        let laneInfo: LaneInfo?
        let isFirst: Bool
        let isLast: Bool
        let isWorkingTree: Bool
        let isStriped: Bool

        static func == (lhs: CommitRowData, rhs: CommitRowData) -> Bool {
            lhs.id == rhs.id &&
            lhs.index == rhs.index &&
            lhs.laneInfo == rhs.laneInfo &&
            lhs.isFirst == rhs.isFirst &&
            lhs.isLast == rhs.isLast &&
            lhs.isStriped == rhs.isStriped
        }
    }
    @Published private(set) var rowData: [CommitRowData] = []

    private let service = GitService()
    private var repo: GitService.Repo? = nil
    private var refreshTask: Task<Void, Never>? = nil
    private var detailTask: Task<Void, Never>? = nil
    private var historyActionTask: Task<Void, Never>? = nil

    // Branch scope controls
    @Published var showAllBranches: Bool = true
    @Published var showRemoteBranches: Bool = true
    @Published var limit: Int = 300
    @Published var branches: [String] = []
    @Published var selectedBranch: String? = nil   // nil = current HEAD when showAllBranches == false
    @Published private(set) var workingChangesCount: Int = 0

    // Detail panel state (files + per-file patch)
    @Published private(set) var detailFiles: [GitService.FileChange] = []
    @Published var selectedDetailFile: String? = nil
    @Published private(set) var detailFilePatch: String = ""
    @Published private(set) var isLoadingDetail: Bool = false
    @Published private(set) var detailMessage: String = ""
    enum HistoryAction: String {
        case fetch, pull, push

        var displayName: String {
            switch self {
            case .fetch: return "Fetch"
            case .pull: return "Pull"
            case .push: return "Push"
            }
        }
    }
    @Published private(set) var historyActionInProgress: HistoryAction? = nil

    func attach(to root: URL?) {
        guard let root else { commits = []; filteredCommits = []; return }
        if SecurityScopedBookmarks.shared.isSandboxed {
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: root)
        }
        self.repo = GitService.Repo(root: root)
        loadBranches()
        loadCommits()
    }

    func loadCommits(limit: Int = 200) {
        guard let repo = self.repo else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            isLoading = true
            let list = await service.logGraphCommits(
                in: repo,
                limit: self.limit,
                includeAllBranches: self.showAllBranches,
                includeRemoteBranches: self.showRemoteBranches,
                singleRef: (self.showAllBranches ? nil : (self.selectedBranch?.isEmpty == false ? self.selectedBranch : nil))
            )
            // Working tree virtual entry
            let status = await service.status(in: repo)
            self.workingChangesCount = status.count
            var finalList = list
            if self.workingChangesCount > 0 {
                let headId = list.first?.id
                let virtual = GitService.GraphCommit(
                    id: "::working-tree::",
                    shortId: "*",
                    author: "*",
                    date: "0 seconds ago",
                    subject: "Uncommitted Changes (\(status.count))",
                    parents: headId != nil ? [headId!] : [],
                    decorations: []
                )
                finalList = [virtual] + list
            }
            isLoading = false
            self.commits = finalList
            applyFilter()
            if selectedCommit == nil { selectedCommit = list.first }
            computeLaneLayout()
        }
    }

    func applyFilter() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            filteredCommits = commits
            buildRowData()
            return
        }
        let basic = commits.filter { c in
            if c.subject.lowercased().contains(q) { return true }
            if c.author.lowercased().contains(q) { return true }
            if c.shortId.lowercased().contains(q) { return true }
            if c.decorations.joined(separator: ",").lowercased().contains(q) { return true }
            return false
        }
        // Also include commits whose messages match (subject/body) via git --grep
        guard let repo else {
            filteredCommits = basic
            buildRowData()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let ids = await self.service.searchCommitIds(in: repo, query: q, includeAllBranches: self.showAllBranches, includeRemoteBranches: self.showRemoteBranches, singleRef: (self.showAllBranches ? nil : (self.selectedBranch?.isEmpty == false ? self.selectedBranch : nil)))
            let extra = commits.filter { ids.contains($0.id) }
            await MainActor.run {
                self.filteredCommits = Array(Set(basic + extra))
                self.buildRowData()
            }
        }
    }

    private func buildRowData() {
        let count = filteredCommits.count
        rowData = filteredCommits.enumerated().map { idx, commit in
            CommitRowData(
                id: commit.id,
                commit: commit,
                index: idx,
                laneInfo: laneInfoById[commit.id],
                isFirst: idx == 0,
                isLast: idx == count - 1,
                isWorkingTree: commit.id == "::working-tree::",
                isStriped: idx % 2 == 1
            )
        }
    }

    func selectCommit(_ c: GitService.GraphCommit) {
        selectedCommit = c
        loadDetail(for: c)
    }

    /// Load detail panel data (files list + first file patch) for the given commit.
    func loadDetail(for commit: GitService.GraphCommit) {
        // The synthetic working-tree node does not correspond to a real commit id.
        // For now, skip detail loading and leave the panel empty.
        if commit.id == "::working-tree::" {
            detailFiles = []
            selectedDetailFile = nil
            detailFilePatch = ""
            isLoadingDetail = false
            return
        }
        guard let repo = self.repo else {
            detailFiles = []
            selectedDetailFile = nil
            detailFilePatch = ""
            detailMessage = ""
            return
        }
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.isLoadingDetail = true
                self.detailFiles = []
                self.detailFilePatch = ""
                self.detailMessage = ""
            }
            async let filesTask = service.filesChanged(in: repo, commitId: commit.id)
            async let messageTask = service.commitMessage(in: repo, commitId: commit.id)
            let (files, message) = await (filesTask, messageTask)
            if Task.isCancelled { return }
            await MainActor.run {
                self.detailFiles = files
                self.selectedDetailFile = files.first?.path
                self.detailMessage = message
            }
            if let first = files.first {
                await loadDetailPatch(for: first.path, in: repo, commitId: commit.id)
            } else {
                await MainActor.run {
                    self.detailFilePatch = ""
                    self.isLoadingDetail = false
                }
            }
        }
    }

    func loadDetailPatch(for path: String) {
        guard let repo = self.repo, let commit = selectedCommit else { return }
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            await self?.loadDetailPatch(for: path, in: repo, commitId: commit.id)
        }
    }

    private func loadDetailPatch(for path: String, in repo: GitService.Repo, commitId: String) async {
        await MainActor.run {
            self.isLoadingDetail = true
            self.detailFilePatch = ""
        }
        // Show diff of this file in the given commit against its first parent.
        let text = await service.filePatch(in: repo, commitId: commitId, path: path)
        if Task.isCancelled { return }
        await MainActor.run {
            self.detailFilePatch = text
            self.isLoadingDetail = false
        }
    }

    // MARK: - Lanes
    private func computeLaneLayout() {
        guard !commits.isEmpty else {
            laneInfoById = [:]
            maxLaneCount = 1
            return
        }
        // lanes array holds the commit SHA expected to appear in that lane in the NEXT row
        var lanes: [String?] = []
        var byId: [String: LaneInfo] = [:]
        var maxLanes = 1

        for commit in commits {
            let before = lanes // snapshot for continuing determination

            // Determine current lane for this commit
            let laneIndex: Int
            if let idx = lanes.firstIndex(where: { $0 == commit.id }) {
                laneIndex = idx
            } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                laneIndex = empty
                if empty >= lanes.count { lanes.append(nil) }
            } else {
                laneIndex = lanes.count
                lanes.append(nil)
            }

            // Assign parents to lanes for the next row
            var parentLaneIndices: [Int] = []
            if let firstParent = commit.parents.first {
                // First parent continues the current lane
                if laneIndex < lanes.count { lanes[laneIndex] = firstParent } else {
                    // shouldn't happen, but be safe
                    lanes.append(firstParent)
                }
                parentLaneIndices.append(laneIndex)
                // Additional parents take other lanes (existing if present, else empty slot, else append)
                if commit.parents.count > 1 {
                    for p in commit.parents.dropFirst() {
                        if let existing = lanes.firstIndex(where: { $0 == p }) {
                            parentLaneIndices.append(existing)
                        } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                            lanes[empty] = p
                            parentLaneIndices.append(empty)
                        } else {
                            lanes.append(p)
                            parentLaneIndices.append(lanes.count - 1)
                        }
                    }
                }
            } else {
                // No parents; lane ends here
                if laneIndex < lanes.count { lanes[laneIndex] = nil }
            }

            // When the same commit id appears in multiple lanes in the pre-state,
            // treat the extra occurrences as branch joins into this commit.
            let joinLanes: [Int] = before.enumerated().compactMap { index, value in
                (value == commit.id && index != laneIndex) ? index : nil
            }
            // After this commit row, those join lanes should terminate instead of
            // continuing further into older history.
            if !joinLanes.isEmpty {
                for j in joinLanes where j < lanes.count {
                    lanes[j] = nil
                }
            }

            // Trim trailing nils to keep lane array compact
            while let last = lanes.last, last == nil { _ = lanes.popLast() }

            let after = lanes
            let activeCount = max(before.count, after.count)
            var continuing: Set<Int> = []
            if activeCount > 0 {
                for i in 0..<activeCount {
                    let hasBefore = i < before.count ? (before[i] != nil || i == laneIndex) : false
                    let hasAfter = i < after.count ? (after[i] != nil) : false
                    if hasBefore || hasAfter { continuing.insert(i) }
                }
            }

            byId[commit.id] = LaneInfo(
                laneIndex: laneIndex,
                parentLaneIndices: parentLaneIndices,
                activeLaneCount: activeCount,
                continuingLanes: continuing,
                joinLaneIndices: joinLanes
            )
            if let localMax = (parentLaneIndices + joinLanes + [laneIndex]).max() {
                maxLanes = max(maxLanes, localMax + 1)
            } else {
                maxLanes = max(maxLanes, laneIndex + 1)
            }
        }
        laneInfoById = byId
        maxLaneCount = max(1, maxLanes)
        buildRowData()
    }

    func loadBranches() {
        guard let repo else { branches = []; return }
        Task { [weak self] in
            guard let self else { return }
            let names = await service.listBranches(in: repo, includeRemoteBranches: showRemoteBranches)
            await MainActor.run { self.branches = names }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func triggerRefresh() {
        loadCommits()
    }

    func fetchRemotes() {
        performHistoryAction(.fetch)
    }

    func pullLatest() {
        performHistoryAction(.pull)
    }

    func pushCurrent() {
        performHistoryAction(.push)
    }

    private func performHistoryAction(_ action: HistoryAction) {
        guard historyActionInProgress == nil else { return }
        guard let repo = self.repo else { return }
        historyActionTask?.cancel()
        historyActionTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.historyActionInProgress = action }
            let code: Int32
            switch action {
            case .fetch:
                code = await service.fetchAllRemotes(in: repo)
            case .pull:
                code = await service.pullCurrentBranch(in: repo)
            case .push:
                code = await service.pushCurrentBranch(in: repo)
            }
            if Task.isCancelled {
                await MainActor.run {
                    self.historyActionInProgress = nil
                    self.historyActionTask = nil
                }
                return
            }
            let failureDetail = (code == 0) ? nil : await self.service.takeLastFailureDescription()
            await MainActor.run {
                self.historyActionInProgress = nil
                self.historyActionTask = nil
                if code == 0 {
                    self.errorMessage = nil
                    self.loadCommits()
                } else {
                    if let detail = failureDetail, !detail.isEmpty {
                        self.errorMessage = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self.errorMessage = "\(action.displayName) failed (exit code \(code))"
                    }
                }
            }
        }
    }
}
