import SwiftUI

public struct UsageRingState {
  public var progress: Double?
  public var color: Color
  public var disabled: Bool

  public init(progress: Double? = nil, color: Color, disabled: Bool) {
    self.progress = progress
    self.color = color
    self.disabled = disabled
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
        .stroke(trackColor.opacity(0.25), lineWidth: 2)
        .frame(width: 22, height: 22)
      ring(for: outerState, lineWidth: 2, size: 22)

      Circle()
        .stroke(trackColor.opacity(0.22), lineWidth: 2)
        .frame(width: 16, height: 16)
      ring(for: middleState, lineWidth: 2, size: 16)

      Circle()
        .stroke(trackColor.opacity(0.2), lineWidth: 2)
        .frame(width: 10, height: 10)
      ring(for: innerState, lineWidth: 2, size: 10)
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
        .foregroundStyle(state.color)
        .rotationEffect(.degrees(-90))
        .frame(width: size, height: size)
    }
  }
}
