import SwiftUI
import AppKit

struct UsageStatusControl: View {
  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  var preferences: SessionPreferencesStore
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  @State private var showPopover = false
  @State private var isHovering = false
  @State private var hoverPhase: Double = 0
  @State private var hoverLockoutActive = false
  @State private var didAutoRefreshCodex = false

  private static let hoverAnimation = Animation.easeInOut(duration: 0.2)

  private static let countdownFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    formatter.includesTimeRemainingPhrase = false
    return formatter
  }()

  private var countdownFormatter: DateComponentsFormatter { Self.countdownFormatter }

  var body: some View {
    let referenceDate = Date()
    return Group {
      if shouldHideAllProviders {
        EmptyView()
      } else {
        content(referenceDate: referenceDate)
      }
    }
  }

  @ViewBuilder
  private func content(referenceDate: Date) -> some View {
    HStack(spacing: 8) {
      let enabledProviders = orderedEnabledProviders()
      let rows = providerRows(at: referenceDate, enabledProviders: enabledProviders)
      let ringStates = enabledProviders.map { ringState(for: $0, relativeTo: referenceDate) }

      Button {
        showPopover.toggle()
      } label: {
        HStack(spacing: isHovering ? 8 : 0) {
          TripleUsageDonutView(
            states: ringStates
          )
          VStack(alignment: .leading, spacing: -1.5) {
            if rows.isEmpty {
              Text("Usage unavailable")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            } else {
              ForEach(rows, id: \.provider) { row in
                Text(row.text)
                  .font(.system(size: 8))
                  .lineLimit(1)
              }
            }
          }
          .opacity(isHovering ? 1 : 0)
          .frame(maxWidth: isHovering ? .infinity : 0, alignment: .leading)
          .clipped()
        }
        .animation(Self.hoverAnimation, value: isHovering)
        .padding(.leading, 4)
        .padding(.vertical, 4)
        .padding(.trailing, isHovering ? 8 : 4)
        .contentShape(Capsule(style: .continuous))
      }
      .buttonStyle(.plain)
      .help("View usage snapshots for Codex, Claude, and Gemini")
      .focusable(false)
      .onHover { hovering in
        if hovering {
          guard !hoverLockoutActive else { return }
          withAnimation(Self.hoverAnimation) {
            isHovering = true
            hoverPhase = 1
          }
        } else {
          if isHovering {
            hoverLockoutActive = true
          }
          withAnimation(Self.hoverAnimation) {
            isHovering = false
            hoverPhase = 0
          }
        }
      }
      .onAppear { autoRefreshCodexIfNeeded() }
      .onChange(of: snapshots[.codex]?.updatedAt ?? nil) { _ in
        autoRefreshCodexIfNeeded()
      }
      .onChange(of: showPopover) { isPresented in
        if isPresented {
          refreshAllProviders()
        }
      }
      .onAnimationCompleted(for: hoverPhase) {
        guard hoverPhase == 0 else { return }
        hoverLockoutActive = false
      }
      .onDisappear {
        hoverLockoutActive = false
        hoverPhase = 0
      }
      .popover(isPresented: $showPopover, arrowEdge: .top) {
        let enabledProviders = orderedEnabledProviders()
        UsageStatusPopover(
          snapshots: snapshots,
          enabledProviders: enabledProviders,
          selectedProvider: $selectedProvider,
          onRequestRefresh: onRequestRefresh
        )
      }
    }
  }

  private var shouldHideAllProviders: Bool {
    let enabledProviders = orderedEnabledProviders()
    guard !enabledProviders.isEmpty else { return true }
    return enabledProviders.allSatisfy { provider in
      guard let snapshot = snapshots[provider] else { return true }
      return snapshot.origin == .thirdParty
    }
  }

  private func providerRows(
    at date: Date,
    enabledProviders: [UsageProviderKind]
  ) -> [(provider: UsageProviderKind, text: String)] {
    enabledProviders.compactMap { provider in
      guard let snapshot = snapshots[provider] else { return nil }
      if snapshot.origin == .thirdParty {
        return (provider, "\(provider.displayName) · Custom provider (usage unavailable)")
      }
      let urgent = snapshot.urgentMetric(relativeTo: date)
      switch snapshot.availability {
      case .ready:
        let percent = urgent?.percentText ?? "—"
        let info: String
        if let urgent = urgent, let reset = urgent.resetDate {
          info =
            resetCountdown(from: reset, kind: urgent.kind) ?? resetFormatter.string(from: reset)
        } else if let minutes = urgent?.fallbackWindowMinutes {
          info = "\(minutes)m window"
        } else {
          info = "—"
        }
        return (provider, "\(provider.displayName) · \(percent) · \(info)")
      case .empty:
        return (provider, "\(provider.displayName) · Not available")
      case .comingSoon:
        return nil
      }
    }
  }

  private func autoRefreshCodexIfNeeded() {
    guard preferences.isCLIEnabled(.codex) else { return }
    let shouldRefresh: Bool = {
      guard let snapshot = snapshots[.codex] else { return true }
      if snapshot.origin == .thirdParty { return false }
      if snapshot.availability == .ready { return false }
      return snapshot.updatedAt == nil
    }()

    if shouldRefresh {
      // Only trigger refresh if we haven't already done so
      guard !didAutoRefreshCodex else { return }
      didAutoRefreshCodex = true
      onRequestRefresh(.codex)
    } else {
      // Reset flag when data is available, allowing future auto-refresh if data becomes unavailable again
      didAutoRefreshCodex = false
    }
  }

  private func ringState(for provider: UsageProviderKind, relativeTo date: Date) -> UsageRingState {
    let color = providerColor(provider)
    guard let snapshot = snapshots[provider] else {
      return UsageRingState(progress: nil, baseColor: color, disabled: false)
    }
    if snapshot.origin == .thirdParty {
      return UsageRingState(progress: nil, baseColor: color, disabled: true)
    }
    guard snapshot.availability == .ready else {
      return UsageRingState(progress: nil, baseColor: color, disabled: false)
    }
    let urgentMetric = snapshot.urgentMetric(relativeTo: date)
    return UsageRingState(
      progress: urgentMetric?.progress,
      baseColor: color,
      healthState: urgentMetric?.healthState(relativeTo: date),
      disabled: false
    )
  }

  private func refreshAllProviders() {
    for provider in orderedEnabledProviders() {
      onRequestRefresh(provider)
    }
  }

  private func providerColor(_ provider: UsageProviderKind) -> Color {
    switch provider {
    case .codex:
      return Color.accentColor
    case .claude:
      return Color(nsColor: .systemPurple)
    case .gemini:
      return Color(nsColor: .systemTeal)
    }
  }

  private func orderedEnabledProviders() -> [UsageProviderKind] {
    let ordered: [UsageProviderKind] = [.gemini, .claude, .codex]
    return ordered.filter { preferences.isCLIEnabled($0.baseKind) }
  }

  private static let resetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
    return formatter
  }()

  private var resetFormatter: DateFormatter { Self.resetFormatter }

  private func resetCountdown(from date: Date, kind: UsageMetricSnapshot.Kind) -> String? {
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else {
      return kind == .sessionExpiry ? "expired" : "reset"
    }
    if let formatted = countdownFormatter.string(from: interval) {
      let verb = kind == .sessionExpiry ? "expires in" : "resets in"
      return "\(verb) \(formatted)"
    }
    return nil
  }
}

