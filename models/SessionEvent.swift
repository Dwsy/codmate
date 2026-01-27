import Foundation

struct SessionRow: Decodable {
    let timestamp: Date
    let kind: Kind

    enum CodingKeys: String, CodingKey {
        case timestamp
        case type
        case payload
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "session_meta":
            let payload = try container.decode(SessionMetaPayload.self, forKey: .payload)
            kind = .sessionMeta(payload)
        case "turn_context":
            let payload = try container.decode(TurnContextPayload.self, forKey: .payload)
            kind = .turnContext(payload)
        case "event_msg":
            let payload = try container.decode(EventMessagePayload.self, forKey: .payload)
            kind = .eventMessage(payload)
        case "response_item":
            let payload = try container.decode(ResponseItemPayload.self, forKey: .payload)
            kind = .responseItem(payload)
        case "assistant":
            // assistant messages use "message" field instead of "payload"
            let message = try container.decode(AssistantMessage.self, forKey: .message)
            kind = .assistantMessage(AssistantMessagePayload(message: message))
        default:
            let payload = try container.decode(JSONValue.self, forKey: .payload)
            kind = .unknown(type: type, payload: payload)
        }
    }

    enum Kind {
        case sessionMeta(SessionMetaPayload)
        case turnContext(TurnContextPayload)
        case eventMessage(EventMessagePayload)
        case responseItem(ResponseItemPayload)
        case assistantMessage(AssistantMessagePayload)
        case unknown(type: String, payload: JSONValue)
    }
}

struct SessionMetaPayload: Decodable {
    let id: String
    let timestamp: Date
    let cwd: String
    let originator: String
    let cliVersion: String
    let instructions: String?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case cwd
        case originator
        case cliVersion = "cli_version"
        case instructions
    }
}

struct TurnContextPayload: Decodable {
    let cwd: String?
    let approvalPolicy: String?
    let model: String?
    let effort: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case cwd
        case approvalPolicy = "approval_policy"
        case model
        case effort
        case summary
    }
}

struct EventMessagePayload: Decodable {
    let type: String
    let message: String?
    let kind: String?
    let text: String?
    let reason: String?
    let info: JSONValue?
    let rateLimits: JSONValue?
    let images: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case kind
        case text
        case reason
        case info
        case rateLimits = "rate_limits"
        case images
    }

    init(
        type: String,
        message: String?,
        kind: String?,
        text: String?,
        reason: String?,
        info: JSONValue?,
        rateLimits: JSONValue?,
        images: [String]? = nil
    ) {
        self.type = type
        self.message = message
        self.kind = kind
        self.text = text
        self.reason = reason
        self.info = info
        self.rateLimits = rateLimits
        self.images = images
    }
}

struct ResponseItemPayload: Decodable {
    let type: String
    let status: String?
    let callID: String?
    let name: String?
    let content: [ResponseContentBlock]?
    let summary: [ResponseSummaryItem]?
    let encryptedContent: String?
    let role: String?
    let arguments: JSONValue?
    let input: JSONValue?
    let output: JSONValue?
    let ghostCommit: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case callID = "call_id"
        case name
        case content
        case summary
        case encryptedContent = "encrypted_content"
        case role
        case arguments
        case input
        case output
        case ghostCommit = "ghost_commit"
    }
}

struct ResponseContentBlock: Decodable {
    let type: String
    let text: String?
}

struct ResponseSummaryItem: Decodable {
    let type: String
    let text: String?
}

struct MessageUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }

    /// Total tokens according to Claude Code billing formula:
    /// input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens
    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
    }
}

struct AssistantMessage: Decodable {
    let id: String?
    let type: String?
    let role: String?
    let usage: MessageUsage?
}

