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
    .onChange(of: vm.repoRoot) { _, newVal in
      graphVM.attach(to: newVal)
    }
  }

  // Host for the graph UI
  struct GraphContainer: View {
    @StateObject var vm: GitGraphViewModel
    let wrapText: Bool
    let showLineNumbers: Bool
    let compactColumns: Bool
    let onActivateCommit: (GitService.GraphCommit?) -> Void

    init(
      vm: GitGraphViewModel,
      wrapText: Bool,
      showLineNumbers: Bool,
      compactColumns: Bool,
      onActivateCommit: @escaping (GitService.GraphCommit?) -> Void
    ) {
      _vm = StateObject(wrappedValue: vm)
      self.wrapText = wrapText
      self.showLineNumbers = showLineNumbers
      self.compactColumns = compactColumns
      self.onActivateCommit = onActivateCommit
    }
    @State private var rowHoverId: String? = nil

    var body: some View {
      VStack(spacing: 8) {
        // Controls + full-width commit list (no right-side diff in History mode)
        // Branch scope controls (search moved to header)
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
        // Match Tasks/Review layout: align controls with consistent inset
        // and keep the block pulled down from the header divider.
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .onChange(of: vm.showAllBranches) { _, _ in vm.loadCommits() }
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
        // Header row (fixed height, fixed column widths; compact mode hides trailing columns)
        HStack(spacing: 8) {
          Color.clear
            .frame(width: graphColumnWidth)
          Text("Description")
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
          if !compactColumns {
            // Date
            Text("Date")
              .foregroundStyle(.secondary)
              .font(.caption)
              .frame(width: dateWidth, alignment: .leading)
            // Author
            Text("Author")
              .foregroundStyle(.secondary)
              .font(.caption)
              .frame(width: authorWidth, alignment: .leading)
            // SHA
            Text("SHA")
              .foregroundStyle(.secondary)
              .font(.caption)
              .frame(width: shaWidth, alignment: .leading)
          }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
          Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }

        // Rows: zero spacing to keep lane connectors continuous between rows
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(vm.filteredCommits.enumerated()), id: \.element.id) { idx, c in
              HStack(spacing: 8) {
                if let info = vm.laneInfoById[c.id] {
                  GraphLaneView(
                    info: info,
                    maxLanes: vm.maxLaneCount,
                    laneSpacing: laneSpacing,
                    verticalWidth: 2,
                    hideTopForCurrentLane: idx == 0,
                    hideBottomForCurrentLane: idx == vm.filteredCommits.count - 1,
                    headIsHollow: c.id == "::working-tree::",
                    headSize: 12
                  )
                  .frame(width: graphColumnWidth, height: rowHeight)
                } else {
                  GraphGlyph()
                    .frame(width: graphColumnWidth, height: rowHeight)
                }
                // Description cell
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    Text(c.subject)
                      .fontWeight(c.id == "::working-tree::" ? .semibold : .regular)
                      .lineLimit(1)
                      .frame(maxWidth: .infinity, alignment: .leading)
                    // Decorations chips
                    ForEach(c.decorations.prefix(3), id: \.self) { d in
                      Text(d)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                  }
                }
                .padding(.trailing, 8)
                if !compactColumns {
                  Text(c.date)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: dateWidth, alignment: .leading)
                  Text(c.author)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: authorWidth, alignment: .leading)
                  Text(c.shortId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: shaWidth, alignment: .leading)
                }
              }
              .frame(height: rowHeight)
              .background(rowHoverId == c.id ? Color.accentColor.opacity(0.07) : Color.clear)
              .background((idx % 2 == 1) ? Color.secondary.opacity(0.06) : Color.clear)
              .contentShape(Rectangle())
              .onHover { inside in
                rowHoverId = inside ? c.id : (rowHoverId == c.id ? nil : rowHoverId)
              }
              .onTapGesture {
                vm.selectCommit(c)
                if c.id == "::working-tree::" {
                  onActivateCommit(nil)
                } else {
                  onActivateCommit(c)
                }
              }
            }
          }
        }
        .padding(.leading, 16)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var graphColumnWidth: CGFloat {
      // Graph column width scales with lanes; lane width equals row height so dot margins match vertically
      return max(rowHeight + 4, CGFloat(max(vm.maxLaneCount, 1)) * laneSpacing)
    }
    private var rowHeight: CGFloat { 24 }
    private var laneSpacing: CGFloat { rowHeight }
    private var dateWidth: CGFloat { 110 }
    private var authorWidth: CGFloat { 120 }
    private var shaWidth: CGFloat { 80 }

    @ViewBuilder
    private var branchSelector: some View {
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
          ForEach(vm.branches, id: \.self) { name in
            Text(name).tag(name)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 200)
      }
    }

    private var remoteBranchesToggle: some View {
      Toggle(
        isOn: $vm.showRemoteBranches
      ) {
        Text("Show Remote Branches")
          .lineLimit(1)
      }
      .onChange(of: vm.showRemoteBranches) { _, _ in
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

  // Monospace-like graph glyph: a vertical line with a centered dot, mimicking a basic lane.
  struct GraphGlyph: View {
    var body: some View {
      ZStack {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).padding(.vertical, 2)
        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
  // Simple background with alternating horizontal stripes to separate rows visually
  struct StripedBackground: View {
    var stripe: CGFloat = 28
    var body: some View {
      GeometryReader { geo in
        let count = Int(ceil(geo.size.height / max(1, stripe)))
        ZStack(alignment: .topLeading) {
          Color(nsColor: .textBackgroundColor)
          ForEach(0..<max(count, 0), id: \.self) { i in
            if i % 2 == 1 {
              Rectangle()
                .fill(Color.secondary.opacity(0.06))
                .frame(height: stripe)
                .offset(y: CGFloat(i) * stripe)
            }
          }
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
      .onChange(of: commit.id) { _, _ in
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
              HistoryFileNode(name: name, path: change.path, dirPath: nil, change: change, children: nil)
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

  private let dotSize: CGFloat = 8
  private let lineWidth: CGFloat = 2

  private func x(_ lane: Int) -> CGFloat {
    CGFloat(lane) * laneSpacing + laneSpacing / 2
  }

  var body: some View {
    GeometryReader { geo in
      let h = max(geo.size.height, 18)

      // Vertical lane segments to maintain continuity across rows
      Path { p in
        let top: CGFloat = 0
        let bottom: CGFloat = h
        let count = max(info.activeLaneCount, maxLanes)
        if count > 0 {
          for i in 0..<count {
            if info.continuingLanes.contains(i) {
              let xi = x(i)
              let dotY = h * 0.5
              // margin to avoid line intruding into hollow ring
              let headRadius: CGFloat =
                headIsHollow && i == info.laneIndex ? max(ceil(headSize / 2), 5) : ceil(dotSize / 2)
              let startBelow: CGFloat = headRadius + 1
              if i == info.laneIndex {
                if hideTopForCurrentLane {
                  // start under the head
                  p.move(to: CGPoint(x: xi, y: dotY + startBelow))
                  if hideBottomForCurrentLane {
                    // draw nothing further; hidden both above and below
                  } else {
                    p.addLine(to: CGPoint(x: xi, y: bottom))
                  }
                } else if hideBottomForCurrentLane {
                  // draw from top to just above the head
                  p.move(to: CGPoint(x: xi, y: top))
                  p.addLine(to: CGPoint(x: xi, y: dotY - startBelow))
                } else {
                  p.move(to: CGPoint(x: xi, y: top))
                  p.addLine(to: CGPoint(x: xi, y: bottom))
                }
              } else if info.parentLaneIndices.contains(i) {
                // For lanes that are only reached via branch connectors on this row,
                // skip vertical segment here so only the diagonal branch is visible.
                continue
              } else {
                p.move(to: CGPoint(x: xi, y: top))
                p.addLine(to: CGPoint(x: xi, y: bottom))
              }
            }
          }
        }
      }
      .stroke(Color.accentColor.opacity(0.6), lineWidth: max(0.5, verticalWidth))

      // Connectors from current dot to parent lanes (downward curves); only draw diagonals
      Path { p in
        if !hideBottomForCurrentLane {
          let cx = x(info.laneIndex)
          let dotY = h * 0.5
          let startY: CGFloat = {
            if headIsHollow { return dotY + CGFloat(max(ceil(headSize / 2), 5)) + 1 }
            return dotY
          }()
          for parent in info.parentLaneIndices where parent != info.laneIndex {
            let px = x(parent)
            p.move(to: CGPoint(x: cx, y: startY))
            // Smooth S-shaped curve toward bottom at parent lane position
            let c1 = CGPoint(x: cx, y: startY + h * 0.25)
            let c2 = CGPoint(x: px, y: h - h * 0.25)
            p.addCurve(to: CGPoint(x: px, y: h), control1: c1, control2: c2)
          }
        }
      }
      .stroke(Color.accentColor.opacity(0.6), lineWidth: lineWidth)

      // Commit dot
      Group {
        if headIsHollow {
          Circle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: headSize, height: headSize)
        } else {
          Circle()
            .fill(Color.accentColor)
            .frame(width: dotSize, height: dotSize)
        }
      }
      .position(x: x(info.laneIndex), y: h * 0.5)
    }
  }
}

// ColumnResizer removed: columns use fixed widths; Description fills remaining space.