private struct AnimationCompletionObserverModifier<Value>: AnimatableModifier
where Value: VectorArithmetic {
  var animatableData: Value {
    didSet { notifyIfFinished() }
  }

  private let targetValue: Value
  private let completion: () -> Void

  init(observedValue: Value, completion: @escaping () -> Void) {
    self.animatableData = observedValue
    self.targetValue = observedValue
    self.completion = completion
  }

  func body(content: Content) -> some View {
    content
  }

  private func notifyIfFinished() {
    guard animatableData == targetValue else { return }
    DispatchQueue.main.async { completion() }
  }
}

extension View {
  fileprivate func onAnimationCompleted<Value: VectorArithmetic>(
    for value: Value,
    completion: @escaping () -> Void
  ) -> some View {
    modifier(AnimationCompletionObserverModifier(observedValue: value, completion: completion))
  }
}

private struct UsageStatusPopover: View {
  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  var enabledProviders: [UsageProviderKind]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  @State private var didTriggerClaudeAutoRefresh = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      content(referenceDate: context.date)
    }
    .padding(16)
    .frame(width: 300)
    .focusable(false)
    .onAppear { maybeTriggerClaudeAutoRefresh(now: Date()) }
    .onChange(of: snapshots[.claude]?.updatedAt ?? nil) { _ in
      maybeTriggerClaudeAutoRefresh(now: Date())
    }
    .onDisappear { didTriggerClaudeAutoRefresh = false }
  }

  @ViewBuilder
  private func content(referenceDate: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(enabledProviders.enumerated()), id: \.element.id) { index, provider in
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            providerIcon(for: provider)
            if let snapshot = snapshots[provider] {
              UsageProviderTitleView(
                title: snapshot.title,
                badge: snapshot.titleBadge,
                provider: provider
              )
            } else {
              Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
            }
            Spacer()
          }

          if let snapshot = snapshots[provider] {
            UsageSnapshotView(
              referenceDate: referenceDate,
              snapshot: snapshot,
              onAction: { onRequestRefresh(provider) }
            )
          } else {
            Text("No usage data available")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        if index < enabledProviders.count - 1 {
          Divider()
            .padding(.vertical, 6)
        }
      }
    }
  }

  private func maybeTriggerClaudeAutoRefresh(now: Date) {
    guard enabledProviders.contains(.claude) else { return }
    guard !didTriggerClaudeAutoRefresh else { return }
    guard let claude = snapshots[.claude],
      claude.origin == .builtin,
      claude.availability == .ready
    else { return }

    let threshold: TimeInterval = 5 * 60
    let soonest = claude.metrics
      .filter { $0.kind == .fiveHour || $0.kind == .weekly }
      .compactMap { metric -> TimeInterval? in
        guard let reset = metric.resetDate else { return nil }
        let interval = reset.timeIntervalSince(now)
        return interval > 0 ? interval : nil
      }
      .min()

    guard let remaining = soonest, remaining <= threshold else { return }
    didTriggerClaudeAutoRefresh = true
    onRequestRefresh(.claude)
  }

  @ViewBuilder
  private func providerIcon(for provider: UsageProviderKind) -> some View {
    ProviderIconView(provider: provider, size: 12, cornerRadius: 2)
  }
}

