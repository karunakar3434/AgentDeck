import Foundation
import Testing
@testable import AgentDeckCore

@Suite struct StatusRulesTests {
    private let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_985_600))

    private func session(_ lines: [String], owner: FileOwner = .main) -> SessionState {
        var s = SessionState(id: "s1")
        s.mainSeen = true
        let parser = LineParser()
        for line in lines {
            if let e = parser.parse(Data(line.utf8)) { SessionReducer.apply(e, owner: owner, to: &s, now: clock.now()) }
        }
        return s
    }

    private func iso(_ offset: TimeInterval) -> String {
        clock.now().addingTimeInterval(offset).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func derive(_ s: SessionState, _ process: ProcessState? = nil) -> StatusRules.Result {
        StatusRules.derive(s, process: process, now: clock.now(), quietInterval: 120, historyWindow: 86_400)
    }

    @Test func midTurnWithoutPidIsRunningThenDoneAfterQuiet() {
        let s = session([SessionReducerTests.prompt("Build it", ts: iso(-1))])
        let first = derive(s)
        #expect(first.task == .running)
        #expect(first.mainRun == .running)
        #expect(first.nextDeadline == clock.now().addingTimeInterval(119))
        clock.advance(by: .seconds(121))
        let later = derive(s)
        #expect(later.task == .done)
        #expect(later.endedAt == s.lastActivityAt)
        #expect(later.nextDeadline == s.lastActivityAt!.addingTimeInterval(86_400))
    }

    @Test func pidStatusWins() {
        let s = session([SessionReducerTests.prompt("x", ts: iso(-3600))])
        #expect(derive(s, ProcessState(alive: true, status: "waiting")).task == .waiting)
        #expect(derive(s, ProcessState(alive: true, status: "busy")).task == .running)
        #expect(derive(s, ProcessState(alive: true, status: "idle")).task == .idle)
        #expect(derive(s, ProcessState(alive: true, status: "idle")).nextDeadline == nil)
        // A dead process's pid file says nothing: quiet rules apply.
        #expect(derive(s, ProcessState(alive: false, status: "busy")).task == .done)
    }

    @Test func turnEndedWithoutProcessIsTransientIdleUntilQuiet() {
        let end = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"},"type":"assistant","timestamp":"\#(iso(-30))"}"#
        let s = session([SessionReducerTests.prompt("x", ts: iso(-60)), end])
        #expect(derive(s).task == .idle)
        clock.advance(by: .seconds(91))
        #expect(derive(s).task == .done)
    }

    @Test func pendingQuestionIsWaiting() {
        let ask = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m","content":[{"type":"tool_use","id":"toolu_Q","name":"AskUserQuestion","input":{}}],"stop_reason":"tool_use"},"type":"assistant","timestamp":"\#(iso(-10))"}"#
        let s = session([SessionReducerTests.prompt("x", ts: iso(-20)), ask])
        #expect(derive(s).task == .waiting)
        #expect(derive(s, ProcessState(alive: true, status: "idle")).task == .waiting)
        clock.advance(by: .seconds(200))
        #expect(derive(s).task == .done)                                             // no process, quiet
        #expect(derive(s, ProcessState(alive: true, status: "idle")).task == .waiting)
    }

    @Test func apiErrorFailsUntilTheNextPrompt() {
        let err = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","id":"e","content":[{"type":"text","text":"limit"}],"stop_reason":"stop_sequence"},"timestamp":"\#(iso(-5))"}"#
        var s = session([SessionReducerTests.prompt("x", ts: iso(-10)), err])
        #expect(derive(s).task == .failed)
        #expect(derive(s).mainRun == .failed)
        let parser = LineParser()
        if let e = parser.parse(Data(SessionReducerTests.prompt("again", ts: iso(-1)).utf8)) {
            SessionReducer.apply(e, owner: .main, to: &s, now: clock.now())
        }
        #expect(derive(s).task == .running)
    }

    @Test func closedSessionCancelsUnfinishedRuns() {
        let s = session([SessionReducerTests.prompt("x", ts: iso(-10)),
                         SessionReducerTests.agentCall(id: "toolu_C", ts: iso(-9)),
                         #"{"type":"cost-state","totalCostUSD":1}"#])
        let r = derive(s)
        #expect(s.closed)
        #expect(r.task == .done)
        #expect(r.runs["toolu_C"] == .cancelled)
        #expect(r.nextDeadline == s.lastActivityAt!.addingTimeInterval(86_400))
    }

    @Test func runningSubagentKeepsTaskRunningUntilQuiet() {
        var s = session([SessionReducerTests.prompt("x", ts: iso(-50)),
                         SessionReducerTests.agentCall(id: "toolu_S", ts: iso(-40), background: true)])
        SessionReducer.applyMeta(AgentMeta(agentType: "Explore", toolUseID: "toolu_S"), agentID: "s9", to: &s, now: clock.now())
        let parser = LineParser()
        if let e = parser.parse(Data(SessionReducerTests.subagentLine("s9", ts: iso(-5)).utf8)) {
            SessionReducer.apply(e, owner: .agent("s9"), to: &s, now: clock.now())
        }
        s.main.own.phase = .ended(.normal)
        #expect(derive(s, ProcessState(alive: true, status: "idle")).task == .running)
        #expect(derive(s, ProcessState(alive: true, status: "idle")).runs["toolu_S"] == .running)
        clock.advance(by: .seconds(130))
        let quiet = derive(s)
        #expect(quiet.task == .done)
        #expect(quiet.runs["toolu_S"] == .cancelled)
    }

    @Test func windowExpiryLeavesScope() {
        let s = session([SessionReducerTests.prompt("x", ts: iso(-200))])
        #expect(derive(s).inScope)
        clock.advance(by: .seconds(86_400))
        #expect(!derive(s).inScope)
    }

    @Test func clockSkewGuardUsesLocalGrowth() {
        // Line timestamps an hour in the past, but the file grew just now (local clock).
        var s = session([SessionReducerTests.prompt("x", ts: iso(-3600))])
        s.lastGrowthAt = clock.now()
        #expect(derive(s).task == .running)
    }
}
