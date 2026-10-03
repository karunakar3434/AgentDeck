import Foundation
import Testing
@testable import AgentDeckCore

/// The newer desktop session under `Fixtures/extra` (Claude Code 2.1.286): 7 background Agent calls, all
/// `async_launched` and finished by `<task-notification>`; peer handbacks as `queued_command` attachments and as
/// `user` lines; two Bash background-task notices; one agent resumed with SendMessage. Kept outside
/// `Fixtures/projects` so the engine tests' exact counts don't change.
enum Extra {
    static let sid = "fb4572c1-e498-4a92-b34e-cbc76531d53a"
    static var root: URL { Fixtures.root.appendingPathComponent("extra") }
    static var mainPath: String { Fixtures.mainPath(sid, in: root) }
    static var subagentDir: String { Fixtures.subagentDir(sid, in: root) }

    static func subagentPath(_ aid: String) -> String {
        (subagentDir as NSString).appendingPathComponent("agent-\(aid).jsonl")
    }

    static func metaPath(_ aid: String) -> String {
        (subagentDir as NSString).appendingPathComponent("agent-\(aid).meta.json")
    }

    /// Agent ids of the subagent files, sorted.
    static let agentIDs: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: subagentDir)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropFirst(6).dropLast(6)) }.sorted()
    }()

    /// Well after the newest line of any file (2026-10-03T01:33:40.519Z).
    static let now = Timestamp.parse("2026-10-03T03:00:00Z")!

    static let mainLines: [Data] = Fixtures.lines(mainPath)

    static func lines(of aid: String) -> [Data] { Fixtures.lines(subagentPath(aid)) }

    static func meta(_ aid: String) -> AgentMeta {
        try! JSONDecoder().decode(AgentMeta.self, from: FileManager.default.contents(atPath: metaPath(aid))!)
    }

    /// The whole session folded in cold-load order (computed once; `SessionState` is a value type).
    static let reduced: SessionState = Fixtures.reduce(sid, root: root, now: now)

    /// Folds the first `mainLines` main lines; subagent files only when `withSubagents`.
    static func reduce(mainLines: Int? = nil, withSubagents: Bool = true) -> SessionState {
        let none = Dictionary(uniqueKeysWithValues: agentIDs.map { ($0, 0) })
        return Fixtures.reduce(sid, root: root, mainLines: mainLines, subagentLines: withSubagents ? [:] : none, now: now)
    }

    /// The tool_use ids of the Agent calls, in file order (reference decode).
    static let agentCallIDs: [String] = mainLines.flatMap { Ref.toolUses(Ref.json($0)) }
        .filter { ($0["name"] as? String) == "Agent" }.compactMap { $0["id"] as? String }
}

/// Reference decoding with `JSONSerialization`, independent of the production `Decodable` models.
enum Ref {
    static func json(_ line: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
    }

    static func type(_ obj: [String: Any]) -> String? { obj["type"] as? String }

    static func message(_ obj: [String: Any]) -> [String: Any] { obj["message"] as? [String: Any] ?? [:] }

    static func blocks(_ obj: [String: Any]) -> [[String: Any]] { message(obj)["content"] as? [[String: Any]] ?? [] }

    static func toolUses(_ obj: [String: Any]) -> [[String: Any]] {
        guard type(obj) == "assistant" else { return [] }
        return blocks(obj).filter { $0["type"] as? String == "tool_use" }
    }

    static func attachmentType(_ obj: [String: Any]) -> String? {
        (obj["attachment"] as? [String: Any])?["type"] as? String
    }

    static func timestamp(_ obj: [String: Any]) -> Date? {
        (obj["timestamp"] as? String).flatMap(Timestamp.parse)
    }

    /// The scanner decision expected from a line's top-level `type` (and attachment `type`).
    static func expectedKind(_ obj: [String: Any]) -> LineKind {
        switch type(obj) {
        case "user": .user
        case "assistant": .assistant
        case "system": .system
        case "queue-operation": .queueOperation
        case "custom-title": .customTitle
        case "ai-title": .aiTitle
        case "relocated": .relocated
        case "cost-state": .costState
        case "fork-context-ref": .forkContextRef
        case "attachment": attachmentType(obj) == "queued_command" ? .queuedCommand : .skip
        default: .skip
        }
    }

