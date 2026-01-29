import Foundation

struct PiUsageStatus: Equatable {
    let updatedAt: Date
    let version: String?
    let defaultProvider: String?
    let defaultModel: String?

    func asProviderSnapshot(titleBadge: String? = nil) -> UsageProviderSnapshot {
        // Pi does not have token quotas like Codex/Claude/Gemini
        // Show basic system status instead

        let metrics: [UsageMetricSnapshot] = [
            UsageMetricSnapshot(
                kind: .snapshot,
                label: "Version",
                usageText: version ?? "Unknown",
                percentText: nil,
                progress: 1.0,
                resetDate: nil,
                fallbackWindowMinutes: nil
            ),
            UsageMetricSnapshot(
                kind: .snapshot,
                label: "Default Provider",
                usageText: defaultProvider ?? "Auto",
                percentText: nil,
                progress: 1.0,
                resetDate: nil,
                fallbackWindowMinutes: nil
            ),
            UsageMetricSnapshot(
                kind: .snapshot,
                label: "Default Model",
                usageText: defaultModel ?? "Auto",
                percentText: nil,
                progress: 1.0,
                resetDate: nil,
                fallbackWindowMinutes: nil
            )
        ]

        return UsageProviderSnapshot(
            provider: .pi,
            title: UsageProviderKind.pi.displayName,
            titleBadge: titleBadge,
            availability: .ready,
            metrics: metrics,
            updatedAt: updatedAt,
            statusMessage: nil,
            origin: .builtin
        )
    }
}