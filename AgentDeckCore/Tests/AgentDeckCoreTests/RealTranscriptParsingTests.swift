import Foundation
import Testing
@testable import AgentDeckCore

// Parser-level checks against real (sanitized) Claude Code 2.1.284–2.1.286 lines: the `extra` session first,
// then the other fixtures for line shapes the `extra` session doesn't contain, then synthetic lines (documented in
// data-sources.md) for shapes no fixture contains.

// MARK: - Line shape table

/// A parse result, coarsely, for the shape table.
enum ParsedShape: Sendable, Equatable {
    case none
    case assistantToolUse, assistantText, assistantOther, assistantAPIError
    case userPrompt, userMeta, userPeer, userNotification, userInterrupt
    case userToolResults(agentResult: Bool, isError: Bool)
    case notices(Int)
    case peerReport, queuedPrompt
    case system(String?)
    case customTitle, aiTitle, relocated, costState, forkContextRef

    init(_ e: TranscriptEvent?) {
        switch e {
        case nil:
            self = .none
        case .assistant(let a)?:
            if a.isAPIError { self = .assistantAPIError; return }
            switch a.blocks.first {
            case .toolUse?: self = .assistantToolUse
            case .text?: self = .assistantText
            default: self = .assistantOther
            }
        case .user(let u)?:
            switch u.kind {
            case .prompt: self = .userPrompt
            case .meta: self = .userMeta
            case .peer: self = .userPeer
            case .notification: self = .userNotification
            case .interrupt: self = .userInterrupt
            case .toolResults:
                self = .userToolResults(agentResult: u.toolResults.contains { $0.agentResult != nil },
                                        isError: u.toolResults.contains(where: \.isError))
            }
        case .system(let subtype, _)?: self = .system(subtype)
        case .notices(let n, _)?: self = .notices(n.count)
        case .queuedPrompt?: self = .queuedPrompt
        case .peerReport?: self = .peerReport
        case .customTitle?: self = .customTitle
        case .aiTitle?: self = .aiTitle
        case .relocated?: self = .relocated
        case .costState?: self = .costState
        case .forkContextRef?: self = .forkContextRef
        }
    }
}

enum LineSource: Sendable {
    case extraMain
    case extraAgent(String)
    case fixtureMain(String)
    case fixtureAgent(String, String)
    case synthetic(String)

    var lines: [Data] {
        switch self {
        case .extraMain: Extra.mainLines
        case .extraAgent(let aid): Extra.lines(of: aid)
        case .fixtureMain(let sid): Fixtures.lines(Fixtures.mainPath(sid))
        case .fixtureAgent(let sid, let aid):
            Fixtures.lines((Fixtures.subagentDir(sid) as NSString).appendingPathComponent("agent-\(aid).jsonl"))
        case .synthetic(let s): [Data(s.utf8)]
        }
    }
}

struct LineShape: Sendable, CustomTestStringConvertible {
    typealias Match = @Sendable ([String: Any]) -> Bool

    let name: String
    let source: LineSource
    let kind: LineKind
    let parsed: ParsedShape
    let match: Match

    init(_ name: String, _ source: LineSource, _ kind: LineKind, _ parsed: ParsedShape, where match: @escaping Match = { _ in true }) {
        self.name = name
        self.source = source
        self.kind = kind
        self.parsed = parsed
        self.match = match
    }

    var testDescription: String { name }

    /// The first real line of this shape.
    func sample() -> Data? { source.lines.first { match(Ref.json($0)) } }

    // Matchers (reference decode).
    static func type(_ t: String) -> Match { { Ref.type($0) == t } }
    static func system(_ subtype: String) -> Match { { Ref.type($0) == "system" && $0["subtype"] as? String == subtype } }
    static func attachment(_ t: String) -> Match { { Ref.type($0) == "attachment" && Ref.attachmentType($0) == t } }
    static func assistantBlock(_ t: String) -> Match {
        { Ref.type($0) == "assistant" && $0["isApiErrorMessage"] == nil && Ref.blocks($0).first?["type"] as? String == t }
    }
    static func toolUse(_ name: String) -> Match { { Ref.toolUses($0).first?["name"] as? String == name } }
    static func queue(_ op: String, notification: Bool) -> Match {
        { Ref.type($0) == "queue-operation" && $0["operation"] as? String == op
            && ((($0["content"] as? String) ?? "").contains("<task-notification>") == notification) }
    }
    static func userString(origin: String?) -> Match {
        { Ref.type($0) == "user" && Ref.message($0)["content"] is String
            && ($0["origin"] as? [String: Any])?["kind"] as? String == origin }
    }
    static func toolResult(hasResult: Bool) -> Match {
        { Ref.type($0) == "user" && Ref.blocks($0).first?["type"] as? String == "tool_result" && ($0["toolUseResult"] != nil) == hasResult }
    }
    static func queuedCommand(mode: String?, origin: String?) -> Match {
        { obj in
            guard let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command" else { return false }
            return a["commandMode"] as? String == mode && (a["origin"] as? [String: Any])?["kind"] as? String == origin
        }
    }

