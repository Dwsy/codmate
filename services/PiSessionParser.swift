import Foundation

// MARK: - Pi Entry Types

struct PiEntry: Codable {
    let type: String
    let id: String?
    let parentId: String?
    let timestamp: Date?
    let cwd: String?
    let provider: String?
    let modelId: String?
    let message: PiMessage?
}

struct PiMessage: Codable {
    let role: String
    let content: [PiContentItem]?
    let api: String?
    let provider: String?
    let model: String?
    let usage: PiUsage?
    let stopReason: String?
    let errorMessage: String?
    let timestamp: Double?
}

struct PiContentItem: Codable {
    let type: String
    let text: String?
    let thinking: String?
    let thinkingSignature: String?
    let id: String?
    let name: String?
    let arguments: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, thinkingSignature
        case id
        case name, arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        thinkingSignature = try container.decodeIfPresent(String.self, forKey: .thinkingSignature)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)

        if let argumentsData = try? container.decodeIfPresent(Data.self, forKey: .arguments) {
            arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]
        } else {
            arguments = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(thinkingSignature, forKey: .thinkingSignature)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)

        if let arguments = arguments {
            if let data = try? JSONSerialization.data(withJSONObject: arguments) {
                try container.encodeIfPresent(data, forKey: .arguments)
            }
        }
    }
}

struct PiUsage: Codable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let cost: PiCost?

    var total: Int { input + output }
}

struct PiCost: Codable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
    let total: Double
}

// MARK: - Parse Result

struct ParsedSession {
    let summary: SessionSummary
    let rows: [SessionRow]
    let content: Data
}

// MARK: - PiSessionParser

