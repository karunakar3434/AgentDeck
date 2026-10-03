import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct SessionReducerTests {
    private func ts(_ s: String) -> Date { Timestamp.parse(s)! }

    // MARK: f275c38e: 9 meta-linked background/foreground subagents, failures, resumes

    @Test func f275AllSubagentsLinkedThroughMeta() throws {
        let s = Fixtures.reduce(Fixtures.f275)
        #expect(s.runs.count == 9)
        #expect(s.orphans.isEmpty)
        let metaDir = Fixtures.subagentDir(Fixtures.f275)
        for name in try FileManager.default.contentsOfDirectory(atPath: metaDir) where name.hasSuffix(".meta.json") {
            let aid = String(name.dropFirst(6).dropLast(10))
            let meta = try JSONDecoder().decode(AgentMeta.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: metaDir).appendingPathComponent(name)))
            let toolUseID = try #require(meta.toolUseID)
            #expect(s.agentToRun[aid] == toolUseID, "\(aid)")
            #expect(s.runs[toolUseID]?.agentID == aid)
            #expect(s.runs[toolUseID]?.own.hasLines == true, "\(aid) own file folded into the Agent run")
        }
        let snap = Fixtures.snapshot(s)
        #expect(snap.title == "Title t-b41e39a2")
        #expect(snap.projectName == "localbiz")
        #expect(snap.projectPath == "/Users/dev/localbiz")
        #expect(snap.runs.count == 10)
        #expect(snap.runs[0].id == "main:\(Fixtures.f275)")
        #expect(snap.runs[0].agentType == "main")
        #expect(snap.mainModel == ModelInfo(id: "claude-opus-5-5", source: .transcript))
        for run in snap.subagents {
            #expect(run.status == .done, "\(run.id)")
            #expect(run.model == ModelInfo(id: "claude-opus-5-5", source: .transcript))
            #expect(run.parentRunID == snap.runs[0].id)
            #expect(run.depth == 1)
        }
        // Runs in start order.
        let starts = snap.subagents.map(\.startedAt)
        #expect(starts == starts.sorted())
        #expect(Set(snap.subagents.map(\.agentType)) == ["localbiz-site-builder", "localbiz-qa"])
    }

    @Test func f275FailedByNotification() throws {
        // Main up to the user-line copy of the failure notice; the agent's file up to its API error.
        let s = Fixtures.reduce(Fixtures.f275, mainLines: 140, subagentLines: ["a28854a40750f97c0": 695])
        let run = try #require(s.runs["toolu_01Y9rxasMpSGkA3SKwTfrYHv"])
        #expect(run.agentID == "a28854a40750f97c0")
        #expect(run.baseStatus == .failed)
        #expect(run.exact?.status == .failed)
        #expect(run.exact?.endedAt == ts("2026-10-01T22:03:45.209Z"))   // first delivery (queue-operation)
        #expect(run.resultSummary?.hasSuffix("failed: Agent terminated early due to an API error") == true)
        #expect(run.isBackground)
        // The Bash task notices in the same session never touch Agent runs.
        #expect(s.runs.count == 9)
    }

    @Test func f275ResumedRunFinishesWithItsResumeNotice() throws {
        let s = Fixtures.reduce(Fixtures.f275)
        let run = try #require(s.runs["toolu_01Y9rxasMpSGkA3SKwTfrYHv"])
        #expect(run.baseStatus == .done)
        #expect(run.exact?.durationMs == 368_549)
        // A resumed run keeps its start; the end is the resume's notice, not start + duration.
        #expect(run.startedAt == ts("2026-10-01T21:25:25.603Z"))
        #expect(run.exact?.endedAt == ts("2026-10-02T01:28:19.450Z"))
    }

    @Test func f275ResumeReopensAFailedRunLive() throws {
        // Live order: the failure, then the agent's resumed lines arrive before the next notice.
        var s = Fixtures.reduce(Fixtures.f275, mainLines: 142, subagentLines: ["a28854a40750f97c0": 695])
        #expect(s.runs["toolu_01Y9rxasMpSGkA3SKwTfrYHv"]?.baseStatus == .failed)
        let path = (Fixtures.subagentDir(Fixtures.f275) as NSString).appendingPathComponent("agent-a28854a40750f97c0.jsonl")
        let parser = LineParser()
        for line in Fixtures.lines(path)[695..<720] {
            if let e = parser.parse(line) { SessionReducer.apply(e, owner: .agent("a28854a40750f97c0"), to: &s, now: Fixtures.now) }
        }
        let run = try #require(s.runs["toolu_01Y9rxasMpSGkA3SKwTfrYHv"])
        #expect(run.baseStatus == .running)
        #expect(run.exact == nil)
    }

    @Test func f275ForegroundExactDuration() throws {
        let s = Fixtures.reduce(Fixtures.f275)
        let run = try #require(s.runs["toolu_01NjH64Y3hNCEohLrCpzXx7a"])
        #expect(!run.isBackground)
        #expect(run.exact?.durationMs == 1_731_278)
        #expect(run.exact?.endedAt == ts("2026-10-01T20:23:51.275Z").addingTimeInterval(1731.278))
    }

    @Test func f275StatusFromPidFile() {
        let s = Fixtures.reduce(Fixtures.f275)
        #expect(Fixtures.snapshot(s, process: ProcessState(alive: true, status: "waiting")).status == .waiting)
        #expect(Fixtures.snapshot(s, process: ProcessState(alive: true, status: "busy")).status == .running)
        #expect(Fixtures.snapshot(s, process: ProcessState(alive: true, status: "idle")).status == .idle)
        let done = Fixtures.snapshot(s, process: nil)
        #expect(done.status == .done)
        #expect(done.endedAt == s.lastActivityAt)
    }

    // MARK: 08cb7b8e: foreground totalDurationMs, failed launch, closed session

    @Test func s08cbForegroundTotalDuration() throws {
        let s = Fixtures.reduce(Fixtures.s08cb)
        let snap = Fixtures.snapshot(s)
        #expect(snap.title == "Title t-8f1cc4c1")
        #expect(s.closed)
        #expect(snap.status == .done)
        #expect(snap.subagents.count == 2)

        let run = try #require(snap.run("toolu_014VmCt9hdrzPCCUfBoz8GxZ"))
        #expect(run.status == .done)
        #expect(run.agentID == "a140524516f2ac0a4")
        #expect(!run.isBackground)
        #expect(run.startedAt == ts("2026-10-02T21:15:58.757Z"))
        #expect(run.endedAt == ts("2026-10-02T21:15:58.757Z").addingTimeInterval(38.698))
        #expect(s.runs[run.id]?.exact?.durationMs == 38_698)
        #expect(run.model == ModelInfo(id: "claude-opus-5-5", source: .transcript))
        #expect(run.tokens != nil)
        #expect(run.toolCallCount == 10)
        #expect(run.recentTools.count == 10)
        #expect(run.currentActivity == nil)

        let failed = try #require(snap.run("toolu_0127jNYurxss4a2E8omtt4yH"))
        #expect(failed.status == .failed)
        #expect(failed.agentType == "gmail-monitor")
        #expect(failed.resultSummary?.hasPrefix("Error: Agent type 'gmail-monitor' not found") == true)
        #expect(failed.endedAt == ts("2026-10-02T21:15:51.485Z") || failed.endedAt! > failed.startedAt)
    }

    // MARK: bd324a5f: fork without toolUseId, haiku via the agent's own lines

    @Test func bd324ForkIsAgentChildOfMain() throws {
        let s = Fixtures.reduce(Fixtures.bd324)
        let snap = Fixtures.snapshot(s)
        #expect(snap.title == "Title t-f359e4bd")
        #expect(snap.subagents.count == 2)
        let fork = try #require(snap.run("agent:achange-the-wake-up-7f18043573d76831"))
        #expect(fork.agentID == "achange-the-wake-up-7f18043573d76831")
        #expect(fork.agentType == "fork")
        #expect(fork.parentRunID == "main:\(Fixtures.bd324)")
        #expect(fork.isBackground)
        #expect(fork.status == .done)
        #expect(s.runs[fork.id]?.isFork == true)
        // The task-id-only notice (no tool-use-id) waited for the fork row, then applied.
        #expect(s.runs[fork.id]?.exact?.durationMs == 23_718)
        #expect(fork.endedAt == fork.startedAt.addingTimeInterval(23.718))
        #expect(fork.model == ModelInfo(id: "claude-sonnet-5", source: .transcript))

        let guide = try #require(snap.run("toolu_012dHwJrNp4263yu6vHVLeQj"))
        #expect(guide.agentType == "claude-code-guide")
        #expect(guide.agentID == "a613b87d4704606e7")
        #expect(guide.status == .done)
        #expect(guide.isBackground)
        #expect(guide.model == ModelInfo(id: "claude-haiku-4-5-20251001", source: .transcript))
        #expect(s.runs[guide.id]?.exact?.durationMs == 46_163)
    }

    @Test func resolvedModelBeforeTheAgentWritesALine() throws {
        // Without the subagent's own file, the launch result's resolvedModel names the model.
        let s = Fixtures.reduce(Fixtures.bd324, subagentLines: ["a613b87d4704606e7": 0])
        let snap = Fixtures.snapshot(s)
        #expect(snap.run("toolu_012dHwJrNp4263yu6vHVLeQj")?.model == ModelInfo(id: "claude-haiku-4-5-20251001", source: .transcript))
    }

    @Test func s5d78NoSubagentsAITitle() {
        let s = Fixtures.reduce(Fixtures.s5d78)
        let snap = Fixtures.snapshot(s)
        #expect(snap.runs.count == 1)
        #expect(snap.title == "Title t-a60ebad4")
        #expect(snap.status == .done)
        #expect(snap.mainModel.id == "claude-sonnet-4-6")
    }

    // MARK: Synthetic orderings

    private func apply(_ lines: [String], owner: FileOwner, to s: inout SessionState, now: Date = Fixtures.now) {
        let parser = LineParser()
        for line in lines {
            if let e = parser.parse(Data(line.utf8)) { SessionReducer.apply(e, owner: owner, to: &s, now: now) }
        }
    }

    static func agentCall(id: String, ts: String, type: String = "Explore", background: Bool = false, model: String? = nil) -> String {
        let modelPart = model.map { #","model":"\#($0)""# } ?? ""
        return #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_\#(id)","content":[{"type":"tool_use","id":"\#(id)","name":"Agent","input":{"description":"Look around","subagent_type":"\#(type)","prompt":"Find things","run_in_background":\#(background)\#(modelPart)}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":2}},"type":"assistant","timestamp":"\#(ts)","cwd":"/Users/dev/proj","sessionId":"s1"}"#
    }

    static func subagentLine(_ aid: String, ts: String, model: String = "claude-haiku-4-5-20251001", tool: String = "Read") -> String {
        #"{"parentUuid":"p","isSidechain":true,"agentId":"\#(aid)","message":{"model":"\#(model)","id":"m-\#(ts)","content":[{"type":"tool_use","id":"t-\#(ts)","name":"\#(tool)","input":{"file_path":"/a/b/c.swift"}}],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":4}},"type":"assistant","timestamp":"\#(ts)"}"#
    }

    static func prompt(_ text: String, ts: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"promptId":"x","type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(ts)","origin":{"kind":"human"},"cwd":"/Users/dev/proj","gitBranch":"main"}"#
    }

    @Test func subagentLinesBeforeMetaAndCallMergeIntoTheAgentRun() {
        var s = SessionState(id: "s1")
        s.mainSeen = true
        let t0 = Fixtures.now
        apply([Self.prompt("Do it", ts: "2026-10-02T23:59:00.000Z")], owner: .main, to: &s, now: t0)
        // The subagent file shows up first: an orphan, hidden during the grace period.
        apply([Self.subagentLine("a1", ts: "2026-10-02T23:59:02.000Z")], owner: .agent("a1"), to: &s, now: t0)
        #expect(s.orphans["a1"] != nil)
        #expect(SessionReducer.promoteOrphans(&s, now: t0.addingTimeInterval(1)) == t0.addingTimeInterval(5))
        #expect(s.runs.isEmpty)
        // After 5 s it is shown as an agent: child of main.
        SessionReducer.promoteOrphans(&s, now: t0.addingTimeInterval(6))
        #expect(s.runs["agent:a1"] != nil)
        // Then the meta and the call arrive: the row merges into the Agent run.
        SessionReducer.applyMeta(AgentMeta(agentType: "Explore", toolUseID: "toolu_A"), agentID: "a1", to: &s, now: t0)
        apply([Self.agentCall(id: "toolu_A", ts: "2026-10-02T23:59:01.000Z")], owner: .main, to: &s, now: t0)
        #expect(s.runs["agent:a1"] == nil)
        let run = s.runs["toolu_A"]
        #expect(run?.agentID == "a1")
        #expect(run?.own.toolCallCount == 1)
        #expect(run?.own.transcriptModel == "claude-haiku-4-5-20251001")
        #expect(run?.baseStatus == .running)
        #expect(s.order == ["toolu_A"])
    }

    @Test func metaBeforeCallLinksWhenTheCallArrives() {
        var s = SessionState(id: "s1")
        SessionReducer.applyMeta(AgentMeta(agentType: "Plan", toolUseID: "toolu_B", model: "sonnet"), agentID: "b1", to: &s, now: Fixtures.now)
        apply([Self.agentCall(id: "toolu_B", ts: "2026-10-02T23:59:01.000Z", type: "Plan")], owner: .main, to: &s)
        #expect(s.runs["toolu_B"]?.agentID == "b1")
        #expect(s.runs["toolu_B"]?.metaModel == "sonnet")
        #expect(s.runs["toolu_B"]?.baseStatus == .queued)
        #expect(s.orphans.isEmpty)
    }

    @Test func interruptCancelsForegroundChildren() {
        var s = SessionState(id: "s1")
        apply([Self.prompt("Go", ts: "2026-10-02T23:58:00.000Z"),
               Self.agentCall(id: "toolu_F", ts: "2026-10-02T23:58:01.000Z"),
               Self.agentCall(id: "toolu_G", ts: "2026-10-02T23:58:02.000Z", background: true),
               #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-10-02T23:58:10.000Z"}"#],
              owner: .main, to: &s)
        #expect(s.runs["toolu_F"]?.baseStatus == .cancelled)
        #expect(s.runs["toolu_G"]?.baseStatus == .queued)
        #expect(s.main.own.phase == .ended(.interrupted))
    }

    @Test func fallbackDoneThenResumeByLaterLines() {
        var s = SessionState(id: "s1")
        apply([Self.agentCall(id: "toolu_R", ts: "2026-10-02T23:50:00.000Z")], owner: .main, to: &s)
        SessionReducer.applyMeta(AgentMeta(agentType: "Explore", toolUseID: "toolu_R"), agentID: "r1", to: &s, now: Fixtures.now)
        apply([Self.subagentLine("r1", ts: "2026-10-02T23:50:01.000Z"),
               #"{"type":"user","agentId":"r1","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-x","content":"ok"}]},"toolEndsTurn":true,"timestamp":"2026-10-02T23:50:30.000Z"}"#],
              owner: .agent("r1"), to: &s)
        #expect(s.runs["toolu_R"]?.baseStatus == .done)
        #expect(s.runs["toolu_R"]?.own.fallback?.endedAt == ts("2026-10-02T23:50:30.000Z"))
        // An exact signal later wins over the fallback.
        apply([#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-02T23:50:31.000Z","content":"<task-notification>\n<task-id>r1</task-id>\n<tool-use-id>toolu_R</tool-use-id>\n<status>completed</status>\n<usage><duration_ms>30500</duration_ms></usage>\n</task-notification>"}"#],
              owner: .main, to: &s)
        #expect(s.runs["toolu_R"]?.exact?.durationMs == 30_500)
        // New own lines after the finish: resumed.
        apply([Self.subagentLine("r1", ts: "2026-10-02T23:55:00.000Z")], owner: .agent("r1"), to: &s)
        #expect(s.runs["toolu_R"]?.baseStatus == .running)
    }

    @Test func notificationIsIdempotent() {
        var s = SessionState(id: "s1")
        apply([Self.agentCall(id: "toolu_N", ts: "2026-10-02T23:40:00.000Z", background: true)], owner: .main, to: &s)
        let notice = "<task-notification>\\n<task-id>n1</task-id>\\n<tool-use-id>toolu_N</tool-use-id>\\n<status>completed</status>\\n<usage><duration_ms>60000</duration_ms></usage>\\n</task-notification>"
        apply([#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-02T23:41:00.100Z","content":"\#(notice)"}"#],
              owner: .main, to: &s)
        let first = s.runs["toolu_N"]?.exact
        apply([#"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(notice)"},"origin":{"kind":"task-notification"},"timestamp":"2026-10-02T23:41:05.000Z"}"#],
              owner: .main, to: &s)
        #expect(s.runs["toolu_N"]?.exact == first)
        #expect(first?.endedAt == ts("2026-10-02T23:41:00.000Z"))
        #expect(s.agentToRun["n1"] == "toolu_N")
    }

    @Test func usageCountsOncePerMessageID() {
        var s = SessionState(id: "s1")
        let line = { (out: Int) in
            #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":\#(out),"cache_read_input_tokens":100,"cache_creation_input_tokens":5}},"type":"assistant","timestamp":"2026-10-02T23:00:00.000Z"}"#
        }
        apply([line(1), line(7)], owner: .main, to: &s)
        #expect(s.main.own.usageTotal == TokenUsage(input: 10, output: 7, cacheRead: 100, cacheCreation: 5))
        #expect(s.main.own.phase == .ended(.normal))
    }

    // MARK: Result summaries and project names

    @Test func resultSummaryPrefersTheAgentsOwnReport() throws {
        let s08 = Fixtures.snapshot(Fixtures.reduce(Fixtures.s08cb))
        // SubagentHandback input.message in the agent's own file beats the peer copy and the tool result.
        #expect(s08.run("toolu_014VmCt9hdrzPCCUfBoz8GxZ")?.resultSummary == "txt-83b25a6b")
        let f275 = Fixtures.snapshot(Fixtures.reduce(Fixtures.f275))
        #expect(f275.run(agentID: "a033d7f9e898edbbb")?.resultSummary == "txt-0c0881e2")
        #expect(f275.run(agentID: "a100180c1b9377947")?.resultSummary == "txt-c448f71b")   // latest handback
        // Without the agent's own file: the parent's peer handback body.
        let noOwn = Fixtures.snapshot(Fixtures.reduce(Fixtures.s08cb, subagentLines: ["a140524516f2ac0a4": 0]))
        #expect(noOwn.run("toolu_014VmCt9hdrzPCCUfBoz8GxZ")?.resultSummary == "txt-ca0903d8")
        // Failed runs show the failure first.
        let failed = Fixtures.snapshot(Fixtures.reduce(Fixtures.f275, mainLines: 140, subagentLines: ["a28854a40750f97c0": 695, "a100180c1b9377947": 100]),
                                       process: ProcessState(alive: true, status: "busy"))
        #expect(failed.run(agentID: "a28854a40750f97c0")?.resultSummary
            == "Agent \"txt-a0f92384\" failed: Agent terminated early due to an API error")
        // Unfinished runs have no summary.
        #expect(failed.run(agentID: "a100180c1b9377947")?.status == .running)
        #expect(failed.run(agentID: "a100180c1b9377947")?.resultSummary == nil)
    }

    @Test func deliveryStubsAreIgnored() {
        var s = SessionState(id: "s1")
        s.mainSeen = true
        let stub = "This agent's report was delivered to you as a message from agent x."
        apply([Self.agentCall(id: "toolu_FG", ts: "2026-10-02T23:00:00.000Z"),
               #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_FG","content":"x"}]},"toolUseResult":{"status":"completed","agentId":"fg1","totalDurationMs":5000,"content":[{"type":"text","text":"\#(stub)"}]},"timestamp":"2026-10-02T23:00:05.100Z"}"#,
               Self.agentCall(id: "toolu_BG", ts: "2026-10-02T23:01:00.000Z", background: true),
               #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-02T23:02:00.000Z","content":"<task-notification>\n<task-id>bg1</task-id>\n<tool-use-id>toolu_BG</tool-use-id>\n<status>completed</status>\n<summary>Agent \"Scan\" finished</summary>\n<result>\#(stub)</result>\n</task-notification>"}"#,
               Self.agentCall(id: "toolu_R3", ts: "2026-10-02T23:03:00.000Z", background: true),
               #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-02T23:04:00.000Z","content":"<task-notification>\n<task-id>r3</task-id>\n<tool-use-id>toolu_R3</tool-use-id>\n<status>completed</status>\n<summary>Agent \"R\" finished</summary>\n<result>Found   3 issues:\n  - a\n  - b</result>\n</task-notification>"}"#],
              owner: .main, to: &s)
        let snap = Fixtures.snapshot(s)
        #expect(snap.run("toolu_FG")?.status == .done)
        #expect(snap.run("toolu_FG")?.resultSummary == nil)
        #expect(snap.run("toolu_BG")?.resultSummary == "Agent \"Scan\" finished")
        #expect(snap.run("toolu_R3")?.resultSummary == "Found 3 issues: - a - b")
        #expect(TextUtil.report(String(repeating: "word ", count: 200))?.count == 400)
    }

    @Test func peerHandbackAttachmentIsNotAPrompt() {
        let s = Fixtures.reduce(Fixtures.s08cb)
        #expect(s.peerReports["a140524516f2ac0a4"] == "txt-ca0903d8")
        #expect(s.main.prompt != "txt-d236372b")       // the queued_command's prompt text
    }

    @Test func scratchWorkspacesShareOneProjectName() {
        let snap = Fixtures.snapshot(Fixtures.reduce(Fixtures.s08cb))
        #expect(snap.projectName == "Scratch")
        #expect(snap.projectPath.contains("/scratch-workspaces/"))
        #expect(snap.projectPath.hasSuffix("scratch-2026-10-02-cfe996"))
        #expect(SnapshotBuilder.projectName("/Users/dev/localbiz") == "localbiz")
    }

    // MARK: Held notices

    static func notice(task: String, toolUse: String, ts: String) -> String {
        #"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(ts)","content":"<task-notification>\n<task-id>\#(task)</task-id>\n<tool-use-id>\#(toolUse)</tool-use-id>\n<status>completed</status>\n<summary>Background command \"x\" finished</summary>\n</task-notification>"}"#
    }

    static func toolCall(_ name: String, id: String, ts: String, input: String = #"{"command":"sleep 60","run_in_background":true}"#) -> String {
        #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m-\#(id)","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}],"stop_reason":"tool_use"},"type":"assistant","timestamp":"\#(ts)"}"#
    }

    @Test func bashNoticesForKnownCallsAreNeverHeld() {
        var s = SessionState(id: "s1")
        apply([Self.toolCall("Bash", id: "toolu_BASH", ts: "2026-10-02T23:00:00.000Z"),
               Self.notice(task: "b1234abcd", toolUse: "toolu_BASH", ts: "2026-10-02T23:01:00.000Z")], owner: .main, to: &s)
        #expect(s.pendingNotices.isEmpty)
        #expect(s.pendingOrder.isEmpty)
    }

    @Test func noticeHeldBeforeItsBashCallIsDroppedWhenTheCallAppears() {
        // Cold-load order: the notice is in the main file, the Bash call in a subagent's file read later.
        var s = SessionState(id: "s1")
        apply([Self.notice(task: "bter9wanp", toolUse: "toolu_SUBBASH", ts: "2026-10-02T23:01:00.000Z"),
               Self.notice(task: "aagent1", toolUse: "toolu_AGENTCALL", ts: "2026-10-02T23:01:01.000Z")], owner: .main, to: &s)
        #expect(Set(s.pendingNotices.keys) == ["bter9wanp", "aagent1"])
        apply([Self.toolCall("Bash", id: "toolu_SUBBASH", ts: "2026-10-02T23:00:00.000Z")], owner: .agent("sub1"), to: &s)
        #expect(Set(s.pendingNotices.keys) == ["aagent1"])
        #expect(s.pendingOrder == ["aagent1"])
    }

    @Test func sendMessageNoticesAreStillHeldForTheirAgent() {
        // A resumed agent's notice carries the SendMessage call's id: it must wait for the agent's run.
        var s = SessionState(id: "s1")
        apply([Self.toolCall("SendMessage", id: "toolu_SEND", ts: "2026-10-02T23:00:00.000Z", input: #"{"to":"x","message":"go"}"#),
               Self.notice(task: "aforky", toolUse: "toolu_SEND", ts: "2026-10-02T23:05:00.000Z")], owner: .main, to: &s)
        #expect(s.pendingNotices["aforky"]?.count == 1)
        SessionReducer.applyMeta(AgentMeta(agentType: "fork", isFork: true), agentID: "aforky", to: &s, now: Fixtures.now)
        #expect(s.pendingNotices.isEmpty)
        #expect(s.runs["agent:aforky"]?.exact?.status == .done)
    }

    @Test func heldNoticesAreEvictedOldestFirst() {
        var s = SessionState(id: "s1")
        let lines = (0..<40).map { i in
            Self.notice(task: "aunknown\(i)", toolUse: "toolu_unknown\(i)", ts: "2026-10-02T23:00:\(String(format: "%02d", i)).000Z")
        }
        apply(lines + lines, owner: .main, to: &s)
        #expect(s.pendingNotices.count == SessionReducer.pendingNoticeLimit)
        #expect(s.pendingOrder == (8..<40).map { "aunknown\($0)" })
        #expect(Set(s.pendingNotices.keys) == Set(s.pendingOrder))
        #expect(s.pendingNotices.values.allSatisfy { $0.count == 1 })
        // Applying a held notice removes it from the order too.
        apply([Self.agentCall(id: "toolu_unknown20", ts: "2026-10-02T22:59:00.000Z", background: true)], owner: .main, to: &s)
        SessionReducer.applyMeta(AgentMeta(agentType: "Explore", toolUseID: "toolu_unknown20"), agentID: "aunknown20", to: &s, now: Fixtures.now)
        #expect(s.pendingNotices["aunknown20"] == nil)
        #expect(!s.pendingOrder.contains("aunknown20"))
        #expect(s.runs["toolu_unknown20"]?.exact?.status == .done)
    }

    // MARK: Field caps

    @Test func agentCallAndMetaFieldsAreCapped() throws {
        let long = String(repeating: "d", count: 5000)
        var s = SessionState(id: "s1")
        s.mainSeen = true
        let call = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m1","content":[{"type":"tool_use","id":"toolu_LONG","name":"Agent","input":{"description":"\#(long)","subagent_type":"\#(long)","prompt":"p"}}],"stop_reason":"tool_use"},"type":"assistant","timestamp":"2026-10-02T23:00:00.000Z"}"#
        apply([call], owner: .main, to: &s)
        let run = try #require(s.runs["toolu_LONG"])
        #expect(run.description.count == TextUtil.fieldLimit)
        #expect(run.agentType.count == TextUtil.fieldLimit)
        #expect(run.description.hasSuffix("…"))

        let metaJSON = #"{"agentType":"\#(long)","description":"\#(long)","name":"\#(long)"}"#
        let meta = try JSONDecoder().decode(AgentMeta.self, from: Data(metaJSON.utf8))
        #expect(meta.agentType?.count == TextUtil.fieldLimit)
        #expect(meta.description?.count == TextUtil.fieldLimit)
        #expect(meta.name?.count == TextUtil.fieldLimit)
        SessionReducer.applyMeta(meta, agentID: "afork", to: &s, now: Fixtures.now)
        let row = try #require(s.runs["agent:afork"])
        #expect(row.description.count <= TextUtil.fieldLimit)
        #expect(row.agentType.count <= TextUtil.fieldLimit)
        // Short values are untouched.
        let short = try JSONDecoder().decode(AgentMeta.self, from: Data(#"{"agentType":"Explore","description":"Look"}"#.utf8))
        #expect(short.agentType == "Explore")
        #expect(short.description == "Look")
    }

    // MARK: Models

    @Test func modelResolutionOrder() throws {
        var defs = AgentDefinitions(dataRoot: Fixtures.root.path)
        let lookup: (String) -> String? = { defs.model(for: $0, projectPath: nil, now: Fixtures.now) }
        var run = RunState(id: "t", parentRunID: "main:s", depth: 1, agentType: "localbiz-qa", isAgentCall: true)
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: lookup).model == ModelInfo(id: "opus", source: .definition))
        run.metaModel = "inherit"
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: lookup).model.source == .definition)
        run.metaModel = "haiku"
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: lookup).model == ModelInfo(id: "haiku", source: .callParameter))
        run.callModel = "sonnet"
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: lookup).model == ModelInfo(id: "sonnet", source: .callParameter))
        run.resolvedModel = "claude-sonnet-5"
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: lookup).model == ModelInfo(id: "claude-sonnet-5", source: .transcript))
        run.own.transcriptModel = "claude-haiku-4-5-20251001"
        #expect(ModelResolver.resolve(run, isMain: false, definitionModel: lookup).model.id == "claude-haiku-4-5-20251001")

        let reviewer = RunState(id: "u", parentRunID: "main:s", depth: 1, agentType: "code-reviewer", isAgentCall: true)
        let inherited = ModelResolver.resolve(reviewer, isMain: false, definitionModel: lookup)
        #expect(inherited.model == ModelInfo(id: nil, source: .inherited))
        #expect(inherited.usedDefinitions)
    }

    @Test func projectDefinitionsWinOverUserDefinitions() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: project) }
        let agents = project.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "---\nname: localbiz-qa\nmodel: \"haiku\"\n---\nBody\n".write(to: agents.appendingPathComponent("qa.md"), atomically: true, encoding: .utf8)
        var defs = AgentDefinitions(dataRoot: Fixtures.root.path)
        #expect(defs.model(for: "localbiz-qa", projectPath: project.path, now: Fixtures.now) == "haiku")
        #expect(defs.model(for: "localbiz-qa", projectPath: nil, now: Fixtures.now) == "opus")
        #expect(defs.model(for: "missing", projectPath: project.path, now: Fixtures.now) == nil)
    }

    @Test func titleFallsBackToFirstPromptLine() {
        var s = SessionState(id: "s1")
        let long = String(repeating: "word ", count: 60)
        apply([Self.prompt("\\n  \(long)\\nsecond line", ts: "2026-10-02T23:00:00.000Z"),
               Self.prompt("later prompt", ts: "2026-10-02T23:10:00.000Z")], owner: .main, to: &s)
        let title = SnapshotBuilder.taskTitle(s)
        #expect(title.count == 120)
        #expect(title.hasPrefix("word word"))
        #expect(title.hasSuffix("…"))
        #expect(s.main.prompt == "later prompt")
        s.aiTitle = "AI title"
        #expect(SnapshotBuilder.taskTitle(s) == "AI title")
        s.customTitle = "Custom"
        #expect(SnapshotBuilder.taskTitle(s) == "Custom")
    }
}