    /// Text between `<name>` and `</name>` (first occurrence).
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// A JSON string literal (quoted and escaped) for splicing into a raw line.
    static func literal(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
               as: UTF8.self)
    }
}

/// Raw-byte helpers for building variants of real lines.
enum RawLine {
    static func string(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    /// `line` with the first occurrence of `target` replaced (the substitution must apply).
    static func replacing(_ target: String, with replacement: String, in line: Data) throws -> Data {
        let s = string(line)
        let range = try #require(s.range(of: target), "\(target) not in line")
        return Data(s.replacingCharacters(in: range, with: replacement).utf8)
    }
}

/// A comparable rendering of a parse result. `String(reflecting:)` prints dates to the second only, so the
/// primary timestamp is appended with full precision.
func fingerprint(_ e: TranscriptEvent?) -> String {
    guard let e else { return "nil" }
    let ts: Date?
    switch e {
    case .assistant(let a): ts = a.context.timestamp
    case .user(let u): ts = u.context.timestamp
    case .system(_, let ctx): ts = ctx.timestamp
    case .notices(_, let t), .queuedPrompt(_, let t): ts = t
    default: ts = nil
    }
    return String(reflecting: e) + " @" + (ts.map { String($0.timeIntervalSince1970) } ?? "-")
}

extension LineParser {
    func parse(_ string: String) -> TranscriptEvent? { parse(Data(string.utf8)) }
}

func classify(_ data: Data) -> LineKind { data.withUnsafeBytes { LineScanner.classify($0) } }

/// Applies raw lines with one parser.
func fold(_ lines: [Data], owner: FileOwner, into s: inout SessionState, now: Date = Extra.now) {
    let parser = LineParser()
    for line in lines {
        if let e = parser.parse(line) { SessionReducer.apply(e, owner: owner, to: &s, now: now) }
    }
}

/// Folds the extra session the way a live watcher sees it: each file in its own order, files interleaved by
/// timestamp (a k-way merge), each meta sidecar applied just before its agent's first line.
func foldExtraLiveOrder() -> SessionState {
    struct Source { var owner: FileOwner; var lines: [Data]; var stamps: [Date?]; var next = 0 }
    var sources = [Source(owner: .main, lines: Extra.mainLines, stamps: Extra.mainLines.map { Ref.timestamp(Ref.json($0)) })]
    for aid in Extra.agentIDs {
        let lines = Extra.lines(of: aid)
        sources.append(Source(owner: .agent(aid), lines: lines, stamps: lines.map { Ref.timestamp(Ref.json($0)) }))
    }
    // Lines without a timestamp (metadata) sort with the previous line of their file.
    for i in sources.indices {
        var last = Date.distantPast
        for k in sources[i].stamps.indices {
            if let t = sources[i].stamps[k] { last = t } else { sources[i].stamps[k] = last }
        }
    }
    let parser = LineParser()
    var s = SessionState(id: Extra.sid)
    s.mainSeen = true
    var metaApplied: Set<String> = []
    while true {
        var pick: Int?
        for i in sources.indices where sources[i].next < sources[i].lines.count {
            guard let p = pick else { pick = i; continue }
            if sources[i].stamps[sources[i].next]! < sources[p].stamps[sources[p].next]! { pick = i }
        }
        guard let i = pick else { break }
        let line = sources[i].lines[sources[i].next]
        sources[i].next += 1
        if case .agent(let aid) = sources[i].owner, !metaApplied.contains(aid) {
            metaApplied.insert(aid)
            SessionReducer.applyMeta(Extra.meta(aid), agentID: aid, to: &s, now: Extra.now)
        }
        if let e = parser.parse(line) { SessionReducer.apply(e, owner: sources[i].owner, to: &s, now: Extra.now) }
    }
    SessionReducer.promoteOrphans(&s, now: Extra.now, force: true)
    return s
}
