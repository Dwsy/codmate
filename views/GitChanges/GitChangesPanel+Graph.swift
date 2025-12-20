import SwiftUI

extension GitChangesPanel {
  // MARK: - Graph detail view
  var graphDetailView: some View {
    graphListView(compactColumns: false) { commit in
      // Enter History Detail mode when a commit is activated.
      historyDetailCommit = commit
    }
  }

  /// Shared helper to host the graph list with repo attachment and activation callback.
  func graphListView(
    compactColumns: Bool,
    onActivateCommit: @escaping (GitService.GraphCommit?) -> Void
  ) -> some View {
    GraphContainer(
      vm: graphVM,
      wrapText: wrapText,
      showLineNumbers: showLineNumbers,
      compactColumns: compactColumns,
      onActivateCommit: onActivateCommit
    )
    .onAppear {
      graphVM.attach(to: vm.repoRoot)
    }
    .onChange(of: vm.repoRoot) { newVal in
      graphVM.attach(to: newVal)
    }
  }

  // Host for the graph UI
  struct GraphContainer: View {
    @ObservedObject var vm: GitGraphViewModel
    let wrapText: Bool
    let showLineNumbers: Bool
    let compactColumns: Bool
    let onActivateCommit: (GitService.GraphCommit?) -> Void
    @State private var selection: GitGraphViewModel.CommitRowData.ID? = nil
    @State private var suppressNextActivation: Bool = false

    init(
      vm: GitGraphViewModel,
      wrapText: Bool,
      showLineNumbers: Bool,
      compactColumns: Bool,
      onActivateCommit: @escaping (GitService.GraphCommit?) -> Void
    ) {
      self.vm = vm
      self.wrapText = wrapText
      self.showLineNumbers = showLineNumbers
      self.compactColumns = compactColumns
      self.onActivateCommit = onActivateCommit
    }

    var body: some View {
      VStack(spacing: 0) {
        // Controls + branch scope
        HStack(spacing: 12) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
              branchSelector
              remoteBranchesToggle
            }
            HStack(spacing: 10) {
              branchSelector
            }
          }
          Spacer()
          actionButtons
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .onChange(of: vm.showAllBranches) { _ in vm.loadCommits() }
        .onChange(of: vm.branchSearchQuery) { _ in vm.applyBranchFilter() }

        if let error = vm.errorMessage, !error.isEmpty {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(error)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            Spacer()
            Button("Dismiss") { vm.clearError() }
              .buttonStyle(.link)
              .font(.caption)
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 4)
        }

