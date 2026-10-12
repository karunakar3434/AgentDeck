import Foundation
import GRDB
import Testing
@testable import AgentDeckCore

/// Main transcripts holding only metadata lines, and the history rows older builds saved from them. When the
/// desktop app moves a worktree session's transcript to the repository's project folder, the session's old
/// CLI can still write its metadata lines at the old path on its way out. No line in that file has a time,
/// so it must not stand in for the conversation, show as a task, or be saved over the task's history row.
@Suite struct MetadataOnlyTranscriptTests {
    static let sid = "c2aa8dd7-6e26-4f0a-92d2-b03f924d3de0"
    static let worktreeDir = "-Users-dev-ai-engineer-course--claude-worktrees-fervent-poitras-30a664"
    static let repoDir = "-Users-dev-ai-engineer-course"
    static let worktreeCwd = "/Users/dev/ai-engineer-course/.claude/worktrees/fervent-poitras-30a664"
    static let start = "2026-10-02T23:50:00.000Z"

    static func answer(ts: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg-\#(ts)","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"},"type":"assistant","timestamp":"\#(ts)","cwd":"\#(worktreeCwd)","sessionId":"\#(sid)"}"#
    }

    /// A finished turn in the worktree.
    static let conversation = WorkflowHistoryTests.prompt("Net re-planned hours out of calendar deficit", ts: start, cwd: worktreeCwd)
        + "\n" + answer(ts: "2026-10-02T23:50:30.000Z") + "\n"

    /// What the CLI writes on its way out: no `timestamp`, no `cwd`.
    static let metadata = [
        #"{"type":"custom-title","customTitle":"Net re-planned hours out of calendar deficit","sessionId":"\#(sid)"}"#,
        #"{"type":"agent-name","agentName":"Net re-planned hours out of calendar deficit","sessionId":"\#(sid)"}"#,
        #"{"type":"last-prompt","leafUuid":"u2","sessionId":"\#(sid)"}"#,
        #"{"type":"mode","mode":"normal","sessionId":"\#(sid)"}"#,
        #"{"type":"cost-state","sessionId":"\#(sid)","totalCostUSD":0.5}"#,
    ].joined(separator: "\n") + "\n"

    static func storedStart(_ history: HistoryStore) async throws -> Double? {
        await history.flush()
        return try await history.database.read { db in
            try Double.fetchOne(db, sql: "SELECT started_at FROM history_task WHERE id = ?", arguments: [sid])
        }
    }

    // MARK: Relocation

