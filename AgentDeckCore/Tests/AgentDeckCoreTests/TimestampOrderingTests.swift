import Foundation
import Testing
@testable import AgentDeckCore

/// Timestamp parsing (fixed-layout fast path and ISO-8601 fallback) and the reducer's use of max()/min() for
/// lines that arrive out of time order.
@Suite struct TimestampOrderingTests {
    /// 2026-10-02T23:56:28Z, the first prompt of the extra session.
    static let base: TimeInterval = 1_790_985_388

    struct Valid: Sendable, CustomTestStringConvertible {
        var text: String
        var epoch: TimeInterval
        var testDescription: String { text }
    }

    static let valid: [Valid] = [
        .init(text: "2026-10-02T23:56:28.204Z", epoch: base + 0.204),
        .init(text: "2026-10-02T23:56:28Z", epoch: base),
        .init(text: "2026-10-02T23:56:28.2Z", epoch: base + 0.2),
        .init(text: "2026-10-02T23:56:28.204123Z", epoch: base + 0.204123),
        .init(text: "2026-10-02T23:56:28.123456789Z", epoch: base + 0.123456789),
        .init(text: "2026-10-02T23:56:28.204+00:00", epoch: base + 0.204),
        .init(text: "2026-10-02T23:56:28.204-00:00", epoch: base + 0.204),
        .init(text: "2026-10-03T05:26:28.204+05:30", epoch: base + 0.204),
        .init(text: "2026-10-03T05:26:28.204+0530", epoch: base + 0.204),
        .init(text: "2026-10-02T19:56:28.5-04:00", epoch: base + 0.5),
        .init(text: "2026-10-03T13:56:28+14:00", epoch: base),
        .init(text: "2026-10-02T11:56:28-12:00", epoch: base),
        .init(text: "2026-10-02t23:56:28.204z", epoch: base + 0.204),
        .init(text: "2026-10-02 23:56:28.204Z", epoch: base + 0.204),
        .init(text: " 2026-10-02T23:56:28.204Z", epoch: base + 0.204),      // fallback after trimming
        .init(text: "1970-01-01T00:00:00Z", epoch: 0),
        .init(text: "2000-02-29T12:00:00Z", epoch: 951_825_600),          // leap day
        .init(text: "2026-12-31T23:59:59.999Z", epoch: 1_798_761_599.999),
        .init(text: "2016-12-31T23:59:60Z", epoch: 1_483_228_800),        // a leap second rolls over
    ]

    @Test(arguments: valid)
    func parsesISO8601Variants(_ v: Valid) throws {
        let date = try #require(Timestamp.parse(v.text))
        #expect(abs(date.timeIntervalSince1970 - v.epoch) < 1e-6)
    }

    /// Rejected by both the fast path and the `Date.ISO8601FormatStyle` fallback. (The fallback normalizes some
    /// near-ISO forms instead, e.g. `T24:00:00Z`, `:60`/`:61` fields, 1-digit offsets, trailing junk.)
    static let invalid = [
        "", "garbage", "2026-10-02", "2026-10-02T23:56", "2026-10-02T23:56:28.204", "2026-10-02T23:56:28",
        "2026-13-02T00:00:00Z", "2026-00-10T00:00:00Z", "2026-10-32T00:00:00Z", "2026-10-00T00:00:00Z",
        "2026-10-02T23:56:28.Z", "2026/10/02T23:56:28Z", "1790985388204",
    ]

    @Test(arguments: invalid)
    func rejectsMalformedTimestamps(_ text: String) {
        #expect(Timestamp.parse(text) == nil)
    }

