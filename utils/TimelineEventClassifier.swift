import Foundation

struct ClassifiedTimelineEvent {
    let kind: MessageVisibilityKind
    let callID: String?
    let isToolLike: Bool
}

struct TimelineEventClassifier {
    private static let skippedEventTypes: Set<String> = [
        "reasoning_output"
    ]

    static func classify(row: SessionRow) -> ClassifiedTimelineEvent? {
        switch row.kind {
        case .sessionMeta:
            return nil
        case .assistantMessage:
            // Assistant message rows are duplicates of response_item message entries.
            return nil
        case .turnContext:
            // Turn context is surfaced elsewhere and not part of the timeline list.
            return nil
        case let .eventMessage(payload):
            return classify(eventMessage: payload)
        case let .responseItem(payload):
            return classify(responseItem: payload)
        case .unknown:
            return nil
        }
    }

    private static func classify(eventMessage payload: EventMessagePayload) -> ClassifiedTimelineEvent? {
        let type = payload.type.lowercased()

        if type == "turn_boundary" { return nil }
        if skippedEventTypes.contains(type) { return nil }
        if type == "turn_aborted" || type == "turn aborted" || type == "compaction" || type == "compacted" {
            return nil
        }
        if type == "ghost_snapshot" || type == "ghost snapshot" { return nil }
        if type == "environment_context" { return nil }

        let rawMessage = payload.message ?? payload.text ?? payload.reason ?? ""
        let message = cleanedAssistantText(rawMessage)
        let hasImages = payload.images?.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? false
        guard !message.isEmpty || hasImages else { return nil }

        if type == "token_count" {
            return ClassifiedTimelineEvent(kind: .tokenUsage, callID: nil, isToolLike: false)
        }
        if type == "agent_reasoning" {
            return ClassifiedTimelineEvent(kind: .reasoning, callID: nil, isToolLike: false)
        }

        let mappedKind = MessageVisibilityKind.mappedKind(
            rawType: payload.type,
            title: payload.kind ?? payload.type,
            metadata: nil
        )
        let effectiveKind: MessageVisibilityKind? = {
            guard mappedKind == .tool else { return mappedKind }
            if containsCodeEditMarkers(message) || containsStrongEditOutputMarkers(message) {
                return .codeEdit
            }
            return mappedKind
        }()

        switch type {
        case "user_message":
            return ClassifiedTimelineEvent(kind: effectiveKind ?? .user, callID: nil, isToolLike: false)
        case "agent_message":
            return ClassifiedTimelineEvent(kind: effectiveKind ?? .assistant, callID: nil, isToolLike: false)
        default:
            let resolved = effectiveKind ?? .infoOther
            return ClassifiedTimelineEvent(kind: resolved, callID: nil, isToolLike: isToolLike(resolved))
        }
    }

    private static func classify(responseItem payload: ResponseItemPayload) -> ClassifiedTimelineEvent? {
        let type = payload.type.lowercased()
        if skippedEventTypes.contains(type) { return nil }
        if type == "ghost_snapshot" || type == "ghost snapshot" { return nil }

        if type == "reasoning",
           payload.summary?.isEmpty == false,
           payload.content?.isEmpty != false
        {
            // Skip summary-only duplicate reasoning events.
            return nil
        }

        if type == "message" {
            let role = payload.role?.lowercased()
            if role == "user" {
                // User content is converted into environment context and not shown in timeline.
                return nil
            }
            let text = cleanedAssistantText(joinedText(from: payload.content ?? []))
            guard !text.isEmpty else { return nil }
            return ClassifiedTimelineEvent(kind: .assistant, callID: nil, isToolLike: false)
        }

        let mappedKind = MessageVisibilityKind.mappedKind(
            rawType: payload.type,
            title: payload.type,
            metadata: nil
        )
        let detectionText = responseDetectionText(payload: payload)
        guard !detectionText.isEmpty else { return nil }
        let resolvedKind: MessageVisibilityKind? = {
            guard mappedKind == .tool else { return mappedKind }
            if isCodeEdit(payload: payload, fallbackText: detectionText) { return .codeEdit }
            return mappedKind
        }()
        let finalKind = resolvedKind ?? .infoOther
        let isTool = isToolLike(finalKind)
        return ClassifiedTimelineEvent(kind: finalKind, callID: payload.callID, isToolLike: isTool)
    }

    private static func responseDetectionText(payload: ResponseItemPayload) -> String {
        let contentText = cleanedAssistantText(joinedText(from: payload.content ?? []))
        if !contentText.isEmpty { return contentText }
        let summaryText = cleanedAssistantText(joinedSummary(from: payload.summary ?? []))
        if !summaryText.isEmpty { return summaryText }
        let fallbackText = responseFallbackText(payload)
        if !fallbackText.isEmpty { return fallbackText }
        if let output = stringValue(payload.output), !output.isEmpty { return output }
        return ""
    }

