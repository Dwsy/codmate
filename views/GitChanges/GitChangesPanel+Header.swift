import SwiftUI

extension GitChangesPanel {
  // MARK: - Header view
  var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        // Mode switcher: Diff | History | Explorer (only show when repo exists)
        if vm.repoRoot != nil {
          let items: [SegmentedIconPicker<ReviewPanelState.Mode>.Item] = [
            .init(title: "Diff", systemImage: "doc.text.magnifyingglass", tag: .diff),
            .init(title: "History", systemImage: "clock.arrow.circlepath", tag: .graph),
            .init(title: "Explorer", systemImage: "folder", tag: .browser),
          ]
          SegmentedIconPicker(items: items, selection: $mode)
        }

        Spacer(minLength: 8)

        // Unified search (right-aligned)
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(searchPlaceholder, text: $headerSearchQuery)
            .textFieldStyle(.plain)
            .onChange(of: headerSearchQuery) { _, newVal in
              onHeaderSearchChanged(newVal)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
          RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2))
        )
        .frame(minWidth: 160, maxWidth: 360)

        // Repo authorization toggle (to the left of the edge)
        let rootURL = vm.repoRoot ?? projectDirectory ?? workingDirectory
        let authorized =
          SecurityScopedBookmarks.shared.isSandboxed
          ? SecurityScopedBookmarks.shared.hasDynamicBookmark(for: rootURL)
          : true
        if vm.repoRoot != nil || explorerRootExists,
          SecurityScopedBookmarks.shared.isSandboxed
        {
          Button {
            if authorized {
              SecurityScopedBookmarks.shared.removeDynamic(url: rootURL)
              NotificationCenter.default.post(name: .codMateRepoAuthorizationChanged, object: nil)
            } else {
              onRequestAuthorization?()
            }
          } label: {
            Image(systemName: authorized ? "checkmark.shield" : "exclamationmark.shield")
              .foregroundStyle(authorized ? .green : .orange)
          }
          .buttonStyle(.plain)
          .help(authorized ? "Revoke repository authorization" : "Authorize repository folder…")
        }

        // Hidden keyboard shortcut to trigger commit confirmation via ⌘⏎
        Button("") {
          let msg = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
          if !msg.isEmpty { showCommitConfirm = true }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
      }
      if vm.repoRoot == nil {
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
          Text("Git repository not found. Explorer mode only.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
      // Moved authorization controls inline in header path; remove separate row
      if let err = vm.errorMessage, !err.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(err)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.orange.opacity(0.08))
        )
      }
    }
  }
}

// MARK: - Header search helpers
extension GitChangesPanel {
  var searchPlaceholder: String {
    switch mode {
    case .graph: return "Search commits"
    case .diff: return "Search diff"
    case .browser: return "Search preview"
    }
  }

  func onHeaderSearchChanged(_ newVal: String) {
    let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
    switch mode {
    case .graph:
      graphVM.searchQuery = trimmed
      graphVM.applyFilter()
    case .diff, .browser:
      // Handled in detailView via AttributedTextView(searchQuery:)
      break
    }
  }
}
