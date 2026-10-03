import Foundation

// Minimal Decodable shapes for transcript lines and sidecars (architecture §5, stage 2).
//
// Only the keys AgentDeck uses are declared, so `JSONDecoder` never materializes tool outputs, thinking
// signatures or Write/Edit bodies. Every field is decoded leniently: a type change in a field we don't
// strictly need yields nil instead of failing the whole line.

extension KeyedDecodingContainer {
    @inline(__always)
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ s: String) { stringValue = s }
}

struct UsageCounts: Decodable, Sendable {
    var input: Int?
    var output: Int?
    var cacheCreation: Int?
    var cacheRead: Int?

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens", output = "output_tokens"
        case cacheCreation = "cache_creation_input_tokens", cacheRead = "cache_read_input_tokens"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = c.lenient(Int.self, .input)
        output = c.lenient(Int.self, .output)
        cacheCreation = c.lenient(Int.self, .cacheCreation)
        cacheRead = c.lenient(Int.self, .cacheRead)
    }

    var tokenUsage: TokenUsage {
        TokenUsage(input: input ?? 0, output: output ?? 0, cacheRead: cacheRead ?? 0, cacheCreation: cacheCreation ?? 0)
    }
}

/// Tool input keys used for Agent calls and one-line summaries.
struct ToolInput: Decodable, Sendable {
    var command: String?
    var description: String?
    var filePath: String?
    var notebookPath: String?
    var path: String?
    var pattern: String?
    var url: String?
    var query: String?
    var prompt: String?
    var subagentType: String?
    var model: String?
    var runInBackground: Bool?
    var skill: String?
    /// `SubagentHandback` report.
    var message: String?

    enum CodingKeys: String, CodingKey {
        case command, description, path, pattern, url, query, prompt, model, skill, message
        case filePath = "file_path", notebookPath = "notebook_path"
        case subagentType = "subagent_type", runInBackground = "run_in_background"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = c.lenient(String.self, .command)
        description = c.lenient(String.self, .description)
        filePath = c.lenient(String.self, .filePath)
        notebookPath = c.lenient(String.self, .notebookPath)
        path = c.lenient(String.self, .path)
        pattern = c.lenient(String.self, .pattern)
        url = c.lenient(String.self, .url)
        query = c.lenient(String.self, .query)
        prompt = c.lenient(String.self, .prompt)
        subagentType = c.lenient(String.self, .subagentType)
        model = c.lenient(String.self, .model)
        runInBackground = c.lenient(Bool.self, .runInBackground)
        skill = c.lenient(String.self, .skill)
        message = c.lenient(String.self, .message)
    }

    init() {}
}

// MARK: - Assistant

struct AssistantLine: Decodable {
    var type: String?
    var timestamp: String?
    var cwd: String?
    var gitBranch: String?
    var isApiErrorMessage: Bool
    var hasError: Bool
    var message: Message?

    struct Message: Decodable {
        var id: String?
        var model: String?
        var stopReason: String?
        var usage: UsageCounts?
        var content: [Block]

        enum CodingKeys: String, CodingKey { case id, model, usage, content, stopReason = "stop_reason" }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(String.self, .id)
            model = c.lenient(String.self, .model)
            stopReason = c.lenient(String.self, .stopReason)
            usage = c.lenient(UsageCounts.self, .usage)
            content = c.lenient([Block].self, .content) ?? []
        }
    }

    struct Block: Decodable {
        var type: String?
        var id: String?
        var name: String?
        var text: String?
        var input: ToolInput?

        enum CodingKeys: String, CodingKey { case type, id, name, text, input }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            switch type {
            case "text":
                text = c.lenient(String.self, .text)
            case "tool_use", "server_tool_use":
                id = c.lenient(String.self, .id)
                name = c.lenient(String.self, .name)
                input = c.lenient(ToolInput.self, .input)
            default:
                break
            }
        }
    }

    enum CodingKeys: String, CodingKey { case type, timestamp, cwd, gitBranch, isApiErrorMessage, error, message }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        timestamp = c.lenient(String.self, .timestamp)
        cwd = c.lenient(String.self, .cwd)
        gitBranch = c.lenient(String.self, .gitBranch)
        isApiErrorMessage = c.lenient(Bool.self, .isApiErrorMessage) ?? false
        hasError = c.contains(.error) && !((try? c.decodeNil(forKey: .error)) ?? true)
        message = c.lenient(Message.self, .message)
    }
}