    static let interruptBlocks = #"{"parentUuid":"b151433a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"u1","timestamp":"2026-10-02T23:58:10.000Z","cwd":"/Users/dev/Projects/AgentDeck","sessionId":"fb4572c1"}"#
    static let interruptForToolUse = #"{"parentUuid":"b151433a","isSidechain":false,"type":"user","message":{"role":"user","content":"[Request interrupted by user for tool use]"},"uuid":"u2","timestamp":"2026-10-02T23:58:11.000Z","sessionId":"fb4572c1"}"#
    static let apiErrorRetry = #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"api_error","level":"error","error":{"status":529},"retryInMs":527,"retryAttempt":1,"maxRetries":10,"timestamp":"2026-10-02T23:56:35.582Z","uuid":"u3","cwd":"/Users/dev/Projects/AgentDeck","sessionId":"fb4572c1"}"#
    static let fileHistorySnapshot = #"{"type":"file-history-snapshot","messageId":"bae29393","snapshot":{"messageId":"bae29393","trackedFileBackups":{"a.swift":{"backupFileName":"x@v1","version":1}},"timestamp":"2026-10-02T23:56:28.204Z"},"isSnapshotUpdate":false}"#
    static let fileHistoryDelta = #"{"type":"file-history-delta","messageId":"bae29393","delta":{"type":"user","message":{"role":"user","content":"not a prompt"}}}"#
    static let relocated = #"{"type":"relocated","sessionId":"fb4572c1","relocatedCwd":"/Users/dev/Projects/Other"}"#
    static let bridgeSession = #"{"type":"bridge-session","sessionId":"fb4572c1","bridge":{"type":"assistant"}}"#

    static let all: [LineShape] = [
        // The extra session's main file.
        .init("queue-operation enqueue of a prompt", .extraMain, .queueOperation, .none, where: queue("enqueue", notification: false)),
        .init("queue-operation enqueue of a task notification", .extraMain, .queueOperation, .notices(1), where: queue("enqueue", notification: true)),
        .init("queue-operation remove of a task notification", .extraMain, .queueOperation, .none, where: queue("remove", notification: true)),
        .init("queue-operation dequeue", .extraMain, .queueOperation, .none, where: { Ref.type($0) == "queue-operation" && $0["operation"] as? String == "dequeue" }),
        .init("user prompt (origin human)", .extraMain, .user, .userPrompt, where: userString(origin: "human")),
        .init("user peer handback (isMeta, origin peer)", .extraMain, .user, .userPeer, where: userString(origin: "peer")),
        .init("assistant thinking block", .extraMain, .assistant, .assistantOther, where: assistantBlock("thinking")),
        .init("assistant text block", .extraMain, .assistant, .assistantText, where: assistantBlock("text")),
        .init("assistant Bash tool_use", .extraMain, .assistant, .assistantToolUse, where: toolUse("Bash")),
        .init("assistant Agent tool_use", .extraMain, .assistant, .assistantToolUse, where: toolUse("Agent")),
        .init("assistant SendMessage tool_use", .extraMain, .assistant, .assistantToolUse, where: toolUse("SendMessage")),
        .init("assistant MCP tool_use", .extraMain, .assistant, .assistantToolUse,
              where: { (Ref.toolUses($0).first?["name"] as? String)?.hasPrefix("mcp__") == true }),
        .init("tool_result with a Bash toolUseResult", .extraMain, .user, .userToolResults(agentResult: false, isError: false),
              where: { toolResult(hasResult: true)($0) && ($0["toolUseResult"] as? [String: Any])?["stdout"] != nil }),
        .init("tool_result with an async_launched Agent toolUseResult", .extraMain, .user, .userToolResults(agentResult: true, isError: false),
              where: { ($0["toolUseResult"] as? [String: Any])?["status"] as? String == "async_launched" }),
        .init("queued_command peer handback", .extraMain, .queuedCommand, .peerReport, where: queuedCommand(mode: "prompt", origin: "peer")),
        .init("queued_command task notification", .extraMain, .queuedCommand, .notices(1),
              where: queuedCommand(mode: "task-notification", origin: "task-notification")),
        .init("system stop_hook_summary (desktop turn end)", .extraMain, .system, .system("stop_hook_summary"), where: system("stop_hook_summary")),
        .init("custom-title", .extraMain, .customTitle, .customTitle, where: type("custom-title")),
        .init("last-prompt", .extraMain, .skip, .none, where: type("last-prompt")),
        .init("agent-name", .extraMain, .skip, .none, where: type("agent-name")),
        .init("atis-latch", .extraMain, .skip, .none, where: type("atis-latch")),
        .init("attachment total_tokens_reminder", .extraMain, .skip, .none, where: attachment("total_tokens_reminder")),
        .init("attachment deferred_tools_record", .extraMain, .skip, .none, where: attachment("deferred_tools_record")),
        .init("attachment edited_text_file", .extraMain, .skip, .none, where: attachment("edited_text_file")),
        .init("attachment silent_turn_reminder", .extraMain, .skip, .none, where: attachment("silent_turn_reminder")),
        // The extra session's subagent files.
        .init("subagent first prompt (sidechain)", .extraAgent("af4448711daf1ca74"), .user, .userPrompt, where: userString(origin: nil)),
        .init("subagent tool_result without toolUseResult", .extraAgent("af4448711daf1ca74"), .user,
              .userToolResults(agentResult: false, isError: false), where: toolResult(hasResult: false)),
        .init("subagent SubagentHandback tool_use", .extraAgent("af4448711daf1ca74"), .assistant, .assistantToolUse, where: toolUse("SubagentHandback")),
        .init("subagent handback result (toolEndsTurn)", .extraAgent("af4448711daf1ca74"), .user,
              .userToolResults(agentResult: false, isError: false), where: { $0["toolEndsTurn"] as? Bool == true }),
        .init("subagent queued_command from the coordinator (SendMessage)", .extraAgent("acdeefa10fce90761"), .queuedCommand, .none,
              where: queuedCommand(mode: nil, origin: "coordinator")),
        .init("subagent queued_command for its Bash background task", .extraAgent("a9247d9f1fbf584d9"), .queuedCommand, .notices(1),
              where: queuedCommand(mode: "task-notification", origin: "task-notification")),
        // Real lines from the other fixtures (shapes the extra session doesn't have).
        .init("system turn_duration (CLI turn end)", .fixtureMain(Fixtures.s5d78), .system, .system("turn_duration"), where: system("turn_duration")),
        .init("system compact_boundary", .fixtureMain(Fixtures.s5d78), .system, .system("compact_boundary"), where: system("compact_boundary")),
        .init("user compact summary", .fixtureMain(Fixtures.s5d78), .user, .userMeta, where: { $0["isCompactSummary"] as? Bool == true }),
        .init("system away_summary", .fixtureMain(Fixtures.s5d78), .system, .system("away_summary"), where: system("away_summary")),
        .init("system local_command", .fixtureMain(Fixtures.s5d78), .system, .system("local_command"), where: system("local_command")),
        .init("ai-title", .fixtureMain(Fixtures.s5d78), .aiTitle, .aiTitle, where: type("ai-title")),
        .init("permission-mode", .fixtureMain(Fixtures.s5d78), .skip, .none, where: type("permission-mode")),
        .init("mode", .fixtureMain(Fixtures.f275), .skip, .none, where: type("mode")),
        .init("queued_command prompt without origin", .fixtureMain(Fixtures.s5d78), .queuedCommand, .queuedPrompt,
              where: queuedCommand(mode: "prompt", origin: nil)),
        .init("queued_command human prompt", .fixtureMain(Fixtures.f275), .queuedCommand, .queuedPrompt, where: queuedCommand(mode: "prompt", origin: "human")),
        .init("user task notification (origin task-notification)", .fixtureMain(Fixtures.f275), .user, .userNotification,
              where: userString(origin: "task-notification")),
        .init("assistant API error (<synthetic>)", .fixtureMain(Fixtures.f275), .assistant, .assistantAPIError,
              where: { $0["isApiErrorMessage"] as? Bool == true }),
        .init("cost-state (process exit)", .fixtureMain(Fixtures.s08cb), .costState, .costState, where: type("cost-state")),
        .init("tool_result with an error string (Agent type not found)", .fixtureMain(Fixtures.s08cb), .user,
              .userToolResults(agentResult: false, isError: true), where: { ($0["toolUseResult"] as? String)?.hasPrefix("Error: Agent type") == true }),
        .init("tool_result with a completed Agent toolUseResult", .fixtureMain(Fixtures.s08cb), .user, .userToolResults(agentResult: true, isError: false),
              where: { ($0["toolUseResult"] as? [String: Any])?["status"] as? String == "completed" }),
        .init("fork-context-ref", .fixtureAgent(Fixtures.bd324, "achange-the-wake-up-7f18043573d76831"), .forkContextRef, .forkContextRef,
              where: type("fork-context-ref")),
        // Synthetic: documented shapes found in no fixture.
        .init("user interrupt (text block)", .synthetic(interruptBlocks), .user, .userInterrupt),
        .init("user interrupt for tool use (string)", .synthetic(interruptForToolUse), .user, .userInterrupt),
        .init("system api_error (a retry)", .synthetic(apiErrorRetry), .system, .system("api_error")),
        .init("file-history-snapshot", .synthetic(fileHistorySnapshot), .skip, .none),
        .init("file-history-delta", .synthetic(fileHistoryDelta), .skip, .none),
        .init("relocated", .synthetic(relocated), .relocated, .relocated),
        .init("bridge-session", .synthetic(bridgeSession), .skip, .none),
    ]
}