private struct UsageProviderTitleView: View {
  var title: String
  var badge: String?
  var provider: UsageProviderKind

  @Environment(\.openURL) private var openURL

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .padding(.trailing, badge == nil ? 0 : badgeWidth)

      if let badge, !badge.isEmpty {
        Text(badge)
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
          .baselineOffset(7)
          .padding(.leading, 4)
          .frame(width: badgeWidth, alignment: .leading)
          .offset(y: -1)
          .onTapGesture {
            guard let url = usageURL else { return }
            openURL(url)
          }
          .onHover { hovering in
            guard usageURL != nil else { return }
            if hovering {
              NSCursor.pointingHand.set()
            } else {
              NSCursor.arrow.set()
            }
          }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var usageURL: URL? {
    switch provider {
    case .codex:
      return URL(string: "https://chatgpt.com/codex/settings/usage")
    case .claude:
      return URL(string: "https://claude.ai/settings/usage")
    case .gemini:
      return nil
    }
  }

  private var badgeWidth: CGFloat { 44 }
}

private struct UsageSnapshotView: View {
  var referenceDate: Date
  var snapshot: UsageProviderSnapshot
  var onAction: (() -> Void)?

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if snapshot.origin == .thirdParty {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Usage data isn't available while a custom provider is selected. Switch Active Provider back to (Built-in) to restore usage."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        .opacity(0.75)
      } else if snapshot.availability == .ready {
        ForEach(snapshot.metrics.filter { $0.kind != .snapshot && $0.kind != .context }) { metric in
          let state = MetricDisplayState(metric: metric, referenceDate: referenceDate)
          UsageMetricRowView(metric: metric, state: state, now: referenceDate)
        }

        HStack {
          Spacer(minLength: 0)
          Label(updatedLabel(reference: referenceDate), systemImage: "clock.arrow.circlepath")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Text(snapshot.statusMessage ?? "No usage data yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)

          if let action = snapshot.action {
            let label = actionLabel(for: action)
            Button {
              onAction?()
            } label: {
              Label(label.text, systemImage: label.icon)
                .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
        }
      }
    }
    .focusable(false)
  }

  private func updatedLabel(reference: Date) -> String {
    if let updated = snapshot.updatedAt {
      let relative = Self.relativeFormatter.localizedString(for: updated, relativeTo: reference)
      return "Updated " + relative
    }
    return "Waiting for usage data"
  }

  private func actionLabel(for action: UsageProviderSnapshot.Action) -> (text: String, icon: String)
  {
    switch action {
    case .refresh:
      return ("Load usage", "arrow.clockwise")
    case .authorizeKeychain:
      return ("Grant access", "lock.open")
    }
  }
}

private struct MetricDisplayState {
  var progress: Double?
  var usageText: String?
  var percentText: String?
  var resetText: String

