import Foundation
import Testing
@testable import AgentDeckCore

/// Hostile and malformed input, built from real lines of the `extra` session. Nothing may crash; each line yields a
/// sensible event or is skipped, and huge fields never reach session state or snapshots.
@Suite struct ParserRobustnessTests {
    let parser = LineParser()

    // Real lines (indexes in the extra main file).
    static var prompt: Data { Extra.mainLines[2] }          // user prompt, origin human
    static var bashCall: Data { Extra.mainLines[22] }       // assistant Bash tool_use
    static var agentCall: Data { Extra.mainLines[33] }      // assistant Agent tool_use (claude-code-guide)
    static var launch: Data { Extra.mainLines[35] }         // user tool_result, async_launched
    static var queueNotice: Data { Extra.mainLines[84] }    // queue-operation enqueue <task-notification>
    static var peer: Data { Extra.mainLines[90] }           // queued_command attachment, peer handback
    static var attachmentNotice: Data { Extra.mainLines[91] }
    static var samples: [Data] { [prompt, bashCall, agentCall, launch, queueNotice, peer, attachmentNotice] }

    static func line(where match: ([String: Any]) -> Bool) -> Data { Extra.mainLines.first { match(Ref.json($0)) }! }

    // MARK: Truncation and degenerate lines

    /// A partial line (a write in progress) never yields an event from a decoded kind.
    @Test func truncatedRealLinesYieldNothing() {
        var lines = Self.samples
        lines.append(Self.line { Ref.type($0) == "system" })
        lines.append(Self.line { Ref.type($0) == "custom-title" })
        var checked = 0
        for line in lines {
            #expect(parser.parse(line) != nil)
            for n in stride(from: 0, to: line.count, by: 3) {
                let prefix = line.prefix(n)
                #expect(parser.parse(Data(prefix)) == nil, "prefix \(n) of \(RawLine.string(line.prefix(40)))")
                checked += 1
            }
        }
        #expect(checked > 2000)
        // Presence-only kinds are decided from the type alone (the engine only hands complete lines to the parser).
        guard case .costState? = parser.parse(#"{"type":"cost-state","sessionId":"08cb7b8e","totalCostUSD":1."#) else {
            Issue.record("cost-state prefix")
            return
        }
    }

    struct Degenerate: Sendable, CustomTestStringConvertible {
        var input: String
        var parsed: ParsedShape
        var testDescription: String { input.isEmpty ? "(empty)" : String(input.prefix(70)) }
    }

