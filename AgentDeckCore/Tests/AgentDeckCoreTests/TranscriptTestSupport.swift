import Foundation
import Synchronization
import Testing
@testable import AgentDeckCore

/// Shared helpers for the Claude Code transcript pipeline tests.
enum Fixtures {
    static var root: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static let f275 = "f275c38e-cde3-4b0c-8cef-c400aa11f151"
    static let s08cb = "08cb7b8e-f5fb-4c5b-a629-6acba5fa664f"
    static let bd324 = "bd324a5f-860d-4c59-9137-4180bda0e2c4"
    static let s5d78 = "5d787e54-feca-4c10-aafd-4948a9ac5167"
    static let allSessions = [f275, s08cb, bd324, s5d78]

    /// "Now" for fixture tests: 2026-10-03T00:00:00Z, about two hours after the newest fixture line.
    static let now = Date(timeIntervalSince1970: 1_790_985_600)

    /// The home folder in fixture paths (`make-fixtures.py` rewrites the real one to this).
    static let home = "/Users/dev"
    /// The default workflow groups, with fixture paths.
    static let classifier = WorkflowClassifier(rules: .defaults, home: home)

    /// The main transcript of a fixture session.
    static func mainPath(_ sid: String, in root: URL = Fixtures.root) -> String {
        let projects = root.appendingPathComponent("projects")
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let p = projects.appendingPathComponent(dir).appendingPathComponent("\(sid).jsonl").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        fatalError("fixture \(sid) not found")
    }

    static func subagentDir(_ sid: String, in root: URL = Fixtures.root) -> String {
        (String(mainPath(sid, in: root).dropLast(6)) as NSString).appendingPathComponent("subagents")
    }

    /// Complete lines of a file (no trailing newline).
    static func lines(_ path: String) -> [Data] {
        let data = FileManager.default.contents(atPath: path)!
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Lines whose JSON matches `predicate` (reference decoding via JSONSerialization).
    static func lines(_ path: String, where predicate: ([String: Any]) -> Bool) -> [Data] {
        lines(path).filter { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
            return predicate(obj)
        }
    }

    /// Folds a fixture session in cold-load order (main → metas → subagents → custom title), like the engine.
    /// `root` selects another fixture tree (e.g. `Fixtures/extra`, kept apart from the engine tests' tree).
    static func reduce(_ sid: String, root: URL = Fixtures.root, mainLines: Int? = nil, subagentLines: [String: Int] = [:],
                       promote: Bool = true, now: Date = Fixtures.now) -> SessionState {
        let parser = LineParser()
        var s = SessionState(id: sid)
        s.mainSeen = true
        var main = lines(mainPath(sid, in: root))
        if let mainLines { main = Array(main.prefix(mainLines)) }
        for line in main {
            if let e = parser.parse(line) { SessionReducer.apply(e, owner: .main, to: &s, now: now) }
        }
        let dir = subagentDir(sid, in: root)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for name in names where name.hasSuffix(".meta.json") {
            let aid = String(name.dropFirst(6).dropLast(10))
            let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(name))!
            let meta = try! JSONDecoder().decode(AgentMeta.self, from: data)
            SessionReducer.applyMeta(meta, agentID: aid, to: &s, now: now)
        }
        for name in names where name.hasSuffix(".jsonl") {
            let aid = String(name.dropFirst(6).dropLast(6))
            var sub = lines((dir as NSString).appendingPathComponent(name))
            if let limit = subagentLines[aid] { sub = Array(sub.prefix(limit)) }
            for line in sub {
                if let e = parser.parse(line) { SessionReducer.apply(e, owner: .agent(aid), to: &s, now: now) }
            }
        }
        let titlePath = (String(mainPath(sid, in: root).dropLast(6)) as NSString).appendingPathComponent("custom-title.json")
        if let data = FileManager.default.contents(atPath: titlePath),
           let t = try? JSONDecoder().decode(CustomTitleFile.self, from: data), let title = t.customTitle {
            s.customTitle = title
        }
        if promote { SessionReducer.promoteOrphans(&s, now: now, force: true) }
        return s
    }

