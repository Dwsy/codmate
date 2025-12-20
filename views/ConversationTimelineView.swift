import AppKit
import SwiftUI

private let timelineTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss"
  return formatter
}()

struct ConversationTimelineView: View {
  let turns: [ConversationTurn]
  @Binding var expandedTurnIDs: Set<String>
  var ascending: Bool = false
  var branding: SessionSourceBranding = SessionSource.codexLocal.branding
  var allowManualToggle: Bool = true
  var autoExpandVisible: Bool = false
  var onScrollToTurn: ((String) -> Void)? = nil
  @StateObject private var layout = TimelineLayoutStore()
  @State private var messageScrollView: NSScrollView?
  @State private var markerScrollView: NSScrollView?
  @State private var messageScrollObserver: NSObjectProtocol?
  @State private var markerScrollObserver: NSObjectProtocol?
  @State private var suppressMarkerSync = false
  @State private var suppressMessageSync = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      markerColumn
      messageColumn
    }
    .onAppear {
      layout.updateOrder(turns.map(\.id))
    }
    .onChange(of: turns.map(\.id)) { newValue in
      layout.updateOrder(newValue)
    }
    .onDisappear {
      if let observer = messageScrollObserver {
        NotificationCenter.default.removeObserver(observer)
      }
      if let observer = markerScrollObserver {
        NotificationCenter.default.removeObserver(observer)
      }
    }
  }

  private var markerColumn: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVStack(alignment: .center, spacing: 0) {
        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
          let pos = ascending ? (index + 1) : (turns.count - index)
          let bodyHeight = layout.bodyHeights[turn.id] ?? 0
          let isVisible = layout.visibleRange?.contains(index) ?? true
          let height = layout.headerHeight + (isVisible ? bodyHeight : 0)
          Button(action: { scrollMessage(to: turn.id) }) {
            TimelineMarker(
              position: pos,
              timeText: timelineTimeFormatter.string(from: turn.timestamp),
              isFirst: index == turns.startIndex,
              isLast: index == turns.count - 1
            )
          }
          .buttonStyle(.plain)
          .frame(height: max(height, layout.headerHeight), alignment: .top)
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
        }
      }
      .padding(.top, 2)
    }
    .frame(width: 72)
    .scrollIndicators(.hidden)
    .background(ScrollViewAccessor { scrollView in
      attachMarkerScrollView(scrollView)
    })
  }

  private var messageColumn: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(Array(turns.enumerated()), id: \.element.id) { _, turn in
          Section {
            ConversationTurnRow(
              turn: turn,
              isExpanded: expandedTurnIDs.contains(turn.id),
              branding: branding,
              toggleExpanded: { toggle(turn) },
              autoExpandVisible: autoExpandVisible
            )
            .id(turn.id)
            .padding(.bottom, 18)
            .background(
              GeometryReader { proxy in
                Color.clear
                  .preference(key: TurnBodyHeightKey.self, value: [turn.id: proxy.size.height])
              }
            )
          } header: {
            ConversationTurnHeaderRow(
              turn: turn,
              isExpanded: expandedTurnIDs.contains(turn.id),
              branding: branding,
              allowToggle: allowManualToggle,
              onToggle: { toggle(turn) },
              onJump: { scrollMessage(to: turn.id) }
            )
            .background(
              GeometryReader { proxy in
                Color.clear
                  .preference(key: TurnHeaderHeightKey.self, value: proxy.size.height)
              }
            )
          }
        }
      }
      .padding(.top, 2)
    }
    .scrollIndicators(.automatic)
    .background(ScrollViewAccessor { scrollView in
      attachMessageScrollView(scrollView)
    })
    .onPreferenceChange(TurnBodyHeightKey.self) { values in
      layout.updateBodyHeights(values)
    }
    .onPreferenceChange(TurnHeaderHeightKey.self) { height in
      if height > 0 { layout.headerHeight = height }
    }
  }

  @MainActor
  private func attachMessageScrollView(_ scrollView: NSScrollView) {
    guard messageScrollView !== scrollView else { return }
    if let observer = messageScrollObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    messageScrollView = scrollView
    scrollView.contentView.postsBoundsChangedNotifications = true
    messageScrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { _ in
      Task { @MainActor in
        messageDidScroll()
      }
    }
    messageDidScroll()
  }

  @MainActor
  private func attachMarkerScrollView(_ scrollView: NSScrollView) {
    guard markerScrollView !== scrollView else { return }
    if let observer = markerScrollObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    markerScrollView = scrollView
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    markerScrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { _ in
      Task { @MainActor in
        markerDidScroll()
      }
    }
  }

  @MainActor
  private func messageDidScroll() {
    guard let messageScrollView else { return }
    if suppressMessageSync { return }
    
    let offsetY = messageScrollView.contentView.bounds.origin.y
    let viewportHeight = messageScrollView.contentView.bounds.height
    layout.updateVisibleRange(for: offsetY, viewportHeight: viewportHeight)
    syncMarkerToMessage(offsetY: offsetY)
  }

  @MainActor
  private func markerDidScroll() {
    guard let markerScrollView else { return }
    if suppressMarkerSync { return }
    
    syncMessageToMarker(markerOffsetY: markerScrollView.contentView.bounds.origin.y)
  }

  @MainActor
  private func syncMarkerToMessage(offsetY: CGFloat? = nil) {
    guard let messageScrollView, let markerScrollView else { return }
    let messageOffset = offsetY ?? messageScrollView.contentView.bounds.origin.y
    guard let markerOffset = layout.markerOffset(forMessageOffset: messageOffset) else { return }
    
    // Dispatch to allow layout to update (accordion effect) before scrolling
    DispatchQueue.main.async {
      let markerViewport = markerScrollView.contentView.bounds.height
      let maxOffset = max(0, layout.markerContentHeight() - markerViewport)
      let clamped = min(max(markerOffset, 0), maxOffset)
      
      if abs(markerScrollView.contentView.bounds.origin.y - clamped) > 0.5 {
        suppressMarkerSync = true
        markerScrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        markerScrollView.reflectScrolledClipView(markerScrollView.contentView)
        // Release suppression in next cycle
        DispatchQueue.main.async {
          suppressMarkerSync = false
        }
      }
    }
  }

  @MainActor
  private func syncMessageToMarker(markerOffsetY: CGFloat? = nil) {
    guard let messageScrollView, let markerScrollView else { return }
    let markerOffset = markerOffsetY ?? markerScrollView.contentView.bounds.origin.y
    guard let targetOffset = layout.messageOffset(forMarkerOffset: markerOffset) else { return }
    let viewport = messageScrollView.contentView.bounds.height
    let maxOffset = max(0, layout.messageContentHeight() - viewport)
    let clamped = min(max(targetOffset, 0), maxOffset)
    
    if abs(messageScrollView.contentView.bounds.origin.y - clamped) > 0.5 {
      suppressMessageSync = true
      messageScrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
      messageScrollView.reflectScrolledClipView(messageScrollView.contentView)
      DispatchQueue.main.async {
        self.suppressMessageSync = false
      }
    }
  }

  private func scrollMessage(to id: String) {
    guard let messageScrollView else { return }
    guard let targetOffset = layout.messageOffset(for: id) else { return }
    let viewport = messageScrollView.contentView.bounds.height
    let maxOffset = max(0, layout.messageContentHeight() - viewport)
    let clamped = min(max(targetOffset, 0), maxOffset)
    
    suppressMessageSync = true
    messageScrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
    messageScrollView.reflectScrolledClipView(messageScrollView.contentView)
    // Manually trigger marker sync since we suppressed the message sync
    layout.updateVisibleRange(for: clamped, viewportHeight: viewport)
    syncMarkerToMessage(offsetY: clamped)
    
    DispatchQueue.main.async {
      self.suppressMessageSync = false
    }
    onScrollToTurn?(id)
  }

  private func toggle(_ turn: ConversationTurn) {
    guard allowManualToggle else { return }
    if expandedTurnIDs.contains(turn.id) {
      expandedTurnIDs.remove(turn.id)
    } else {
      expandedTurnIDs.insert(turn.id)
    }
  }

}