// MARK: - User

struct UserLine: Decodable {
    var type: String?
    var timestamp: String?
    var cwd: String?
    var gitBranch: String?
    var isMeta: Bool
    var isCompactSummary: Bool
    var toolEndsTurn: Bool
    var originKind: String?
    /// `origin.from` (the sending agent id for peer handbacks).
    var originFrom: String?
    /// `origin.body` (a peer handback's report).
    var originBody: String?
    var content: Content
    /// `toolUseResult` of an Agent call (launch or completion).
    var agentResult: AgentToolResult?
    /// `toolUseResult` when it is a plain string (errors): first line, ≤ 200 chars.
    var resultText: String?

    enum Content {
        case none
        case text(String)
        case blocks([Block])
    }

    struct Block: Decodable {
        var type: String?
        var text: String?
        var toolUseID: String?
        var isError: Bool

        enum CodingKeys: String, CodingKey { case type, text, toolUseID = "tool_use_id", isError = "is_error" }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            switch type {
            case "text":
                text = c.lenient(String.self, .text)
                isError = false
            case "tool_result":
                toolUseID = c.lenient(String.self, .toolUseID)
                isError = c.lenient(Bool.self, .isError) ?? false
            default:
                isError = false
            }
        }
    }

    private struct Message: Decodable {
        var content: Content

        enum CodingKeys: String, CodingKey { case content }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? c.decode(String.self, forKey: .content) {
                content = .text(s)
            } else if let blocks = try? c.decode([Block].self, forKey: .content) {
                content = .blocks(blocks)
            } else {
                content = .none
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, timestamp, cwd, gitBranch, isMeta, isCompactSummary, toolEndsTurn, origin, message, toolUseResult
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        timestamp = c.lenient(String.self, .timestamp)
        cwd = c.lenient(String.self, .cwd)
        gitBranch = c.lenient(String.self, .gitBranch)
        isMeta = c.lenient(Bool.self, .isMeta) ?? false
        isCompactSummary = c.lenient(Bool.self, .isCompactSummary) ?? false
        toolEndsTurn = c.lenient(Bool.self, .toolEndsTurn) ?? false
        let origin = c.lenient(LineOrigin.self, .origin)
        originKind = origin?.kind
        originFrom = origin?.from
        originBody = origin?.body
        content = c.lenient(Message.self, .message)?.content ?? .none

        // toolUseResult is tool-specific. Only Agent results (an object with agentId) and error strings matter.
        if case .blocks(let blocks) = content, blocks.contains(where: { $0.type == "tool_result" }),
           c.contains(.toolUseResult) {
            if let result = c.lenient(AgentToolResult.self, .toolUseResult), result.agentID != nil {
                agentResult = result
            } else if blocks.contains(where: \.isError), let s = c.lenient(String.self, .toolUseResult) {
                resultText = TextUtil.firstLine(s, limit: 200)
            }
        }
    }
}

/// The structured result of an Agent tool call.
struct AgentToolResult: Decodable, Sendable {
    var status: String?
    var agentID: String?
    var agentType: String?
    var resolvedModel: String?
    var totalDurationMs: Int?
    var totalTokens: Int?
    var usage: TokenUsage?
    /// The report text (whitespace collapsed, ≤ 400 chars), unless it is a delivery stub.
    var text: String?

    enum CodingKeys: String, CodingKey {
        case status, agentType, resolvedModel, totalDurationMs, totalTokens, usage, content
        case agentID = "agentId"
    }