  init(metric: UsageMetricSnapshot, referenceDate: Date) {
    let expired = metric.resetDate.map { $0 <= referenceDate } ?? false
    if expired {
      progress = metric.progress != nil ? 0 : nil
      percentText = metric.percentText != nil ? "0%" : nil
      if metric.kind == .fiveHour {
        usageText = "No usage since reset"
      } else {
        usageText = metric.usageText
      }
      if metric.kind == .fiveHour {
        resetText = "Reset"
      } else {
        resetText = ""
      }
    } else {
      progress = metric.progress
      percentText = metric.percentText
      // Real-time calculation of remaining time using current referenceDate
      usageText = Self.remainingText(for: metric, referenceDate: referenceDate)
      resetText = Self.resetDescription(for: metric)
    }
  }

  private static func remainingText(for metric: UsageMetricSnapshot, referenceDate: Date) -> String?
  {
    guard let resetDate = metric.resetDate else {
      return metric.usageText  // Fallback to cached text if no reset date
    }

    let remaining = resetDate.timeIntervalSince(referenceDate)
    if remaining <= 0 {
      return metric.kind == .sessionExpiry ? "Expired" : "Reset"
    }

    let minutes = Int(remaining / 60)
    let hours = minutes / 60
    let days = hours / 24

    switch metric.kind {
    case .fiveHour:
      let mins = minutes % 60
      if hours > 0 {
        return "\(hours)h \(mins)m remaining"
      } else {
        return "\(mins)m remaining"
      }

    case .weekly:
      let remainingHours = hours % 24
      if days > 0 {
        if remainingHours > 0 {
          return "\(days)d \(remainingHours)h remaining"
        } else {
          return "\(days)d remaining"
        }
      } else if hours > 0 {
        let mins = minutes % 60
        return "\(hours)h \(mins)m remaining"
      } else {
        return "\(minutes)m remaining"
      }

    case .sessionExpiry, .quota:
      let mins = minutes % 60
      if hours > 0 {
        return "\(hours)h \(mins)m remaining"
      } else {
        return "\(mins)m remaining"
      }

    case .context, .snapshot:
      return metric.usageText
    }
  }

  private static func resetDescription(for metric: UsageMetricSnapshot) -> String {
    if let date = metric.resetDate {
      let prefix = metric.kind == .sessionExpiry ? "Expires at " : ""
      return prefix + Self.resetFormatter.string(from: date)
    }
    if let minutes = metric.fallbackWindowMinutes {
      if minutes >= 60 {
        return String(format: "%.1fh window", Double(minutes) / 60.0)
      }
      return "\(minutes) min window"
    }
    return ""
  }

  private static let resetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
    return formatter
  }()
}

private struct UsageMetricRowView: View {
  var metric: UsageMetricSnapshot
  var state: MetricDisplayState
  var now: Date = Date()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(metric.label)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(state.resetText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if let progress = state.progress {
        UsageProgressBar(
          progress: progress,
          healthState: metric.healthState(relativeTo: now)
        )
        .frame(height: 4)
      }

      HStack {
        Text(state.usageText ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(state.percentText ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct UsageProgressBar: View {
  var progress: Double
  var healthState: UsageMetricSnapshot.HealthState

  var body: some View {
    GeometryReader { geo in
      let clamped = max(0, min(progress, 1))
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(Color.secondary.opacity(0.2))
        if clamped <= 0.002 {
          Circle()
            .fill(barColor)
            .frame(width: 6, height: 6)
        } else {
          Capsule(style: .continuous)
            .fill(barColor)
            .frame(width: max(6, geo.size.width * CGFloat(clamped)))
        }
      }
    }
  }

  private var barColor: Color {
    switch healthState {
    case .healthy:
      return .accentColor  // Blue - usage is slower than time
    case .warning:
      return .orange       // Orange - usage is faster than time
    case .unknown:
      return .accentColor  // Default blue
    }
  }
}

struct DarkModeInvertModifier: ViewModifier {
  var active: Bool

  func body(content: Content) -> some View {
    if active {
      content.colorInvert()
    } else {
      content
    }
  }
}
