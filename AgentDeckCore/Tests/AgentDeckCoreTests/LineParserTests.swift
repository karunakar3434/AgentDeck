import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct LineParserTests {
    let parser = LineParser()

    private func toolUseLine(_ sid: String, id: String) throws -> Data {
        let matches = Fixtures.lines(Fixtures.mainPath(sid)) { obj in
            guard obj["type"] as? String == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["id"] as? String == id }
        }
        return try #require(matches.first)
    }

    private func resultLine(_ sid: String, toolUseID: String) throws -> Data {
        let matches = Fixtures.lines(Fixtures.mainPath(sid)) { obj in
            guard obj["type"] as? String == "user",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["tool_use_id"] as? String == toolUseID }
        }
        return try #require(matches.first)
    }

    @Test func agentToolUseFromFixture() throws {
        let line = try toolUseLine(Fixtures.f275, id: "toolu_01Y9rxasMpSGkA3SKwTfrYHv")
        guard case .assistant(let e) = parser.parse(line) else { Issue.record("not assistant"); return }
        #expect(e.model == "claude-opus-5-5")
        #expect(e.messageID != nil)
        #expect(e.context.timestamp == Timestamp.parse("2026-10-01T21:25:25.603Z"))
        #expect(e.context.cwd != nil)
        guard case .toolUse(let t) = e.blocks.first else { Issue.record("no tool_use"); return }
        #expect(t.name == "Agent")
        #expect(t.summary == "txt-dd192ca6")
        let call = try #require(t.agentCall)
        #expect(call.subagentType == "localbiz-site-builder")
        #expect(call.description == "txt-dd192ca6")
        #expect(call.runInBackground == true)
        #expect(call.prompt == "txt-af2e43c8")
    }

    @Test func asyncLaunchedResult() throws {
        let line = try resultLine(Fixtures.f275, toolUseID: "toolu_01Y9rxasMpSGkA3SKwTfrYHv")
        guard case .user(let e) = parser.parse(line) else { Issue.record("not user"); return }
        #expect(e.kind == .toolResults)
        let r = try #require(e.toolResults.first)
        #expect(r.toolUseID == "toolu_01Y9rxasMpSGkA3SKwTfrYHv")
        #expect(!r.isError)
        #expect(r.agentResult?.status == "async_launched")
        #expect(r.agentResult?.agentID == "a28854a40750f97c0")
        #expect(r.agentResult?.resolvedModel == "claude-opus-5-5")
    }

    @Test func foregroundCompletedResultHasExactDuration() throws {
        let line = try resultLine(Fixtures.s08cb, toolUseID: "toolu_014VmCt9hdrzPCCUfBoz8GxZ")
        guard case .user(let e) = parser.parse(line) else { Issue.record("not user"); return }
        let ar = try #require(e.toolResults.first?.agentResult)
        #expect(ar.status == "completed")
        #expect(ar.agentID == "a140524516f2ac0a4")
        #expect(ar.agentType == "general-purpose")
        #expect(ar.totalDurationMs == 38_698)
        #expect(ar.totalTokens == 115_853)
        #expect(ar.usage != nil)
        #expect(ar.text == "txt-9e0019f0")
    }

    @Test func failedLaunchResultIsErrorString() throws {
        let line = try resultLine(Fixtures.s08cb, toolUseID: "toolu_0127jNYurxss4a2E8omtt4yH")
        guard case .user(let e) = parser.parse(line) else { Issue.record("not user"); return }
        let r = try #require(e.toolResults.first)
        #expect(r.isError)
        #expect(r.agentResult == nil)
        #expect(r.errorText?.hasPrefix("Error: Agent type 'gmail-monitor' not found") == true)
    }

    @Test func humanPromptAndTitles() throws {
        let lines = Fixtures.lines(Fixtures.mainPath(Fixtures.f275))
        guard case .user(let e) = parser.parse(lines[2]) else { Issue.record("not user"); return }
        #expect(e.kind == .prompt("txt-e2d7cced"))
        let titles = lines.filter { String(decoding: $0.prefix(30), as: UTF8.self).contains("custom-title") }
        let title = try #require(titles.first)
        guard case .customTitle(let t) = parser.parse(title) else { Issue.record("no title"); return }
        #expect(t == "Title t-b41e39a2")
        let aiLines = Fixtures.lines(Fixtures.mainPath(Fixtures.s5d78)) { $0["type"] as? String == "ai-title" }
        let ai = try #require(aiLines.first)
        guard case .aiTitle(let a) = parser.parse(ai) else { Issue.record("no ai title"); return }
        #expect(a == "Title t-a60ebad4")
    }

    @Test func apiErrorLine() throws {
        let errors = Fixtures.lines(Fixtures.mainPath(Fixtures.f275)) { $0["isApiErrorMessage"] as? Bool == true }
        let line = try #require(errors.first)
        guard case .assistant(let e) = parser.parse(line) else { Issue.record("not assistant"); return }
        #expect(e.isAPIError)
        #expect(e.model == nil)    // <synthetic>
    }

    @Test func syntheticForkContextLineIsNotAnError() throws {
        let path = (Fixtures.subagentDir(Fixtures.bd324) as NSString)
            .appendingPathComponent("agent-achange-the-wake-up-7f18043573d76831.jsonl")
        let lines = Fixtures.lines(path)
        guard case .forkContextRef = parser.parse(lines[0]) else { Issue.record("no fork ref"); return }
        guard case .assistant(let e) = parser.parse(lines[2]) else { Issue.record("not assistant"); return }
        #expect(e.model == nil)
        #expect(!e.isAPIError)
    }

    @Test func notificationsFromAllThreeCarriers() throws {
        let lines = Fixtures.lines(Fixtures.mainPath(Fixtures.f275))
        // queue-operation enqueue
        guard case .notices(let q, let ts) = parser.parse(lines[137]) else { Issue.record("no queue notice"); return }
        #expect(q.first?.taskID == "a28854a40750f97c0")
        #expect(q.first?.status == "failed")
        #expect(ts == Timestamp.parse("2026-10-01T22:03:45.209Z"))
        // user line with origin task-notification
        guard case .user(let u) = parser.parse(lines[139]) else { Issue.record("not user"); return }
        #expect(u.kind == .notification)
        #expect(u.notices.first?.toolUseID == "toolu_01Y9rxasMpSGkA3SKwTfrYHv")
        // queued_command attachment
        guard case .notices(let a, _) = parser.parse(lines[205]) else { Issue.record("no attachment notice"); return }
        #expect(a.first?.status == "completed")
        #expect(a.first?.durationMs == 368_549)
        // queue-operation remove is ignored
        #expect(parser.parse(lines[142]) == nil)
    }

    @Test func onlyTextThatIsANotificationCarriesNotices() {
        let n = "<task-notification>\\n<task-id>a1</task-id>\\n<tool-use-id>toolu_1</tool-use-id>\\n<status>completed</status>\\n</task-notification>"
        let quoted = #"Another Claude session sent a message:\n<agent-message from=\"a9\">"# + n + "</agent-message>"
        // queue-operation: real vs quoted content
        let qReal = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-02T23:00:00.000Z","content":"  \#(n)"}"#
        let qQuoted = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-02T23:00:00.000Z","content":"\#(quoted)"}"#
        guard case .notices(let a, _)? = parser.parse(Data(qReal.utf8)) else { Issue.record("real queue notice"); return }
        #expect(a.first?.taskID == "a1")
        #expect(parser.parse(Data(qQuoted.utf8)) == nil)
        // queued_command: a peer handback quoting a notice is a report
        let peer = #"{"parentUuid":"p","isSidechain":false,"attachment":{"type":"queued_command","prompt":"\#(n)","commandMode":"prompt","origin":{"kind":"peer","from":"a9","body":"\#(n)"},"isMeta":true},"type":"attachment","timestamp":"2026-10-02T23:00:01.000Z"}"#
        guard case .peerReport(let from, _)? = parser.parse(Data(peer.utf8)) else { Issue.record("peer report"); return }
        #expect(from == "a9")
        // A peer delivery without a body: the message inside the wrapper.
        let bare = #"{"parentUuid":"p","isSidechain":false,"attachment":{"type":"queued_command","prompt":"\#(quoted)","origin":{"kind":"peer","from":"a9"}},"type":"attachment","timestamp":"2026-10-02T23:00:01.000Z"}"#
        guard case .peerReport(_, let text)? = parser.parse(Data(bare.utf8)) else { Issue.record("bare peer"); return }
        #expect(text.hasPrefix("<task-notification>"))
        #expect(!text.contains("agent-message"))
        // user line: a human prompt that mentions a notice is a prompt
        let human = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"Why did this fail? \#(n)"},"origin":{"kind":"human"},"timestamp":"2026-10-02T23:00:02.000Z"}"#
        guard case .user(let u)? = parser.parse(Data(human.utf8)) else { Issue.record("human"); return }
        #expect(u.notices.isEmpty)
        if case .prompt = u.kind {} else { Issue.record("not a prompt: \(u.kind)") }
        // user line from a peer quoting a notice
        let peerUser = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(quoted)"},"origin":{"kind":"peer","from":"a9"},"timestamp":"2026-10-02T23:00:03.000Z"}"#
        guard case .user(let pu)? = parser.parse(Data(peerUser.utf8)) else { Issue.record("peer user"); return }
        #expect(pu.kind == .peer)
        #expect(pu.notices.isEmpty)
        #expect(pu.peerReport?.agentID == "a9")
    }

    @Test func toolEndsTurnOnHandbackResult() throws {
        let path = (Fixtures.subagentDir(Fixtures.s08cb) as NSString).appendingPathComponent("agent-a140524516f2ac0a4.jsonl")
        let last = try #require(Fixtures.lines(path).last)
        guard case .user(let e) = parser.parse(last) else { Issue.record("not user"); return }
        #expect(e.toolEndsTurn)
        #expect(e.kind == .toolResults)
    }

    @Test func attachmentsAndMetadataAreSkipped() throws {
        let lines = Fixtures.lines(Fixtures.mainPath(Fixtures.f275))
        #expect(parser.parse(lines[3]) == nil)      // environment attachment
        let skipped = lines.filter { line in
            let s = String(decoding: line.prefix(40), as: UTF8.self)
            return s.contains("\"last-prompt\"") || s.contains("\"atis-latch\"") || s.contains("\"agent-name\"")
        }
        #expect(!skipped.isEmpty)
        for line in skipped { #expect(parser.parse(line) == nil) }
    }

    @Test func everyFixtureLineParsesWithoutCrashing() {
        let projects = Fixtures.root.appendingPathComponent("projects")
        var events = 0
        for case let rel as String in FileManager.default.enumerator(atPath: projects.path)! where rel.hasSuffix(".jsonl") {
            for line in Fixtures.lines(projects.appendingPathComponent(rel).path) where parser.parse(line) != nil {
                events += 1
            }
        }
        #expect(events > 3000)
    }

    @Test func durationsModeKeepsOnlyAgentSignals() throws {
        let durations = LineParser(mode: .durations)
        let lines = Fixtures.lines(Fixtures.mainPath(Fixtures.f275))
        var agentCalls = 0, results = 0, notices = 0
        for line in lines {
            switch durations.parse(line) {
            case .assistant(let e):
                for case .toolUse(let t) in e.blocks where t.agentCall != nil { agentCalls += 1 }
            case .user(let e):
                results += e.toolResults.filter { $0.agentResult != nil }.count
                notices += e.notices.count
            case .notices(let n, _):
                notices += n.count
            default:
                break
            }
        }
        #expect(agentCalls == 9)
        #expect(results == 9)
        #expect(notices > 9)
    }

    @Test func toolSummaries() {
        var input = ToolInput()
        input.command = "npm test\nmore"
        #expect(ToolSummary.make(name: "Bash", input: input) == "npm test")
        input.description = "Run tests"
        #expect(ToolSummary.make(name: "Bash", input: input) == "Run tests")
        var file = ToolInput()
        file.filePath = "/Users/dev/project/Sources/App/main.swift"
        #expect(ToolSummary.make(name: "Read", input: file) == "App/main.swift")
        var web = ToolInput()
        web.url = "https://example.com/docs/page?q=1"
        #expect(ToolSummary.make(name: "WebFetch", input: web) == "example.com/docs/page")
        var long = ToolInput()
        long.pattern = String(repeating: "a", count: 300)
        #expect(ToolSummary.make(name: "Grep", input: long).count == 120)
    }

    @Test func timestamps() {
        let d = Timestamp.parse("2026-10-02T23:56:28.204Z")
        #expect(d == Date(timeIntervalSince1970: 1_790_985_388.204))
        #expect(Timestamp.parse("2026-10-02T23:56:28Z") == Date(timeIntervalSince1970: 1_790_985_388))
        #expect(Timestamp.parse("2026-10-02T19:56:28.5-04:00") == Date(timeIntervalSince1970: 1_790_985_388.5))
        #expect(Timestamp.parse("garbage") == nil)
        let ctime = CTime.parse("Fri Oct  2 23:56:27 2026")
        #expect(ctime?.utc == 1_790_985_387)
    }
}