    static let degenerate: [Degenerate] = [
        .init(input: "", parsed: .none),
        .init(input: "   \t ", parsed: .none),
        .init(input: "{}", parsed: .none),
        .init(input: "{ }", parsed: .none),
        .init(input: "[]", parsed: .none),
        .init(input: "null", parsed: .none),
        .init(input: #""user""#, parsed: .none),
        .init(input: "{", parsed: .none),
        .init(input: "}", parsed: .none),
        .init(input: #"{"type":}"#, parsed: .none),
        .init(input: #"{"type":null}"#, parsed: .none),
        .init(input: #"{"type":123,"message":{"content":"x"}}"#, parsed: .none),
        .init(input: #"{"type":"brand-new-kind","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t","name":"Agent","input":{}}]}}"#, parsed: .none),
        .init(input: #"{"type":"us\u0065r","message":{"role":"user","content":"hi"}}"#, parsed: .none),   // escaped type: not recognized, skipped
        .init(input: #"{"type":"attachment","attachment":"queued_command"}"#, parsed: .none),
        .init(input: #"{"attachment":{"type":"queued_command"},"type":"attachment"}"#, parsed: .none),          // no prompt
        .init(input: #"{"type":"queue-operation","operation":"enqueue","content":{"x":"<task-notification>"}}"#, parsed: .none),
        .init(input: #"{"type":"custom-title"}"#, parsed: .none),
        .init(input: #"{"type":"user"}"#, parsed: .userMeta),
        .init(input: #"{"type":"user","message":{"role":"user","content":42}}"#, parsed: .userMeta),
        .init(input: #"{"type":"system"}"#, parsed: .system(nil)),
        .init(input: #"{"type":"assistant","message":"text"}"#, parsed: .assistantOther),
        .init(input: #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#, parsed: .assistantOther),  // no id: dropped
    ]

    @Test(arguments: degenerate)
    func degenerateLinesAreSkippedOrMinimal(_ d: Degenerate) {
        #expect(ParsedShape(parser.parse(d.input)) == d.parsed)
        #expect(ParsedShape(LineParser(mode: .durations).parse(d.input)) != .assistantToolUse)
    }

    // MARK: Huge fields

    /// 2 MB payloads in every free-text field AgentDeck reads or skips: none is retained beyond its cap.
    @Test func twoMegabyteFieldsAreNotRetained() throws {
        // 2 MB of text in 32k lines, as a JSON string literal (built directly: "\n" escaped).
        let huge = "\"" + String(repeating: String(repeating: "x", count: 63) + "\\n", count: 32 * 1024) + "\""
        #expect(huge.utf8.count == 2 * 1024 * 1024 + 32 * 1024 + 2)
        let bashResult = Self.line { Ref.blocks($0).first?["tool_use_id"] as? String == "toolu_01X9aqdXV8Czu46AUr3V2NmC" }

        let main: [Data] = [
            try RawLine.replacing(#""content":"txt-2a51893f""#, with: #""content":"# + huge, in: Self.prompt),
            try RawLine.replacing(#""command":"txt-1be0ec84","description":"txt-689fb6da""#, with: #""command":"# + huge, in: Self.bashCall),
            try RawLine.replacing(#""stdout":"#, with: #""stdout":"# + huge + #","ignored":"#, in: bashResult),
            try RawLine.replacing(#""prompt":"txt-9f0c1ad2""#, with: #""prompt":"# + huge, in: Self.agentCall),
            Self.launch,
            try RawLine.replacing(#""body":"txt-cb8eb1bf""#, with: #""body":"# + huge, in: Self.peer),
            try RawLine.replacing("<result>…</result>", with: "<result>" + String(huge.dropFirst().dropLast()) + "</result>", in: Self.queueNotice),
        ]
        let text = try RawLine.replacing(#""content":[{"type":"tool_use""#, with: #""content":[{"type":"text","text":"# + huge + #"},{"type":"tool_use""#, in: Self.bashCall)
        guard case .assistant(let a)? = parser.parse(text), case .text(let t)? = a.blocks.first else {
            Issue.record("text block")
            return
        }
        #expect(t.count == 300)                          // text blocks: first 300 chars

        var s = SessionState(id: Extra.sid)
        s.mainSeen = true
        SessionReducer.applyMeta(Extra.meta("af4448711daf1ca74"), agentID: "af4448711daf1ca74", to: &s, now: Extra.now)
        fold(main, owner: .main, into: &s)
        // The agent's own file: a 2 MB prompt and a 2 MB SubagentHandback message.
        let own = Extra.lines(of: "af4448711daf1ca74")
        let handback = own.first { Ref.toolUses(Ref.json($0)).first?["name"] as? String == "SubagentHandback" }!
        fold([try RawLine.replacing(#""content":"txt-9f0c1ad2""#, with: #""content":"# + huge, in: own[0]),
              try RawLine.replacing(#""message":"txt-551757ca""#, with: #""message":"# + huge, in: handback)],
             owner: .agent("af4448711daf1ca74"), into: &s)

        let cap = 32 * 1024                              // documented caps (architecture §memory), not the constants
        #expect(s.main.prompt.utf8.count <= cap)
        #expect((s.firstPrompt ?? "").count <= 120)
        let run = try #require(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"])
        #expect(run.prompt.utf8.count <= cap)
        #expect((run.own.firstPrompt ?? "").count <= 120)
        #expect((run.own.handbackReport ?? "").count <= 400)
        #expect((run.resultSummary ?? "").count <= 400)
        #expect(s.peerReports.values.allSatisfy { $0.count <= 400 })
        for tool in s.main.own.recentTools + run.own.recentTools { #expect(tool.summary.count <= 120) }

        let snap = Fixtures.snapshot(s, now: Extra.now)
        let encoded = try JSONEncoder().encode(snap)
        #expect(encoded.count < 2 * cap + 16 * 1024)     // two capped prompts plus small fields
        #expect(snap.title.count <= 120)
    }

    // MARK: Encoding

    @Test func invalidUTF8InASkippedOrUndecodedFieldChangesNothing() throws {
        let bashResult = Self.line { Ref.blocks($0).first?["tool_use_id"] as? String == "toolu_01X9aqdXV8Czu46AUr3V2NmC" }
        var damaged = bashResult
        let stdout = try #require(RawLine.string(damaged).range(of: #""stdout":""#))
        let offset = RawLine.string(damaged).utf8.distance(from: RawLine.string(damaged).startIndex, to: stdout.upperBound)
        damaged.insert(contentsOf: [0xFF, 0xFE, 0xC3, 0x28, 0xED, 0xA0, 0x80], at: offset)    // invalid bytes, an encoded surrogate
        #expect(fingerprint(parser.parse(damaged)) == fingerprint(parser.parse(bashResult)))

        var skipped = Data(#"{"type":"last-prompt","lastPrompt":""#.utf8)
        skipped.append(contentsOf: [0xFF, 0xC0, 0x80])
        skipped.append(contentsOf: Data(#"","sessionId":"s"}"#.utf8))
        #expect(classify(skipped) == .skip)
        #expect(parser.parse(skipped) == nil)
    }

    @Test func invalidUTF8InADecodedFieldDropsOnlyThatField() throws {
        // A prompt whose text can't be decoded: still a user line (timestamp kept), never a garbled prompt.
        var badPrompt = try RawLine.replacing("txt-2a51893f", with: "txt-2a51893f\u{FFFD}", in: Self.prompt)
        let marker = Data("\u{FFFD}".utf8)
        let r = try #require(badPrompt.range(of: marker))
        badPrompt.replaceSubrange(r, with: [0xFF])
        guard case .user(let u)? = parser.parse(badPrompt) else {
            Issue.record("not a user line")
            return
        }
        #expect(u.kind == .meta)
        #expect(u.context.timestamp == Timestamp.parse("2026-10-02T23:56:28.204Z"))
        #expect(u.context.cwd == "/Users/dev/Projects/AgentDeck")

        // An Agent call whose description can't be decoded: the call (and its run) survive.
        var badCall = try RawLine.replacing(#""description":"txt-e1e763bd""#, with: #""description":"txt-\#u{FFFD}""#, in: Self.agentCall)
        let r2 = try #require(badCall.range(of: marker))
        badCall.replaceSubrange(r2, with: [0xC3])     // a truncated 2-byte sequence
        let lone = try RawLine.replacing(#""description":"txt-e1e763bd""#, with: #""description":"half \ud83d""#, in: Self.agentCall)
        for line in [badCall, lone] {
            guard case .assistant(let e)? = parser.parse(line), case .toolUse(let t)? = e.blocks.first else {
                Issue.record("Agent call lost")
                continue
            }
            #expect(t.id == "toolu_018qrqzL6FSeQxxoqveyoN5h")
            #expect(t.agentCall?.subagentType == "claude-code-guide")
            #expect(t.agentCall?.description == nil)
            #expect(t.summary == "")
            var s = SessionState(id: Extra.sid)
            fold([line], owner: .main, into: &s)
            #expect(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"]?.agentType == "claude-code-guide")
        }

        // Garbage before the object: undecidable and undecodable, skipped.
        var prefixed = Data([0xFF, 0xFE])
        prefixed.append(Self.prompt)
        #expect(classify(prefixed) == .decode)
        #expect(parser.parse(prefixed) == nil)
    }

    @Test func crlfLineEndingsParseTheSame() {
        var lines = Self.samples
        lines += [Self.line { Ref.type($0) == "system" }, Self.line { Ref.type($0) == "custom-title" },
                  Self.line { Ref.type($0) == "last-prompt" }]
        for line in lines {
            var crlf = line
            crlf.append(0x0D)
            #expect(classify(crlf) == classify(line))
            #expect(fingerprint(parser.parse(crlf)) == fingerprint(parser.parse(line)))
        }
    }

    /// The whole main file with CRLF endings, split on LF like the engine: the same session.
    @Test func crlfFileFoldsToTheSameSession() {
        var lf = SessionState(id: Extra.sid)
        fold(Extra.mainLines, owner: .main, into: &lf)
        var crlf = SessionState(id: Extra.sid)
        fold(Extra.mainLines.map { $0 + Data([0x0D]) }, owner: .main, into: &crlf)
        #expect(crlf.main == lf.main)
        #expect(crlf.runs == lf.runs)
        #expect(crlf.customTitle == lf.customTitle)
        #expect(crlf.peerReports == lf.peerReports)
        #expect(crlf.startedAt == lf.startedAt && crlf.lastActivityAt == lf.lastActivityAt)
    }

    @Test func byteOrderMarkOnTheFirstLineIsTolerated() {
        for line in [Extra.mainLines[0], Self.prompt, Self.agentCall] {
            let bom = Data([0xEF, 0xBB, 0xBF]) + line
            #expect(classify(bom) == .decode)        // not '{': the envelope probe decides
            #expect(fingerprint(parser.parse(bom)) == fingerprint(parser.parse(line)))
        }
    }

    // MARK: Key order

    /// `line` with `"type":"<t>",` moved to the end of the top-level object.
    static func typeLast(_ line: Data, _ t: String) throws -> Data {
        let s = RawLine.string(line)
        let key = #""type":"\#(t)","#
        let r = try #require(s.range(of: key))
        var moved = s.replacingCharacters(in: r, with: "")
        moved.removeLast()                       // "}"
        moved += #","type":"\#(t)"}"#
        return Data(moved.utf8)
    }

    @Test func messageBeforeTypeOnUserLinesIsRerouted() throws {
        for line in [Self.prompt, Self.launch] {
            let moved = try Self.typeLast(line, "user")
            #expect(classify(moved) == .assistant)   // the scanner's guess from `message`
            #expect(fingerprint(parser.parse(moved)) == fingerprint(parser.parse(line)))
        }
    }

    @Test func typeBeforeAttachmentAndTypeFirstOnAssistantLines() throws {
        // Attachment: `type` moved to the front, before `attachment`.
        for line in [Self.peer, Self.attachmentNotice] {
            let s = RawLine.string(line)
            let front = Data((#"{"type":"attachment","# + s.dropFirst()).replacingOccurrences(of: #","type":"attachment","#, with: ",").utf8)
            #expect(Ref.type(Ref.json(front)) == "attachment")
            #expect(classify(front) == .queuedCommand)
            #expect(fingerprint(parser.parse(front)) == fingerprint(parser.parse(line)))
        }
        // Assistant: `type` first instead of after `message`.
        let s = RawLine.string(Self.agentCall)
        let front = Data((#"{"type":"assistant","# + s.dropFirst()).replacingOccurrences(of: #","type":"assistant","#, with: ",").utf8)
        #expect(classify(front) == .assistant)
        #expect(fingerprint(parser.parse(front)) == fingerprint(parser.parse(Self.agentCall)))
    }

    @Test func attachmentTypeNotFirstFallsBackToTheEnvelopeProbe() throws {
        for line in [Self.peer, Self.attachmentNotice] {
            let moved = try RawLine.replacing(#""attachment":{"type":"queued_command","#,
                                              with: #""attachment":{"deliveryHint":1,"type":"queued_command","#, in: line)
            #expect(classify(moved) == .decode)
            #expect(fingerprint(parser.parse(moved)) == fingerprint(parser.parse(line)))
        }
        // Not a queued_command: the probe skips it.
        let reminder = Self.line { Ref.attachmentType($0) == "total_tokens_reminder" }
        let moved = try RawLine.replacing(#""attachment":{"type":"total_tokens_reminder""#,
                                          with: #""attachment":{"n":1,"type":"total_tokens_reminder""#, in: reminder)
        #expect(classify(moved) == .decode)
        #expect(parser.parse(moved) == nil)
    }

    /// A large field before `type`: decided by the scanner within 4 KB, else by the envelope probe; same event.
    @Test func typeAfterALargeLeadingFieldAroundTheScanLimit() {
        let reference = fingerprint(parser.parse(Self.prompt))
        var kinds: Set<String> = []
        for pad in [3_000] + Array(stride(from: 4_020, through: 4_110, by: 3)) {
            let line = Data((#"{"parentUuidLike":"\#(String(repeating: "f", count: pad))","# + RawLine.string(Self.prompt).dropFirst()).utf8)
            let kind = classify(line)
            #expect(kind == .user || kind == .decode, "pad \(pad)")
            if pad == 3_000 { #expect(kind == .user) }
            kinds.insert("\(kind)")
            #expect(fingerprint(parser.parse(line)) == reference, "pad \(pad)")
        }
        #expect(kinds == ["user", "decode"])
    }

    @Test func typeInsideNestedStringsIsNotTheLineType() {
        let body = RawLine.string(Self.prompt).dropFirst()
        let reference = fingerprint(parser.parse(Self.prompt))
        for lead in [#""parentUuid":"{\"type\":\"cost-state\"}","#,
                     #""note":"\"type\":\"assistant\",\"message\":{}","#,
                     #""path":"C:\\","#,
                     #""nested":{"type":"queue-operation","attachment":{"type":"queued_command"}},"#,
                     #""list":[{"type":"custom-title"},"\"type\"",["type"]],"#,
                     #""type_hint":"system","#] {
            let line = Data(("{" + lead + body).utf8)
            #expect(classify(line) == .user, "\(lead)")
            #expect(fingerprint(parser.parse(line)) == reference, "\(lead)")
        }
    }

    @Test func deeplyNestedFieldsDoNotCrash() {
        let body = RawLine.string(Self.prompt).dropFirst()
        for depth in [100, 1_000, 100_000] {
            let nest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            let line = Data((#"{"x":"# + nest + "," + body).utf8)
            let event = parser.parse(line)
            if depth == 100 {
                #expect(fingerprint(event) == fingerprint(parser.parse(Self.prompt)))
            } else {
                #expect(event == nil, "depth \(depth)")     // beyond the decoder's nesting limit: skipped
            }
        }
    }

    // MARK: Field types and values

    @Test func wrongTypedFieldsAreLenient() throws {
        // Agent call: a non-Bool run_in_background and a numeric model keep the call.
        let call = try RawLine.replacing(#""run_in_background":true"#, with: #""run_in_background":"yes","model":7"#, in: Self.agentCall)
        guard case .assistant(let e)? = parser.parse(call), case .toolUse(let t)? = e.blocks.first else {
            Issue.record("call lost")
            return
        }
        #expect(t.agentCall?.runInBackground == nil)
        #expect(t.agentCall?.model == nil)
        #expect(t.agentCall?.subagentType == "claude-code-guide")

        // Assistant usage with a string count; a numeric timestamp.
        let usage = try RawLine.replacing(#""output_tokens":3025"#, with: #""output_tokens":"many""#, in: Self.agentCall)
        let stamp = try RawLine.replacing(#""timestamp":"2026-10-02T23:56:49.573Z""#, with: #""timestamp":1790985409573"#, in: usage)
        guard case .assistant(let e2)? = parser.parse(stamp) else {
            Issue.record("assistant lost")
            return
        }
        #expect(e2.usage == TokenUsage(input: 2, output: 0, cacheRead: 75_306, cacheCreation: 3571))
        #expect(e2.context.timestamp == nil)
        #expect(e2.blocks.count == 1)

        // User prompt with origin as a string and isMeta as a string: still a prompt.
        let prompt = try RawLine.replacing(#""origin":{"kind":"human"}"#, with: #""origin":"human","isMeta":"no""#, in: Self.prompt)
        guard case .user(let u)? = parser.parse(prompt) else {
            Issue.record("prompt lost")
            return
        }
        #expect(u.kind == .prompt("txt-2a51893f"))

        // Agent result whose toolUseResult is an array: a plain tool result, not an Agent result.
        let tur = RawLine.string(Self.launch)
        let start = try #require(tur.range(of: #""toolUseResult":{"#))
        let end = try #require(tur.range(of: #""canReadOutputFile":true}"#, range: start.upperBound..<tur.endIndex))
        let arrayResult = Data(tur.replacingCharacters(in: start.lowerBound..<end.upperBound, with: #""toolUseResult":[1,2]"#).utf8)
        guard case .user(let r)? = parser.parse(arrayResult) else {
            Issue.record("result lost")
            return
        }
        #expect(r.kind == .toolResults)
        #expect(r.toolResults.first?.agentResult == nil)
    }

    @Test func outOfRangeNotificationDurationsEndAtTheSignal() throws {
        for value in ["-5", "99999999999999999999", "86400000000", " 1000 "] {
            var s = Extra.reduce(mainLines: 84, withSubagents: false)
            let line = try RawLine.replacing("<duration_ms>186693</duration_ms>", with: "<duration_ms>\(value)</duration_ms>", in: Self.queueNotice)
            fold([line], owner: .main, into: &s)
            let run = try #require(s.runs["toolu_018qrqzL6FSeQxxoqveyoN5h"])
            #expect(run.baseStatus == .done, "\(value)")
            let signal = Timestamp.parse("2026-10-03T00:00:14.222Z")!
            if value == " 1000 " {
                #expect(run.exact?.durationMs == 1000)
                #expect(run.exact?.endedAt == signal)      // start + 1 s is more than 60 s before the signal
            } else {
                #expect(run.exact?.endedAt == signal, "\(value)")
            }
            let snap = try #require(Fixtures.snapshot(s, now: Extra.now).run("toolu_018qrqzL6FSeQxxoqveyoN5h"))
            #expect(snap.endedAt! >= snap.startedAt)
        }
    }
}