    private static func cleanedText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .replacingOccurrences(of: "<user_instructions>", with: "")
            .replacingOccurrences(of: "</user_instructions>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedAssistantText(_ text: String) -> String {
        let base = cleanedText(text)
        return stripTaggedBlocks(
            base,
            tags: [
                "permissions_instructions",
                "permissions instructions",
                "collaboration_mode",
                "collaboration mode"
            ]
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTaggedBlocks(_ text: String, tags: [String]) -> String {
        var result = text
        for tag in tags {
            result = stripTaggedBlock(result, tag: tag)
        }
        return result
    }

    private static func stripTaggedBlock(_ text: String, tag: String) -> String {
        let lowerTag = tag.lowercased()
        let openToken = "<\(lowerTag)>"
        let closeToken = "</\(lowerTag)>"
        var output = text
        while let openRange = output.lowercased().range(of: openToken) {
            if let closeRange = output.lowercased().range(
                of: closeToken,
                range: openRange.upperBound..<output.endIndex
            ) {
                output.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                output.removeSubrange(openRange.lowerBound..<output.endIndex)
                break
            }
        }
        return output
    }

    private static func joinedText(from blocks: [ResponseContentBlock]) -> String {
        blocks.compactMap { $0.text }.joined(separator: "\n\n")
    }

    private static func joinedSummary(from items: [ResponseSummaryItem]) -> String {
        items.compactMap { $0.text }.joined(separator: "\n\n")
    }

    private static func responseFallbackText(_ payload: ResponseItemPayload) -> String {
        var lines: [String] = []

        if let name = payload.name, !name.isEmpty {
            lines.append("name: \(name)")
        }
        if let args = renderValue(payload.arguments), !args.isEmpty {
            lines.append(formatLabel("arguments", value: args))
        }
        if let input = renderValue(payload.input), !input.isEmpty {
            lines.append(formatLabel("input", value: input))
        }
        if let output = renderValue(payload.output), !output.isEmpty {
            lines.append(formatLabel("output", value: output))
        }
        if let ghost = renderValue(payload.ghostCommit), !ghost.isEmpty {
            lines.append(formatLabel("ghost_commit", value: ghost))
        }
        if lines.isEmpty, let callID = payload.callID, !callID.isEmpty {
            lines.append("call_id: \(callID)")
        }

        return lines.joined(separator: "\n")
    }

    private static func renderValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return nil
        case .array, .object:
            let raw = toAny(value)
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return text
        }
    }

    private static func toAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let flag):
            return flag
        case .array(let array):
            return array.map(toAny)
        case .object(let dict):
            return dict.mapValues(toAny)
        case .null:
            return NSNull()
        }
    }

    private static func formatLabel(_ label: String, value: String) -> String {
        value.contains("\n") ? "\(label):\n\(value)" : "\(label): \(value)"
    }

    private static func isToolLike(_ kind: MessageVisibilityKind) -> Bool {
        switch kind {
        case .tool, .codeEdit:
            return true
        default:
            return false
        }
    }

    private static func isCodeEdit(payload: ResponseItemPayload, fallbackText: String) -> Bool {
        let name = normalizeToolName(payload.name)
        if codeEditToolNames.contains(name) { return true }

        if containsEditKeys(payload.arguments) || containsEditKeys(payload.input) {
            return true
        }

        if name == "execcommand" || name == "bash" || name == "runshellcommand" {
            let argsText = stringValue(payload.arguments) ?? ""
            if containsCodeEditMarkers(argsText) { return true }
        }

        if let outputText = stringValue(payload.output),
           containsStrongEditOutputMarkers(outputText) { return true }

        if containsCodeEditMarkers(fallbackText) { return true }

        return false
    }

    private static var codeEditToolNames: Set<String> {
        [
            "edit",
            "write",
            "replace",
            "applypatch",
            "patch",
            "createfile",
            "writefile",
            "deletefile",
            "fileedit",
            "filewrite",
            "updatefile",
            "insert",
            "append",
            "move",
            "rename",
            "remove",
            "multiedit"
        ]
    }

    private static func normalizeToolName(_ name: String?) -> String {
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty { return "" }
        return raw
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func containsEditKeys(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .object(let dict):
            let keys = Set(dict.keys.map { $0.lowercased() })
            let hasPath = keys.contains("file_path") || keys.contains("filepath") || keys.contains("path")
            let hasOldNew = keys.contains("old_string") || keys.contains("new_string")
            let hasPatch = keys.contains("patch") || keys.contains("diff")
            let hasContent = keys.contains("content") || keys.contains("new_content") || keys.contains("text")
            if hasOldNew || hasPatch { return true }
            if hasPath && hasContent { return true }
            return dict.values.contains { containsEditKeys($0) }
        case .array(let array):
            return array.contains { containsEditKeys($0) }
        default:
            return false
        }
    }

    private static func containsCodeEditMarkers(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("*** begin patch") { return true }
        if lowered.contains("*** update file") { return true }
        if lowered.contains("*** add file") { return true }
        if lowered.contains("*** delete file") { return true }
        if lowered.contains("update file:") { return true }
        return false
    }

    private static func containsStrongEditOutputMarkers(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("updated the following files") { return true }
        if lowered.contains("success. updated the following files") { return true }
        return false
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .object, .array:
            return nil
        case .null:
            return nil
        }
    }
}
