import Foundation
import GRDB
import Testing
@testable import AgentDeckCore

/// Workflow groups in the engine and the history store: entries that change while a task runs, rule edits
/// that reclassify history without reading transcripts, and rows left by older builds.
@Suite struct WorkflowHistoryTests {
    static let scratchDir = "-Users-dev-Library-Application-Support-Claude-scratch-workspaces-9e5ecb1e-scratch-2026-10-02-ab12cd"
    static let scratchCwd = "/Users/dev/Library/Application Support/Claude/scratch-workspaces/9e5ecb1e/scratch-2026-10-02-ab12cd"

    static func emptyRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        return root
    }

    static func prompt(_ text: String, ts: String, cwd: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(ts)","origin":{"kind":"human"},"cwd":"\#(cwd)","sessionId":"s"}"#
    }

    static func entries(_ engine: TranscriptEngine) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: await engine.allSnapshots().map { ($0.id, $0.projectName) })
    }

    // MARK: A running task changes entry

    @Test func scratchSessionMovesToPubgMontagesPartwayAndIsSavedThere() async throws {
        let h = try EngineHarness(root: Self.emptyRoot(), alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let sid = "5e55c1a0-7d2f-4c55-9a43-0b1e2f3a4b5c"
        let main = h.path("projects/\(Self.scratchDir)/\(sid).jsonl")

        // A scratch session with no workflow signal yet: Others.
        try EngineTests.append(Data((Self.prompt("Find the best moments in IMG_6120.mov", ts: "2026-10-02T23:58:00.000Z",
                                                 cwd: Self.scratchCwd) + "\n"
            + SessionReducerTests.toolCall("Bash", id: "toolu_B1", ts: "2026-10-02T23:58:05.000Z",
                                           input: #"{"command":"ffprobe IMG_6120.mov"}"#) + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let before = try #require(await h.engine.snapshot(sid))
        #expect(before.projectName == "Others")
        #expect(before.projectKind == .others)

        // Partway through it runs the pubg-montage skill.
        try EngineTests.append(Data((SessionReducerTests.toolCall("Skill", id: "toolu_S1", ts: "2026-10-02T23:59:00.000Z",
                                                                  input: #"{"skill":"anthropic-skills:pubg-montage"}"#) + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let after = try #require(await h.engine.snapshot(sid))
        #expect(after.projectName == "PubgMontages")
        #expect(after.projectKind == .workflow)
        #expect(after.projectPath == Self.scratchCwd, "the real folder is still there")

        // When it finishes, its history row keeps the entry and the signals it came from.
        try EngineTests.append(Data((#"{"type":"cost-state","sessionId":"\#(sid)","totalCostUSD":0.5}"# + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        #expect(await h.engine.snapshot(sid)?.status == .done)
        await h.history.flush()
        let row = try await h.history.database.read { db -> (name: String?, signals: String?)? in
            try Row.fetchOne(db, sql: "SELECT project_name, signals FROM history_task WHERE id = ?", arguments: [sid])
                .map { ($0["project_name"], $0["signals"]) }
        }
        #expect(row?.name == "PubgMontages")
        let json = try #require(row?.signals)
        let signals = try JSONDecoder().decode(TaskSignals.self, from: Data(json.utf8))
        #expect(signals.skills == ["anthropic-skills:pubg-montage"])
        #expect(signals.tools == ["Bash", "Skill"])
        #expect(signals.workingFolder == Self.scratchCwd)
    }

    // MARK: Rule edits

    /// A finished task whose transcript is gone: only its history row is left.
    static func storedOnly(id: String, folder: String, title: String, signals: TaskSignals, endedAt: Date) -> StoredTask {
        let main = AgentRunSnapshot(
            id: "main:\(id)", taskID: id, parentRunID: nil, agentID: nil, agentType: "main", description: title,
            prompt: title, model: ModelInfo(id: "claude-opus-5-5", source: .transcript), status: .done, isBackground: false,
            startedAt: endedAt.addingTimeInterval(-300), endedAt: endedAt, lastActivityAt: endedAt, estimate: nil,
            toolCallCount: 3, currentActivity: nil, tokens: nil, resultSummary: nil, recentTools: [], depth: 0)
        let snapshot = TaskSnapshot(
            id: id, source: "claude-code", projectName: (folder as NSString).lastPathComponent, projectPath: folder,
            title: title, status: .done, startedAt: endedAt.addingTimeInterval(-300), lastActivityAt: endedAt,
            endedAt: endedAt, mainModel: ModelInfo(id: "claude-opus-5-5", source: .transcript), gitBranch: nil, runs: [main])
        return StoredTask(snapshot: snapshot, signals: signals, transcriptPath: "/Users/dev/.claude/projects/gone/\(id).jsonl",
                          fileID: 1, fileSize: 10, fileMtime: endedAt)
    }

    @Test func ruleEditReclassifiesEveryTaskIncludingHistoryWithoutReadingTranscripts() async throws {
        let history = HistoryStore.inMemory()
        let clipFolder = WorkflowClassifierTests.scratch("3535d5")
        history.enqueue(.finishedTask(Self.storedOnly(
            id: "db-only", folder: clipFolder, title: "Clip the stream",
            signals: TaskSignals(workingFolder: clipFolder, title: "Clip the stream", skills: ["anthropic-skills:pubg-montage"]),
            endedAt: Fixtures.now.addingTimeInterval(-3600))))
        await history.flush()
        let h = try EngineHarness(history: history)
        defer { h.cleanup() }
        await h.engine.loadInitial()
        #expect(await Self.entries(h.engine) == [
            Fixtures.s08cb: "GmailMonitor",     // scratch workspace, gmail-monitor run
            Fixtures.f275: "localbiz",          // real folder
            Fixtures.bd324: "Others",           // home folder
            Fixtures.s5d78: "Others",
            "db-only": "PubgMontages",          // from its stored signals
        ])

        // Without the transcripts, the signals already in memory and in the history rows are enough.
        try FileManager.default.removeItem(at: h.root.appendingPathComponent("projects"))
        var rules = WorkflowRules.defaults
        rules.groups[0].name = "Inbox"
        rules.groups.remove(at: 1)
        rules.groups.append(WorkflowGroup(name: "Websites", folders: ["~/localbiz"]))
        await h.engine.setWorkflowRules(rules)
        #expect(await Self.entries(h.engine) == [
            Fixtures.s08cb: "Inbox",
            Fixtures.f275: "Websites",
            Fixtures.bd324: "Others",
            Fixtures.s5d78: "Others",
            "db-only": "Others",
        ])
        #expect(await h.engine.snapshot(Fixtures.f275)?.projectKind == .workflow)
        #expect(await h.engine.snapshot("db-only")?.projectKind == .others)

        // The parsed session that changed entry is saved again with it.
        await h.history.flush()
        let saved = try await h.history.database.read { db in
            try String.fetchOne(db, sql: "SELECT project_name FROM history_task WHERE id = ?", arguments: [Fixtures.s08cb])
        }
        #expect(saved == "Inbox")
    }

    @Test func ruleEditSendsOnlyTheTasksWhoseEntryChanged() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        let log = UpdateLog()
        let stream = await h.engine.updates()
        let consumer = Task { for await u in stream { log.append(u, at: h.clock.now()) } }
        defer { consumer.cancel() }
        #expect(await eventually { await h.engine.isInitialLoadComplete })
        await EngineTests().advanceFrame(h)
        #expect(await eventually { log.count == 1 })

        var rules = WorkflowRules.defaults
        rules.groups[0].name = "Inbox"
        await h.engine.setWorkflowRules(rules)
        await EngineTests().advanceFrame(h)
        #expect(await eventually { log.count == 2 })
        #expect(log.updates[1].0.changed.map(\.id) == [Fixtures.s08cb])
        #expect(log.updates[1].0.changed.first?.projectName == "Inbox")

        // The same rules again: nothing to send.
        await h.engine.setWorkflowRules(rules)
        for _ in 0..<3 { h.clock.advance(by: .milliseconds(16)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.count == 2)
    }

    // MARK: Rows from older builds

    /// Writes a history row the way a pre-v2 build did: schema v1, the raw scratch folder as project name.
    static func insertV1Row(_ db: Database, id: String, folder: String, title: String, agentTypes: [String]) throws {
        let encoder = SnapshotCoding.makeEncoder()
        let ended = Fixtures.now.addingTimeInterval(-7200)
        let name = (folder as NSString).lastPathComponent
        let task = storedOnly(id: id, folder: folder, title: title, signals: TaskSignals(workingFolder: folder, title: title),
                              endedAt: ended)
        var header = task.snapshot
        header.runs = []
        header.projectName = name
        try db.execute(sql: """
            INSERT INTO history_task (id, status, project_name, started_at, ended_at, transcript_path, file_id,
                                      file_size, file_mtime, snapshot)
            VALUES (?, 'done', ?, ?, ?, ?, 1, 10, ?, ?)
            """, arguments: [id, name, HistoryTime.column(header.startedAt), HistoryTime.column(ended),
                             task.transcriptPath, HistoryTime.column(ended), try encoder.encode(header)])
        var runs = [task.snapshot.runs[0]]
        for (i, type) in agentTypes.enumerated() {
            var run = runs[0]
            run.id = "toolu_\(id)_\(i)"
            run.parentRunID = runs[0].id
            run.agentType = type
            run.depth = 1
            runs.append(run)
        }
        for (ord, run) in runs.enumerated() {
            try db.execute(sql: "INSERT INTO history_run (task_id, id, ord, agent_type, status, snapshot) VALUES (?, ?, ?, ?, 'done', ?)",
                           arguments: [id, run.id, ord, run.agentType, try encoder.encode(run)])
        }
    }

    @Test func staleScratchHistoryRowsGetTheirEntryFromStoredSignals() async throws {
        let dir = try Self.emptyRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agentdeck.sqlite")
        do {
            let pool = try DatabasePool(path: url.path)
            try HistorySchema.migrator.migrate(pool, upTo: "v1")
            try await pool.write { db in
                try Self.insertV1Row(db, id: "gmail", folder: WorkflowClassifierTests.scratch("cfe996"),
                                     title: "Daily Gmail report", agentTypes: ["gmail-monitor"])
                try Self.insertV1Row(db, id: "video", folder: WorkflowClassifierTests.scratch("3535d5"),
                                     title: "Video quality enhancement", agentTypes: [])
                try Self.insertV1Row(db, id: "second", folder: "/private/tmp/claude-501/x/scratchpad/second-session",
                                     title: "Make two Agent tool calls", agentTypes: ["Explore", "Explore"])
            }
            try pool.close()
        }

        // Opening migrates to v2, which fills the signals from what each row kept.
        let store = HistoryStore.open(at: url)
        #expect(store.health == .ok)
        let signals = try await store.database.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, signals FROM history_task").map { row in
                (row["id"] as String, try JSONDecoder().decode(TaskSignals.self, from: Data((row["signals"] as String).utf8)))
            })
        }
        #expect(signals["gmail"]?.agentTypes == ["gmail-monitor"])
        #expect(signals["gmail"]?.workingFolder == WorkflowClassifierTests.scratch("cfe996"))
        #expect(signals["second"]?.agentTypes == ["Explore"])
        #expect(signals["video"]?.title == "Video quality enhancement")

        // The stale names never come back: every entry is decided from the signals.
        let h = try EngineHarness(root: Self.emptyRoot(), alive: [], history: store)
        defer { h.cleanup() }
        await h.engine.loadInitial()
        #expect(await Self.entries(h.engine) == ["gmail": "GmailMonitor", "video": "PubgMontages", "second": "Others"])
        let stored = await store.loadHistory(endedAfter: .distantPast)
        #expect(stored.count == 3)
        #expect(stored.allSatisfy { $0.snapshot.projectName.hasPrefix("scratch-") || $0.snapshot.projectName == "second-session" },
                "the rows still hold the old names; only the entries are recomputed")
        await store.close()
    }

    @Test func rowsWithoutSignalsRecoverThemFromTheSnapshot() async throws {
        // An older build writing after the migration leaves `signals` NULL.
        let store = HistoryStore.inMemory()
        let folder = WorkflowClassifierTests.scratch("cfe996")
        try await store.database.write { db in
            try Self.insertV1Row(db, id: "late", folder: folder, title: "Gmail monitor subagent",
                                 agentTypes: ["general-purpose", "gmail-monitor"])
        }
        let stored = try #require(await store.loadHistory(endedAfter: .distantPast).first)
        #expect(stored.signals.agentTypes == ["general-purpose", "gmail-monitor"])
        #expect(Fixtures.classifier.classify(stored.signals).name == "GmailMonitor")
    }
}
