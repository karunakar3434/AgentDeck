import Foundation
import Testing
@testable import AgentDeckCore

/// Golden checks of the reducer and snapshot builder on the `extra` session (fb4572c1, Claude Code 2.1.286):
/// 7 background Agent calls (all `async_launched`, all finished by `<task-notification>`, one resumed with
/// SendMessage), linked through meta sidecars; peer handbacks; two Bash background-task notices.
@Suite struct ReducerGoldenExtraSessionTests {
    static let snapshot = Fixtures.snapshot(Extra.reduced, now: Extra.now)

    private func ts(_ s: String) -> Date { Timestamp.parse(s)! }

    static let guideAgent = "af4448711daf1ca74"          // claude-code-guide → haiku
    static let guideCall = "toolu_018qrqzL6FSeQxxoqveyoN5h"
    static let resumedAgent = "a49f40cd2299a9396"        // resumed with SendMessage
    static let resumedCall = "toolu_011JdZBNjLnF1pEHNuoaV1Eg"

    /// Agent call id → call timestamp (reference decode).
    static let callTimes: [String: Date] = {
        var out: [String: Date] = [:]
        for line in Extra.mainLines {
            let obj = Ref.json(line)
            for t in Ref.toolUses(obj) where t["name"] as? String == "Agent" { out[t["id"] as! String] = Ref.timestamp(obj) }
        }
        return out
    }()

    /// Agent call id → (duration_ms, timestamp of its first delivery) of the first notice naming that call.
    static let firstNotices: [String: (ms: Int, at: Date)] = {
        var out: [String: (ms: Int, at: Date)] = [:]
        for line in Extra.mainLines {
            let obj = Ref.json(line)
            guard Ref.type(obj) == "queue-operation", obj["operation"] as? String == "enqueue",
                  let content = obj["content"] as? String, let tuid = Ref.tag("tool-use-id", in: content),
                  Extra.agentCallIDs.contains(tuid),          // not the SendMessage resume notice
                  let ms = Ref.tag("duration_ms", in: content).flatMap({ Int($0) }), out[tuid] == nil else { continue }
            out[tuid] = (ms, Ref.timestamp(obj)!)
        }
        return out
    }()

    /// Usage counted once per `message.id`, taking the last line of each id (reference decode).
    static func referenceUsage(_ lines: [Data]) -> TokenUsage {
        var last: [String: [String: Any]] = [:]
        for line in lines {
            let obj = Ref.json(line)
            let m = Ref.message(obj)
            guard Ref.type(obj) == "assistant", let id = m["id"] as? String, let u = m["usage"] as? [String: Any],
                  m["model"] as? String != "<synthetic>" else { continue }
            last[id] = u
        }
        var total = TokenUsage()
        for u in last.values {
            total = total + TokenUsage(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                       cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                       cacheCreation: u["cache_creation_input_tokens"] as? Int ?? 0)
        }
        return total
    }

    // MARK: Runs and linking

    @Test func oneRunPerLaunchedAgentCall() {
        let launched = Extra.mainLines.filter {
            let status = (Ref.json($0)["toolUseResult"] as? [String: Any])?["status"] as? String
            return status == "async_launched" || status == "completed"
        }.count
        #expect(launched == 7)
        let s = Extra.reduced
        #expect(s.runs.count == launched)
        #expect(s.order == Extra.agentCallIDs)
        #expect(s.orphans.isEmpty)
        let snap = Self.snapshot
        #expect(snap.runs.count == 8)
        #expect(snap.runs[0].id == "main:\(Extra.sid)")
        #expect(snap.subagents.map(\.id) == Extra.agentCallIDs)     // start order = call order
        for run in snap.subagents {
            #expect(run.parentRunID == snap.runs[0].id)
            #expect(run.depth == 1)
        }
    }