    /// Builds a snapshot from a reduced state with fixture definitions and the default estimator. The state
    /// must have a dated line (every fixture session has).
    static func snapshot(_ s: SessionState, process: ProcessState? = nil, now: Date = Fixtures.now,
                         historyWindow: TimeInterval = 90 * 86_400,
                         classifier: WorkflowClassifier = Fixtures.classifier) -> TaskSnapshot {
        var defs = AgentDefinitions(dataRoot: root.path)
        let estimator = Estimator()
        let status = StatusRules.derive(s, process: process, now: now, quietInterval: 120, historyWindow: historyWindow)
        return SnapshotBuilder.build(s, status: status,
                                     definitionModel: { defs.model(for: $0, projectPath: s.projectPath, now: now) },
                                     estimate: { estimator.estimate(agentType: $0, family: $1) },
                                     finishedEstimate: { _, type, family in estimator.estimate(agentType: type, family: family) },
                                     classifier: classifier)!.snapshot
    }

    /// A writable copy of the fixtures in a temporary directory, every file's mtime set to `mtime`.
    static func temporaryCopy(mtime: Date = Date(timeIntervalSince1970: 1_790_982_000)) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: dest)
        let enumerator = FileManager.default.enumerator(atPath: dest.path)!
        for case let rel as String in enumerator {
            try FileManager.default.setAttributes([.modificationDate: mtime],
                                                  ofItemAtPath: dest.appendingPathComponent(rel).path)
        }
        return dest
    }
}

/// Process probe with a fixed set of live pids; exits can be simulated.
final class FakeProbe: ProcessProbe {
    private let state: Mutex<(alive: Set<Int32>, watchers: [Int32: @Sendable () -> Void])>

    init(alive: Set<Int32> = []) {
        state = Mutex((alive, [:]))
    }

    func isAlive(pid: Int32, procStart: String?, startedAtMs: Int64?) -> Bool {
        state.withLock { $0.alive.contains(pid) }
    }

    func watchExit(pid: Int32, _ onExit: @escaping @Sendable () -> Void) -> ExitWatch {
        state.withLock { $0.watchers[pid] = onExit }
        return ExitWatch { [weak self] in self?.state.withLock { _ = $0.watchers.removeValue(forKey: pid) } }
    }

    /// Simulates the process exiting.
    func exit(_ pid: Int32) {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            s.alive.remove(pid)
            return s.watchers.removeValue(forKey: pid)
        }
        handler?()
    }
}

/// Polls `condition` (real time) until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

extension TaskSnapshot {
    func run(_ id: String) -> AgentRunSnapshot? { runs.first { $0.id == id } }
    func run(agentID: String) -> AgentRunSnapshot? { runs.first { $0.agentID == agentID } }
}

/// An engine over a temporary fixture copy with a test clock, a fake probe and an in-memory store.
struct EngineHarness {
    let root: URL
    let clock: TestClock
    let probe: FakeProbe
    let history: HistoryStore
    let engine: TranscriptEngine
    let configuration: ClaudeCodeSource.Configuration

    init(root: URL? = nil, alive: Set<Int32> = [3156], now: Date = Fixtures.now,
         historyWindow: TimeInterval = 30 * 86_400, history: HistoryStore = .inMemory(),
         rules: WorkflowRules = .defaults) throws {
        let root = try root ?? Fixtures.temporaryCopy()
        self.root = root
        clock = TestClock(now: now)
        probe = FakeProbe(alive: alive)
        self.history = history
        var config = ClaudeCodeSource.Configuration(dataRoot: root, historyWindow: historyWindow)
        config.databaseURL = root.appendingPathComponent("unused.sqlite")
        config.workflowRules = rules
        config.homeDirectory = Fixtures.home
        configuration = config
        engine = TranscriptEngine(configuration: config,
                                  environment: CoreEnvironment(clock: clock, probe: probe, history: history,
                                                               watchFileSystem: false, runsEstimateScan: false))
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A meta sidecar's JSON.
struct AgentMetaJSON {
    var type: String
    var toolUseID: String?

    var json: String {
        let tool = toolUseID.map { #","toolUseId":"\#($0)""# } ?? ""
        return #"{"agentType":"\#(type)","description":"d"\#(tool),"spawnDepth":1,"requestShape":"background"}"#
    }
}

extension SessionReducerTests {
    static func writeMeta(_ meta: AgentMetaJSON, to path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(meta.json.utf8))
    }
}
