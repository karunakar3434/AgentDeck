import Foundation

// MARK: - Events

/// Envelope fields shared by user, assistant and system lines.
struct LineContext: Sendable, Equatable {
    var timestamp: Date?
    var cwd: String?
    var gitBranch: String?
}

/// One parsed transcript line, reduced to what the session reducer needs.
enum TranscriptEvent: Sendable {
    case assistant(AssistantEvent)
    case user(UserEvent)
    case system(subtype: String?, LineContext)
    /// Task notifications from a `queue-operation` enqueue or a `queued_command` attachment.
    case notices([TaskNotice], timestamp: Date?)
    /// A prompt typed while the agent was busy (`queued_command`, commandMode `prompt`).
    case queuedPrompt(String, timestamp: Date?)
    /// A subagent's handback report delivered to its parent (`origin.kind == "peer"`).
    case peerReport(agentID: String, text: String)
    case customTitle(String)
    case aiTitle(String)
    case relocated(cwd: String)
    case costState
    case forkContextRef
}

struct AssistantEvent: Sendable {
    var context: LineContext
    var messageID: String?
    /// nil for `<synthetic>`.
    var model: String?
    var stopReason: String?
    var usage: TokenUsage?
    /// An API error line (`isApiErrorMessage`, or a `<synthetic>` message carrying `error`).
    var isAPIError: Bool
    var blocks: [Block]

    enum Block: Sendable {
        /// First 300 characters.
        case text(String)
        case toolUse(ToolUse)
        case other
    }
}

struct ToolUse: Sendable {
    var id: String
    var name: String
    var summary: String
    /// Set for `Agent` / `Task` calls.
    var agentCall: AgentCall?
    /// `SubagentHandback` `input.message` (collapsed, ≤ 400 chars).
    var handbackMessage: String?
}

struct AgentCall: Sendable {
    var subagentType: String?
    var description: String?
    /// ≤ 32 KB.
    var prompt: String?
    var model: String?
    var runInBackground: Bool?
}

struct UserEvent: Sendable {
    enum Kind: Sendable, Equatable {
        /// A real human prompt (text).
        case prompt(String)
        /// `[Request interrupted by user…]`.
        case interrupt
        /// One or more tool results.
        case toolResults
        /// A `<task-notification>` delivered as a user turn.
        case notification
        /// A subagent's handback report (`origin.kind == "peer"`).
        case peer
        /// System-made text: `isMeta`, compact summaries, coordinator messages, local command output.
        case meta
    }

    var context: LineContext
    var kind: Kind
    var toolResults: [ToolResult] = []
    var notices: [TaskNotice] = []
    /// `toolEndsTurn` (SubagentHandback results).
    var toolEndsTurn = false
    /// A peer handback: the sending agent id and its report.
    var peerReport: (agentID: String, text: String)?
}

struct ToolResult: Sendable {
    var toolUseID: String
    var isError: Bool
    var agentResult: AgentToolResult?
    /// First line of an error string result.
    var errorText: String?
}

// MARK: - Parser

/// Bytes → `TranscriptEvent` (architecture §5). Owns one `JSONDecoder`; each actor keeps its own parser.
struct LineParser {
    enum Mode: Sendable {
        /// Everything the session reducer uses.
        case full
        /// Only what the estimate scanner needs: Agent calls, Agent results, notifications, main model.
        case durations
    }

    static let promptLimit = 32 * 1024
    static let textLimit = 300

    let mode: Mode
    private let decoder = JSONDecoder()

    init(mode: Mode = .full) {
        self.mode = mode
    }

    func parse(_ bytes: UnsafeRawBufferPointer) -> TranscriptEvent? {
        parse(bytes, kind: LineScanner.classify(bytes), depth: 0)
    }

    func parse(_ data: Data) -> TranscriptEvent? {
        data.withUnsafeBytes { parse($0) }
    }