    @Test func everyRunIsLinkedToItsFileThroughTheMetaToolUseID() throws {
        let s = Extra.reduced
        #expect(Extra.agentIDs.count == 7)
        for aid in Extra.agentIDs {
            let meta = Extra.meta(aid)
            let tuid = try #require(meta.toolUseID)
            #expect(meta.requestShape == "background")
            #expect(s.agentToRun[aid] == tuid, "\(aid)")
            let run = try #require(s.runs[tuid])
            #expect(run.isAgentCall)
            #expect(run.agentID == aid)
            #expect(run.agentType == meta.agentType)
            #expect(run.description == meta.description)
            // The agent's own file was folded into the Agent run.
            let lines = Extra.lines(of: aid)
            let objs = lines.map(Ref.json)
            #expect(run.own.hasLines)
            #expect(run.own.toolCallCount == objs.reduce(0) { $0 + Ref.toolUses($1).count }, "\(aid)")
            let stamps = objs.filter { ["user", "assistant", "system"].contains(Ref.type($0) ?? "") }.compactMap(Ref.timestamp)
            #expect(run.own.firstAt == stamps.min())
            #expect(run.own.lastAt == stamps.max())
            // The subagent's first prompt is the call's prompt (equal tokens).
            #expect(run.prompt == Ref.message(objs[0])["content"] as? String)
        }
    }

    // MARK: Models

    @Test func modelsComeFromEachRunsOwnLines() throws {
        let snap = Self.snapshot
        #expect(snap.mainModel == ModelInfo(id: "claude-opus-5-5", source: .transcript))
        for run in snap.subagents {
            let aid = try #require(run.agentID)
            let expected = run.agentType == "claude-code-guide" ? "claude-haiku-4-5-20251001" : "claude-opus-5-5"
            #expect(run.model == ModelInfo(id: expected, source: .transcript), "\(run.agentType)")
            let own = Set(Extra.lines(of: aid).compactMap { Ref.message(Ref.json($0))["model"] as? String })
            #expect(own == [expected])
        }
        #expect(snap.run(agentID: Self.guideAgent)?.agentType == "claude-code-guide")
    }

    @Test func launchResultsNameTheModelBeforeTheAgentWritesALine() throws {
        let s = Extra.reduce(withSubagents: false)
        let snap = Fixtures.snapshot(s, now: Extra.now)
        for line in Extra.mainLines {
            guard let r = Ref.json(line)["toolUseResult"] as? [String: Any], let aid = r["agentId"] as? String else { continue }
            let run = try #require(snap.run(agentID: aid))
            #expect(s.runs[run.id]?.own.hasLines == false)
            #expect(run.model == ModelInfo(id: r["resolvedModel"] as? String, source: .transcript), "\(aid)")
        }
        #expect(snap.run(agentID: Self.guideAgent)?.model.id == "claude-haiku-4-5-20251001")
    }

    // MARK: Status and durations

    @Test func backgroundRunsFinishWithTheirNotificationDurations() throws {
        let s = Extra.reduced
        let snap = Self.snapshot
        #expect(snap.status == .done)                 // no pid file, quiet since 01:33
        #expect(!s.closed)                            // the desktop session never wrote cost-state
        for run in snap.subagents {
            let state = try #require(s.runs[run.id])
            #expect(run.isBackground)
            #expect(state.launched)
            #expect(run.status == .done)
            #expect(state.exact?.status == .done)
            #expect(state.startedAt == Self.callTimes[run.id])
            #expect(run.startedAt == Self.callTimes[run.id])
            guard run.agentID != Self.resumedAgent else { continue }
            let notice = try #require(Self.firstNotices[run.id])
            #expect(state.exact?.durationMs == notice.ms)
            #expect(state.exact?.signalAt == notice.at)               // the first delivery (queue-operation)
            let end = try #require(run.endedAt)
            #expect(abs(end.timeIntervalSince(run.startedAt) - Double(notice.ms) / 1000) < 1, "\(run.agentType)")
            #expect(end <= notice.at)
        }
        #expect(Self.firstNotices.count == 7)
    }

