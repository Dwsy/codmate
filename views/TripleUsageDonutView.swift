import SwiftUI

public struct UsageRingState {
  public var progress: Double?
  public var baseColor: Color
  public var healthState: UsageMetricSnapshot.HealthState?
  public var disabled: Bool

  public init(
    progress: Double? = nil,
    baseColor: Color,
    healthState: UsageMetricSnapshot.HealthState? = nil,
    disabled: Bool
  ) {
    self.progress = progress
    self.baseColor = baseColor
    self.healthState = healthState
    self.disabled = disabled
  }

  public var effectiveColor: Color {
    if disabled {
      return Color(nsColor: .quaternaryLabelColor)
    }

    // Apply health state color if available
    if let state = healthState {
      switch state {
      case .healthy:
        return baseColor  // Use provider color
      case .warning:
        return .orange    // Warning color
      case .unknown:
        return baseColor  // Default to provider color
      }
    }

    return baseColor
  }
}

public struct TripleUsageDonutView: View {
  public var states: [UsageRingState]
  public var trackColor: Color

  public init(
    states: [UsageRingState],
    trackColor: Color = .secondary
  ) {
    self.states = states
    self.trackColor = trackColor
  }

  public var body: some View {
    let layout = ringLayout(for: states.count)
    return ZStack {
      ForEach(Array(states.enumerated()), id: \.offset) { index, state in
        let size = layout.sizes[index]
        let lineWidth = layout.lineWidth
        let opacity = layout.trackOpacities[index]
        Circle()
          .stroke(trackColor.opacity(opacity), lineWidth: lineWidth)
          .frame(width: size, height: size)
        ring(for: state, lineWidth: lineWidth, size: size)
      }
    }
  }

  @ViewBuilder
  private func ring(for state: UsageRingState, lineWidth: CGFloat, size: CGFloat) -> some View {
    if state.disabled {
      Circle()
        .stroke(Color(nsColor: .quaternaryLabelColor), lineWidth: lineWidth)
        .frame(width: size, height: size)
    } else if let progress = state.progress {
      Circle()
        .trim(from: 0, to: CGFloat(max(0, min(progress, 1))))
        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .foregroundStyle(state.effectiveColor)
        .rotationEffect(.degrees(-90))
        .frame(width: size, height: size)
    }
  }

  private func ringLayout(for count: Int) -> (sizes: [CGFloat], lineWidth: CGFloat, trackOpacities: [Double]) {
    let outerDiameter: CGFloat = 22
    let outerRadius = outerDiameter / 2
    let innerClearRadius: CGFloat = 4.25
    let availableSpan = max(outerRadius - innerClearRadius, 1)
    let ringCount = max(count, 1)
    let units = CGFloat(ringCount * 2 - 1)
    let unit = availableSpan / units
    let minLineWidth: CGFloat = 1.2
    let maxLineWidth: CGFloat = 2.8
    let lineWidth = min(maxLineWidth, max(minLineWidth, unit))
    let gap = lineWidth

    var sizes: [CGFloat] = []
    var opacities: [Double] = []
    let startRadius = outerRadius - lineWidth / 2
    for index in 0..<ringCount {
      let radius = startRadius - CGFloat(index) * (lineWidth + gap)
      sizes.append(max(0, radius * 2))
      opacities.append(max(0.12, 0.25 - (Double(index) * 0.03)))
    }

    return (sizes: sizes, lineWidth: lineWidth, trackOpacities: opacities)
  }
}