    private func parse(_ bytes: UnsafeRawBufferPointer, kind: LineKind, depth: Int) -> TranscriptEvent? {
        switch kind {
        case .skip:
            return nil
        case .assistant:
            if mode == .durations, !bytesContain(bytes, "\"tool_use\"") || !(bytesContain(bytes, "\"Agent\"") || bytesContain(bytes, "\"Task\"")) {
                return Self.cheapModel(bytes).map {
                    .assistant(AssistantEvent(context: LineContext(), model: $0, isAPIError: false, blocks: []))
                }
            }
            guard let line = decode(AssistantLine.self, bytes) else { return nil }
            if let type = line.type, type != "assistant", depth == 0 {
                return parse(bytes, kind: Self.kind(forType: type), depth: 1)
            }
            return .assistant(Self.assistantEvent(line))
        case .user:
            if mode == .durations, !(bytesContain(bytes, "\"agentId\"") || bytesContain(bytes, "<task-notification>")) {
                return nil
            }
            guard let line = decode(UserLine.self, bytes) else { return nil }
            return .user(Self.userEvent(line))
        case .system:
            if mode == .durations { return nil }
            guard let line = decode(SystemLine.self, bytes) else { return nil }
            return .system(subtype: line.subtype, Self.context(line.timestamp, line.cwd, line.gitBranch))
        case .queueOperation:
            guard bytesContain(bytes, "<task-notification>"),
                  let line = decode(QueueOperationLine.self, bytes), line.operation == "enqueue",
                  let content = line.content
            else { return nil }
            // Only a queued notification, not a queued message that quotes one (a peer handback).
            let notices = TaskNotice.parseLeading(content)
            return notices.isEmpty ? nil : .notices(notices, timestamp: line.timestamp.flatMap(Timestamp.parse))
        case .queuedCommand:
            guard let line = decode(QueuedCommandLine.self, bytes), let prompt = line.prompt else { return nil }
            let ts = line.timestamp.flatMap(Timestamp.parse)
            let kind = line.origin?.kind
            if kind == "peer" {
                // A subagent's handback: a report, never a notification (even when it quotes one).
                guard mode == .full, let from = line.origin?.from,
                      let report = TextUtil.report(line.origin?.body ?? Self.peerMessageBody(prompt)) else { return nil }
                return .peerReport(agentID: from, text: report)
            }
            if kind == nil || kind == "task-notification" {
                let notices = TaskNotice.parseLeading(prompt)
                if !notices.isEmpty { return .notices(notices, timestamp: ts) }
            }
            guard mode == .full else { return nil }
            let human = line.origin == nil || line.origin?.kind == "human"
            if human, !line.isMeta, line.commandMode == nil || line.commandMode == "prompt" {
                return .queuedPrompt(TextUtil.cap(prompt, bytes: Self.promptLimit), timestamp: ts)
            }
            return nil
        case .customTitle, .aiTitle, .relocated:
            if mode == .durations { return nil }
            guard let line = decode(MetadataLine.self, bytes) else { return nil }
            switch kind {
            case .customTitle: return line.customTitle.map { .customTitle($0) }
            case .aiTitle: return line.aiTitle.map { .aiTitle($0) }
            default: return line.relocatedCwd.map { .relocated(cwd: $0) }
            }
        case .costState:
            return mode == .full ? .costState : nil
        case .forkContextRef:
            return mode == .full ? .forkContextRef : nil
        case .decode:
            guard depth == 0, let probe = decode(EnvelopeProbe.self, bytes), let type = probe.type else { return nil }
            if type == "attachment" {
                return probe.attachmentType == "queued_command" ? parse(bytes, kind: .queuedCommand, depth: 1) : nil
            }
            return parse(bytes, kind: Self.kind(forType: type), depth: 1)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ bytes: UnsafeRawBufferPointer) -> T? {
        guard let base = bytes.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        return try? decoder.decode(T.self, from: data)
    }

    static func kind(forType type: String) -> LineKind {
        switch type {
        case "user": .user
        case "assistant": .assistant
        case "system": .system
        case "queue-operation": .queueOperation
        case "custom-title": .customTitle
        case "ai-title": .aiTitle
        case "relocated": .relocated
        case "cost-state": .costState
        case "fork-context-ref": .forkContextRef
        default: .skip
        }
    }

    // MARK: Event builders

    static func context(_ ts: String?, _ cwd: String?, _ branch: String?) -> LineContext {
        LineContext(timestamp: ts.flatMap(Timestamp.parse), cwd: cwd, gitBranch: branch)
    }

    static func assistantEvent(_ line: AssistantLine) -> AssistantEvent {
        let message = line.message
        let rawModel = message?.model
        let synthetic = rawModel == "<synthetic>"
        var blocks: [AssistantEvent.Block] = []
        for block in message?.content ?? [] {
            switch block.type {
            case "text":
                blocks.append(.text(TextUtil.clamp(block.text ?? "", limit: textLimit)))
            case "tool_use", "server_tool_use":
                guard let id = block.id else { continue }
                let name = block.name ?? "tool"
                let input = block.input ?? ToolInput()
                var call: AgentCall?
                if name == "Agent" || name == "Task" {
                    call = AgentCall(subagentType: input.subagentType.map { TextUtil.clamp($0, limit: TextUtil.fieldLimit) },
                                     description: input.description.map { TextUtil.clamp($0, limit: TextUtil.fieldLimit) },
                                     prompt: input.prompt.map { TextUtil.cap($0, bytes: promptLimit) },
                                     model: input.model, runInBackground: input.runInBackground)
                }
                let handback = name == "SubagentHandback" ? input.message.flatMap(TextUtil.report) : nil
                blocks.append(.toolUse(ToolUse(id: id, name: name, summary: ToolSummary.make(name: name, input: input),
                                               agentCall: call, handbackMessage: handback)))
            default:
                blocks.append(.other)
            }
        }
        return AssistantEvent(
            context: context(line.timestamp, line.cwd, line.gitBranch),
            messageID: message?.id,
            model: synthetic ? nil : rawModel,
            stopReason: message?.stopReason,
            usage: synthetic ? nil : message?.usage?.tokenUsage,
            isAPIError: line.isApiErrorMessage || (synthetic && line.hasError),
            blocks: blocks)
    }

    static func userEvent(_ line: UserLine) -> UserEvent {
        let ctx = context(line.timestamp, line.cwd, line.gitBranch)
        var text: String?
        var results: [ToolResult] = []
        switch line.content {
        case .none:
            break
        case .text(let s):
            text = s
        case .blocks(let blocks):
            var parts: [String] = []
            for block in blocks {
                switch block.type {
                case "text":
                    if let t = block.text { parts.append(t) }
                case "tool_result":
                    guard let id = block.toolUseID else { continue }
                    results.append(ToolResult(toolUseID: id, isError: block.isError, agentResult: line.agentResult,
                                              errorText: block.isError ? line.resultText : nil))
                default:
                    break
                }
            }
            if !parts.isEmpty { text = parts.joined(separator: "\n") }
        }
        // A line has one tool result in practice; the structured result belongs to it.
        if results.count > 1 {
            for i in results.indices.dropFirst() { results[i].agentResult = nil }
        }

        var event = UserEvent(context: ctx, kind: .meta, toolResults: results, toolEndsTurn: line.toolEndsTurn)
        if !results.isEmpty {
            event.kind = .toolResults
            if let text, text.hasPrefix("[Request interrupted by user") { event.kind = .interrupt }
            return event
        }
        guard let text else { return event }
        // Only a turn that *is* a notification carries notices; a peer message quoting one doesn't.
        let notificationOrigin = line.originKind == nil || line.originKind == "task-notification"
        let notices = notificationOrigin ? TaskNotice.parseLeading(text) : []
        if text.hasPrefix("[Request interrupted by user") {
            event.kind = .interrupt
        } else if line.originKind == "peer" {
            event.kind = .peer
            let body: String = line.originBody ?? peerMessageBody(text)
            if let from = line.originFrom, let report = TextUtil.report(body) {
                event.peerReport = (from, report)
            }
        } else if line.originKind == "task-notification" || !notices.isEmpty {
            event.kind = .notification
            event.notices = notices
        } else if line.isMeta || line.isCompactSummary || (line.originKind != nil && line.originKind != "human")
                    || isCommandText(text) {
            event.kind = .meta
        } else {
            event.kind = .prompt(TextUtil.cap(text, bytes: promptLimit))
        }
        return event
    }

    /// The message inside a peer delivery ("Another Claude session sent a message:
    /// <agent-message from=…>…</agent-message>"), or the text itself when it has no such wrapper.
    static func peerMessageBody(_ text: String) -> String {
        guard let open = text.range(of: "<agent-message"),
              let close = text[open.upperBound...].firstIndex(of: ">") else { return text }
        let start = text.index(after: close)
        let end = text.range(of: "</agent-message>", options: .backwards, range: start..<text.endIndex)?.lowerBound
            ?? text.endIndex
        return String(text[start..<end])
    }

    /// Slash-command echoes and local command output are recorded as user lines but aren't prompts.
    static func isCommandText(_ text: String) -> Bool {
        text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") || text.hasPrefix("<local-command-")
            || text.hasPrefix("<bash-input>") || text.hasPrefix("<bash-stdout>")
    }

    /// The `message.model` value of an assistant line from its first bytes, without decoding.
    static func cheapModel(_ bytes: UnsafeRawBufferPointer) -> String? {
        let limit = min(bytes.count, LineScanner.limit)
        guard limit > 0, let base = bytes.baseAddress else { return nil }
        let needle: StaticString = "\"model\":\""
        guard let hit = memmem(base, limit, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        let start = base.distance(to: hit) + needle.utf8CodeUnitCount
        var end = start
        while end < limit, bytes[end] != 0x22 { end += 1 }
        guard end < limit, end > start else { return nil }
        let model = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        return model == "<synthetic>" ? nil : model
    }
}

// MARK: - Tool summaries

/// One-line summaries of tool inputs for the inspector feed (≤ 120 chars).
enum ToolSummary {
    static let limit = 120

    static func make(name: String, input: ToolInput) -> String {
        let raw: String?
        switch name {
        case "Bash":
            raw = nonEmpty(input.description) ?? input.command.map { TextUtil.firstLine($0, limit: limit) }
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead":
            raw = (input.filePath ?? input.notebookPath ?? input.path).map(lastTwoComponents)
        case "Grep", "Glob":
            raw = input.pattern
        case "LS":
            raw = input.path.map(lastTwoComponents)
        case "WebFetch":
            raw = input.url.map(hostAndPath)
        case "WebSearch":
            raw = input.query
        case "Agent", "Task":
            raw = input.description
        case "Skill":
            raw = input.skill ?? input.description
        default:
            raw = nonEmpty(input.description) ?? input.filePath.map(lastTwoComponents) ?? input.pattern ?? input.query
                ?? input.url.map(hostAndPath) ?? input.command.map { TextUtil.firstLine($0, limit: limit) }
        }
        guard let raw else { return "" }
        return TextUtil.firstLine(raw, limit: limit)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    static func lastTwoComponents(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.suffix(2).joined(separator: "/")
    }

    static func hostAndPath(_ url: String) -> String {
        guard let u = URLComponents(string: url), let host = u.host else { return url }
        return host + u.path
    }
}
