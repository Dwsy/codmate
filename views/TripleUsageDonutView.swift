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
  public var outerState: UsageRingState
  public var middleState: UsageRingState
  public var innerState: UsageRingState
  public var trackColor: Color

  public init(
    outerState: UsageRingState,
    middleState: UsageRingState,
    innerState: UsageRingState,
    trackColor: Color = .secondary
  ) {
    self.outerState = outerState
    self.middleState = middleState
    self.innerState = innerState
    self.trackColor = trackColor
  }

  public var body: some View {
    ZStack {
      Circle()
        .stroke(trackColor.opacity(0.25), lineWidth: 1.5)
        .frame(width: 22, height: 22)
      ring(for: outerState, lineWidth: 1.5, size: 22)

      Circle()
        .stroke(trackColor.opacity(0.22), lineWidth: 1.5)
        .frame(width: 16, height: 16)
      ring(for: middleState, lineWidth: 1.5, size: 16)

      Circle()
        .stroke(trackColor.opacity(0.2), lineWidth: 1.5)
        .frame(width: 10, height: 10)
      ring(for: innerState, lineWidth: 1.5, size: 10)
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
}