@Suite struct RealTranscriptParsingTests {
    let parser = LineParser()

    // MARK: Line classification

    @Test(arguments: LineShape.all)
    func lineShapeIsClassifiedAndParsed(_ shape: LineShape) throws {
        let line = try #require(shape.sample(), "no line of this shape in its source")
        #expect(classify(line) == shape.kind)
        #expect(ParsedShape(parser.parse(line)) == shape.parsed)

        if shape.kind == .skip {
            // Decided from a prefix: everything after the decisive value may be garbage, so the line is never decoded.
            let cut = try #require((1...min(line.count, LineScanner.limit)).first { classify(line.prefix($0)) == .skip })
            #expect(cut < line.count)
            var damaged = Data(line.prefix(cut))
            damaged.append(contentsOf: [0xFF, 0x00, 0x7B, 0x22])    // invalid UTF-8, NUL, an unclosed object and string
            #expect(classify(damaged) == .skip)
            #expect(parser.parse(damaged) == nil)
        }
    }

    /// Every line of the 8 files agrees with a reference decode, and none needs the full-decode fallback.
    @Test func scannerDecidesEveryExtraLineLikeAReferenceDecode() {
        var files: [(String, [Data])] = [("main", Extra.mainLines)]
        for aid in Extra.agentIDs { files.append((aid, Extra.lines(of: aid))) }
        var checked = 0, undecided = 0, skipped = 0
        for (name, lines) in files {
            for (i, line) in lines.enumerated() {
                let got = classify(line)
                #expect(got == Ref.expectedKind(Ref.json(line)), "\(name):\(i)")
                if got == .decode { undecided += 1 }
                if got == .skip {
                    skipped += 1
                    #expect(parser.parse(line) == nil, "\(name):\(i)")
                }
                checked += 1
            }
        }
        #expect(files.count == 8)
        #expect(checked == 1369 + 107 + 223 + 362 + 116 + 626 + 477 + 79)
        #expect(undecided == 0)
        #expect(skipped > 1000)
    }