    @Test func resumedRunReopensThenEndsAtItsLastNotice() throws {
        // Live order: main up to the first notice (line 884), the agent's file up to its first handback (237 lines).
        var limits = Dictionary(uniqueKeysWithValues: Extra.agentIDs.map { ($0, 0) })
        limits[Self.resumedAgent] = 237
        var s = Fixtures.reduce(Extra.sid, root: Extra.root, mainLines: 885, subagentLines: limits, now: Extra.now)
        let start = ts("2026-10-03T00:30:18.192Z")
        var run = try #require(s.runs[Self.resumedCall])
        #expect(run.startedAt == start)
        #expect(run.baseStatus == .done)
        #expect(run.exact?.durationMs == 1_404_528)
        #expect(run.exact?.endedAt == start.addingTimeInterval(1404.528))

        // SendMessage resumes the agent: its next own line reopens the run.
        let own = Extra.lines(of: Self.resumedAgent)
        fold([own[237]], owner: .agent(Self.resumedAgent), into: &s)
        run = try #require(s.runs[Self.resumedCall])
        #expect(run.baseStatus == .running)
        #expect(run.exact == nil)
        #expect(run.resultSummary == nil)

        // The rest of its file, then main through the resume notice (which names the SendMessage call).
        fold(Array(own[238...]), owner: .agent(Self.resumedAgent), into: &s)
        fold(Array(Extra.mainLines[885...1088]), owner: .main, into: &s)
        run = try #require(s.runs[Self.resumedCall])
        #expect(run.baseStatus == .done)
        #expect(run.exact?.durationMs == 770_119)
        // start + 770 s is far before the signal: a resumed run ends at the notice, keeping its start.
        #expect(run.exact?.endedAt == ts("2026-10-03T01:15:58.104Z"))
        #expect(run.startedAt == start)
        #expect(run.appliedNotices.count == 2)
        #expect(s.runs["toolu_019cd8PhmNEtiamhMjkuRxy1"] == nil)
        let sendMessage = Extra.mainLines.flatMap { Ref.toolUses(Ref.json($0)) }.first { $0["id"] as? String == "toolu_019cd8PhmNEtiamhMjkuRxy1" }
        #expect(sendMessage?["name"] as? String == "SendMessage")

        // Same end state as the cold load.
        #expect(Extra.reduced.runs[Self.resumedCall]?.exact == run.exact)
        #expect(Self.snapshot.run(Self.resumedCall)?.endedAt == ts("2026-10-03T01:15:58.104Z"))
    }

    // MARK: Result summaries