struct AssistantMessagePayload: Decodable {
    let message: AssistantMessage?
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    var objectValue: [String: JSONValue]? {
        if case let .object(dict) = self { return dict }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            if value.isFinite {
                return Int(value)
            }
            return nil
        case .string(let string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool(let flag):
            return flag ? 1 : 0
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        // Try keyed container first (for objects)
        if let keyedContainer = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var dict: [String: JSONValue] = [:]
            for key in keyedContainer.allKeys {
                let value = try keyedContainer.decode(JSONValue.self, forKey: key)
                dict[key.stringValue] = value
            }
            self = .object(dict)
            return
        }

        // Try unkeyed container (for arrays)
        if var arrayContainer = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !arrayContainer.isAtEnd {
                let value = try arrayContainer.decode(JSONValue.self)
                items.append(value)
            }
            self = .array(items)
            return
        }

        // Finally try single value container (for primitives)
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .null
            }
            return
        }

        self = .null
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }
}

struct SessionSummaryBuilder {
    private(set) var id: String?
    private(set) var startedAt: Date?
    private(set) var lastUpdatedAt: Date?
    private(set) var cliVersion: String?
    private(set) var cwd: String?
    private(set) var originator: String?
    private(set) var instructions: String?
    private(set) var model: String?
    private(set) var approvalPolicy: String?
    private(set) var userMessageCount: Int = 0
    private(set) var assistantMessageCount: Int = 0
    private(set) var toolInvocationCount: Int = 0
    private(set) var responseCounts: [String: Int] = [:]
    private(set) var turnContextCount: Int = 0
    private(set) var messageTypeCounts: [MessageVisibilityKind: Int] = [:]
    private var seenToolCallIDs: Set<String> = []
    private(set) var totalTokens: Int = 0
    private(set) var tokenInput: Int = 0
    private(set) var tokenOutput: Int = 0
    private(set) var tokenCacheRead: Int = 0
    private(set) var tokenCacheCreation: Int = 0
    private(set) var eventCount: Int = 0
    private(set) var lineCount: Int = 0
    private(set) var fileSizeBytes: UInt64?
    private(set) var source: SessionSource = .codexLocal
    var parseLevel: SessionSummary.ParseLevel? = nil

    var hasEssentialMetadata: Bool {
        id != nil && startedAt != nil && cliVersion != nil && cwd != nil
    }

    mutating func setFileSize(_ size: UInt64?) {
        fileSizeBytes = size
    }

    mutating func setSource(_ source: SessionSource) {
        self.source = source
    }

    mutating func seedTotalTokens(_ total: Int) {
        if total > totalTokens {
            totalTokens = total
        }
    }

    mutating func seedLastUpdated(_ date: Date) {
        if let existing = lastUpdatedAt {
            if date > existing { lastUpdatedAt = date }
        } else {
            lastUpdatedAt = date
        }
    }

    mutating func accumulateIncrementalTokens(
        input: Int?,
        output: Int?,
        cacheRead: Int?,
        cacheCreation: Int?
    ) {
        if let value = input, value > 0 { tokenInput += value }
        if let value = output, value > 0 { tokenOutput += value }
        if let value = cacheRead, value > 0 { tokenCacheRead += value }
        if let value = cacheCreation, value > 0 { tokenCacheCreation += value }
    }

    mutating func seedTokenSnapshot(
        input: Int?,
        output: Int?,
        cacheRead: Int?,
        cacheCreation: Int?
    ) {
        if let value = input, value > tokenInput { tokenInput = value }
        if let value = output, value > tokenOutput { tokenOutput = value }
        if let value = cacheRead, value > tokenCacheRead { tokenCacheRead = value }
        if let value = cacheCreation, value > tokenCacheCreation { tokenCacheCreation = value }
    }

    func currentTokenBreakdown() -> SessionTokenBreakdown? {
        let input = max(tokenInput, 0)
        let output = max(tokenOutput, 0)
        let cacheRead = max(tokenCacheRead, 0)
        let cacheCreation = max(tokenCacheCreation, 0)
        if input == 0 && output == 0 && cacheRead == 0 && cacheCreation == 0 {
            return nil
        }
        return SessionTokenBreakdown(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation)
    }