private struct ConversationTurnRow: View {
  let turn: ConversationTurn
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let toggleExpanded: () -> Void
  let autoExpandVisible: Bool
  @State private var isVisible = false

  var body: some View {
    let expanded = autoExpandVisible ? isVisible : isExpanded
    ConversationCard(
      turn: turn,
      isExpanded: expanded,
      branding: branding,
      toggle: toggleExpanded
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, -6)
    .padding(.bottom, 16)
    .onAppear { if autoExpandVisible { isVisible = true } }
    .onDisappear { if autoExpandVisible { isVisible = false } }
    .onChange(of: autoExpandVisible) { newValue in
      if !newValue { isVisible = false }
    }
  }
}

private struct TimelineMarker: View {
  let position: Int
  let timeText: String
  let isFirst: Bool
  let isLast: Bool

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      Text(String(position))
        .font(.caption.bold())
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule()
            .fill(Color.accentColor)
        )

      Text(timeText)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Color.accentColor)

      VStack(spacing: 0) {
        Rectangle()
          .fill(Color.secondary.opacity(isFirst ? 0 : 0.25))
          .frame(width: 2)
          .frame(height: isFirst ? 0 : 12)

        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.accentColor)
          .frame(width: 3, height: 12)

        Rectangle()
          .fill(Color.secondary.opacity(isLast ? 0 : 0.25))
          .frame(width: 2)
          .frame(maxHeight: .infinity)
      }
    }
    .frame(width: 72, alignment: .top)
  }
}