    /// A real line whose timestamp is written with an offset parses to the same instant.
    @Test func offsetTimestampOnARealLine() throws {
        let line = Extra.mainLines[22]
        let offset = try RawLine.replacing(#""timestamp":"2026-10-02T23:56:35.582Z""#, with: #""timestamp":"2026-10-03T01:56:35.582+02:00""#, in: line)
        let parser = LineParser()
        guard case .assistant(let a)? = parser.parse(line), case .assistant(let b)? = parser.parse(offset) else {
            Issue.record("not assistant")
            return
        }
        #expect(a.context.timestamp == b.context.timestamp)
        #expect(fingerprint(.assistant(a)) == fingerprint(.assistant(b)))
    }

    // MARK: Reducer ordering

    private static func prompt(_ text: String, ts: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(ts)","origin":{"kind":"human"},"cwd":"/Users/dev/proj"}"#
    }

    private static func assistant(_ id: String, ts: String, owner: String? = nil) -> String {
        let agent = owner.map { #""agentId":"\#($0)","isSidechain":true,"# } ?? ""
        return #"{"parentUuid":"p",\#(agent)"message":{"model":"claude-opus-5-5","id":"msg_\#(id)","content":[{"type":"tool_use","id":"t_\#(id)","name":"Read","input":{"file_path":"/a/b.swift"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}},"type":"assistant","timestamp":"\#(ts)"}"#
    }

    private static func system(ts: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":5,"timestamp":"\#(ts)"}"#
    }

    @Test func outOfOrderLinesNeverMoveStartLaterOrActivityEarlier() throws {
        let t = { (s: String) in Timestamp.parse(s)! }
        var s = SessionState(id: "s1")
        // File order vs time order: 10:00:05, 09:59:58 (written with an offset), 10:00:10, 10:00:01, then lines
        // with an unparsable or missing timestamp.
        let lines = [
            Self.prompt("go", ts: "2026-10-02T10:00:05.000Z"),
            Self.assistant("a", ts: "2026-10-02T11:59:58.000+02:00"),
            Self.system(ts: "2026-10-02T10:00:10.250Z"),
            Self.assistant("b", ts: "2026-10-02T10:00:01.000Z"),
            Self.assistant("c", ts: "not a time"),
            #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t_c","content":"ok"}]}}"#,
        ]
        let parser = LineParser()
        var seen: [(Date?, Date?)] = []
        for line in lines {
            if let e = parser.parse(line) { SessionReducer.apply(e, owner: .main, to: &s, now: Fixtures.now) }
            seen.append((s.startedAt, s.lastActivityAt))
        }
        #expect(s.startedAt == t("2026-10-02T09:59:58.000Z"))
        #expect(s.lastActivityAt == t("2026-10-02T10:00:10.250Z"))
        #expect(s.main.own.firstAt == t("2026-10-02T09:59:58.000Z"))
        #expect(s.main.own.lastAt == t("2026-10-02T10:00:10.250Z"))
        #expect(s.main.lastActivityAt == t("2026-10-02T10:00:10.250Z"))
        for (prev, next) in zip(seen, seen.dropFirst()) {
            #expect(next.0! <= prev.0!)
            #expect(next.1! >= prev.1!)
        }
        // Lines without a usable timestamp still count as activity (tool calls, results) but don't move the clock.
        #expect(s.main.own.toolCallCount == 3)
        #expect(s.main.own.openTools == ["t_b"])        // turn_duration closed t_a; t_c got its result
    }

    @Test func subagentLinesOlderThanTheCallKeepTheCallAsStart() throws {
        let t = { (s: String) in Timestamp.parse(s)! }
        var s = SessionState(id: "s1")
        let call = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_call","content":[{"type":"tool_use","id":"toolu_K","name":"Agent","input":{"description":"d","subagent_type":"Explore","prompt":"p","run_in_background":true}}],"stop_reason":"tool_use"},"type":"assistant","timestamp":"2026-10-02T10:00:00.000Z"}"#
        fold([Data(call.utf8)], owner: .main, into: &s, now: Fixtures.now)
        SessionReducer.applyMeta(AgentMeta(agentType: "Explore", toolUseID: "toolu_K"), agentID: "k1", to: &s, now: Fixtures.now)
        // Clock skew: the agent's lines are stamped before its call, and out of order.
        fold([Self.assistant("x", ts: "2026-10-02T10:00:20.000Z", owner: "k1"),
              Self.assistant("y", ts: "2026-10-02T09:59:59.000Z", owner: "k1"),
              Self.assistant("z", ts: "2026-10-02T10:00:10.000Z", owner: "k1")].map { Data($0.utf8) },
             owner: .agent("k1"), into: &s, now: Fixtures.now)
        let run = try #require(s.runs["toolu_K"])
        #expect(run.startedAt == t("2026-10-02T10:00:00.000Z"))
        #expect(run.own.firstAt == t("2026-10-02T09:59:59.000Z"))
        #expect(run.own.lastAt == t("2026-10-02T10:00:20.000Z"))
        #expect(run.lastActivityAt == t("2026-10-02T10:00:20.000Z"))
        #expect(s.startedAt == t("2026-10-02T09:59:59.000Z"))
        let snap = try #require(Fixtures.snapshot(s, process: ProcessState(alive: true, status: "busy")).run("toolu_K"))
        #expect(snap.startedAt == t("2026-10-02T10:00:00.000Z"))
        #expect(snap.lastActivityAt == t("2026-10-02T10:00:20.000Z"))
    }
}
