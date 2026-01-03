import SwiftUI

struct StatusBarOverlayView: View {
  @ObservedObject var store: StatusBarLogStore
  @ObservedObject var preferences: SessionPreferencesStore
  let sidebarInset: CGFloat

  @State private var dragStartHeight: CGFloat? = nil
  @State private var draggedHeight: CGFloat? = nil
  @State private var filterText: String = ""
  @State private var filterLevel: StatusBarLogLevel? = nil  // nil = All

  private let maxVisibleLines: Int = 160
  private let minExpandedHeight: CGFloat = 120
  private let maxExpandedHeight: CGFloat = 520

  var body: some View {
    if preferences.statusBarVisibility != .hidden {
      content
        .frame(maxHeight: totalHeight, alignment: .bottomLeading)
        .animation(.none, value: sidebarInset)
        .onAppear {
          store.setAutoCollapseEnabled(preferences.statusBarVisibility == .auto)
        }
        .onChange(of: preferences.statusBarVisibility) { newValue in
          store.setAutoCollapseEnabled(newValue == .auto)
        }
    }
  }

  private var totalHeight: CGFloat {
    if let draggedHeight = draggedHeight {
      return store.isExpanded ? draggedHeight : store.collapsedHeight
    }
    return store.isExpanded ? store.expandedHeight : store.collapsedHeight
  }

  private var logListHeight: CGFloat {
    let effectiveHeight = draggedHeight ?? store.expandedHeight
    return max(0, effectiveHeight - store.collapsedHeight)
  }