        tableView
        .environment(\.defaultMinListRowHeight, rowHeight)
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .removeTableSpacing(rowHeight: rowHeight)
        .padding(.horizontal, 0)
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
          if vm.isLoadingMore {
            ProgressView()
              .controlSize(.small)
              .padding(8)
              .background(.regularMaterial, in: Capsule())
              .padding(.bottom, 16)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        syncSelectionFromViewModel()
      }
      .onChange(of: vm.rowData) { _ in
        syncSelectionFromViewModel()
      }
      .onChange(of: selection) { newValue in
        if suppressNextActivation {
          // Skip the activation corresponding to a programmatic
          // selection restore (e.g. when the view is recreated
          // after closing the history detail pane).
          suppressNextActivation = false
          return
        }
        guard let id = newValue,
          let row = vm.rowData.first(where: { $0.id == id })
        else { return }
        vm.selectCommit(row.commit)
        if row.isWorkingTree {
          onActivateCommit(nil)
        } else {
          onActivateCommit(row.commit)
        }
      }
    }

    @ViewBuilder
    private var tableView: some View {
      if compactColumns {
        Table(vm.rowData, selection: $selection) {
          // Graph column
          TableColumn("") { row in
            graphColumnContent(for: row)
          }
          .width(min: graphColumnWidth, ideal: graphColumnWidth, max: graphColumnWidth)

          // Description
          TableColumn("Description") { row in
            descriptionColumnContent(for: row)
          }
        }
      } else {
        Table(vm.rowData, selection: $selection) {
          // Graph column
          TableColumn("") { row in
            graphColumnContent(for: row)
          }
          .width(min: graphColumnWidth, ideal: graphColumnWidth, max: graphColumnWidth)

          // Description
          TableColumn("Description") { row in
            descriptionColumnContent(for: row)
          }

          TableColumn("Date") { row in
            Text(row.commit.date)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .width(dateWidth)

          TableColumn("Author") { row in
            Text(row.commit.author)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .width(authorWidth)

          TableColumn("SHA") { row in
            Text(row.commit.shortId)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .width(shaWidth)
        }
      }
    }

    @ViewBuilder
    private func graphColumnContent(for row: GitGraphViewModel.CommitRowData) -> some View {
      let isSelected = (selection == row.id)
      if let info = row.laneInfo {
        GraphLaneView(
          info: info,
          maxLanes: vm.maxLaneCount,
          laneSpacing: laneSpacing,
          verticalWidth: 2,
          hideTopForCurrentLane: row.isFirst,
          hideBottomForCurrentLane: row.isLast,
          headIsHollow: row.isWorkingTree,
          headSize: 12,
          isSelected: isSelected
        )
        .frame(width: graphColumnWidth, height: rowHeight)
      } else {
        GraphGlyph(isSelected: isSelected)
          .frame(width: graphColumnWidth, height: rowHeight)
      }
    }

    private func descriptionColumnContent(for row: GitGraphViewModel.CommitRowData) -> some View {
      HStack(spacing: 6) {
        Text(row.commit.subject)
          .fontWeight(row.isWorkingTree ? .semibold : .regular)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if !row.commit.decorations.isEmpty {
          ForEach(row.commit.decorations.prefix(3), id: \.self) { d in
            Text(d)
              .font(.system(size: 10, weight: .medium))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.secondary.opacity(0.15)))
          }
        }
      }
      .onAppear {
        if row.isLast {
          vm.loadMore()
        }
      }
    }

    /// Ensure that the SwiftUI `Table` selection tracks the
    /// view model's selected commit across layout mode switches
    /// (e.g. when entering History Detail full-width mode).
    private func syncSelectionFromViewModel() {
      guard let current = vm.selectedCommit else { return }
      // If we don't have a selection yet, or it already matches the
      // view model, restore it from the current rowData.
      if selection == nil || selection == current.id {
        if let row = vm.rowData.first(where: { $0.commit.id == current.id }) {
          suppressNextActivation = true
          selection = row.id
        }
      }
    }
    private var graphColumnWidth: CGFloat {
      // Graph column width scales with lanes; lane spacing controls horizontal density.
      // Lane layout is computed before the first rows are built (we suppress the
      // initial rowData build once in the view model), so maxLaneCount should
      // reflect the actual width needed for the graph.
      let lanes = max(vm.maxLaneCount, 1)
      return max(rowHeight + 4, CGFloat(lanes) * laneSpacing)
    }
    private var rowHeight: CGFloat { 28 }
    private var laneSpacing: CGFloat { rowHeight }
    private var dateWidth: CGFloat { 110 }
    private var authorWidth: CGFloat { 120 }
    private var shaWidth: CGFloat { 80 }

    @ViewBuilder
    private var branchSelector: some View {
      VStack(spacing: 4) {
        HStack(spacing: 6) {
          Text("Branches:")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Picker(
            "",
            selection: Binding<String>(
              get: { vm.showAllBranches ? "__all__" : (vm.selectedBranch ?? "__current__") },
              set: { newVal in
                if newVal == "__all__" {
                  vm.showAllBranches = true
                  vm.selectedBranch = nil
                } else if newVal == "__current__" {
                  vm.showAllBranches = false
                  vm.selectedBranch = nil
                } else {
                  vm.showAllBranches = false
                  vm.selectedBranch = newVal
                }
                vm.loadCommits()
              })
          ) {
            Text("Show All").tag("__all__")
            Text("Current").tag("__current__")
            Divider()
            if vm.fullBranchList.count > 100 {
              Text("Search to filter \(vm.fullBranchList.count) branches...").tag("__search__")
                .foregroundStyle(.secondary)
                .italic()
            }
            ForEach(vm.branches, id: \.self) { name in
              Text(name).tag(name)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 200)
          .onAppear {
            if vm.fullBranchList.isEmpty && !vm.isLoadingBranches {
              vm.loadBranches()
            }
          }

          if vm.isLoadingBranches {
            ProgressView().controlSize(.small)
          }
        }

        if !vm.showAllBranches && vm.fullBranchList.count > 100 {
          HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextField("Filter branches...", text: $vm.branchSearchQuery)
              .textFieldStyle(.plain)
              .font(.caption)
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .stroke(Color.secondary.opacity(0.2))
          )
          .frame(width: 200)
        }
      }
    }

    private var remoteBranchesToggle: some View {
      Toggle(
        isOn: $vm.showRemoteBranches
      ) {
        Text("Show Remote Branches")
          .lineLimit(1)
      }
      .onChange(of: vm.showRemoteBranches) { _ in
        vm.loadBranches()
        vm.loadCommits()
      }
    }

    private var actionButtons: some View {
      HStack(spacing: 8) {
        Button {
          vm.triggerRefresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(vm.isLoading)
        .help("Reload the commit list")

        Button {
          vm.fetchRemotes()
        } label: {
          Label("Fetch", systemImage: "arrow.down.circle")
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(vm.historyActionInProgress != nil)
        .help("Fetch all remotes")

        Button {
          vm.pullLatest()
        } label: {
          Label("Pull", systemImage: "square.and.arrow.down")
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(vm.historyActionInProgress != nil)
        .help("Pull current branch (fast-forward)")

        Button {
          vm.pushCurrent()
        } label: {
          Label("Push", systemImage: "square.and.arrow.up")
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(vm.historyActionInProgress != nil)
        .help("Push current branch")

        if vm.historyActionInProgress != nil {
          ProgressView()
            .controlSize(.small)
            .padding(.leading, 2)
        }
      }
    }
  }

  // Detailed view for a single commit: meta info, files list, and diff viewer.
  struct HistoryCommitDetailView: View {
    let commit: GitService.GraphCommit
    @ObservedObject var viewModel: GitGraphViewModel
    var onClose: () -> Void
    let wrap: Bool
    let showLineNumbers: Bool
    @State private var fileSearch: String = ""
    @State private var showMessageBody: Bool = false

    var body: some View {
      VSplitView {
        // Top: meta + files tree (stacked vertically)
        VSplitView {
          metaSection
          filesSection
        }
        // Bottom: diff viewer
        diffSection
      }
      .onAppear {
        viewModel.loadDetail(for: commit)
      }
      .onChange(of: commit.id) { _ in
        viewModel.loadDetail(for: commit)
      }
    }

    private var metaSection: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
              .font(.headline)
              .lineLimit(2)
            HStack(spacing: 12) {
              Text(commit.shortId)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
              if !commit.parents.isEmpty {
                Text("Parents: \(commit.parents.joined(separator: ", "))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            HStack(spacing: 12) {
              Text(commit.author)
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(commit.date)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Close commit details")
        }
        if !commit.decorations.isEmpty {
          HStack(spacing: 6) {
            ForEach(commit.decorations.prefix(4), id: \.self) { deco in
              Text(deco)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
          }
        }
        if !viewModel.detailMessage.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Button {
              showMessageBody.toggle()
            } label: {
              HStack(spacing: 4) {
                Image(systemName: showMessageBody ? "chevron.down" : "chevron.right")
                  .font(.system(size: 11, weight: .semibold))
                Text("Message")
                  .font(.caption.weight(.semibold))
                Spacer()
              }
            }
            .buttonStyle(.plain)

            if showMessageBody {
              ScrollView(.vertical, showsIndicators: true) {
                Text(viewModel.detailMessage)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
                  .padding(.trailing, 2)
              }
              .frame(maxHeight: .infinity, alignment: .topLeading)
            }
          }
        }
      }
      .padding(16)
      .frame(minHeight: showMessageBody ? 140 : 110, alignment: .topLeading)
    }

    private var filesSection: some View {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter files", text: $fileSearch)
              .textFieldStyle(.plain)
          }
          .padding(.vertical, 4)
          .padding(.horizontal, 6)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.secondary.opacity(0.2))
          )

          Spacer()

          HStack(spacing: 0) {
            Button {
              expandedHistoryDirs.removeAll()
            } label: {
              Image(systemName: "arrow.up.right.and.arrow.down.left")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)

            Button {
              let nodes = buildHistoryTree(from: filteredDetailFiles)
              var all: Set<String> = []
              collectAllDirKeys(nodes: nodes, into: &all)
              expandedHistoryDirs = all
            } label: {
              Image(systemName: "arrow.down.left.and.arrow.up.right")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
          }

          if viewModel.isLoadingDetail && viewModel.detailFiles.isEmpty {
            ProgressView().controlSize(.small)
          }
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if filteredDetailFiles.isEmpty, !viewModel.isLoadingDetail {
              Text("No files changed in this commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
              HistoryTreeView(
                nodes: buildHistoryTree(from: filteredDetailFiles),
                depth: 0,
                expandedDirs: $expandedHistoryDirs,
                selectedPath: viewModel.selectedDetailFile,
                onSelectFile: { path in
                  viewModel.selectedDetailFile = path
                  viewModel.loadDetailPatch(for: path)
                }
              )
            }
          }
        }
      }.padding(16)
    }

    private var diffSection: some View {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Diff")
            .font(.subheadline.weight(.semibold))
          if let file = viewModel.selectedDetailFile {
            Text("— \(file)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if viewModel.isLoadingDetail {
            ProgressView().controlSize(.small)
          }
        }

        if viewModel.detailFilePatch.isEmpty && !viewModel.isLoadingDetail {
          Text("Select a file to view its diff.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } else {
          AttributedTextView(
            text: viewModel.detailFilePatch,
            isDiff: true,
            wrap: wrap,
            showLineNumbers: showLineNumbers,
            fontSize: 12
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .padding(16)
    }

    // MARK: - History file tree helpers

    private var filteredDetailFiles: [GitService.FileChange] {
      let q = fileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !q.isEmpty else { return viewModel.detailFiles }
      return viewModel.detailFiles.filter {
        $0.path.localizedCaseInsensitiveContains(q)
          || ($0.oldPath?.localizedCaseInsensitiveContains(q) ?? false)
      }
    }

    struct HistoryFileNode: Identifiable {
      let id = UUID()
      let name: String
      let path: String?
      let dirPath: String?
      let change: GitService.FileChange?
      var children: [HistoryFileNode]?
      var isDirectory: Bool { dirPath != nil }
    }

    private func buildHistoryTree(from changes: [GitService.FileChange]) -> [HistoryFileNode] {
      struct Builder {
        var children: [String: Builder] = [:]
        var fileChange: GitService.FileChange? = nil
      }
      var root = Builder()
      for change in changes {
        let path = change.path
        guard !path.isEmpty else { continue }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { continue }
        func insert(_ index: Int, current: inout Builder) {
          let key = components[index]
          if index == components.count - 1 {
            var child = current.children[key, default: Builder()]
            child.fileChange = change
            current.children[key] = child
          } else {
            var child = current.children[key, default: Builder()]
            insert(index + 1, current: &child)
            current.children[key] = child
          }
        }
        insert(0, current: &root)
      }
      func convert(_ builder: Builder, prefix: String?) -> [HistoryFileNode] {
        var nodes: [HistoryFileNode] = []
        for (name, child) in builder.children {
          let fullPath = prefix.map { "\($0)/\(name)" } ?? name
          if let change = child.fileChange, child.children.isEmpty {
            nodes.append(
              HistoryFileNode(
                name: name, path: change.path, dirPath: nil, change: change, children: nil)
            )
          } else {
            let childrenNodes = convert(child, prefix: fullPath)
            nodes.append(
              HistoryFileNode(
                name: name,
                path: nil,
                dirPath: fullPath,
                change: nil,
                children: childrenNodes.sorted {
                  $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
              )
            )
          }
        }
        return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      }
      return convert(root, prefix: nil)
    }

    private func collectAllDirKeys(nodes: [HistoryFileNode], into set: inout Set<String>) {
      for node in nodes {
        if let dir = node.dirPath {
          set.insert(dir)
        }
        if let children = node.children {
          collectAllDirKeys(nodes: children, into: &set)
        }
      }
    }

    @State private var expandedHistoryDirs: Set<String> = []

    struct HistoryTreeView: View {
      let nodes: [HistoryFileNode]
      let depth: Int
      @Binding var expandedDirs: Set<String>
      let selectedPath: String?
      let onSelectFile: (String) -> Void

      var body: some View {
        ForEach(nodes) { node in
          if node.isDirectory {
            let key = node.dirPath ?? ""
            let isExpanded = expandedDirs.contains(key)
            directoryRow(node: node, key: key, isExpanded: isExpanded)
            if isExpanded, let children = node.children {
              HistoryTreeView(
                nodes: children,
                depth: depth + 1,
                expandedDirs: $expandedDirs,
                selectedPath: selectedPath,
                onSelectFile: onSelectFile
              )
            }
          } else if let path = node.path {
            fileRow(node: node, path: path)
          }
        }
      }

      private func directoryRow(node: HistoryFileNode, key: String, isExpanded: Bool) -> some View {
        let indentStep: CGFloat = 16
        let chevronWidth: CGFloat = 16
        return HStack(spacing: 0) {
          ZStack(alignment: .leading) {
            Color.clear.frame(width: CGFloat(depth) * indentStep + chevronWidth)
            let guideColor = Color.secondary.opacity(0.15)
            ForEach(0..<depth, id: \.self) { i in
              Rectangle()
                .fill(guideColor)
                .frame(width: 1)
                .offset(x: CGFloat(i) * indentStep + chevronWidth / 2)
            }
            HStack(spacing: 0) {
              Spacer().frame(width: CGFloat(depth) * indentStep)
              Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: chevronWidth, height: 20)
            }
          }
          HStack(spacing: 6) {
            Image(systemName: "folder")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            Text(node.name)
              .font(.system(size: 13))
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.trailing, 8)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
          if let dir = node.dirPath {
            if expandedDirs.contains(dir) {
              expandedDirs.remove(dir)
            } else {
              expandedDirs.insert(dir)
            }
          }
        }
      }

      private func fileRow(node: HistoryFileNode, path: String) -> some View {
        let indentStep: CGFloat = 16
        let chevronWidth: CGFloat = 16
        let isSelected = (path == selectedPath)
        return HStack(spacing: 0) {
          ZStack(alignment: .leading) {
            Color.clear.frame(width: CGFloat(depth) * indentStep + chevronWidth)
            let guideColor = Color.secondary.opacity(0.15)
            ForEach(0..<depth, id: \.self) { i in
              Rectangle()
                .fill(guideColor)
                .frame(width: 1)
                .offset(x: CGFloat(i) * indentStep + chevronWidth / 2)
            }
          }
          HStack(spacing: 6) {
            let icon = GitFileIcon.icon(for: path)
            Image(systemName: icon.name)
              .font(.system(size: 12))
              .foregroundStyle(icon.color)
            Text(node.name)
              .font(.system(size: 13))
              .lineLimit(1)
            Spacer(minLength: 0)
            if let change = node.change {
              Circle()
                .fill(Self.statusColor(for: change))
                .frame(width: 6, height: 6)
              Self.statusBadge(text: Self.badgeText(for: change))
            }
          }
          .padding(.trailing, 8)
        }
        .frame(height: 22)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          onSelectFile(path)
        }
      }

      // MARK: - Helper methods
      private static func statusColor(for change: GitService.FileChange) -> Color {
        guard let code = change.statusCode.first else { return Color.secondary.opacity(0.6) }
        switch code {
        case "A": return .green
        case "M": return .orange
        case "D": return .red
        case "R": return .purple
        case "C": return .blue
        case "T": return .teal
        case "U": return .gray
        default: return Color.secondary.opacity(0.6)
        }
      }

      private static func badgeText(for change: GitService.FileChange) -> String {
        guard let first = change.statusCode.first else { return "?" }
        return String(first)
      }

      private static func statusBadge(text: String) -> some View {
        Text(text)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: 3)
              .fill(Color.secondary.opacity(0.1))
          )
      }
    }
  }
}