    mutating func observe(_ row: SessionRow) {
        if case let .eventMessage(payload) = row.kind,
           payload.type.lowercased() == "turn_boundary"
        {
            return
        }
        lineCount += 1
        seedLastUpdated(row.timestamp)

        switch row.kind {
        case let .sessionMeta(payload):
            id = payload.id
            startedAt = payload.timestamp
            cwd = payload.cwd
            originator = payload.originator
            cliVersion = payload.cliVersion
            if let instructionsText = payload.instructions, instructions == nil {
                instructions = instructionsText
            }
        case let .turnContext(payload):
            turnContextCount += 1
            if let model = payload.model {
                self.model = model
            }
            if let approval = payload.approvalPolicy {
                approvalPolicy = approval
            }
            if let cwd = payload.cwd, self.cwd == nil {
                self.cwd = cwd
            }
        case let .eventMessage(payload):
            eventCount += 1
            let type = payload.type
            if type == "user_message" {
                userMessageCount += 1
            } else if type == "agent_message" {
                assistantMessageCount += 1
            } else if type == "token_count" {
                handleTokenCountEvent(message: payload.message ?? payload.text, info: payload.info)
            }
        case let .responseItem(payload):
            eventCount += 1
            responseCounts[payload.type, default: 0] += 1
            if payload.type == "message" {
                assistantMessageCount += 1
            }
            // Only count invocation events themselves; ignore corresponding *_output entries
            // to avoid double-counting.
            if payload.type == "function_call" || payload.type == "custom_tool_call" || payload.type == "tool_call" {
                toolInvocationCount += 1
            }
        case let .assistantMessage(payload):
            // Accumulate tokens from all assistant messages according to Claude Code formula:
            // total = input_tokens + output_tokens + cache_read_input_tokens + cache_creation_input_tokens
            assistantMessageCount += 1
            if let usage = payload.message?.usage {
                totalTokens += usage.totalTokens
                accumulateIncrementalTokens(
                    input: usage.inputTokens,
                    output: usage.outputTokens,
                    cacheRead: usage.cacheReadInputTokens,
                    cacheCreation: usage.cacheCreationInputTokens)
            }
        case .unknown:
            lineCount += 0
        }

        if let classified = TimelineEventClassifier.classify(row: row) {
            if classified.isToolLike, let callID = classified.callID, !callID.isEmpty {
                if !seenToolCallIDs.insert(callID).inserted {
                    return
                }
            }
            messageTypeCounts[classified.kind, default: 0] += 1
        }
    }

    @discardableResult
    private mutating func handleTokenCountEvent(message: String?, info: JSONValue?) -> Bool {
        var handled = false
        if let snapshot = SessionTokenSnapshot.from(info: info) {
            applyTokenSnapshot(snapshot)
            handled = true
        }
        if let snapshot = SessionTokenSnapshot.from(message: message) {
            applyTokenSnapshot(snapshot)
            handled = true
        }
        return handled
    }

    private mutating func applyTokenSnapshot(_ snapshot: SessionTokenSnapshot) {
        if let total = snapshot.total {
            totalTokens = max(totalTokens, total)
        }
        seedTokenSnapshot(
            input: snapshot.input,
            output: snapshot.output,
            cacheRead: snapshot.cacheRead,
            cacheCreation: snapshot.cacheCreation)
    }

    mutating func setModelFallback(_ fallback: String) {
        if model == nil || model?.isEmpty == true {
            model = fallback
        }
    }

    func build(for url: URL) -> SessionSummary? {
        guard let id,
              let startedAt,
              let cliVersion,
              let originator,
              let cwd
        else {
            return nil
        }

        var s = SessionSummary(
            id: id,
            fileURL: url,
            fileSizeBytes: fileSizeBytes,
            startedAt: startedAt,
            endedAt: lastUpdatedAt,
            activeDuration: nil,
            cliVersion: cliVersion,
            cwd: cwd,
            originator: originator,
            instructions: instructions,
            model: model,
            approvalPolicy: approvalPolicy,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolInvocationCount: toolInvocationCount,
            responseCounts: responseCounts,
            turnContextCount: turnContextCount,
            messageTypeCounts: messageTypeCounts.isEmpty ? nil : messageTypeCounts.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            totalTokens: totalTokens,
            tokenBreakdown: currentTokenBreakdown(),
            eventCount: eventCount,
            lineCount: lineCount,
            lastUpdatedAt: lastUpdatedAt,
            source: source,
            remotePath: nil
        )
        s.parseLevel = parseLevel
        return s
    }
}