    private struct TextBlock: Decodable { var text: String? }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentID = c.lenient(String.self, .agentID)
        guard agentID != nil else { return }      // not an Agent result: decode nothing else
        status = c.lenient(String.self, .status)
        agentType = c.lenient(String.self, .agentType)
        resolvedModel = c.lenient(String.self, .resolvedModel)
        totalDurationMs = c.lenient(Int.self, .totalDurationMs)
        totalTokens = c.lenient(Int.self, .totalTokens)
        usage = c.lenient(UsageCounts.self, .usage)?.tokenUsage
        if status == "completed", let blocks = c.lenient([TextBlock].self, .content),
           let raw = blocks.lazy.compactMap(\.text).first {
            text = TextUtil.report(raw)
        }
    }
}

// MARK: - System, queue, metadata

struct SystemLine: Decodable {
    var subtype: String?
    var timestamp: String?
    var cwd: String?
    var gitBranch: String?

    enum CodingKeys: String, CodingKey { case subtype, timestamp, cwd, gitBranch }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtype = c.lenient(String.self, .subtype)
        timestamp = c.lenient(String.self, .timestamp)
        cwd = c.lenient(String.self, .cwd)
        gitBranch = c.lenient(String.self, .gitBranch)
    }
}

struct QueueOperationLine: Decodable {
    var operation: String?
    var content: String?
    var timestamp: String?

    enum CodingKeys: String, CodingKey { case operation, content, timestamp }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation = c.lenient(String.self, .operation)
        content = c.lenient(String.self, .content)
        timestamp = c.lenient(String.self, .timestamp)
    }
}

struct QueuedCommandLine: Decodable {
    var commandMode: String?
    var prompt: String?
    var timestamp: String?
    var isMeta: Bool
    var origin: LineOrigin?

    private struct Attachment: Decodable {
        var commandMode: String?
        var prompt: String?
        var isMeta: Bool?
        var origin: LineOrigin?

        enum CodingKeys: String, CodingKey { case commandMode, prompt, isMeta, origin }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            commandMode = c.lenient(String.self, .commandMode)
            prompt = c.lenient(String.self, .prompt)
            isMeta = c.lenient(Bool.self, .isMeta)
            origin = c.lenient(LineOrigin.self, .origin)
        }
    }

    enum CodingKeys: String, CodingKey { case attachment, timestamp }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let a = c.lenient(Attachment.self, .attachment)
        commandMode = a?.commandMode
        prompt = a?.prompt
        isMeta = a?.isMeta ?? false
        origin = a?.origin
        timestamp = c.lenient(String.self, .timestamp)
    }
}

/// `origin` on user lines and queued commands: `{kind, from, body, …}`.
struct LineOrigin: Decodable, Sendable {
    var kind: String?
    var from: String?
    var body: String?

    enum CodingKeys: String, CodingKey { case kind, from, body }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(String.self, .kind)
        from = c.lenient(String.self, .from)
        body = c.lenient(String.self, .body)
    }
}

/// `custom-title`, `ai-title`, `relocated` and the `type` probe for undecided lines.
struct MetadataLine: Decodable {
    var type: String?
    var customTitle: String?
    var aiTitle: String?
    var relocatedCwd: String?

    enum CodingKeys: String, CodingKey { case type, customTitle, aiTitle, relocatedCwd }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        customTitle = c.lenient(String.self, .customTitle)
        aiTitle = c.lenient(String.self, .aiTitle)
        relocatedCwd = c.lenient(String.self, .relocatedCwd)
    }
}

/// The envelope keys needed to route a line whose kind the scanner couldn't decide.
struct EnvelopeProbe: Decodable {
    var type: String?
    var attachmentType: String?

    private struct Attachment: Decodable { var type: String? }
    enum CodingKeys: String, CodingKey { case type, attachment }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        attachmentType = c.lenient(Attachment.self, .attachment)?.type
    }
}

// MARK: - Sidecars

/// `subagents/agent-<id>.meta.json`.
struct AgentMeta: Decodable, Sendable, Equatable {
    var agentType: String?
    var description: String?
    var toolUseID: String?
    var model: String?
    var isFork: Bool?
    var name: String?
    /// `background` | `foreground`.
    var requestShape: String?