  private var content: some View {
    VStack(spacing: 0) {
      // Top divider - separates status bar from content above
      Divider()

      if store.isExpanded {
        // Title bar (serves as resize handle)
        titleBar
          .frame(height: store.collapsedHeight)
          .background(Color(nsColor: .windowBackgroundColor))
        // Divider between title bar and log content
        Divider()
        // Log content
        logList
          .frame(height: logListHeight)
          .background(Color(nsColor: .textBackgroundColor))
      } else {
        // Collapsed state - just show the title bar
        titleBar
          .frame(height: store.collapsedHeight)
          .background(Color(nsColor: .windowBackgroundColor))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
    .onHover { hovering in
      store.setInteracting(hovering)
    }
  }

  private var titleBar: some View {
    HStack(spacing: 8) {
      statusIcon
      if store.isExpanded {
        // Filter menu and search field when expanded
        filterMenu
        searchField
        Spacer(minLength: 8)
      } else {
        statusText
        Spacer(minLength: 8)
      }
      // Toggle button on the right
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          store.isExpanded.toggle()
          if store.isExpanded {
            store.reveal(expanded: false)
          }
        }
      } label: {
        Image(systemName: "rectangle.bottomthird.inset.filled")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
      .help(store.isExpanded ? "Hide Debug Area" : "Show Debug Area")
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .gesture(
      store.isExpanded ? DragGesture(minimumDistance: 2)
        .onChanged { value in
          if dragStartHeight == nil {
            dragStartHeight = store.expandedHeight
          }
          let startHeight = dragStartHeight ?? store.expandedHeight
          let newHeight = startHeight - value.translation.height
          let clamped = min(max(newHeight, minExpandedHeight), maxExpandedHeight)

          store.setInteracting(true)
          draggedHeight = clamped
        }
        .onEnded { _ in
          if let finalHeight = draggedHeight {
            store.setExpandedHeight(finalHeight)
          }
          dragStartHeight = nil
          draggedHeight = nil
          store.setInteracting(false)
        } : nil
    )
  }


  private var filterMenu: some View {
    Menu {
      Button {
        filterLevel = nil
      } label: {
        HStack {
          Text("All")
          if filterLevel == nil {
            Image(systemName: "checkmark")
          }
        }
      }
      Divider()
      ForEach(StatusBarLogLevel.allCases) { level in
        Button {
          filterLevel = level
        } label: {
          HStack {
            Circle()
              .fill(levelColor(level))
              .frame(width: 6, height: 6)
            Text(level.rawValue.capitalized)
            if filterLevel == level {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: 11))
        if let level = filterLevel {
          Circle()
            .fill(levelColor(level))
            .frame(width: 6, height: 6)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
    }
    .menuStyle(.borderlessButton)
    .frame(height: 20)
    .help("Filter by level")
  }

  private var searchField: some View {
    HStack(spacing: 4) {
      TextField("Filter messages", text: $filterText)
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .frame(minWidth: 180, maxWidth: 240)
      if !filterText.isEmpty {
        Button {
          filterText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(Color(nsColor: .textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    )
  }

  private var filteredEntries: [StatusBarLogEntry] {
    store.entries.filter { entry in
      // Filter by level
      if let filterLevel = filterLevel, entry.level != filterLevel {
        return false
      }
      // Filter by text
      if filterText.isEmpty { return true }
      let searchLower = filterText.lowercased()
      if entry.message.lowercased().contains(searchLower) { return true }
      if let source = entry.source, source.lowercased().contains(searchLower) { return true }
      return false
    }
  }

  private var statusIcon: some View {
    let level = store.entries.last?.level ?? .info
    let systemName: String
    switch level {
    case .info:
      systemName = store.activeTaskCount > 0 ? "clock.badge.checkmark" : "info.circle"
    case .success:
      systemName = "checkmark.circle"
    case .warning:
      systemName = "exclamationmark.triangle"
    case .error:
      systemName = "xmark.octagon"
    }
    return Image(systemName: systemName)
      .foregroundStyle(levelColor(level))
  }

  private var statusText: some View {
    let entry = store.entries.last
    let text = entry?.message ?? "No recent activity"
    return HStack(spacing: 6) {
      if let entry {
        Text(timeString(entry.timestamp))
          .foregroundStyle(.secondary)
      }
      Text(text)
        .foregroundStyle(levelColor(entry?.level ?? .info))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var logList: some View {
    let displayEntries = Array(filteredEntries.suffix(maxVisibleLines))
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(displayEntries) { entry in
            logEntryRow(entry)
              .id(entry.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
      }
      .onChange(of: store.entries.count) { _ in
        guard !store.isInteracting, let last = displayEntries.last else { return }
        withAnimation(.easeOut(duration: 0.1)) {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
    }
    .simultaneousGesture(
      DragGesture()
        .onChanged { _ in store.setInteracting(true) }
        .onEnded { _ in store.setInteracting(false) }
    )
  }

  private func logEntryRow(_ entry: StatusBarLogEntry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(timeString(entry.timestamp))
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 60, alignment: .leading)
      Circle()
        .fill(levelColor(entry.level))
        .frame(width: 5, height: 5)
      if let source = entry.source, !source.isEmpty {
        Text(source)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(minWidth: 60, alignment: .leading)
      }
      Text(highlightedMessage(entry.message))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(levelColor(entry.level))
        .textSelection(.enabled)
    }
    .padding(.vertical, 1)
  }

  private func highlightedMessage(_ message: String) -> AttributedString {
    guard !filterText.isEmpty else {
      return AttributedString(message)
    }
    var result = AttributedString(message)
    var searchStart = result.startIndex
    while searchStart < result.endIndex,
          let range = result[searchStart...].range(of: filterText, options: .caseInsensitive) {
      result[range].backgroundColor = .yellow.opacity(0.3)
      searchStart = range.upperBound
    }
    return result
  }

  private func levelColor(_ level: StatusBarLogLevel) -> Color {
    switch level {
    case .info:
      return .secondary
    case .success:
      return Color.green
    case .warning:
      return Color.orange
    case .error:
      return Color.red
    }
  }

  private func timeString(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("HH:mm:ss")
    return formatter
  }()
}