extension SessionRow {
    init(timestamp: Date, kind: SessionRow.Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

struct SessionTokenSnapshot {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheCreation: Int?
    var total: Int?

    init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheCreation: Int? = nil, total: Int? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.total = total
    }

    var hasValues: Bool {
        return input != nil || output != nil || cacheRead != nil || cacheCreation != nil || total != nil
    }

    var breakdown: SessionTokenBreakdown? {
        let inputValue = input ?? 0
        let outputValue = output ?? 0
        let cacheReadValue = cacheRead ?? 0
        let cacheCreationValue = cacheCreation ?? 0
        if inputValue == 0 && outputValue == 0 && cacheReadValue == 0 && cacheCreationValue == 0 {
            return nil
        }
        return SessionTokenBreakdown(
            input: inputValue,
            output: outputValue,
            cacheRead: cacheReadValue,
            cacheCreation: cacheCreationValue)
    }

    mutating func merge(_ other: SessionTokenSnapshot) {
        if let value = other.input { input = max(input ?? 0, value) }
        if let value = other.output { output = max(output ?? 0, value) }
        if let value = other.cacheRead { cacheRead = max(cacheRead ?? 0, value) }
        if let value = other.cacheCreation { cacheCreation = max(cacheCreation ?? 0, value) }
        if let value = other.total { total = max(total ?? 0, value) }
    }

    static func from(info: JSONValue?) -> SessionTokenSnapshot? {
        guard let info, let dict = info.objectValue else { return nil }
        var snapshot = SessionTokenSnapshot()

        // Use total_token_usage (cumulative) instead of last_token_usage (incremental)
        // Codex/Claude log files have both, but we want the cumulative total
        if let tokenUsage = dict["total_token_usage"]?.objectValue {
            snapshot.merge(dict: tokenUsage)
        } else if let tokenUsage = dict["token_usage"]?.objectValue {
            // Fallback for other formats that only have token_usage
            snapshot.merge(dict: tokenUsage)
        } else {
            // Fallback to top-level keys
            snapshot.merge(dict: dict)
        }

        if snapshot.total == nil, let total = dict["total"]?.intValue {
            snapshot.total = total
        }
        return snapshot.hasValues ? snapshot : nil
    }

    static func from(message: String?) -> SessionTokenSnapshot? {
        guard let text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        var snapshot = SessionTokenSnapshot()
        let parts = text.split(separator: ",")
        for part in parts {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueString = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(valueString) else { continue }
            snapshot.assign(key: key, value: value)
        }
        if !snapshot.hasValues {
            let lower = text.lowercased()
            if let range = lower.range(of: "total:") {
                let substring = lower[range.upperBound...]
                let digits = substring.prefix(while: { $0.isWhitespace || $0.isNumber })
                if let value = Int(digits.trimmingCharacters(in: .whitespaces)) {
                    snapshot.total = value
                }
            }
        }
        return snapshot.hasValues ? snapshot : nil
    }

    mutating func merge(dict: [String: JSONValue]) {
        for (key, value) in dict {
            guard let number = value.intValue else { continue }
            assign(key: key, value: number)
        }
    }

    mutating func assign(key: String, value: Int) {
        let normalized = key
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let lower = normalized.lowercased()
        if lower.contains("total") {
            total = value
            return
        }
        if lower.contains("cache") || lower.contains("cached") {
            if lower.contains("creation") {
                cacheCreation = value
            } else {
                cacheRead = value
            }
            return
        }
        // Handle input tokens (but not cached_input_tokens which was handled above)
        if lower.contains("input") && !lower.contains("cache") && !lower.contains("cached") {
            input = value
            return
        }
        // Handle output tokens - use max to avoid overwriting with reasoning_output_tokens
        // since output_tokens usually includes reasoning_output_tokens already
        if lower.contains("output") || lower.contains("reasoning") {
            output = max(output ?? 0, value)
            return
        }
    }
}