// Renders commit lanes and connectors for a single row.
private struct GraphLaneView: View {
  let info: GitGraphViewModel.LaneInfo
  let maxLanes: Int
  let laneSpacing: CGFloat
  let verticalWidth: CGFloat
  let hideTopForCurrentLane: Bool
  let hideBottomForCurrentLane: Bool
  let headIsHollow: Bool
  let headSize: CGFloat
  let isSelected: Bool

  private let dotSize: CGFloat = 8
  private let lineWidth: CGFloat = 2

  private func x(_ lane: Int) -> CGFloat {
    CGFloat(lane) * laneSpacing + laneSpacing / 2
  }

  var body: some View {
    Canvas { context, size in
      drawGraph(in: context, size: size)
    }
  }

  private func drawGraph(in context: GraphicsContext, size: CGSize) {
    let baseColor: Color = isSelected ? .white : .accentColor
    let verticalColor: Color = isSelected ? .white : .accentColor.opacity(0.6)

    let h = size.height
    // Slightly extend beyond row bounds so vertical lanes visually connect between rows.
    let top: CGFloat = -2
    let bottom: CGFloat = h + 2
    let dotY = h * 0.5

    // Draw vertical lane lines
    let count = max(info.activeLaneCount, maxLanes)
    if count > 0 {
      for i in 0..<count where info.continuingLanes.contains(i) {
        let xi = x(i)
        let headRadius: CGFloat =
          headIsHollow && i == info.laneIndex
          ? max(ceil(headSize / 2), 5) : ceil(dotSize / 2)
        let margin: CGFloat = headRadius + 1

        var path = Path()

        if i == info.laneIndex {
          if !hideTopForCurrentLane && !hideBottomForCurrentLane {
            path.move(to: CGPoint(x: xi, y: top))
            path.addLine(to: CGPoint(x: xi, y: bottom))
          } else if hideTopForCurrentLane && !hideBottomForCurrentLane {
            path.move(to: CGPoint(x: xi, y: dotY + margin))
            path.addLine(to: CGPoint(x: xi, y: bottom))
          } else if !hideTopForCurrentLane && hideBottomForCurrentLane {
            path.move(to: CGPoint(x: xi, y: top))
            path.addLine(to: CGPoint(x: xi, y: dotY - margin))
          }
        } else if !info.parentLaneIndices.contains(i) && !info.joinLaneIndices.contains(i) {
          path.move(to: CGPoint(x: xi, y: top))
          path.addLine(to: CGPoint(x: xi, y: bottom))
        }

        context.stroke(path, with: .color(verticalColor), lineWidth: verticalWidth)
      }
    }

    // Draw join connectors (incoming branches from above)
    let cx = x(info.laneIndex)
    let endY = headIsHollow ? dotY - max(ceil(headSize / 2), 5) - 1 : dotY - ceil(dotSize / 2) - 1

    for source in info.joinLaneIndices where source != info.laneIndex {
      var path = Path()
      let sx = x(source)
      path.move(to: CGPoint(x: sx, y: top))
      path.addCurve(
        to: CGPoint(x: cx, y: endY),
        control1: CGPoint(x: sx, y: h * 0.25),
        control2: CGPoint(x: cx, y: endY - h * 0.25)
      )
      context.stroke(path, with: .color(verticalColor), lineWidth: lineWidth)
    }

    // Draw parent connectors (outgoing branches downward)
    if !hideBottomForCurrentLane {
      let startY = headIsHollow ? dotY + max(ceil(headSize / 2), 5) + 1 : dotY

      for parent in info.parentLaneIndices where parent != info.laneIndex {
        var path = Path()
        let px = x(parent)
        path.move(to: CGPoint(x: cx, y: startY))
        path.addCurve(
          to: CGPoint(x: px, y: bottom),
          control1: CGPoint(x: cx, y: startY + h * 0.25),
          control2: CGPoint(x: px, y: bottom - h * 0.25)
        )
        context.stroke(path, with: .color(verticalColor), lineWidth: lineWidth)
      }
    }

    // Draw commit dot
    if headIsHollow {
      var circle = Path()
      circle.addEllipse(
        in: CGRect(
          x: x(info.laneIndex) - headSize / 2,
          y: dotY - headSize / 2,
          width: headSize,
          height: headSize
        ))
      context.stroke(circle, with: .color(baseColor), lineWidth: 2)
    } else {
      var circle = Path()
      circle.addEllipse(
        in: CGRect(
          x: x(info.laneIndex) - dotSize / 2,
          y: dotY - dotSize / 2,
          width: dotSize,
          height: dotSize
        ))
      context.fill(circle, with: .color(baseColor))
    }
  }

}

// ColumnResizer removed: columns use fixed widths; Description fills remaining space.

// MARK: - Graph Glyph
// Monospace-like graph glyph: a vertical line with a centered dot, mimicking a basic lane.
private struct GraphGlyph: View {
  let isSelected: Bool

  var body: some View {
    let lineColor = isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.25)
    let dotColor = isSelected ? Color.white : Color.accentColor

    ZStack {
      Rectangle().fill(lineColor).frame(width: 1).padding(.vertical, 2)
      Circle().fill(dotColor).frame(width: 6, height: 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

// MARK: - Scroll Detection
// No custom scroll detection needed for the Table-based graph;
// row selection and highlighting are handled by NSTableView under the hood.