private struct ConversationTurnHeaderRow: View {
  let turn: ConversationTurn
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let allowToggle: Bool
  let onToggle: () -> Void
  let onJump: () -> Void

  var body: some View {
    Button(action: onJump) {
      HStack {
        Text(turn.actorSummary(using: branding.displayName))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
        Spacer()
        Button(action: onToggle) {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!allowToggle)
      }
      .padding(12)
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 0,
          topTrailingRadius: 14
        )
        .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 0,
          topTrailingRadius: 14
        )
        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .hoverHand()
  }
}

private struct TurnBodyHeightKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { max($0, $1) })
  }
}

private struct TurnHeaderHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct ConversationCard: View {
  let turn: ConversationTurn
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let toggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isExpanded {
        expandedBody
      } else {
        collapsedBody
      }
    }
    .padding(16)
    .background(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 0
      )
      .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 14
      )
      .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    )
  }

  @ViewBuilder
  private var collapsedBody: some View {
    if let preview = turn.previewText, !preview.isEmpty {
      Text(preview)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text("Tap to view details")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var expandedBody: some View {
    if let user = turn.userMessage {
      EventSegmentView(event: user, branding: branding)
    }

    ForEach(Array(turn.outputs.enumerated()), id: \.offset) { index, event in
      if index > 0 || turn.userMessage != nil {
        Divider()
      }
      EventSegmentView(event: event, branding: branding)
    }
  }
}

private struct EventSegmentView: View {
  let event: TimelineEvent
  let branding: SessionSourceBranding
  @State private var isHover = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 6) {
        Label {
          Text(roleTitle)
            .font(.subheadline.weight(.semibold))
        } icon: {
          Image(systemName: roleIcon)
            .foregroundStyle(roleColor)
        }
        .labelStyle(.titleAndIcon)

        if let title = event.title, !title.isEmpty, event.actor != .user, title != roleTitle {
          Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let text = event.text, !text.isEmpty {
          if event.visibilityKind == .user {
            CollapsibleUserText(text: text, lineLimit: 10)
          } else {
            Text(text)
              .textSelection(.enabled)
              .font(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if !event.attachments.isEmpty {
          HStack(spacing: 6) {
            Image(systemName: "photo")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("\(event.attachments.count) image\(event.attachments.count == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let metadata = event.metadata, !metadata.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(metadata.keys.sorted(), id: \.self) { key in
              if let value = metadata[key], !value.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                  Text(key + ":")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(value)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }

      HStack(spacing: 6) {
        if isHover {
          Button(action: copyEvent) {
            Image(systemName: "doc.on.doc")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Copy")
          }
          .buttonStyle(.plain)
          .help("Copy")
          .transition(.opacity)
        }
        if event.repeatCount > 1 {
          Text("×\(event.repeatCount)")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              Capsule().fill(Color.secondary.opacity(0.15))
            )
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
      .padding(.trailing, 6)
    }
    .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { isHover = inside } }
  }

  private func copyEvent() {
    var lines: [String] = []
    // Role/title
    lines.append("**\(roleTitle)**")
    if let title = event.title, !title.isEmpty, event.actor != .user {
      lines.append(title)
    }
    // Body
    if let text = event.text, !text.isEmpty { lines.append(text) }
    if !event.attachments.isEmpty {
      lines.append("Images: \(event.attachments.count)")
    }
    // Metadata
    if let metadata = event.metadata, !metadata.isEmpty {
      for key in metadata.keys.sorted() {
        if let value = metadata[key], !value.isEmpty { lines.append("- \(key): \(value)") }
      }
    }
    let s = lines.joined(separator: "\n")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
  }

  private var roleTitle: String {
    switch event.visibilityKind {
    case .user: return "User"
    case .assistant: return branding.displayName
    case .tool: return "Tool"
    case .reasoning: return "Reasoning"
    case .tokenUsage: return "Token Usage"
    case .environmentContext: return "Environment"
    case .turnContext: return "Turn Context"
    case .sessionMeta: return "Session Meta"
    case .taskInstructions: return "Task Instructions"
    case .compaction: return "Compaction"
    case .turnAborted: return "Turn Aborted"
    case .ghostSnapshot: return "Ghost Snapshot"
    case .infoOther: return "Info"
    }
  }

  private var roleIcon: String {
    switch event.visibilityKind {
    case .user: return "person.fill"
    case .assistant: return branding.symbolName
    case .tool: return "hammer.fill"
    case .reasoning: return "brain"
    case .tokenUsage: return "gauge"
    case .environmentContext: return "macwindow"
    case .turnContext: return "arrow.triangle.2.circlepath"
    case .sessionMeta: return "info.circle"
    case .taskInstructions: return "list.bullet.rectangle"
    case .compaction: return "arrow.down.right.and.arrow.up.left"
    case .turnAborted: return "exclamationmark.triangle"
    case .ghostSnapshot: return "camera"
    case .infoOther: return "info.circle"
    }
  }

  private var roleColor: Color {
    switch event.visibilityKind {
    case .user: return .accentColor
    case .assistant: return branding.iconColor
    case .tool: return .yellow
    case .reasoning: return .purple
    case .tokenUsage: return .orange
    case .environmentContext, .turnContext, .sessionMeta, .taskInstructions, .compaction, .ghostSnapshot, .infoOther:
      return .gray
    case .turnAborted: return .red
    }
  }
}

private struct CollapsibleUserText: View {
  let text: String
  let lineLimit: Int
  @State private var isExpanded = false

  var body: some View {
    let previewInfo = linePreview(text, limit: lineLimit)
    let preview = previewInfo.text
    let truncated = previewInfo.truncated
    VStack(alignment: .leading, spacing: 6) {
      Text(isExpanded ? text : preview)
        .textSelection(.enabled)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)

      if truncated {
        Button(action: { isExpanded.toggle() }) {
          Image(systemName: "ellipsis")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .hoverHand()
      }
    }
  }

  private func linePreview(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
    guard limit > 0 else { return ("", !text.isEmpty) }
    var newlineCount = 0
    for index in text.indices {
      if text[index] == "\n" {
        newlineCount += 1
        if newlineCount == limit {
          return (String(text[..<index]), true)
        }
      }
    }
    return (text, false)
  }
}

@MainActor
private final class TimelineLayoutStore: ObservableObject {
  @Published var headerHeight: CGFloat = 44
  @Published var bodyHeights: [String: CGFloat] = [:]
  @Published var visibleRange: ClosedRange<Int>? = nil

  private(set) var order: [String] = []
  private var indexById: [String: Int] = [:]

  func updateOrder(_ ids: [String]) {
    guard ids != order else { return }
    order = ids
    indexById = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    visibleRange = nil
  }

  func updateBodyHeights(_ values: [String: CGFloat]) {
    var changed = false
    for (id, height) in values {
      guard height > 0 else { continue }
      if bodyHeights[id] != height {
        bodyHeights[id] = height
        changed = true
      }
    }
    if changed == false {
      return
    }
  }

  func messageContentHeight() -> CGFloat {
    messageHeights().reduce(0, +)
  }

  func markerContentHeight() -> CGFloat {
    guard !order.isEmpty else { return 0 }
    return markerHeights().reduce(0, +)
  }

  func messageOffset(for id: String) -> CGFloat? {
    guard let index = indexById[id] else { return nil }
    let heights = messageHeights()
    guard index <= heights.count else { return nil }
    return heights.prefix(index).reduce(0, +)
  }

  func updateVisibleRange(for offset: CGFloat, viewportHeight: CGFloat) {
    let heights = messageHeights()
    guard !heights.isEmpty else {
      visibleRange = nil
      return
    }
    let prefix = prefixSums(heights)
    let start = indexForOffset(offset, prefix: prefix, count: heights.count)
    let end = indexForOffset(offset + viewportHeight, prefix: prefix, count: heights.count)
    let range = start...min(end, heights.count - 1)
    if range != visibleRange {
      visibleRange = range
    }
  }

  func markerOffset(forMessageOffset offset: CGFloat) -> CGFloat? {
    let messageHeights = messageHeights()
    guard !messageHeights.isEmpty else { return nil }
    let messagePrefix = prefixSums(messageHeights)
    let index = indexForOffset(offset, prefix: messagePrefix, count: messageHeights.count)
    let rawHeaderY = messagePrefix[index] - offset
    var headerY = max(rawHeaderY, 0)
    if index + 1 < messagePrefix.count {
      let nextHeaderY = messagePrefix[index + 1] - offset
      let pushUpLimit = nextHeaderY - headerHeight
      headerY = min(headerY, pushUpLimit)
    }

    let markerHeights = markerHeights()
    let markerPrefix = prefixSums(markerHeights)
    guard index < markerPrefix.count else { return nil }
    return markerPrefix[index] - headerY
  }

  func messageOffset(forMarkerOffset offset: CGFloat) -> CGFloat? {
    let messageHeights = messageHeights()
    let markerHeights = markerHeights()
    guard !messageHeights.isEmpty, !markerHeights.isEmpty else { return nil }
    let markerPrefix = prefixSums(markerHeights)
    let index = indexForOffset(offset, prefix: markerPrefix, count: markerHeights.count)
    let messagePrefix = prefixSums(messageHeights)
    let headerY = markerPrefix[index] - offset
    if headerY < 0, index + 1 < messagePrefix.count {
      return messagePrefix[index + 1] - headerHeight - headerY
    }
    return messagePrefix[index] - headerY
  }

  private func messageHeights() -> [CGFloat] {
    order.map { headerHeight + (bodyHeights[$0] ?? 0) }
  }

  private func markerHeight(at index: Int) -> CGFloat {
    guard order.indices.contains(index) else { return headerHeight }
    let body = bodyHeights[order[index]] ?? 0
    let visible = visibleRange?.contains(index) ?? true
    return headerHeight + (visible ? body : 0)
  }

  private func markerHeights() -> [CGFloat] {
    order.indices.map { markerHeight(at: $0) }
  }

  private func prefixSums(_ heights: [CGFloat]) -> [CGFloat] {
    var prefix = Array(repeating: CGFloat(0), count: heights.count + 1)
    for i in heights.indices {
      prefix[i + 1] = prefix[i] + heights[i]
    }
    return prefix
  }

  private func indexForOffset(_ offset: CGFloat, prefix: [CGFloat], count: Int) -> Int {
    if count <= 1 { return 0 }
    var low = 0
    var high = count
    while low + 1 < high {
      let mid = (low + high) / 2
      if prefix[mid] <= offset {
        low = mid
      } else {
        high = mid
      }
    }
    return min(max(low, 0), count - 1)
  }
}

private struct ScrollViewAccessor: NSViewRepresentable {
  let onResolve: (NSScrollView) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onResolve: onResolve)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.attach(to: nsView)
  }

  final class Coordinator {
    private let onResolve: (NSScrollView) -> Void
    private weak var lastResolved: NSScrollView?
    private var pendingWork: DispatchWorkItem?

    init(onResolve: @escaping (NSScrollView) -> Void) {
      self.onResolve = onResolve
    }

    func attach(to view: NSView) {
      scheduleResolve(from: view)
    }

    private func scheduleResolve(from view: NSView) {
      pendingWork?.cancel()
      let work = DispatchWorkItem { [weak self, weak view] in
        guard let self, let view else { return }
        if let scrollView = self.findScrollView(from: view) {
          if self.lastResolved !== scrollView {
            self.lastResolved = scrollView
            self.onResolve(scrollView)
          }
          return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak view] in
          guard let self, let view else { return }
          self.scheduleResolve(from: view)
        }
      }
      pendingWork = work
      DispatchQueue.main.async(execute: work)
    }

    private func findScrollView(from view: NSView) -> NSScrollView? {
      if let scrollView = view.enclosingScrollView { return scrollView }
      var current = view.superview
      while let candidate = current {
        if let scrollView = candidate as? NSScrollView { return scrollView }
        if let enclosing = candidate.enclosingScrollView { return enclosing }
        current = candidate.superview
      }
      return nil
    }
  }
}


#Preview {
  ConversationTimelinePreview()
}

private struct ConversationTimelinePreview: View {
  @State private var expanded: Set<String> = []

  private var sampleTurn: ConversationTurn {
    let now = Date()
    let userEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now,
      actor: .user,
      visibilityKind: .user,
      title: nil,
      text: "Please outline a multi-tenant design for the MCP Mate project.",
      metadata: nil
    )
    let infoEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now.addingTimeInterval(6),
      actor: .info,
      visibilityKind: .turnContext,
      title: "Context Updated",
      text: "model: gpt-5.2-codex\npolicy: on-request",
      metadata: nil,
      repeatCount: 3
    )
    let assistantEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now.addingTimeInterval(12),
      actor: .assistant,
      visibilityKind: .assistant,
      title: nil,
      text: "Certainly. Here are the key considerations for a multi-tenant design...",
      metadata: nil
    )
    return ConversationTurn(
      id: UUID().uuidString,
      timestamp: now,
      userMessage: userEvent,
      outputs: [infoEvent, assistantEvent]
    )
  }

  var body: some View {
    ConversationTimelineView(
      turns: [sampleTurn],
      expandedTurnIDs: $expanded,
            branding: SessionSource.codexLocal.branding
    )
    .padding()
    .frame(width: 540)
  }
}

// Provide a handy pointer extension to keep cursor behavior consistent on clickable areas
extension View {
  func hoverHand() -> some View {
    self.onHover { inside in
      if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
  }
}
