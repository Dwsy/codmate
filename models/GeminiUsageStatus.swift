import Foundation

struct GeminiUsageStatus: Equatable {
  struct Bucket: Equatable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remainingAmount: String?
    let resetTime: Date?
  }

  let updatedAt: Date
  let projectId: String?
  let buckets: [Bucket]

  func asProviderSnapshot() -> UsageProviderSnapshot {
    // Filter buckets to only show models that have been used (remainingFraction < 1.0)
    let usedBuckets = buckets.filter { bucket in
      guard let remaining = bucket.remainingFraction else { return false }
      return remaining < 1.0
    }

    let metrics: [UsageMetricSnapshot] = usedBuckets.map { bucket in
      let remaining = bucket.remainingFraction?.clamped01()
      let percentText: String? = {
        guard let remaining else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: remaining))
          ?? String(format: "%.0f%%", remaining * 100)
      }()

      let labelParts = [bucket.modelId, bucket.tokenType].compactMap { $0 }.filter { !$0.isEmpty }
      let label = labelParts.first ?? "Usage"

      let usageText: String? = {
        if let amount = bucket.remainingAmount, !amount.isEmpty {
          return "Remaining \(amount)"
        }
        return nil
      }()

      // Debug: Log resetTime
      if let resetTime = bucket.resetTime {
        NSLog("[GeminiUsage] Creating metric for \(label), resetTime: \(resetTime)")
      } else {
        NSLog("[GeminiUsage] Creating metric for \(label), resetTime is nil!")
      }

      return UsageMetricSnapshot(
        kind: .quota,
        label: label,
        usageText: usageText,
        percentText: percentText,
        progress: remaining,
        resetDate: bucket.resetTime,
        fallbackWindowMinutes: nil
      )
    }

    let availability: UsageProviderSnapshot.Availability = metrics.isEmpty ? .empty : .ready

    // Count total models with quota
    let totalModels = buckets.count
    let statusMessage: String? = {
      if availability == .empty {
        if totalModels > 0 {
          return "No models used yet. Quotas available for \(totalModels) models."
        }
        return "No Gemini usage data."
      }
      return nil
    }()

    return UsageProviderSnapshot(
      provider: .gemini,
      title: UsageProviderKind.gemini.displayName,
      availability: availability,
      metrics: metrics,
      updatedAt: updatedAt,
      statusMessage: statusMessage,
      origin: .builtin
    )
  }
}

private extension Double {
  func clamped01() -> Double { max(0, min(self, 1)) }
}