    @Test func resultSummariesComeFromTheAgentsHandback() throws {
        let snap = Self.snapshot
        let expected = [
            "af4448711daf1ca74": "txt-551757ca", "a24415a2937f26397": "txt-5264f550",
            "a49f40cd2299a9396": "txt-db22b284",                          // the latest of its two handbacks
            "a9247d9f1fbf584d9": "txt-d16289da", "acdeefa10fce90761": "txt-18fecd7b", "ae6919190b8b8cd0b": "txt-08b49047",
        ]
        for (aid, text) in expected { #expect(snap.run(agentID: aid)?.resultSummary == text, "\(aid)") }
        // The Explore agent handed back another agent's notification verbatim; it is shown collapsed.
        let explore = try #require(snap.run(agentID: "a2cb440a58ad617b7")?.resultSummary)
        #expect(explore.hasPrefix("<task-notification> <task-id>af4448711daf1ca74</task-id>"))
        for run in snap.subagents {
            let summary = try #require(run.resultSummary)
            #expect(summary.count <= 400)
            #expect(!TextUtil.isStub(summary))
            #expect(summary != "…")
            #expect(!summary.hasPrefix("Agent \""))       // not the notification's summary line
        }
    }

    @Test func withoutTheAgentsFilesSummariesComeFromPeerHandbacks() {
        let expected = [
            "af4448711daf1ca74": "txt-cb8eb1bf", "a2cb440a58ad617b7": "txt-8d357d09", "a24415a2937f26397": "txt-4950a087",
            "a49f40cd2299a9396": "txt-0e65573e",                          // latest of a user line and an attachment
            "a9247d9f1fbf584d9": "txt-08bac05d", "ae6919190b8b8cd0b": "txt-2df08827", "acdeefa10fce90761": "txt-0cc98336",
        ]
        #expect(Extra.reduced.peerReports == expected)
        let snap = Fixtures.snapshot(Extra.reduce(withSubagents: false), now: Extra.now)
        for (aid, text) in expected { #expect(snap.run(agentID: aid)?.resultSummary == text, "\(aid)") }
    }

    // MARK: Session fields

    @Test func sessionTitleProjectAndMainRun() throws {
        let s = Extra.reduced
        let snap = Self.snapshot
        #expect(snap.title == "Title t-fd6e28e9")
        // From the custom-title lines alone (no custom-title.json).
        var mainOnly = SessionState(id: Extra.sid)
        fold(Extra.mainLines, owner: .main, into: &mainOnly)
        #expect(mainOnly.customTitle == "Title t-fd6e28e9")
        #expect(SnapshotBuilder.taskTitle(mainOnly) == "Title t-fd6e28e9")
        #expect(mainOnly.firstPrompt == "txt-2a51893f")
        // Later lines ran in a subdirectory; the project is the first cwd.
        let cwds = Set(Extra.mainLines.compactMap { Ref.json($0)["cwd"] as? String })
        #expect(cwds.count > 1)
        #expect(snap.projectPath == "/Users/dev/Projects/AgentDeck")
        #expect(snap.projectName == "AgentDeck")
        #expect(snap.gitBranch == "HEAD")
        #expect(snap.mainModel == ModelInfo(id: "claude-opus-5-5", source: .transcript))
        #expect(snap.runs[0].toolCallCount == 204)
        #expect(snap.runs[0].prompt == "txt-2a51893f")
        #expect(s.startedAt == ts("2026-10-02T23:56:28.204Z"))     // first user line (queue-operations don't count)
        #expect(s.lastActivityAt == ts("2026-10-03T01:33:40.519Z"))
        #expect(snap.endedAt == s.lastActivityAt)
        #expect(Fixtures.snapshot(s, process: ProcessState(alive: true, status: "busy"), now: Extra.now).status == .running)
        #expect(Fixtures.snapshot(s, process: ProcessState(alive: true, status: "idle"), now: Extra.now).status == .idle)
    }

    @Test func relocatedLineMovesTheProject() {
        var s = Extra.reduced
        fold([Data(#"{"type":"relocated","sessionId":"\#(Extra.sid)","relocatedCwd":"/Users/dev/Projects/Other"}"#.utf8)], owner: .main, into: &s)
        let snap = Fixtures.snapshot(s, now: Extra.now)
        #expect(snap.projectPath == "/Users/dev/Projects/Other")
        #expect(snap.projectName == "Other")
        #expect(snap.id == Extra.sid)
        // A subagent file can't relocate the session.
        var t = Extra.reduced
        fold([Data(#"{"type":"relocated","relocatedCwd":"/elsewhere"}"#.utf8)], owner: .agent(Self.guideAgent), into: &t)
        #expect(t.projectPath == "/Users/dev/Projects/AgentDeck")
    }

    @Test func usageCountsOncePerMessageIDOnRealStreams() throws {
        let snap = Self.snapshot
        let mainAssistant = Extra.mainLines.filter { Ref.type(Ref.json($0)) == "assistant" }
        let ids = Set(mainAssistant.compactMap { Ref.message(Ref.json($0))["id"] as? String })
        #expect(mainAssistant.count > ids.count)                    // streamed: several lines per message
        #expect(snap.runs[0].tokens == Self.referenceUsage(Extra.mainLines))
        for run in snap.subagents {
            let aid = try #require(run.agentID)
            #expect(run.tokens == Self.referenceUsage(Extra.lines(of: aid)), "\(aid)")
        }
    }

    // MARK: Notifications

    @Test func bashTaskNoticesNeverTouchAgentRuns() {
        var s = Extra.reduced
        let before = s.runs
        #expect(Set(s.pendingNotices.keys) == ["bter9wanp", "b7m0ifs3j"])
        #expect(s.pendingNotices["b7m0ifs3j"]?.count == 1)          // main file and subagent file: held once
        let bash = Extra.mainLines.filter { RawLine.string($0).contains(#"<task-id>b"#) && Ref.json($0)["operation"] as? String == "enqueue" }
        #expect(bash.count == 2)
        fold(bash + bash, owner: .main, into: &s)
        #expect(s.runs == before)
        #expect(s.order == Extra.agentCallIDs)
        #expect(Set(s.pendingNotices.keys) == ["bter9wanp", "b7m0ifs3j"])
    }

    @Test func repeatedDeliveryIsAppliedOnce() throws {
        // Through the launch results, before the first notice (line 84); no subagent lines.
        var s = Extra.reduce(mainLines: 84, withSubagents: false)
        #expect(s.runs[Self.guideCall]?.baseStatus == .running)
        let queue = Extra.mainLines[84], attachment = Extra.mainLines[91], removal = Extra.mainLines[93]
        #expect(ParsedShape(LineParser().parse(attachment)) == .notices(1))
        // The third documented carrier: the same text as a user turn with origin task-notification.
        let content = try #require(Ref.json(queue)["content"] as? String)
        let userLine = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":\#(Ref.literal(content))},"origin":{"kind":"task-notification"},"uuid":"u","timestamp":"2026-10-03T00:00:14.300Z","sessionId":"\#(Extra.sid)"}"#

        fold([queue], owner: .main, into: &s)
        let first = try #require(s.runs[Self.guideCall]?.exact)
        #expect(first.status == .done)
        #expect(first.durationMs == 186_693)
        #expect(first.signalAt == ts("2026-10-03T00:00:14.222Z"))
        #expect(first.endedAt == ts("2026-10-02T23:56:49.573Z").addingTimeInterval(186.693))

        // The attachment's timestamp (.221) is earlier than the queue-operation's (.222) but comes later in the file;
        // the user turn is later still. None of them re-finishes the run.
        for (name, line) in [("attachment", attachment), ("queue remove", removal), ("user turn", Data(userLine.utf8)),
                             ("queue again", queue)] {
            fold([line], owner: .main, into: &s)
            #expect(s.runs[Self.guideCall]?.exact == first, "after \(name)")
            #expect(s.runs[Self.guideCall]?.appliedNotices.count == 1, "after \(name)")
        }
    }

    @Test func noticeBeforeItsCallIsHeldThenApplied() throws {
        var s = SessionState(id: Extra.sid)
        fold([Extra.mainLines[84]], owner: .main, into: &s)
        #expect(s.runs.isEmpty)
        #expect(s.pendingNotices[Self.guideAgent]?.count == 1)
        // The call (line 33) and its launch result (line 35) arrive after the notice.
        fold(Array(Extra.mainLines[0..<84]), owner: .main, into: &s)
        let run = try #require(s.runs[Self.guideCall])
        #expect(run.baseStatus == .done)
        #expect(run.exact?.durationMs == 186_693)
        #expect(run.exact?.endedAt == ts("2026-10-02T23:56:49.573Z").addingTimeInterval(186.693))
        #expect(s.pendingNotices[Self.guideAgent] == nil)
    }

    @Test func failedNoticeThenALaterCompletedNotice() throws {
        var s = Extra.reduce(mainLines: 84, withSubagents: false)
        var failed = try RawLine.replacing("<status>completed</status>", with: "<status>failed</status>", in: Extra.mainLines[84])
        failed = try RawLine.replacing(#"<summary>Agent \"txt-7f905e13\" finished</summary>"#,
                                       with: #"<summary>Agent \"txt-7f905e13\" failed: Agent terminated early due to an API error</summary>"#, in: failed)
        failed = try RawLine.replacing(#"\n<usage><subagent_tokens>106553</subagent_tokens><tool_uses>18</tool_uses><duration_ms>186693</duration_ms></usage>"#,
                                       with: "", in: failed)
        fold([failed], owner: .main, into: &s)
        let run = try #require(s.runs[Self.guideCall])
        #expect(run.baseStatus == .failed)
        #expect(run.exact?.durationMs == nil)
        #expect(run.exact?.endedAt == ts("2026-10-03T00:00:14.222Z"))
        let snap = Fixtures.snapshot(s, now: Extra.now)
        #expect(snap.run(Self.guideCall)?.status == .failed)
        #expect(snap.run(Self.guideCall)?.resultSummary == "Agent \"txt-7f905e13\" failed: Agent terminated early due to an API error")
        // A later notice with another identity (as after a resume) wins.
        fold([Extra.mainLines[84]], owner: .main, into: &s)
        #expect(s.runs[Self.guideCall]?.baseStatus == .done)
        #expect(s.runs[Self.guideCall]?.exact?.durationMs == 186_693)
    }

    @Test func unknownTaskIDsAreHeldBoundedAndHarmless() throws {
        var s = Extra.reduced
        let before = s.runs
        var lines: [Data] = []
        for i in 0..<40 {
            var line = try RawLine.replacing("<task-id>af4448711daf1ca74</task-id>", with: "<task-id>aunknown\(i)</task-id>", in: Extra.mainLines[84])
            line = try RawLine.replacing("toolu_018qrqzL6FSeQxxoqveyoN5h", with: "toolu_unknown\(i)", in: line)
            lines.append(line)
        }
        // No task id and an unknown tool-use id: nothing to hold.
        lines.append(try RawLine.replacing(#"<task-id>af4448711daf1ca74</task-id>\n<tool-use-id>toolu_018qrqzL6FSeQxxoqveyoN5h</tool-use-id>"#,
                                           with: "<tool-use-id>toolu_nowhere</tool-use-id>", in: Extra.mainLines[84]))
        fold(lines + lines, owner: .main, into: &s)
        #expect(s.runs == before)
        #expect(s.pendingNotices.count == 32)
        #expect(s.pendingNotices["aunknown39"]?.count == 1)          // the newest is kept, once
        #expect(s.pendingNotices.values.allSatisfy { $0.count == 1 })
    }

    // MARK: Arrival order

    @Test func liveArrivalOrderMatchesTheColdLoad() {
        let live = foldExtraLiveOrder()
        #expect(live.runs.count == 7)
        #expect(live.orphans.isEmpty)
        #expect(EngineTests.normalized(Fixtures.snapshot(live, now: Extra.now)) == EngineTests.normalized(Self.snapshot))
    }

    @Test func subagentFilesBeforeTheMainFileMatchTheColdLoad() {
        var s = SessionState(id: Extra.sid)
        s.mainSeen = true
        for aid in Extra.agentIDs { SessionReducer.applyMeta(Extra.meta(aid), agentID: aid, to: &s, now: Extra.now) }
        for aid in Extra.agentIDs { fold(Extra.lines(of: aid), owner: .agent(aid), into: &s) }
        #expect(s.orphans.count == 7)
        #expect(s.runs.isEmpty)
        fold(Extra.mainLines, owner: .main, into: &s)
        SessionReducer.promoteOrphans(&s, now: Extra.now, force: true)
        #expect(s.orphans.isEmpty)
        #expect(EngineTests.normalized(Fixtures.snapshot(s, now: Extra.now)) == EngineTests.normalized(Self.snapshot))
    }

    /// Cold-load order folds each subagent file after the whole main file, so most of their lines are older than
    /// what the session has already seen: start never moves later and activity never moves earlier, at any step.
    @Test func coldLoadOrderNeverMovesStartLaterOrActivityEarlier() {
        let parser = LineParser()
        var s = SessionState(id: Extra.sid)
        var steps: [(FileOwner, Data)] = Extra.mainLines.map { (.main, $0) }
        for aid in Extra.agentIDs {
            SessionReducer.applyMeta(Extra.meta(aid), agentID: aid, to: &s, now: Extra.now)
            steps += Extra.lines(of: aid).map { (.agent(aid), $0) }
        }
        // Metas were applied up front, so runs link as soon as their calls are read.
        var olderThanSeen = 0
        var violations: [String] = []
        for (i, (owner, line)) in steps.enumerated() {
            let (start, last) = (s.startedAt, s.lastActivityAt)
            let runsLast = s.runs.mapValues(\.lastActivityAt)
            if let t = Ref.timestamp(Ref.json(line)), let l = last, t < l { olderThanSeen += 1 }
            if let e = parser.parse(line) { SessionReducer.apply(e, owner: owner, to: &s, now: Extra.now) }
            if let start, s.startedAt! > start { violations.append("step \(i): startedAt moved later") }
            if let last, s.lastActivityAt! < last { violations.append("step \(i): lastActivityAt moved earlier") }
            for (id, previous) in runsLast {
                if let previous, s.runs[id]!.lastActivityAt! < previous { violations.append("step \(i): \(id) activity moved earlier") }
            }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        #expect(olderThanSeen > 1000)
        #expect(s.startedAt == Extra.reduced.startedAt)
        #expect(s.lastActivityAt == Extra.reduced.lastActivityAt)
    }

    // MARK: Failed launch (08cb7b8e: the only real "Agent type … not found" in the fixtures)

    @Test func failedLaunchIsFailedWithItsReasonAndNoAgent() throws {
        let s = Fixtures.reduce(Fixtures.s08cb)
        let id = "toolu_0127jNYurxss4a2E8omtt4yH"
        let run = try #require(s.runs[id])
        #expect(run.agentType == "gmail-monitor")
        #expect(run.agentID == nil)
        #expect(!run.launched)
        #expect(!run.isBackground)
        #expect(!run.own.hasLines)
        #expect(!s.agentToRun.values.contains(id))
        #expect(run.exact?.status == .failed)
        #expect(run.exact?.durationMs == nil)
        #expect(run.exact?.endedAt == ts("2026-10-02T21:15:51.872Z"))     // the error result's timestamp
        #expect(run.resultSummary == "Error: Agent type 'gmail-monitor' not found. Available agents: general-purpose")
        let snap = try #require(Fixtures.snapshot(s).run(id))
        #expect(snap.status == .failed)
        #expect(snap.startedAt == ts("2026-10-02T21:15:51.485Z"))
        #expect(snap.endedAt == ts("2026-10-02T21:15:51.872Z"))
        #expect(snap.resultSummary == run.resultSummary)
        #expect(snap.tokens == nil)
        #expect(snap.model == ModelInfo(id: nil, source: .inherited))   // no definition for an unknown type
    }
}