    enum CodingKeys: String, CodingKey {
        case agentType, description, model, isFork, name, requestShape, toolUseID = "toolUseId"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentType = c.lenient(String.self, .agentType)
        description = c.lenient(String.self, .description)
        toolUseID = c.lenient(String.self, .toolUseID)
        model = c.lenient(String.self, .model)
        isFork = c.lenient(Bool.self, .isFork)
        name = c.lenient(String.self, .name)
        requestShape = c.lenient(String.self, .requestShape)
    }

    init(agentType: String? = nil, description: String? = nil, toolUseID: String? = nil, model: String? = nil,
         isFork: Bool? = nil, name: String? = nil, requestShape: String? = nil) {
        self.agentType = agentType
        self.description = description
        self.toolUseID = toolUseID
        self.model = model
        self.isFork = isFork
        self.name = name
        self.requestShape = requestShape
    }
}

/// `sessions/<pid>.json`.
struct PidFile: Decodable, Sendable, Equatable {
    var pid: Int32?
    var sessionID: String?
    var cwd: String?
    var startedAt: Int64?
    var procStart: String?
    var status: String?
    var waitingFor: String?

    enum CodingKeys: String, CodingKey { case pid, cwd, startedAt, procStart, status, waitingFor, sessionID = "sessionId" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = c.lenient(Int32.self, .pid)
        sessionID = c.lenient(String.self, .sessionID)
        cwd = c.lenient(String.self, .cwd)
        startedAt = c.lenient(Int64.self, .startedAt) ?? c.lenient(Double.self, .startedAt).map { Int64($0) }
        procStart = c.lenient(String.self, .procStart)
        status = c.lenient(String.self, .status)
        waitingFor = c.lenient(String.self, .waitingFor)
    }
}

/// `<sessionId>/custom-title.json`.
struct CustomTitleFile: Decodable {
    var customTitle: String?
}

/// One line of `<dataRoot>/agentdeck/events.jsonl` (optional hook, §12).
struct HookEvent: Decodable, Sendable {
    var sessionID: String?
    var transcriptPath: String?
    var agentTranscriptPath: String?
    var hookEventName: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", transcriptPath = "transcript_path"
        case agentTranscriptPath = "agent_transcript_path", hookEventName = "hook_event_name"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = c.lenient(String.self, .sessionID)
        transcriptPath = c.lenient(String.self, .transcriptPath)
        agentTranscriptPath = c.lenient(String.self, .agentTranscriptPath)
        hookEventName = c.lenient(String.self, .hookEventName)
    }
}

// MARK: - Text helpers

enum TextUtil {
    /// The first non-empty line, trimmed, at most `limit` characters (an ellipsis marks a cut).
    static func firstLine(_ text: String, limit: Int) -> String {
        var line: Substring = ""
        for candidate in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { line = Substring(trimmed); break }
        }
        return clamp(String(line), limit: limit)
    }

    static let reportLimit = 400

    /// A result/report text for `resultSummary`: whitespace collapsed, ≤ 400 chars; nil when empty, a bare
    /// ellipsis, or a delivery stub ("This agent's report was delivered…", "Async agent launched…").
    static func report(_ text: String) -> String? {
        let collapsed = collapse(text, limit: reportLimit)
        guard !collapsed.isEmpty, collapsed != "…", !isStub(collapsed) else { return nil }
        return collapsed
    }

    static func isStub(_ text: String) -> Bool {
        text.hasPrefix("This agent's report was delivered") || text.hasPrefix("Async agent launched")
    }

    /// Runs of whitespace (including newlines) become one space; trimmed; at most `limit` characters.
    static func collapse(_ text: String, limit: Int) -> String {
        let head = text.count > limit * 4 ? String(text.prefix(limit * 4)) : text
        let words = head.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return clamp(words.joined(separator: " "), limit: limit)
    }

    /// At most `limit` characters; an ellipsis marks a cut.
    static func clamp(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// At most `bytes` UTF-8 bytes, cut on a character boundary.
    static func cap(_ text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > bytes else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: bytes)
        while end > utf8.startIndex, (utf8[end] & 0xC0) == 0x80 {   // back to a scalar boundary
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }
}