    /// Golden event counts for the extra main file (1,369 lines).
    @Test func extraMainFileEventCounts() {
        var counts: [String: Int] = [:]
        for line in Extra.mainLines {
            let key: String
            switch parser.parse(line) {
            case nil: key = "nil"
            case .assistant?: key = "assistant"
            case .user?: key = "user"
            case .system?: key = "system"
            case .notices?: key = "notices"
            case .peerReport?: key = "peer"
            case .customTitle?: key = "customTitle"
            case let other?: key = "\(other)"
            }
            counts[key, default: 0] += 1
        }
        #expect(counts == ["assistant": 423, "user": 207, "system": 3, "notices": 18, "peer": 5, "customTitle": 87, "nil": 626])
    }

    // MARK: Agent calls and tool summaries

    @Test func everyAgentCallInTheExtraSession() throws {
        var types: [String?] = []
        for line in Extra.mainLines {
            for ref in Ref.toolUses(Ref.json(line)) where ref["name"] as? String == "Agent" {
                let input = try #require(ref["input"] as? [String: Any])
                guard case .assistant(let e)? = parser.parse(line), case .toolUse(let t)? = e.blocks.first else {
                    Issue.record("Agent call \(ref["id"] ?? "?") not parsed")
                    continue
                }
                #expect(t.id == ref["id"] as? String)
                #expect(t.name == "Agent")
                #expect(t.summary == input["description"] as? String)
                #expect(t.handbackMessage == nil)
                let call = try #require(t.agentCall)
                #expect(call.subagentType == input["subagent_type"] as? String)
                #expect(call.description == input["description"] as? String)
                #expect(call.prompt == input["prompt"] as? String)
                #expect(call.runInBackground == true)
                #expect(call.model == nil)                       // no `model` parameter in this session
                #expect(e.model == "claude-opus-5-5")
                types.append(call.subagentType)
            }
        }
        #expect(types == ["claude-code-guide", "Explore", "system-architect", "software-engineer", "software-engineer",
                          "software-engineer", "code-reviewer"])
    }

    @Test func agentCallModelParameterAndTheTaskAlias() throws {
        let real = Extra.mainLines[33]
        let withModel = try RawLine.replacing(#""run_in_background":true}"#, with: #""run_in_background":false,"model":"sonnet"}"#, in: real)
        guard case .assistant(let e)? = parser.parse(withModel), case .toolUse(let t)? = e.blocks.first else {
            Issue.record("not parsed")
            return
        }
        #expect(t.agentCall?.model == "sonnet")
        #expect(t.agentCall?.runInBackground == false)

        // Older versions name the tool `Task`.
        let task = try RawLine.replacing(#""name":"Agent""#, with: #""name":"Task""#, in: withModel)
        guard case .assistant(let e2)? = parser.parse(task), case .toolUse(let t2)? = e2.blocks.first else {
            Issue.record("Task call not parsed")
            return
        }
        #expect(t2.name == "Task")
        #expect(t2.agentCall?.subagentType == "claude-code-guide")
        #expect(t2.agentCall?.model == "sonnet")

        // The call's model is used until the agent's own lines or the launch result name a model.
        var s = SessionState(id: Extra.sid)
        fold([task], owner: .main, into: &s)
        let run = try #require(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"])
        #expect(run.callModel == "sonnet")
        #expect(!run.isBackground)
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: { _ in "opus" }).model == ModelInfo(id: "sonnet", source: .callParameter))
    }

    @Test func agentPromptIsCappedAt32KB() throws {
        let prompt = String(repeating: "\u{E9}", count: 40_000)     // 80,000 UTF-8 bytes
        let line = try RawLine.replacing(#""prompt":"txt-9f0c1ad2""#, with: #""prompt":"\#(prompt)""#, in: Extra.mainLines[33])
        guard case .assistant(let e)? = parser.parse(line), case .toolUse(let t)? = e.blocks.first else {
            Issue.record("not parsed")
            return
        }
        let capped = try #require(t.agentCall?.prompt)
        #expect(capped.utf8.count == 32 * 1024)              // 2-byte scalars: cut exactly on a boundary
        #expect(capped.allSatisfy { $0 == "\u{E9}" })

        // 3-byte scalars: the cap falls inside one and backs up to the boundary.
        let euros = String(repeating: "\u{20AC}", count: 20_000)
        let line3 = try RawLine.replacing(#""prompt":"txt-9f0c1ad2""#, with: #""prompt":"\#(euros)""#, in: Extra.mainLines[33])
        guard case .assistant(let e3)? = parser.parse(line3), case .toolUse(let t3)? = e3.blocks.first else {
            Issue.record("not parsed")
            return
        }
        let capped3 = try #require(t3.agentCall?.prompt)
        #expect(capped3.utf8.count == 32 * 1024 - (32 * 1024) % 3)
        #expect(capped3.allSatisfy { $0 == "\u{20AC}" })
    }

    /// Summaries of every tool_use in the 8 files: one line, ≤ 120 chars, from the documented input key.
    @Test func toolSummariesOfEveryRealToolUse() throws {
        var byTool: [String: Int] = [:]
        var files = [Extra.mainLines]
        for aid in Extra.agentIDs { files.append(Extra.lines(of: aid)) }
        for lines in files {
            for line in lines {
                guard let ref = Ref.toolUses(Ref.json(line)).first, let name = ref["name"] as? String else { continue }
                let input = ref["input"] as? [String: Any] ?? [:]
                guard case .assistant(let e)? = parser.parse(line), case .toolUse(let t)? = e.blocks.first else {
                    Issue.record("\(name) tool_use not parsed")
                    continue
                }
                #expect(t.summary.count <= 120)
                let multiline = t.summary.contains(where: \.isNewline)
                #expect(!multiline)
                let expected: String?
                switch name {
                case "Bash":    // description, else the command (one call here has no description)
                    let d = (input["description"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    expected = d ?? input["command"] as? String
                case "Read", "Write", "Edit": expected = input["file_path"] as? String   // tokenized: no "/"
                case "WebFetch": expected = input["url"] as? String              // tokenized: not a URL, kept as is
                case "WebSearch", "ToolSearch": expected = input["query"] as? String
                case "Agent": expected = input["description"] as? String
                case "SubagentHandback", "SendMessage": expected = ""
                default: expected = name.hasPrefix("mcp__") ? "" : nil
                }
                if let expected { #expect(t.summary == expected, "\(name)") } else { Issue.record("unexpected tool \(name)") }
                #expect((t.handbackMessage != nil) == (name == "SubagentHandback"))
                byTool[name, default: 0] += 1
            }
        }
        #expect(byTool["Bash"] == 115 + 15 + 52 + 55 + 21 + 101 + 77 + 1)
        #expect(byTool["SubagentHandback"] == 8)
        #expect(byTool["WebFetch"] == 15)
        #expect(byTool["Agent"] == 7)
    }

    struct SummaryCase: Sendable, CustomTestStringConvertible {
        var tool: String
        var input: String
        var expected: String
        var testDescription: String { "\(tool) \(input.prefix(60)) → \(expected.prefix(40))" }
    }

    static let summaryCases: [SummaryCase] = [
        .init(tool: "Bash", input: #"{"command":"git status\n--short","description":"   "}"#, expected: "git status"),
        .init(tool: "Bash", input: #"{"command":"x","description":"Run the suite\nand report"}"#, expected: "Run the suite"),
        .init(tool: "Bash", input: #"{"command":"\n\n   swift test --parallel   \n"}"#, expected: "swift test --parallel"),
        .init(tool: "Bash", input: #"{"command":"\#(String(repeating: "a", count: 500))"}"#, expected: String(repeating: "a", count: 119) + "…"),
        .init(tool: "Bash", input: #"{"command":"ls","description":"\#(String(repeating: "🙂", count: 200))"}"#,
              expected: String(repeating: "🙂", count: 119) + "…"),
        .init(tool: "Bash", input: #"{"command":["ls","-la"]}"#, expected: ""),
        .init(tool: "Read", input: #"{"file_path":"/Users/dev/Projects/AgentDeck/AgentDeckCore/Package.swift"}"#, expected: "AgentDeckCore/Package.swift"),
        .init(tool: "Read", input: #"{"file_path":"/Package.swift"}"#, expected: "Package.swift"),
        .init(tool: "Read", input: #"{"file_path":42}"#, expected: ""),
        .init(tool: "Edit", input: #"{"file_path":"/Users/dev/a b/c d.swift","old_string":"x","new_string":"y"}"#, expected: "a b/c d.swift"),
        .init(tool: "Write", input: #"{"file_path":"/tmp/out/","content":"…"}"#, expected: "tmp/out"),
        .init(tool: "MultiEdit", input: #"{"file_path":"Sources/App/main.swift","edits":[]}"#, expected: "App/main.swift"),
        .init(tool: "NotebookEdit", input: #"{"notebook_path":"/Users/dev/nb/analysis.ipynb","new_source":"x"}"#, expected: "nb/analysis.ipynb"),
        .init(tool: "LS", input: #"{"path":"/Users/dev/Projects"}"#, expected: "dev/Projects"),
        .init(tool: "Grep", input: #"{"pattern":"func\\s+parse\\(","path":"/Users/dev"}"#, expected: #"func\s+parse\("#),
        .init(tool: "Glob", input: #"{"pattern":"**/*.swift"}"#, expected: "**/*.swift"),
        .init(tool: "WebFetch", input: #"{"url":"https://code.claude.com/docs/en/hooks?tab=1#events","prompt":"p"}"#, expected: "code.claude.com/docs/en/hooks"),
        .init(tool: "WebFetch", input: #"{"url":"http://localhost:8080","prompt":"p"}"#, expected: "localhost"),
        .init(tool: "WebFetch", input: #"{"url":"not a url","prompt":"p"}"#, expected: "not a url"),
        .init(tool: "WebSearch", input: #"{"query":"swift testing withKnownIssue"}"#, expected: "swift testing withKnownIssue"),
        .init(tool: "Skill", input: #"{"skill":"pdf","args":"x"}"#, expected: "pdf"),
        .init(tool: "Agent", input: #"{"description":"Review the diff","subagent_type":"code-reviewer","prompt":"p"}"#, expected: "Review the diff"),
        .init(tool: "mcp__github__get_issue", input: #"{"url":"https://github.com/o/r/issues/1"}"#, expected: "github.com/o/r/issues/1"),
        .init(tool: "TodoWrite", input: #"{"todos":[{"content":"a","status":"pending"}]}"#, expected: ""),
    ]

    /// Summary rules on a real Bash tool_use line whose name and input are swapped.
    @Test(arguments: summaryCases)
    func toolSummaryRules(_ c: SummaryCase) throws {
        let line = try RawLine.replacing(#""name":"Bash","input":{"command":"txt-1be0ec84","description":"txt-689fb6da"}"#,
                                         with: #""name":"\#(c.tool)","input":\#(c.input)"#, in: Extra.mainLines[22])
        guard case .assistant(let e)? = parser.parse(line), case .toolUse(let t)? = e.blocks.first else {
            Issue.record("not parsed")
            return
        }
        #expect(t.id == "toolu_01X9aqdXV8Czu46AUr3V2NmC")
        #expect(t.summary == c.expected)
        #expect(t.summary.count <= 120)
    }

    // MARK: Tool result shapes

    @Test func asyncLaunchedResultsMatchTheReference() throws {
        var models: [String: String] = [:]
        for line in Extra.mainLines {
            let obj = Ref.json(line)
            guard let ref = obj["toolUseResult"] as? [String: Any], let aid = ref["agentId"] as? String else { continue }
            guard case .user(let e)? = parser.parse(line) else {
                Issue.record("result for \(aid) not parsed")
                continue
            }
            #expect(e.kind == .toolResults)
            let r = try #require(e.toolResults.first)
            #expect(r.toolUseID == Ref.blocks(obj).first?["tool_use_id"] as? String)
            #expect(!r.isError)
            #expect(r.errorText == nil)
            let ar = try #require(r.agentResult)
            #expect(ref["isAsync"] as? Bool == true)
            #expect(ar.status == "async_launched")
            #expect(ar.agentID == aid)
            #expect(ar.resolvedModel == ref["resolvedModel"] as? String)
            #expect(ar.totalDurationMs == nil)
            #expect(ar.text == nil)               // "Async agent launched successfully…" is not a report
            models[aid] = ar.resolvedModel
        }
        #expect(models.count == 7)
        #expect(Set(models.keys) == Set(Extra.agentIDs))
        #expect(models["af4448711daf1ca74"] == "claude-haiku-4-5-20251001")    // claude-code-guide
        #expect(models.values.filter { $0 == "claude-opus-5-5" }.count == 6)
    }

    @Test func completedResultCarriesExactUsageAndModel() throws {
        let completed = Fixtures.lines(Fixtures.mainPath(Fixtures.s08cb)) {
            ($0["toolUseResult"] as? [String: Any])?["status"] as? String == "completed"
        }
        let line = try #require(completed.first)
        guard case .user(let e)? = parser.parse(line) else {
            Issue.record("not user")
            return
        }
        let ar = try #require(e.toolResults.first?.agentResult)
        #expect(ar.resolvedModel == "claude-opus-5-5")
        #expect(ar.agentType == "general-purpose")
        #expect(ar.totalDurationMs == 38_698)
        #expect(ar.totalTokens == 115_853)
        // Only the 4 token counts are kept; nested objects (output_tokens_details, cache_creation, server_tool_use) are skipped.
        #expect(ar.usage == TokenUsage(input: 2, output: 2007, cacheRead: 105_183, cacheCreation: 8661))
        #expect(ar.usage?.total == ar.totalTokens)            // the four counts add up to totalTokens on this line
    }

    @Test func errorStringResultKeepsItsFirstLine() throws {
        let errors = Fixtures.lines(Fixtures.mainPath(Fixtures.s08cb)) { $0["toolUseResult"] is String }
        let line = try #require(errors.first)
        guard case .user(let e)? = parser.parse(line) else {
            Issue.record("not user")
            return
        }
        let r = try #require(e.toolResults.first)
        #expect(r.toolUseID == "toolu_0127jNYurxss4a2E8omtt4yH")
        #expect(r.isError)
        #expect(r.agentResult == nil)
        #expect(r.errorText == "Error: Agent type 'gmail-monitor' not found. Available agents: general-purpose")

        // A long multi-line error string: first line, at most 200 characters.
        let long = "Error: Agent type '\(String(repeating: "x", count: 300))' not found.\nAvailable agents: a, b"
        let longLine = try RawLine.replacing(#""toolUseResult":"Error: Agent type 'gmail-monitor' not found. Available agents: general-purpose""#,
                                             with: #""toolUseResult":"# + Ref.literal(long), in: line)
        guard case .user(let e2)? = parser.parse(longLine) else {
            Issue.record("not user")
            return
        }
        let text = try #require(e2.toolResults.first?.errorText)
        #expect(text.count == 200)
        #expect(text.hasPrefix("Error: Agent type 'xxx"))
        #expect(text.hasSuffix("…"))
        #expect(!text.contains("Available agents"))
    }

    @Test func twoToolResultsOnOneLineKeepTheAgentResultOnTheFirst() throws {
        let line = try RawLine.replacing(#"agentId: af4448711daf1ca74"}]}]"#,
                                         with: #"agentId: af4448711daf1ca74"}]},{"tool_use_id":"toolu_other","type":"tool_result","content":"x","is_error":true}]"#,
                                         in: Extra.mainLines[35])
        guard case .user(let e)? = parser.parse(line) else {
            Issue.record("not user")
            return
        }
        #expect(e.toolResults.map(\.toolUseID) == ["toolu_018qrqzL6FSeQxxoqveyoN5h", "toolu_other"])
        #expect(e.toolResults[0].agentResult?.agentID == "af4448711daf1ca74")
        #expect(e.toolResults[1].agentResult == nil)
        #expect(e.toolResults[1].isError)
    }

    @Test func agentResultWithAnErrorStatusFailsTheRun() throws {
        var line = try RawLine.replacing(#""status":"async_launched""#, with: #""status":"error""#, in: Extra.mainLines[35])
        line = try RawLine.replacing(#""type":"tool_result","#, with: #""type":"tool_result","is_error":true,"#, in: line)
        var s = SessionState(id: Extra.sid)
        fold([Extra.mainLines[33], line], owner: .main, into: &s)
        let run = try #require(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"])
        #expect(run.agentID == "af4448711daf1ca74")
        #expect(run.baseStatus == .failed)
        #expect(!run.launched)
        #expect(run.resolvedModel == "claude-haiku-4-5-20251001")
    }

    /// Non-Agent results never carry an Agent result, and only errors carry error text.
    @Test func nonAgentToolResultsCarryNoAgentResult() {
        var results = 0
        for line in Extra.mainLines {
            guard case .user(let e)? = parser.parse(line), e.kind == .toolResults else { continue }
            let obj = Ref.json(line)
            let isAgent = (obj["toolUseResult"] as? [String: Any])?["agentId"] != nil
            for r in e.toolResults {
                #expect((r.agentResult != nil) == isAgent)
                if !r.isError { #expect(r.errorText == nil) }
                results += 1
            }
        }
        #expect(results == 203)
    }

    // MARK: Task notifications

    /// Every notification block on every carrier line of the 8 files matches a reference tag scan.
    @Test func notificationsOnEveryCarrierLineMatchTheReference() throws {
        var files = [Extra.mainLines]
        for aid in Extra.agentIDs { files.append(Extra.lines(of: aid)) }
        var agent = 0, bash = 0
        for lines in files {
            for line in lines {
                let notices: [TaskNotice]
                switch parser.parse(line) {
                case .notices(let n, _)?: notices = n
                case .user(let u)? where u.kind == .notification: notices = u.notices
                default: continue
                }
                let obj = Ref.json(line)
                let text = try #require((obj["content"] as? String)
                    ?? (obj["attachment"] as? [String: Any])?["prompt"] as? String ?? Ref.message(obj)["content"] as? String)
                #expect(notices.count == 1)
                let n = try #require(notices.first)
                #expect(n.taskID == Ref.tag("task-id", in: text))
                #expect(n.toolUseID == Ref.tag("tool-use-id", in: text))
                #expect(n.status == "completed")
                #expect(n.durationMs == Ref.tag("duration_ms", in: text).flatMap { Int($0) })
                #expect(n.subagentTokens == Ref.tag("subagent_tokens", in: text).flatMap { Int($0) })
                #expect(n.summary == Ref.tag("summary", in: text))
                #expect(n.result == nil)                         // `<result>…</result>`: a bare ellipsis is no report
                if n.taskID?.hasPrefix("b") == true {
                    bash += 1
                    #expect(n.durationMs == nil)                 // Bash tasks have no <usage>
                    #expect(n.summary?.hasPrefix("Background command") == true)
                } else {
                    agent += 1
                    #expect(n.durationMs != nil)
                    #expect(n.subagentTokens != nil)
                    #expect(n.summary?.hasPrefix("Agent \"") == true)
                }
            }
        }
        #expect(agent == 16)   // 8 Agent notices (one a SendMessage resume), each on a queue-operation and an attachment
        #expect(bash == 4)     // 2 Bash notices on the main file, and on the subagent that started each task
    }

    @Test func bashTaskNoticesCarryTheBashToolUseID() throws {
        var bashIDs: Set<String> = []
        var files = [Extra.mainLines]
        for aid in Extra.agentIDs { files.append(Extra.lines(of: aid)) }
        for lines in files {
            for line in lines {
                for t in Ref.toolUses(Ref.json(line)) where t["name"] as? String == "Bash" { bashIDs.insert(t["id"] as! String) }
            }
        }
        let notices = Extra.mainLines.compactMap { line -> TaskNotice? in
            guard case .notices(let n, _)? = parser.parse(line), let first = n.first, first.taskID?.hasPrefix("b") == true else { return nil }
            return first
        }
        #expect(notices.map(\.taskID) == ["bter9wanp", "b7m0ifs3j"])
        for n in notices {
            #expect(bashIDs.contains(n.toolUseID ?? ""), "\(n.toolUseID ?? "nil") is a Bash call")
            #expect(!Extra.agentCallIDs.contains(n.toolUseID ?? ""))
        }
    }

    /// The Explore agent's real handback (a2cb440a58ad617b7, SubagentHandback) quotes another agent's
    /// `<task-notification>`. The parent records a peer message as `queue-operation` content and as a
    /// `queued_command` prompt wrapped in `<agent-message>` (tokenized in the fixture; restored here from the real
    /// handback text and the wrapper visible on the peer user lines). A peer message is not a notification.
    @Test func peerHandbackQuotingANotificationIsNotANotification() throws {
        let handbackLine = try #require(Extra.lines(of: "a2cb440a58ad617b7").first {
            Ref.toolUses(Ref.json($0)).first?["name"] as? String == "SubagentHandback"
        })
        let message = try #require((Ref.toolUses(Ref.json(handbackLine)).first?["input"] as? [String: Any])?["message"] as? String)
        #expect(message.hasPrefix("<task-notification>\n<task-id>af4448711daf1ca74</task-id>"))
        let wrapped = "Another Claude session sent a message:\n<agent-message from=\"a2cb440a58ad617b7\">\(message)</agent-message>"
        // Lines 303 and 312: the parent's queue-operation and queued_command for that handback.
        let origin = (Ref.json(Extra.mainLines[312])["attachment"] as? [String: Any])?["origin"] as? [String: Any]
        #expect(origin?["kind"] as? String == "peer")
        #expect(origin?["from"] as? String == "a2cb440a58ad617b7")
        let queueLine = try RawLine.replacing(#""content":"txt-7c5a7ecb""#, with: #""content":"# + Ref.literal(wrapped), in: Extra.mainLines[303])
        let attachmentLine = try RawLine.replacing(#""prompt":"txt-7c5a7ecb""#, with: #""prompt":"# + Ref.literal(wrapped), in: Extra.mainLines[312])

        withKnownIssue("LineParser reads <task-notification> blocks out of peer messages: notices are checked before origin.kind == \"peer\" (queuedCommand), and queue-operation content isn't checked to be a notification") {
            let event = parser.parse(attachmentLine)
            guard case .peerReport(let from, _)? = event else {
                Issue.record("peer attachment parsed as \(ParsedShape(event))")
                return
            }
            #expect(from == "a2cb440a58ad617b7")
            #expect(parser.parse(queueLine) == nil)
        }

        // The quoted notice (usage in a non-tag form, so a different identity) overwrites af44's exact outcome:
        // durationMs 186,693 is lost and the run's end moves from 23:59:56 to 00:07:34.
        var s = Extra.reduced
        let before = try #require(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"]?.exact)
        #expect(before.durationMs == 186_693)
        fold([queueLine, attachmentLine], owner: .main, into: &s)
        withKnownIssue("A peer handback quoting another agent's notification re-finishes that agent") {
            #expect(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"]?.exact == before)
        }
    }

    // MARK: Durations mode and paths

    @Test func durationsModeKeepsTheAgentSignalsOfTheExtraSession() {
        let durations = LineParser(mode: .durations)
        var calls = 0, results = 0, notices = 0
        var models: Set<String> = []
        for line in Extra.mainLines {
            switch durations.parse(line) {
            case .assistant(let e)?:
                if let m = e.model { models.insert(m) }
                for case .toolUse(let t) in e.blocks where t.agentCall != nil { calls += 1 }
            case .user(let e)?:
                results += e.toolResults.filter { $0.agentResult != nil }.count
                notices += e.notices.count
            case .notices(let n, _)?:
                notices += n.count
            case nil:
                break
            case let other?:
                Issue.record("durations mode produced \(ParsedShape(other))")
            }
        }
        #expect(calls == 7)
        #expect(results == 7)
        #expect(notices == 18)
        #expect(models == ["claude-opus-5-5"])
    }

    @Test func pathClassifierOnTheExtraSessionTree() throws {
        let classifier = PathClassifier(dataRoot: Extra.root)
        let root = classifier.canonicalRoot
        let projects = (root as NSString).appendingPathComponent("projects")
        let dir = (projects as NSString).appendingPathComponent("-Users-dev-Projects-AgentDeck")
        let sid = Extra.sid
        var seen: [String: Int] = [:]
        for case let rel as String in FileManager.default.enumerator(atPath: dir)! {
            let path = (dir as NSString).appendingPathComponent(rel)
            let role = classifier.classify(path)
            switch role {
            case .main(let s): #expect(s == sid); seen["main", default: 0] += 1
            case .subagent(let s, let a): #expect(s == sid && Extra.agentIDs.contains(a)); seen["subagent", default: 0] += 1
            case .meta(let s, let a): #expect(s == sid && Extra.agentIDs.contains(a)); seen["meta", default: 0] += 1
            case .title(let s): #expect(s == sid); seen["title", default: 0] += 1
            case .sessionDirectory(let s): #expect(s == sid); seen["dir", default: 0] += 1
            default: Issue.record("\(rel) → \(role)")
            }
        }
        #expect(seen == ["main": 1, "subagent": 7, "meta": 7, "title": 1, "dir": 2])
        #expect(classifier.classify(dir) == .projectDirectory)
        #expect(classifier.classify(projects) == .watchedDirectory)
        let session = (dir as NSString).appendingPathComponent(sid)
        for ignored in ["\(session)/tool-results/toolu_01.txt", "\(session).desktop-released.json", "\(dir)/memory",
                        "\(session)/subagents/agent-.jsonl", "\(session)/subagents/notes.jsonl", "\(dir)/.jsonl",
                        "/elsewhere/projects/x/\(sid).jsonl"] {
            #expect(classifier.classify(ignored) == .ignored, "\(ignored)")
        }
    }
}