    /// The incident: the metadata copy arrives after the move (`sameBatch == false`), or in the same batch,
    /// after replacing the old file in place before the moved one is seen.
    @Test(arguments: [false, true])
    func movedTranscriptKeepsItsConversationWhenTheOldPathGetsMetadataLines(sameBatch: Bool) async throws {
        let h = try EngineHarness(root: WorkflowHistoryTests.emptyRoot(), alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let worktreeMain = h.path("projects/\(Self.worktreeDir)/\(Self.sid).jsonl")
        let repoMain = h.path("projects/\(Self.repoDir)/\(Self.sid).jsonl")
        try EngineTests.append(Data(Self.conversation.utf8), to: worktreeMain)
        await h.engine.handle([FSChange(path: worktreeMain)])
        let before = try #require(await h.engine.snapshot(Self.sid))
        #expect(before.startedAt == Timestamp.parse(Self.start))
        #expect(before.projectName == "ai-engineer-course")

        // The worktree is gone: the desktop app moves the transcript, and the old CLI writes at the old path.
        try FileManager.default.createDirectory(atPath: h.path("projects/\(Self.repoDir)"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: worktreeMain, toPath: repoMain)
        if !sameBatch { await h.engine.handle([FSChange(path: worktreeMain), FSChange(path: repoMain)]) }
        try EngineTests.append(Data(Self.metadata.utf8), to: worktreeMain)
        await h.engine.handle(sameBatch ? [FSChange(path: worktreeMain), FSChange(path: repoMain)]
                                        : [FSChange(path: worktreeMain)])

        let after = try #require(await h.engine.snapshot(Self.sid))
        #expect(after.startedAt == before.startedAt)
        #expect(after.projectPath == Self.worktreeCwd)
        #expect(after.projectName == "ai-engineer-course")
        #expect(await h.engine.fileState(FileIO.realPath(worktreeMain)) == nil, "the metadata copy isn't read")
        #expect(await h.engine.fileState(FileIO.realPath(repoMain)) != nil)

        // The session goes on in the moved transcript, and finishes there.
        try EngineTests.append(Data((WorkflowHistoryTests.prompt("And next week?", ts: "2026-10-02T23:59:00.000Z",
                                                                 cwd: "/Users/dev/ai-engineer-course") + "\n"
            + Self.answer(ts: "2026-10-02T23:59:10.000Z") + "\n").utf8), to: repoMain)
        await h.engine.handle([FSChange(path: repoMain)])
        #expect(await h.engine.snapshot(Self.sid)?.runs.first?.prompt == "And next week?")
        h.clock.advance(by: .seconds(121))
        #expect(await h.engine.snapshot(Self.sid)?.status == .done)
        #expect(try await Self.storedStart(h.history) == HistoryTime.column(before.startedAt))

        // The transcript is deleted while the metadata copy is still there: it isn't adopted, the task stays.
        try FileManager.default.removeItem(atPath: repoMain)
        await h.engine.handle([FSChange(path: repoMain)])
        h.clock.advance(by: .seconds(3))
        await h.engine.timerFired()
        #expect(await h.engine.fileState(FileIO.realPath(worktreeMain)) == nil)
        let gone = try #require(await h.engine.snapshot(Self.sid))
        #expect(gone.startedAt == before.startedAt)
        #expect(gone.runs.first?.prompt == "And next week?")
    }

    @Test func coldLoadReadsTheCopyHoldingTheConversation() async throws {
        let h = try EngineHarness(root: WorkflowHistoryTests.emptyRoot(), alive: [])
        defer { h.cleanup() }
        let worktreeMain = h.path("projects/\(Self.worktreeDir)/\(Self.sid).jsonl")
        let repoMain = h.path("projects/\(Self.repoDir)/\(Self.sid).jsonl")
        try EngineTests.append(Data(Self.conversation.utf8), to: repoMain)
        try EngineTests.append(Data(Self.metadata.utf8), to: worktreeMain)
        // The metadata copy is the newer one.
        try FileManager.default.setAttributes([.modificationDate: Fixtures.now.addingTimeInterval(-600)], ofItemAtPath: repoMain)
        try FileManager.default.setAttributes([.modificationDate: Fixtures.now.addingTimeInterval(-60)], ofItemAtPath: worktreeMain)
        await h.engine.loadInitial()

        let snap = try #require(await h.engine.snapshot(Self.sid))
        #expect(snap.startedAt == Timestamp.parse(Self.start))
        #expect(snap.projectPath == Self.worktreeCwd)
        #expect(await h.engine.fileState(FileIO.realPath(repoMain)) != nil)
        #expect(await h.engine.fileState(FileIO.realPath(worktreeMain)) == nil)
    }

    // MARK: No known start

    @Test func metadataOnlyTranscriptIsNeitherShownNorSavedOverTheTask() async throws {
        let h = try EngineHarness(root: WorkflowHistoryTests.emptyRoot(), alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let main = h.path("projects/\(Self.worktreeDir)/\(Self.sid).jsonl")
        try EngineTests.append(Data(Self.conversation.utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let task = try #require(await h.engine.snapshot(Self.sid))
        #expect(task.status == .done)
        #expect(try await Self.storedStart(h.history) == HistoryTime.column(task.startedAt))

        // Replaced by metadata lines alone (new inode): the session is re-read from them and has no start.
        let tmp = main + ".tmp"
        try Data(Self.metadata.utf8).write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, main)
        await h.engine.handle([FSChange(path: main)])
        #expect(await h.engine.sessionState(Self.sid)?.customTitle != nil)
        #expect(await h.engine.snapshot(Self.sid) == nil)
        h.clock.advance(by: .seconds(300))
        #expect(await h.engine.allSnapshots().isEmpty)
        #expect(try await Self.storedStart(h.history) == HistoryTime.column(task.startedAt), "the task's row is kept")

        // Once a dated line arrives, it is a task again.
        try EngineTests.append(Data((WorkflowHistoryTests.prompt("Again", ts: "2026-10-03T00:04:00.000Z", cwd: Self.worktreeCwd)
            + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        #expect(await h.engine.snapshot(Self.sid)?.startedAt == Timestamp.parse("2026-10-03T00:04:00.000Z"))
    }

    // MARK: Rows from older builds

    /// The row an older build saved from the metadata copy: 1970 start, no folder, no runs but main.
    static func undated(id: String) -> StoredTask {
        let ended = Fixtures.now.addingTimeInterval(-3600)
        var task = WorkflowHistoryTests.storedOnly(id: id, folder: "", title: "Net re-planned hours out of calendar deficit",
                                                   signals: TaskSignals(workingFolder: "", title: "Net re-planned hours"),
                                                   endedAt: ended)
        let epoch = Date(timeIntervalSince1970: 0)
        task.snapshot.startedAt = epoch
        task.snapshot.lastActivityAt = epoch
        task.snapshot.runs[0].startedAt = epoch
        task.snapshot.runs[0].lastActivityAt = epoch
        return task
    }

    @Test func historyRowsSavedWithNoStartAreDeletedAndSkipped() async throws {
        let dir = try WorkflowHistoryTests.emptyRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agentdeck.sqlite")
        let kept = WorkflowHistoryTests.storedOnly(id: "kept", folder: "/Users/dev/ai-engineer-course", title: "Plan the week",
                                                   signals: TaskSignals(workingFolder: "/Users/dev/ai-engineer-course", title: "Plan the week"),
                                                   endedAt: Fixtures.now.addingTimeInterval(-7200))
        do {
            let pool = try DatabasePool(path: url.path)
            try HistorySchema.migrator.migrate(pool, upTo: "v2")
            try await pool.write { db in
                for stored in [kept, Self.undated(id: Self.sid)] {
                    let (task, runs) = try stored.records(encoder: SnapshotCoding.makeEncoder())
                    try task.insert(db)
                    for run in runs { try run.insert(db) }
                }
            }
            try pool.close()
        }

        // Opening migrates to v3, which deletes the undated task and its runs.
        let store = HistoryStore.open(at: url)
        #expect(store.health == .ok)
        let left = try await store.database.read { db in
            (tasks: try String.fetchAll(db, sql: "SELECT id FROM history_task"),
             runs: try String.fetchAll(db, sql: "SELECT DISTINCT task_id FROM history_run"))
        }
        #expect(left.tasks == ["kept"])
        #expect(left.runs == ["kept"])

        // A row an older build writes after the migration is skipped on load.
        store.enqueue(.finishedTask(Self.undated(id: "later")))
        await store.flush()
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["kept"])
        await store.close()
    }
}
