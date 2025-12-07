import Foundation

struct ClaudeParsedLog {
    let summary: SessionSummary
    let rows: [SessionRow]
}

private struct ActiveDurationAccumulator {
    var currentTurnStart: Date?
    var lastOutput: Date?
    var total: TimeInterval = 0

    mutating func observe(type: String?, timestamp: Date?) {
        guard let ts = timestamp else { return }
        switch type {
        case "user":
            flush()
            currentTurnStart = ts
            lastOutput = nil
        case "assistant", "system", "summary":
            lastOutput = ts
        default:
            break
        }
    }

    mutating func flush() {
        guard let end = lastOutput else { return }
        let start = currentTurnStart ?? end
        let delta = end.timeIntervalSince(start)
        if delta > 0 { total += delta }
        currentTurnStart = nil
        lastOutput = nil
    }
}

struct ClaudeSessionParser {
    private let decoder: JSONDecoder
    private let newline: UInt8 = 0x0A
    private let carriageReturn: UInt8 = 0x0D
    private let chunkSize = 64 * 1024

    init() {
        self.decoder = FlexibleDecoders.iso8601Flexible()
    }

    /// Fast path: extract sessionId by scanning until a line that carries it.
    /// Avoids doing full conversion work. Returns nil if not found.
    func fastSessionId(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return nil
        }
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true).prefix(256) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let line = decodeLine(Data(slice)) else { continue }
            if let sid = line.sessionId, !sid.isEmpty { return sid }
        }
        return nil
    }

    func parse(at url: URL, fileSize: UInt64? = nil) -> ClaudeParsedLog? {
        // Skip agent-*.jsonl files entirely (sidechain warmup files)
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("agent-") {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else { return nil }

        var accumulator = MetadataAccumulator()
        var activeAccumulator = ActiveDurationAccumulator()
        var rows: [SessionRow] = []
        rows.reserveCapacity(256)
        var seenUserMessageIds: Set<String> = []
        var seenAssistantMessageIds: Set<String> = []
        var seenToolUseIds: Set<String> = []
        var dedupUserCount = 0
        var dedupAssistantCount = 0
        var dedupToolCount = 0

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let line = decodeLine(Data(slice)) else { continue }
            if line.isSidechain == true { continue }
            let renderedText = line.message.flatMap(Self.renderFlatText)
            let model = line.message?.model
            let usageTokens = line.message?.usage?.totalTokens
            accumulator.consume(line, renderedText: renderedText, model: model, usageTokens: usageTokens)
            activeAccumulator.observe(type: line.type, timestamp: line.timestamp)
            let hasText = ClaudeSessionParser.hasRenderableText(line.message)
            if let type = line.type {
                let messageId = line.message?.id
                switch type {
                case "user":
                    if hasText, messageId.map({ seenUserMessageIds.insert($0).inserted }) ?? true {
                        dedupUserCount &+= 1
                    }
                case "assistant":
                    let newTools = ClaudeSessionParser.countToolUses(in: line.message, seen: &seenToolUseIds)
                    if newTools > 0 { dedupToolCount &+= newTools }
                    if hasText {
                        let isNew = messageId.map({ seenAssistantMessageIds.insert($0).inserted }) ?? true
                        if isNew { dedupAssistantCount &+= 1 }
                    }
                default:
                    break
                }
            }
            rows.append(contentsOf: convert(line))
        }
        activeAccumulator.flush()

        let contextRow = accumulator.makeContextRow()
        guard let metaRow = accumulator.makeMetaRow(),
              let summary = buildSummary(
                url: url,
                fileSize: fileSize,
                metaRow: metaRow,
                contextRow: contextRow,
                additionalRows: rows,
                totalTokens: accumulator.totalTokens,
                tokenBreakdown: accumulator.tokenBreakdown(),
                lastTimestamp: accumulator.lastTimestamp,
                activeDuration: activeAccumulator.total > 0 ? activeAccumulator.total : nil) else {
            return nil
        }

        var combinedRows: [SessionRow] = [metaRow]
        if let contextRow { combinedRows.append(contextRow) }
        combinedRows.append(contentsOf: rows)
        let finalSummary = adjustCounts(
            summary: summary,
            userCount: dedupUserCount,
            assistantCount: dedupAssistantCount,
            toolCount: dedupToolCount)
        let timelineAdjusted = adjustCountsFromTimeline(summary: finalSummary, rows: combinedRows)
        return ClaudeParsedLog(summary: timelineAdjusted, rows: combinedRows)
    }

    private func adjustCounts(
        summary: SessionSummary,
        userCount: Int,
        assistantCount: Int,
        toolCount: Int
    ) -> SessionSummary {
        let adjustedUser = userCount > 0 ? userCount : summary.userMessageCount
        let adjustedAssistant = assistantCount > 0 ? assistantCount : summary.assistantMessageCount
        let adjustedTools = toolCount > 0 ? toolCount : summary.toolInvocationCount

        var adjustedResponseCounts = summary.responseCounts
        if toolCount > 0 {
            adjustedResponseCounts["tool_call"] = toolCount
        }
        let adjustedEventCount = adjustedUser + adjustedAssistant + adjustedResponseCounts.values.reduce(0, +)

        var adjusted = SessionSummary(
            id: summary.id,
            fileURL: summary.fileURL,
            fileSizeBytes: summary.fileSizeBytes,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            activeDuration: summary.activeDuration,
            cliVersion: summary.cliVersion,
            cwd: summary.cwd,
            originator: summary.originator,
            instructions: summary.instructions,
            model: summary.model,
            approvalPolicy: summary.approvalPolicy,
            userMessageCount: adjustedUser,
            assistantMessageCount: adjustedAssistant,
            toolInvocationCount: adjustedTools,
            responseCounts: adjustedResponseCounts,
            turnContextCount: summary.turnContextCount,
            totalTokens: summary.totalTokens,
            tokenBreakdown: summary.tokenBreakdown,
            eventCount: adjustedEventCount,
            lineCount: summary.lineCount,
            lastUpdatedAt: summary.lastUpdatedAt,
            source: summary.source,
            remotePath: summary.remotePath,
            userTitle: summary.userTitle,
            userComment: summary.userComment,
            taskId: summary.taskId
        )
        adjusted.parseLevel = summary.parseLevel
        return adjusted
    }

    /// Align counts with the visible timeline logic to keep list metrics consistent.
    private func adjustCountsFromTimeline(
        summary: SessionSummary,
        rows: [SessionRow]
    ) -> SessionSummary {
        let loader = SessionTimelineLoader()
        let turns = loader.turns(from: rows)
        let turnCount = turns.count
        // Preserve the tool invocation count from the previous adjustCounts() step,
        // which correctly counts tool_use blocks in assistant messages.
        // Do NOT count tool outputs here (actor == .tool), as those are results, not calls.
        return ClaudeSessionParser.normalizeCounts(
            summary: summary,
            turnCount: turnCount,
            assistantTextCount: turnCount,
            toolCount: summary.toolInvocationCount)
    }

    /// Normalize counts to CodMate's definition: one user→assistant exchange equals one message.
    private static func normalizeCounts(
        summary: SessionSummary,
        turnCount: Int,
        assistantTextCount: Int,
        toolCount: Int
    ) -> SessionSummary {
        let turns = max(turnCount, 0)
        let assistant = turns > 0 ? max(min(turns, assistantTextCount), turns) : assistantTextCount
        let tools = max(toolCount, 0)

        var counts = summary.responseCounts
        counts["tool_call"] = tools

        return SessionSummary(
            id: summary.id,
            fileURL: summary.fileURL,
            fileSizeBytes: summary.fileSizeBytes,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            activeDuration: summary.activeDuration,
            cliVersion: summary.cliVersion,
            cwd: summary.cwd,
            originator: summary.originator,
            instructions: summary.instructions,
            model: summary.model,
            approvalPolicy: summary.approvalPolicy,
            userMessageCount: turns,
            assistantMessageCount: assistant,
            toolInvocationCount: tools,
            responseCounts: counts,
            turnContextCount: summary.turnContextCount,
            totalTokens: summary.totalTokens,
            tokenBreakdown: summary.tokenBreakdown,
            eventCount: turns + tools,
            lineCount: summary.lineCount,
            lastUpdatedAt: summary.lastUpdatedAt,
            source: summary.source,
            remotePath: summary.remotePath,
            userTitle: summary.userTitle,
            userComment: summary.userComment,
            taskId: summary.taskId,
            parseLevel: .enriched  // Mark as enriched with timeline-based turn counting
        )
    }

    private func decodeLine(_ data: Data) -> ClaudeLogLine? {
        do {
            return try decoder.decode(ClaudeLogLine.self, from: data)
        } catch {
            return nil
        }
    }

    private func convert(_ line: ClaudeLogLine) -> [SessionRow] {
        guard let timestamp = line.timestamp else { return [] }
        guard let type = line.type else { return [] }

        // Skip sidechain messages (warmup, etc.)
        if line.isSidechain == true {
            return []
        }

        switch type {
        case "user":
            return convertUser(line, timestamp: timestamp)
        case "assistant":
            return convertAssistant(line, timestamp: timestamp)
        case "system":
            return convertSystem(line, timestamp: timestamp)
        case "summary":
            guard let summary = line.summary else { return [] }
            let payload = EventMessagePayload(
                type: "system_summary",
                message: summary,
                kind: nil,
                text: summary,
                info: nil,
                rateLimits: nil)
            return [SessionRow(timestamp: timestamp, kind: .eventMessage(payload))]
        default:
            return []
        }
    }

    private func convertUser(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let blocks = Self.blocks(from: message)
        var rows: [SessionRow] = []

        for block in blocks {
            switch block.type {
            case "text", nil:
                if let text = Self.renderText(from: block), !text.isEmpty {
                    let payload = EventMessagePayload(
                        type: "user_message",
                        message: text,
                        kind: nil,
                        text: text,
                        info: nil,
                        rateLimits: nil)
                    rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
                }
            case "tool_result":
                if let text = Self.renderText(from: block), !text.isEmpty {
                    let item = ResponseItemPayload(
                        type: "tool_output",
                        status: nil,
                        callID: block.toolUseId,
                        name: block.name,
                        content: [ResponseContentBlock(type: "text", text: text)],
                        summary: nil,
                        encryptedContent: nil,
                        role: "system")
                    rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
                }
            default:
                break
            }
        }

        if let toolResult = line.toolUseResult,
           let rendered = Self.stringify(toolResult),
           !rendered.isEmpty {
            let payload = EventMessagePayload(
                type: "tool_output",
                message: rendered,
                kind: nil,
                text: rendered,
                info: nil,
                rateLimits: nil)
            rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
        }

        return rows
    }

    private func convertAssistant(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let blocks = Self.blocks(from: message)
        var rows: [SessionRow] = []

        for block in blocks {
            switch block.type {
            case "text", nil:
                if let text = Self.renderText(from: block), !text.isEmpty {
                    let payload = EventMessagePayload(
                        type: "agent_message",
                        message: text,
                        kind: nil,
                        text: text,
                        info: nil,
                        rateLimits: nil)
                    rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
                }
            case "thinking":
                // Extended thinking block - count as reasoning
                if let text = Self.renderText(from: block), !text.isEmpty {
                    let item = ResponseItemPayload(
                        type: "reasoning",
                        status: nil,
                        callID: block.id,
                        name: nil,
                        content: [ResponseContentBlock(type: "text", text: text)],
                        summary: nil,
                        encryptedContent: nil,
                        role: "assistant")
                    rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
                }
            case "tool_use":
                let rendered = block.input.flatMap { Self.stringify($0) } ?? ""
                let contentBlocks = rendered.isEmpty
                    ? []
                    : [ResponseContentBlock(type: "text", text: rendered)]
                let item = ResponseItemPayload(
                    type: "tool_call",
                    status: nil,
                    callID: block.id,
                    name: block.name,
                    content: contentBlocks,
                    summary: nil,
                    encryptedContent: nil,
                    role: "assistant")
                rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
            default:
                break
            }
        }

        return rows
    }

    private func convertSystem(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let text = Self.renderFlatText(message) ?? Self.renderText(from: Self.blocks(from: message).first)
        guard let text, !text.isEmpty else { return [] }
        let payload = EventMessagePayload(
            type: "system_message",
            message: text,
            kind: line.subtype,
            text: text,
            info: nil,
            rateLimits: nil)
        return [SessionRow(timestamp: timestamp, kind: .eventMessage(payload))]
    }

    private func buildSummary(
        url: URL,
        fileSize: UInt64?,
        metaRow: SessionRow,
        contextRow: SessionRow?,
        additionalRows: [SessionRow],
        totalTokens: Int,
        tokenBreakdown: SessionTokenBreakdown?,
        lastTimestamp: Date?,
        activeDuration: TimeInterval?
    ) -> SessionSummary? {
        var builder = SessionSummaryBuilder()
        builder.setSource(.claudeLocal)
        builder.setFileSize(fileSize)
        builder.seedTotalTokens(totalTokens)
        if let breakdown = tokenBreakdown {
            builder.seedTokenSnapshot(
                input: breakdown.input,
                output: breakdown.output,
                cacheRead: breakdown.cacheRead,
                cacheCreation: breakdown.cacheCreation
            )
        }

        builder.observe(metaRow)
        if let contextRow { builder.observe(contextRow) }
        for row in additionalRows { builder.observe(row) }
        if let lastTimestamp { builder.seedLastUpdated(lastTimestamp) }
        builder.setModelFallback("Claude")
        guard let summary = builder.build(for: url) else { return nil }
        if let activeDuration {
            return SessionSummary(
                id: summary.id,
                fileURL: summary.fileURL,
                fileSizeBytes: summary.fileSizeBytes,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt,
                activeDuration: activeDuration,
                cliVersion: summary.cliVersion,
                cwd: summary.cwd,
                originator: summary.originator,
                instructions: summary.instructions,
                model: summary.model,
                approvalPolicy: summary.approvalPolicy,
                userMessageCount: summary.userMessageCount,
                assistantMessageCount: summary.assistantMessageCount,
                toolInvocationCount: summary.toolInvocationCount,
                responseCounts: summary.responseCounts,
                turnContextCount: summary.turnContextCount,
                totalTokens: summary.totalTokens,
                tokenBreakdown: summary.tokenBreakdown,
                eventCount: summary.eventCount,
                lineCount: summary.lineCount,
                lastUpdatedAt: summary.lastUpdatedAt,
                source: summary.source,
                remotePath: summary.remotePath,
                userTitle: summary.userTitle,
                userComment: summary.userComment,
                taskId: summary.taskId
            )
        }
        return summary
    }

    private static func blocks(from message: ClaudeMessage) -> [ClaudeContentBlock] {
        switch message.content {
        case .string(let text):
            return [ClaudeContentBlock(type: "text", text: text, id: nil, name: nil, input: nil, toolUseId: nil, content: nil)]
        case .blocks(let blocks):
            return blocks
        case .none:
            return []
        }
    }

    private static func renderFlatText(_ message: ClaudeMessage) -> String? {
        switch message.content {
        case .string(let text):
            return text
        case .blocks(let blocks):
            let rendered = blocks.compactMap { renderText(from: $0) }.joined(separator: "\n")
            return rendered.isEmpty ? nil : rendered
        case .none:
            return nil
        }
    }

    private static func renderText(from block: ClaudeContentBlock?) -> String? {
        guard let block else { return nil }
        if let text = block.text, !text.isEmpty { return text }
        if let rendered = block.content.flatMap({ stringify($0) }), !rendered.isEmpty {
            return rendered
        }
        if let rendered = block.input.flatMap({ stringify($0) }), !rendered.isEmpty {
            return rendered
        }
        return nil
    }

    private static func stringify(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let str):
            return str
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array(let array):
            let rendered = array.compactMap { stringify($0) }.joined(separator: "\n")
            return rendered.isEmpty ? nil : rendered
        case .object(let object):
            let raw = object.mapValues { $0.toAnyValue() }
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        case .null:
            return nil
        }
    }

    private struct MetadataAccumulator {
        var sessionId: String?
        var agentId: String?
        var version: String?
        var cwd: String?
        var model: String?
        var instructions: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var totalTokens: Int = 0
        var tokenInput: Int = 0
        var tokenOutput: Int = 0
        var tokenCacheRead: Int = 0
        var tokenCacheCreation: Int = 0
        var seenMessageIds: Set<String> = []
        var usageByMessageId: [String: UsageSnapshot] = [:]

        struct UsageSnapshot {
            let total: Int
            let input: Int
            let output: Int
            let cacheRead: Int
            let cacheCreation: Int
        }

        mutating func consume(
            _ line: ClaudeLogLine,
            renderedText: String?,
            model: String?,
            usageTokens: Int?
        ) {
            if let sid = line.sessionId, sessionId == nil { sessionId = sid }
            if let aid = line.agentId, agentId == nil { agentId = aid }
            if let ver = line.version, version == nil { version = ver }
            if let path = line.cwd, cwd == nil { cwd = path }
            if let timestamp = line.timestamp {
                if firstTimestamp == nil || timestamp < firstTimestamp! { firstTimestamp = timestamp }
                if lastTimestamp == nil || timestamp > lastTimestamp! { lastTimestamp = timestamp }
            }
            if instructions == nil, line.isMeta == true,
               let text = renderedText, !text.isEmpty {
                instructions = text
            }
            if self.model == nil, let model, !model.isEmpty {
                self.model = model
            }
            let messageId = line.message?.id
            let isNewMessage = messageId.map { seenMessageIds.insert($0).inserted } ?? true

            if let usage = line.message?.usage {
                let snapshot = UsageSnapshot(
                    total: usage.totalTokens,
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cacheRead: usage.cacheReadInputTokens ?? 0,
                    cacheCreation: (usage.cacheCreationInputTokens ?? 0)
                        + (usage.cacheCreation?.ephemeral5m ?? 0)
                        + (usage.cacheCreation?.ephemeral1h ?? 0)
                )
                applyUsage(snapshot: snapshot, messageId: messageId, isNewMessage: isNewMessage)
            } else if let usageTokens, usageTokens > 0 {
                let snapshot = UsageSnapshot(total: usageTokens, input: 0, output: 0, cacheRead: 0, cacheCreation: 0)
                applyUsage(snapshot: snapshot, messageId: messageId, isNewMessage: isNewMessage)
            }
        }

        private mutating func applyUsage(snapshot: UsageSnapshot, messageId: String?, isNewMessage: Bool) {
            // For messages with IDs, accumulate deltas (streamed usage updates share the same ID)
            if let messageId {
                let previous = usageByMessageId[messageId]
                let deltaTotal = snapshot.total - (previous?.total ?? 0)
                let deltaInput = snapshot.input - (previous?.input ?? 0)
                let deltaOutput = snapshot.output - (previous?.output ?? 0)
                let deltaCacheRead = snapshot.cacheRead - (previous?.cacheRead ?? 0)
                let deltaCacheCreation = snapshot.cacheCreation - (previous?.cacheCreation ?? 0)

                if deltaTotal > 0 { totalTokens &+= deltaTotal }
                if deltaInput > 0 { tokenInput &+= deltaInput }
                if deltaOutput > 0 { tokenOutput &+= deltaOutput }
                if deltaCacheRead > 0 { tokenCacheRead &+= deltaCacheRead }
                if deltaCacheCreation > 0 { tokenCacheCreation &+= deltaCacheCreation }
                usageByMessageId[messageId] = snapshot
                return
            }

            // Messages without IDs: retain legacy behavior to avoid over-counting duplicated lines.
            if isNewMessage {
                totalTokens &+= snapshot.total
                tokenInput &+= snapshot.input
                tokenOutput &+= snapshot.output
                tokenCacheRead &+= snapshot.cacheRead
                tokenCacheCreation &+= snapshot.cacheCreation
            }
        }

        func makeMetaRow() -> SessionRow? {
            guard let sessionId, let timestamp = firstTimestamp, let cwd else { return nil }
            let payload = SessionMetaPayload(
                id: sessionId,
                timestamp: timestamp,
                cwd: cwd,
                originator: "Claude Code",
                cliVersion: "claude-code \(version ?? "unknown")",
                instructions: instructions
            )
            return SessionRow(timestamp: timestamp, kind: .sessionMeta(payload))
        }

        func makeContextRow() -> SessionRow? {
            // For Claude sessions, we don't generate context update rows.
            // Model info is already shown in the session info card at the top.
            // This avoids duplicate "Syncing / Context Updated / model: xxx" entries in the timeline.
            return nil
        }

        func tokenBreakdown() -> SessionTokenBreakdown? {
            let input = tokenInput
            let output = tokenOutput
            let cacheRead = tokenCacheRead
            let cacheCreation = tokenCacheCreation
            if input == 0 && output == 0 && cacheRead == 0 && cacheCreation == 0 {
                return nil
            }
            return SessionTokenBreakdown(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation
            )
        }
    }

    private struct ClaudeLogLine: Decodable {
        let type: String?
        let timestamp: Date?
        let sessionId: String?
        let agentId: String?
        let version: String?
        let cwd: String?
        let message: ClaudeMessage?
        let toolUseResult: JSONValue?
        let summary: String?
        let isMeta: Bool?
        let subtype: String?
        let isSidechain: Bool?
    }

    private struct ClaudeMessage: Decodable {
        let id: String?
        let role: String?
        let model: String?
        let content: ClaudeMessageContent?
        let usage: ClaudeUsage?

        enum CodingKeys: String, CodingKey {
            case id
            case role
            case model
            case content
            case usage
        }
    }

    private struct ClaudeUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }

        struct CacheCreation: Decodable {
            let ephemeral5m: Int?
            let ephemeral1h: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens"
                case ephemeral1h = "ephemeral_1h_input_tokens"
            }
        }

        var totalTokens: Int {
            let creation = (cacheCreationInputTokens ?? 0) +
                (cacheCreation?.ephemeral5m ?? 0) +
                (cacheCreation?.ephemeral1h ?? 0)
            return (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + creation
        }
    }

    private enum ClaudeMessageContent: Decodable {
        case string(String)
        case blocks([ClaudeContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .string(text)
                return
            }
            if let block = try? container.decode(ClaudeContentBlock.self) {
                self = .blocks([block])
                return
            }
            if let blocks = try? container.decode([ClaudeContentBlock].self) {
                self = .blocks(blocks)
                return
            }
            self = .blocks([])
        }
    }

    private struct ClaudeContentBlock: Decodable {
        let type: String?
        let text: String?
        let id: String?
        let name: String?
        let input: JSONValue?
        let toolUseId: String?
        let content: JSONValue?
    }

    private static func countToolUses(in message: ClaudeMessage?, seen: inout Set<String>) -> Int {
        guard let message else { return 0 }
        switch message.content {
        case .blocks(let blocks):
            return blocks.reduce(0) { partial, block in
                guard block.type == "tool_use" else { return partial }
                if let id = block.id {
                    return seen.insert(id).inserted ? partial + 1 : partial
                }
                return partial + 1
            }
        case .string, .none:
            return 0
        }
    }

    private static func hasRenderableText(_ message: ClaudeMessage?) -> Bool {
        guard let message else { return false }
        switch message.content {
        case .string(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .blocks(let blocks):
            return blocks.contains { block in
                guard let rendered = renderText(from: block) else { return false }
                return !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .none:
            return false
        }
    }
}

private extension JSONValue {
    func toAnyValue() -> Any {
        switch self {
        case .string(let str): return str
        case .number(let number): return number
        case .bool(let flag): return flag
        case .array(let array): return array.map { $0.toAnyValue() }
        case .object(let dict): return dict.mapValues { $0.toAnyValue() }
        case .null: return NSNull()
        }
    }
}
