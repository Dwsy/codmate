import Foundation

enum TimelineActor: Hashable {
    case user
    case assistant
    case tool
    case info
}

struct TimelineEvent: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let actor: TimelineActor
    let visibilityKind: MessageVisibilityKind
    let title: String?
    let text: String?
    let metadata: [String: String]?
    let attachments: [TimelineAttachment]
    let repeatCount: Int
    let callID: String?

    init(
        id: String,
        timestamp: Date,
        actor: TimelineActor,
        title: String?,
        text: String?,
        metadata: [String: String]?,
        repeatCount: Int = 1,
        attachments: [TimelineAttachment] = [],
        visibilityKind: MessageVisibilityKind? = nil,
        callID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.visibilityKind = visibilityKind
            ?? MessageVisibilityKind.infer(actor: actor, title: title, metadata: metadata)
        self.title = title
        self.text = text
        self.metadata = metadata
        self.attachments = attachments
        self.repeatCount = repeatCount
        self.callID = callID
    }

    func incrementingRepeatCount() -> TimelineEvent {
        TimelineEvent(
            id: id,
            timestamp: timestamp,
            actor: actor,
            title: title,
            text: text,
            metadata: metadata,
            repeatCount: repeatCount + 1,
            attachments: attachments,
            visibilityKind: visibilityKind,
            callID: callID
        )
    }
}

extension TimelineEvent {
    static let environmentContextTitle = "Environment Context"
}

// MARK: - Message visibility kinds and helpers
enum MessageVisibilityKind: String, CaseIterable, Identifiable {
    case user
    case assistant
    case tool
    case codeEdit
    case reasoning
    case tokenUsage
    case environmentContext
    case turnContext
    case infoOther

    var id: String { rawValue }

    var title: String {
        settingsLabel
    }

    var settingsLabel: String {
        switch self {
        case .user: return "User Message"
        case .assistant: return "Assistant Message"
        case .tool: return "Tool Invocation"
        case .codeEdit: return "Code Edit"
        case .reasoning: return "Reasoning"
        case .tokenUsage: return "Token Usage"
        case .environmentContext: return "Environment Context"
        case .turnContext: return "Turn Context"
        case .infoOther: return "Other Info"
        }
    }
}

extension MessageVisibilityKind {
    static let timelineDefault: Set<MessageVisibilityKind> = [
        .user, .assistant, .codeEdit, .reasoning
        // environment context is shown in its dedicated section by default
    ]

    static let markdownDefault: Set<MessageVisibilityKind> = [
        .user, .assistant
    ]

    static func coerced(from raw: String) -> MessageVisibilityKind? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = MessageVisibilityKind(rawValue: trimmed) { return exact }
        switch trimmed {
        case "syncing":
            return .turnContext
        case "environment":
            return .environmentContext
        case "code_edit":
            return .codeEdit
        case "codeedit":
            return .codeEdit
        default:
            return nil
        }
    }

    static func infer(
        actor: TimelineActor,
        title: String?,
        metadata: [String: String]?
    ) -> MessageVisibilityKind {
        if let mapped = mappedKind(rawType: nil, title: title, metadata: metadata) {
            return mapped
        }

        switch actor {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .tool:
            return .tool
        case .info:
            return .infoOther
        }
    }

    static func mappedKind(
        rawType: String?,
        title: String?,
        metadata: [String: String]?
    ) -> MessageVisibilityKind? {
        if let kind = kindFromToken(rawType) { return kind }
        if let kind = kindFromToken(metadata?["event_kind"]) { return kind }
        if let kind = kindFromToken(title) { return kind }
        return nil
    }

    static func kindFromToken(_ value: String?) -> MessageVisibilityKind? {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return nil }

        func matchesExact(_ tokens: [String]) -> Bool {
            tokens.contains(normalized)
        }

        func matchesContains(_ tokens: [String]) -> Bool {
            tokens.contains(where: { normalized.contains($0) })
        }

        if matchesExact(["user", "user message", "user msg"]) { return .user }
        if matchesExact(["assistant", "assistant message", "agent message"]) { return .assistant }
        if matchesContains(["tool call", "tool output", "tool result", "function call", "tool"]) {
            return .tool
        }
        if matchesContains(["code edit", "file edit", "apply patch", "applypatch", "codeedit", "patch"]) {
            return .codeEdit
        }
        if matchesContains(["token usage", "token count", "token"]) { return .tokenUsage }
        if matchesContains(["agent reasoning", "reasoning", "thinking", "thought"]) { return .reasoning }
        if matchesContains(["environment context"]) { return .environmentContext }
        if matchesExact(["context updated"]) || matchesContains(["turn context"]) { return .turnContext }
        if matchesContains(["collaboration mode", "permissions instructions", "permissions instruction"]) {
            return .infoOther
        }
        if matchesExact(["info", "warning", "error", "info other", "info_other"])
            || matchesContains(["system message", "system summary"]) { return .infoOther }

        return nil
    }

    private static func normalize(_ value: String?) -> String {
        guard let raw = value else { return "" }
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return "" }
        normalized = normalized
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }
        return normalized
    }
}

extension MessageVisibilityKind {
    var defaultActor: TimelineActor {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .tool, .codeEdit: return .tool
        case .reasoning, .tokenUsage, .environmentContext, .turnContext, .infoOther:
            return .info
        }
    }
}

extension Set where Element == MessageVisibilityKind {
    func contains(event: TimelineEvent) -> Bool {
        contains(event.visibilityKind)
    }

    var rawValues: [String] {
        map { $0.rawValue }.sorted()
    }

    static func fromRawValues(_ rawValues: [String]?) -> Set<MessageVisibilityKind>? {
        guard let rawValues else { return nil }
        return Set(rawValues.compactMap { MessageVisibilityKind.coerced(from: $0) })
    }
}

struct TimelineAttachment: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case image
    }

    let id: String
    let kind: Kind
    let label: String?
    let dataURL: String?
    let url: URL?

    init(
        kind: Kind,
        label: String? = nil,
        dataURL: String? = nil,
        url: URL? = nil,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.dataURL = dataURL
        self.url = url
    }

    static func == (lhs: TimelineAttachment, rhs: TimelineAttachment) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