struct PiSessionParser {
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.decoder = FlexibleDecoders.iso8601Flexible()
    }

    func parse(at url: URL, fileSize: UInt64? = nil) -> ParsedSession? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let lines = data.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }

        #if DEBUG
        NSLog("[PiSessionParser] Parsing file: \(url.lastPathComponent), lines: \(lines.count)")
        #endif

        var sessionId: String?
        var startedAt: Date?
        var endedAt: Date?
        var cwd: String?
        var model: String?
        var provider: String?
        var userMessageCount = 0
        var assistantMessageCount = 0
        var toolInvocationCount = 0
        var responseCounts: [String: Int] = [:]
        var totalTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        let eventCount = Int(lines.count)
        var lastUpdatedAt: Date?
        let originator = "pi"
        var rows: [SessionRow] = []
        var assistantMessages: [(Date, [PiContentItem], String?, PiUsage?)] = []
        var userMessages: [(Date, [PiContentItem])] = []

        for (index, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(PiEntry.self, from: lineData) else { continue }

            // Parse session header
            if entry.type == "session" {
                sessionId = entry.id
                startedAt = entry.timestamp
                cwd = entry.cwd
            }

            // Parse model change
            if entry.type == "model_change", let modelId = entry.modelId {
                model = modelId
                provider = entry.provider
            }

            // Collect messages for later conversion
            if entry.type == "message", let message = entry.message, let ts = entry.timestamp {
                switch message.role {
                case "assistant":
                    assistantMessages.append((ts, message.content ?? [], message.stopReason, message.usage))
                    #if DEBUG
                    if let usage = message.usage {
                        NSLog("[PiSessionParser] Assistant message at \(ts): \(usage.totalTokens) tokens")
                    } else {
                        NSLog("[PiSessionParser] Assistant message at \(ts): NO USAGE")
                    }
                    #endif
                case "user":
                    userMessageCount += 1
                    userMessages.append((ts, message.content ?? []))
                case "toolResult":
                    // Add tool result as event
                    if let content = message.content {
                        for item in content {
                            if item.type == "text", let itemText = item.text {
                                let payload = EventMessagePayload(
                                    type: "tool_result",
                                    message: itemText,
                                    kind: "info",
                                    text: nil,
                                    reason: nil,
                                    info: nil,
                                    rateLimits: nil,
                                    images: nil
                                )
                                rows.append(SessionRow(timestamp: ts, kind: .eventMessage(payload)))
                            }
                        }
                    }
                default:
                    break
                }
            }

            // Track last update time
            if let timestamp = entry.timestamp {
                lastUpdatedAt = timestamp
                if index == lines.count - 1 {
                    endedAt = timestamp
                }
            }
        }

        // Convert user messages to SessionRow format
        for (ts, content) in userMessages {
            // Extract text from content items
            var textParts: [String] = []
            for item in content {
                if item.type == "text", let itemText = item.text {
                    textParts.append(itemText)
                }
            }
            let combinedText = textParts.joined(separator: "\n")
            guard !combinedText.isEmpty else { continue }

            // Create user_message event
            let payload = EventMessagePayload(
                type: "user_message",
                message: combinedText,
                kind: nil,
                text: nil,
                reason: nil,
                info: nil,
                rateLimits: nil,
                images: nil
            )
            let row = SessionRow(timestamp: ts, kind: .eventMessage(payload))
            rows.append(row)
        }

        // Convert assistant messages to SessionRow format
        for (ts, content, stopReason, usage) in assistantMessages {
            assistantMessageCount += 1

            // Accumulate token usage
            if let usage = usage {
                inputTokens += usage.input
                outputTokens += usage.output
                totalTokens += usage.totalTokens
                #if DEBUG
                NSLog("[PiSessionParser] Accumulated tokens: input=\(usage.input), output=\(usage.output), total=\(usage.totalTokens), runningTotal=\(totalTokens)")
                #endif
            }

            // Process content items
            var textParts: [String] = []
            var thinkingParts: [String] = []

            for item in content {
                if item.type == "text", let itemText = item.text {
                    textParts.append(itemText)
                } else if item.type == "thinking", let itemThinking = item.thinking {
                    thinkingParts.append(itemThinking)
                }
            }

            // Create agent_message event for text content
            if !textParts.isEmpty {
                let combinedText = textParts.joined(separator: "\n")
                let payload = EventMessagePayload(
                    type: "agent_message",
                    message: combinedText,
                    kind: nil,
                    text: nil,
                    reason: nil,
                    info: nil,
                    rateLimits: nil,
                    images: nil
                )
                let row = SessionRow(timestamp: ts, kind: .eventMessage(payload))
                rows.append(row)
            }

            // Create agent_reasoning event for thinking content
            if !thinkingParts.isEmpty {
                let combinedThinking = thinkingParts.joined(separator: "\n")
                let payload = EventMessagePayload(
                    type: "agent_reasoning",
                    message: combinedThinking,
                    kind: nil,
                    text: nil,
                    reason: nil,
                    info: nil,
                    rateLimits: nil,
                    images: nil
                )
                let row = SessionRow(timestamp: ts, kind: .eventMessage(payload))
                rows.append(row)
            }

            // Create response_item rows for tool calls and other content items
            for item in content {
                // Skip tool arguments for now to avoid JSON serialization issues
                let payload = ResponseItemPayload(
                    type: item.type,
                    status: nil,
                    callID: item.id,
                    name: item.name,
                    content: nil,
                    summary: nil,
                    encryptedContent: nil,
                    role: nil,
                    arguments: nil,
                    input: nil,
                    output: nil,
                    ghostCommit: nil
                )
                let row = SessionRow(timestamp: ts, kind: .responseItem(payload))
                rows.append(row)
            }

            // Add stop reason as event if present
            if let stop = stopReason {
                let payload = EventMessagePayload(
                    type: "info",
                    message: stop,
                    kind: "stop_reason",
                    text: nil,
                    reason: nil,
                    info: nil,
                    rateLimits: nil,
                    images: nil
                )
                rows.append(SessionRow(timestamp: ts, kind: .eventMessage(payload)))
            }
        }

        guard let sid = sessionId ?? extractSessionId(from: url),
              let start = startedAt else { return nil }

        #if DEBUG
        NSLog("[PiSessionParser] Session \(sid): assistantMessages=\(assistantMessages.count), totalTokens=\(totalTokens), inputTokens=\(inputTokens), outputTokens=\(outputTokens)")
        #endif

        let summary = SessionSummary(
            id: sid,
            fileURL: url,
            fileSizeBytes: fileSize,
            startedAt: start,
            endedAt: endedAt,
            activeDuration: nil,
            cliVersion: "0.0.0",
            cwd: cwd ?? "",
            originator: originator,
            instructions: nil,
            model: model,
            approvalPolicy: nil,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolInvocationCount: toolInvocationCount,
            responseCounts: responseCounts,
            turnContextCount: 0,
            messageTypeCounts: nil,
            totalTokens: totalTokens > 0 ? totalTokens : nil,
            tokenBreakdown: totalTokens > 0 ? SessionTokenBreakdown(
                input: inputTokens,
                output: outputTokens,
                cacheRead: 0,
                cacheCreation: 0
            ) : nil,
            eventCount: eventCount,
            lineCount: lines.count,
            lastUpdatedAt: lastUpdatedAt,
            source: .piLocal,
            remotePath: nil,
            parseLevel: .metadata
        )

        return ParsedSession(summary: summary, rows: rows, content: data)
    }

    private func extractSessionId(from url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        // Format: <timestamp>_<uuid>.jsonl
        let components = filename.split(separator: "_", maxSplits: 1)
        guard components.count == 2 else { return nil }
        return String(components[1])
    }
}