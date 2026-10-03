import Foundation
import Synchronization
import GRDB
import Testing
@testable import AgentDeckCore

@Suite struct HistoryStoreTests {
    enum Kind: String, CaseIterable, Sendable { case memory, file }

    /// Fractional on purpose: dates must round-trip exactly.
    static let now = Date(timeIntervalSince1970: 1_790_000_000.123_456_7)
    static let day: TimeInterval = 86_400

    // MARK: Helpers

    /// A fresh temporary directory, removed by `cleanup`.
    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDeckCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL?) {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private static func makeStore(_ kind: Kind) throws -> (store: HistoryStore, directory: URL?) {
        switch kind {
        case .memory:
            return (HistoryStore.inMemory(), nil)
        case .file:
            let directory = try makeTempDirectory()
            let store = HistoryStore.open(at: directory.appendingPathComponent("nested/agentdeck.sqlite"))
            #expect(store.databasePath != nil)
            return (store, directory)
        }
    }

    private static func run(_ id: String, task: String, ord: Int, parent: String?, tools: Int = 3,
                            type: String = "Explore") -> AgentRunSnapshot {
        let started = now.addingTimeInterval(Double(ord) * 1.5)
        let toolEvents = (0..<tools).map { index in
            ToolEvent(id: "\(id)-tool\(index)", name: "Bash", summary: "step \(index)",
                      startedAt: started.addingTimeInterval(Double(index) * 0.25),
                      endedAt: started.addingTimeInterval(Double(index) * 0.25 + 0.1), isError: index == 1)
        }
        return AgentRunSnapshot(
            id: id, taskID: task, parentRunID: parent, agentID: parent == nil ? nil : "a\(id)",
            agentType: parent == nil ? "main" : type, description: "run \(id)", prompt: "Do the thing \(id)",
            model: ModelInfo(id: "claude-opus-5-5", source: .transcript), status: .done, isBackground: ord % 2 == 0,
            startedAt: started, endedAt: started.addingTimeInterval(42.125), lastActivityAt: started.addingTimeInterval(42),
            estimate: parent == nil ? nil : DurationEstimate(seconds: 61.5, confidence: .medium, sampleCount: 4),
            toolCallCount: tools, currentActivity: "Bash: step", tokens: TokenUsage(input: 1, output: 2, cacheRead: 3, cacheCreation: 4),
            resultSummary: parent == nil ? nil : "Found it", recentTools: toolEvents, depth: parent == nil ? 0 : 1)
    }

    private static func task(_ id: String, endedAt: Date, runIDs: [String] = ["b", "a"], tools: Int = 3) -> StoredTask {
        let main = run("main:\(id)", task: id, ord: 0, parent: nil)
        let subagents = runIDs.enumerated().map { index, runID in
            run("\(id)-\(runID)", task: id, ord: index + 1, parent: main.id, tools: tools)
        }
        let snapshot = TaskSnapshot(
            id: id, source: "claude-code", projectName: "AgentDeck", projectPath: "/Users/dev/AgentDeck",
            title: "Task \(id)", status: .done, startedAt: now.addingTimeInterval(-600), lastActivityAt: endedAt,
            endedAt: endedAt, mainModel: ModelInfo(id: "claude-opus-5-5", source: .transcript), gitBranch: "main",
            runs: [main] + subagents)
        return StoredTask(snapshot: snapshot, transcriptPath: "/Users/dev/.claude/projects/x/\(id).jsonl",
                          fileID: UInt64.max - 7, fileSize: 123_456, fileMtime: now.addingTimeInterval(-0.000_001))
    }

    private static func duration(_ id: String, type: String = "Explore", family: ModelFamily = .opus,
                                 endedAt: Date?, ms: Int?, exact: Bool = true,
                                 outcome: String? = "completed") -> RunDurationRow {
        RunDurationRow(toolUseID: id, sessionID: "s1", agentType: type, modelFamily: family,
                       startedAt: (endedAt ?? now).addingTimeInterval(-Double(ms ?? 0) / 1000),
                       endedAt: endedAt, durationMs: ms, isExact: exact, outcome: outcome)
    }

    private static func storedDuration(_ store: HistoryStore, _ id: String) async throws -> RunDurationRow? {
        try await store.database.read { db in try RunDurationRecord.fetchOne(db, key: id)?.row }
    }

    // MARK: Schema

    @Test(arguments: Kind.allCases)
    func migrationCreatesTheSchema(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        #expect(store.health == .ok)

        let (tables, indexes, foreignKeys, migrations) = try await store.database.read { db in
            (try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"),
             try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"),
             try Int.fetchOne(db, sql: "PRAGMA foreign_keys"),
             try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
        #expect(Set(tables) == HistorySchema.tableNames)
        #expect(Set(indexes) == ["run_duration_estimator", "history_task_ended"])
        #expect(foreignKeys == 1)
        #expect(migrations == ["v1"])

        if kind == .file {
            let mode = try await store.database.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
        }
    }

    // MARK: run_duration

    @Test(arguments: Kind.allCases)
    func runDurationCallRowMergesWithItsResult(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        let started = Self.now

        // The Agent call: no outcome, family unknown yet.
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .other,
            startedAt: started, endedAt: nil, durationMs: nil, isExact: false, outcome: nil)))
        await store.flush()
        #expect(try await Self.storedDuration(store, "toolu_1")?.outcome == nil)

        // A fallback result (end_turn in the subagent file).
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .opus,
            startedAt: started.addingTimeInterval(0.5), endedAt: started.addingTimeInterval(40),
            durationMs: 40_000, isExact: false, outcome: "completed")))
        // The exact result arrives later and overwrites the fallback.
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .other,
            startedAt: started, endedAt: started.addingTimeInterval(42.5),
            durationMs: 42_500, isExact: true, outcome: "completed")))
        await store.flush()

        let exact = RunDurationRow(toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .opus,
                                   startedAt: started, endedAt: started.addingTimeInterval(42.5),
                                   durationMs: 42_500, isExact: true, outcome: "completed")
        #expect(try await Self.storedDuration(store, "toolu_1") == exact)

        // A repeated call row (NULLs) and a late fallback row don't clobber the exact values.
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .other,
            startedAt: started, endedAt: nil, durationMs: nil, isExact: false, outcome: nil)))
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .opus,
            startedAt: started, endedAt: started.addingTimeInterval(50), durationMs: 50_000,
            isExact: false, outcome: "failed")))
        await store.flush()
        #expect(try await Self.storedDuration(store, "toolu_1") == exact)

        // A later exact report (a resumed run) replaces the earlier exact one.
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "toolu_1", sessionID: "s1", agentType: "Explore", modelFamily: .haiku,
            startedAt: started, endedAt: started.addingTimeInterval(90), durationMs: 90_000,
            isExact: true, outcome: "completed")))
        await store.flush()
        let resumed = try await Self.storedDuration(store, "toolu_1")
        #expect(resumed?.durationMs == 90_000)
        #expect(resumed?.modelFamily == .haiku)
        #expect(resumed?.endedAt == started.addingTimeInterval(90))
    }

    @Test func runDurationFallbackFillsGapsWithoutOverwritingExact() async throws {
        let store = HistoryStore.inMemory()
        let started = Self.now
        // Exact row without an end date (unusual), then a fallback row that knows it.
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "t", sessionID: "s", agentType: "Plan", modelFamily: .sonnet, startedAt: started,
            endedAt: nil, durationMs: 1_000, isExact: true, outcome: nil)))
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "t", sessionID: "s", agentType: "Plan", modelFamily: .other, startedAt: started,
            endedAt: started.addingTimeInterval(3), durationMs: 3_000, isExact: false, outcome: "completed")))
        await store.flush()
        let row = try await Self.storedDuration(store, "t")
        #expect(row?.durationMs == 1_000)                      // exact kept
        #expect(row?.endedAt == started.addingTimeInterval(3)) // gap filled
        #expect(row?.outcome == "completed")                   // gap filled
        #expect(row?.modelFamily == .sonnet)                   // 'other' doesn't clobber
        #expect(row?.isExact == true)
    }

    // MARK: Samples

    @Test(arguments: Kind.allCases)
    func loadSamplesReturnsCompletedNewestFirstPerType(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        for index in 0..<5 {
            store.enqueue(.runDuration(Self.duration("explore-\(index)", type: "Explore", family: .haiku,
                                                     endedAt: Self.now.addingTimeInterval(Double(index * 10)),
                                                     ms: 1_000 * (index + 1))))
        }
        for index in 0..<2 {
            store.enqueue(.runDuration(Self.duration("plan-\(index)", type: "Plan", family: .opus,
                                                     endedAt: Self.now.addingTimeInterval(Double(index * 10 + 25)),
                                                     ms: 2_500)))
        }
        // Not samples: failed, unfinished, completed without a duration.
        store.enqueue(.runDuration(Self.duration("failed", endedAt: Self.now.addingTimeInterval(100), ms: 9_000, outcome: "failed")))
        store.enqueue(.runDuration(Self.duration("open", endedAt: nil, ms: nil, exact: false, outcome: nil)))
        store.enqueue(.runDuration(Self.duration("noduration", endedAt: Self.now.addingTimeInterval(100), ms: nil)))
        await store.flush()

        let samples = await store.loadSamples(perTypeLimit: 3)
        // Explore ends at +40/+30/+20 (the newest 3 of 5), Plan at +35/+25.
        #expect(samples.map(\.agentType) == ["Explore", "Plan", "Explore", "Plan", "Explore"])
        #expect(samples.map(\.seconds) == [5, 2.5, 4, 2.5, 3])
        #expect(samples.first == DurationSample(agentType: "Explore", family: .haiku, seconds: 5,
                                                endedAt: Self.now.addingTimeInterval(40)))
        #expect(samples.map(\.endedAt) == samples.map(\.endedAt).sorted(by: >))

        #expect(await store.loadSamples(perTypeLimit: 10).count == 7)
        #expect(await store.loadSamples(perTypeLimit: 0).isEmpty)
    }

    // MARK: Finished tasks

    @Test(arguments: Kind.allCases)
    func finishedTaskRoundTripsWithRunsInOrder(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        let original = Self.task("t1", endedAt: Self.now, runIDs: ["zeta", "alpha", "mid"], tools: 25)
        store.enqueue(.finishedTask(original))
        await store.flush()

        let loaded = await store.loadHistory(endedAfter: Self.now.addingTimeInterval(-60))
        var expected = original
        for index in expected.snapshot.runs.indices {
            expected.snapshot.runs[index].recentTools = Array(expected.snapshot.runs[index].recentTools.suffix(20))
        }
        #expect(loaded == [expected])
        #expect(loaded.first?.snapshot.runs.map(\.id) == ["main:t1", "t1-zeta", "t1-alpha", "t1-mid"])
        #expect(loaded.first?.snapshot.runs[1].recentTools.first?.id == "t1-zeta-tool5")
        #expect(loaded.first?.fileID == UInt64.max - 7)

        // Re-storing replaces the run rows.
        let shorter = Self.task("t1", endedAt: Self.now, runIDs: ["only"])
        store.enqueue(.finishedTask(shorter))
        await store.flush()
        #expect(await store.loadHistory(endedAfter: .distantPast) == [shorter])
        let runRows = try await store.database.read { db in try HistoryRunRecord.fetchCount(db) }
        #expect(runRows == 2)
    }

    @Test(arguments: Kind.allCases)
    func loadHistoryFiltersByEndedAtNewestFirst(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        let ends: [(String, TimeInterval)] = [("old", -3 * Self.day), ("mid", -Self.day), ("new", -7200), ("edge", -2 * Self.day)]
        for (id, offset) in ends {
            store.enqueue(.finishedTask(Self.task(id, endedAt: Self.now.addingTimeInterval(offset))))
        }
        await store.flush()

        let loaded = await store.loadHistory(endedAfter: Self.now.addingTimeInterval(-2 * Self.day))
        #expect(loaded.map(\.snapshot.id) == ["new", "mid", "edge"])   // inclusive bound
        #expect(loaded.allSatisfy { $0.snapshot.runs.count == 3 })
        #expect(await store.loadHistory(endedAfter: Self.now).isEmpty)
    }

    @Test func removeTaskDeletesItsRuns() async throws {
        let store = HistoryStore.inMemory()
        store.enqueue(.finishedTask(Self.task("keep", endedAt: Self.now)))
        store.enqueue(.finishedTask(Self.task("drop", endedAt: Self.now)))
        store.enqueue(.removeTask(id: "drop"))
        await store.flush()
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["keep"])
        let runTasks = try await store.database.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT task_id FROM history_run")
        }
        #expect(runTasks == ["keep"])
    }

    @Test func undecodableTasksAreSkipped() async throws {
        let store = HistoryStore.inMemory()
        store.enqueue(.finishedTask(Self.task("good", endedAt: Self.now)))
        store.enqueue(.finishedTask(Self.task("badRun", endedAt: Self.now.addingTimeInterval(-1))))
        await store.flush()
        try await store.database.write { db in
            let (record, _) = try Self.task("badTask", endedAt: Self.now).records(encoder: SnapshotCoding.makeEncoder())
            var broken = record
            broken.snapshot = Data("{\"not\":\"a task\"}".utf8)
            try broken.insert(db)
            try db.execute(sql: "UPDATE history_run SET snapshot = x'00ff' WHERE task_id = 'badRun' AND ord = 1")
        }
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["good"])
    }

    // MARK: Scan cache

    @Test(arguments: Kind.allCases)
    func scanCacheRoundTripsExactly(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        let entry = ScanCacheEntry(path: "/tmp/a.jsonl", sessionID: "s1", fileID: UInt64.max - 1,
                                   size: 10_000_000_000, mtime: Self.now.addingTimeInterval(0.000_000_3), offset: 9_999)
        store.enqueue(.scanCache(entry))
        var updated = entry
        updated.offset = 10_000
        store.enqueue(.scanCache(updated))
        await store.flush()
        #expect(await store.loadScanCache() == ["/tmp/a.jsonl": updated])
    }

    // MARK: Prune

    @Test(arguments: Kind.allCases)
    func pruneAppliesWindowFloorSampleAgeAndMissingFiles(kind: Kind) async throws {
        let (store, directory) = try Self.makeStore(kind)
        defer { Self.cleanup(directory) }
        let scratch = try Self.makeTempDirectory()
        defer { Self.cleanup(scratch) }
        let existing = scratch.appendingPathComponent("present.jsonl")
        try Data("{}\n".utf8).write(to: existing)

        store.enqueue(.finishedTask(Self.task("8d", endedAt: Self.now.addingTimeInterval(-8 * Self.day))))
        store.enqueue(.finishedTask(Self.task("3d", endedAt: Self.now.addingTimeInterval(-3 * Self.day))))
        store.enqueue(.finishedTask(Self.task("1h", endedAt: Self.now.addingTimeInterval(-3600))))
        store.enqueue(.runDuration(Self.duration("181d", endedAt: Self.now.addingTimeInterval(-181 * Self.day), ms: 1_000)))
        store.enqueue(.runDuration(Self.duration("179d", endedAt: Self.now.addingTimeInterval(-179 * Self.day), ms: 1_000)))
        store.enqueue(.runDuration(RunDurationRow(
            toolUseID: "open200d", sessionID: "s", agentType: "Explore", modelFamily: .other,
            startedAt: Self.now.addingTimeInterval(-200 * Self.day), endedAt: nil, durationMs: nil,
            isExact: false, outcome: nil)))
        for path in [existing.path, scratch.appendingPathComponent("gone.jsonl").path] {
            store.enqueue(.scanCache(ScanCacheEntry(path: path, sessionID: "s", fileID: 1, size: 3,
                                                    mtime: Self.now, offset: 3)))
        }
        await store.flush()

        // A 1-day window is floored to 7 days, so the 3-day-old task survives.
        await store.prune(historyWindow: Self.day, now: Self.now)
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["1h", "3d"])
        let (runTasks, durations) = try await store.database.read { db in
            (try String.fetchAll(db, sql: "SELECT DISTINCT task_id FROM history_run ORDER BY task_id"),
             try String.fetchAll(db, sql: "SELECT tool_use_id FROM run_duration ORDER BY tool_use_id"))
        }
        #expect(runTasks == ["1h", "3d"])     // cascade removed the 8-day task's runs
        #expect(durations == ["179d"])
        #expect(Array(await store.loadScanCache().keys) == [existing.path])

        // A window wider than the floor is honored.
        await store.prune(historyWindow: 2 * Self.day, now: Self.now)
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["1h", "3d"])
        await store.prune(historyWindow: 0, now: Self.now.addingTimeInterval(5 * Self.day))
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["1h"])
    }

    // MARK: Opening

    @Test func sharedReturnsOneInstancePerPath() throws {
        let directory = try Self.makeTempDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("agentdeck.sqlite")
        let first = HistoryStore.shared(at: url)
        let second = HistoryStore.shared(at: directory.appendingPathComponent("sub/../agentdeck.sqlite"))
        let other = HistoryStore.shared(at: directory.appendingPathComponent("other.sqlite"))
        #expect(first === second)
        #expect(first !== other)
        #expect(first.health == .ok)
        #expect(first.databasePath == url.standardizedFileURL.path)
    }

    @Test func sharedIsSafeUnderConcurrentFirstUse() async throws {
        let directory = try Self.makeTempDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("race.sqlite")
        let stores = await withTaskGroup(of: HistoryStore.self) { group in
            for _ in 0..<8 { group.addTask { HistoryStore.shared(at: url) } }
            return await group.reduce(into: [HistoryStore]()) { $0.append($1) }
        }
        #expect(stores.allSatisfy { $0 === stores[0] })
    }

    @Test func corruptFileIsQuarantinedAndRecreated() async throws {
        let directory = try Self.makeTempDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("agentdeck.sqlite")
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: url)
        try Data("not a wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

        let store = HistoryStore.open(at: url)
        #expect(store.health == .ok)
        #expect(store.databasePath == url.path)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        // SQLite may also have created a -shm while failing; it is moved along with the -wal.
        let broken = try #require(names.first { $0.wholeMatch(of: /agentdeck\.sqlite\.broken-\d{8}-\d{6}/) != nil },
                                  "no quarantined database in \(names)")
        #expect(names.contains(broken + "-wal"), "\(names)")
        #expect(names.contains("agentdeck.sqlite"), "\(names)")   // the fresh database
        #expect(try Data(contentsOf: directory.appendingPathComponent(broken)) == garbage)

        store.enqueue(.finishedTask(Self.task("t", endedAt: Self.now)))
        await store.close()
        #expect(await store.loadHistory(endedAfter: .distantPast).count == 1)
    }

    @Test func unusableLocationFallsBackToMemory() async throws {
        let directory = try Self.makeTempDirectory()
        defer { Self.cleanup(directory) }
        let blocker = directory.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)

        let store = HistoryStore.open(at: blocker.appendingPathComponent("agentdeck.sqlite"))
        guard case .degraded(let reason) = store.health else {
            Issue.record("expected degraded health, got \(store.health)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(store.databasePath == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["file"])

        store.enqueue(.finishedTask(Self.task("t", endedAt: Self.now)))
        await store.flush()
        #expect(await store.loadHistory(endedAfter: .distantPast).count == 1)
    }

    // MARK: Buffered writes

    @Test func enqueueFlushAndReopenPersists() async throws {
        let directory = try Self.makeTempDirectory()
        defer { Self.cleanup(directory) }
        let url = directory.appendingPathComponent("agentdeck.sqlite")

        let first = HistoryStore.open(at: url)
        let task = Self.task("persisted", endedAt: Self.now)
        let entry = ScanCacheEntry(path: "/p.jsonl", sessionID: "s", fileID: 42, size: 7,
                                   mtime: Self.now.addingTimeInterval(0.000_000_1), offset: 7)
        first.enqueue(.finishedTask(task))
        first.enqueue(.runDuration(Self.duration("toolu_9", endedAt: Self.now, ms: 12_345)))
        first.enqueue(.scanCache(entry))
        await first.flush()
        await first.close()
        await first.close()   // idempotent

        let reopened = HistoryStore.open(at: url)
        #expect(reopened !== first)
        #expect(await reopened.loadHistory(endedAfter: .distantPast) == [task])
        #expect(await reopened.loadSamples(perTypeLimit: 50)
                == [DurationSample(agentType: "Explore", family: .opus, seconds: 12.345, endedAt: Self.now)])
        #expect(await reopened.loadScanCache() == ["/p.jsonl": entry])
        await reopened.close()
    }

    @Test func drainTaskWritesWithoutAnExplicitFlush() async throws {
        let store = HistoryStore.inMemory()
        store.enqueue(.scanCache(ScanCacheEntry(path: "/auto", sessionID: "s", fileID: 1, size: 1,
                                                mtime: Self.now, offset: 1)))
        let deadline = ContinuousClock.now + .seconds(10)
        while await store.loadScanCache().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await store.loadScanCache().keys.contains("/auto"))
        await store.close()
    }

    @Test func closeFlushesAndAStoreStaysUsableAfterClose() async throws {
        let store = HistoryStore.inMemory()
        await store.close()   // closing an idle store is fine
        store.enqueue(.removeTask(id: "nothing"))
        store.enqueue(.finishedTask(Self.task("a", endedAt: Self.now)))
        await store.close()
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["a"])

        // Enqueue after close restarts the drain task (a shared store handed to the next source).
        store.enqueue(.finishedTask(Self.task("b", endedAt: Self.now.addingTimeInterval(1))))
        await store.flush()
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["b", "a"])
        await store.close()
    }

    @Test func concurrentFlushesPreserveEnqueueOrder() async throws {
        let store = HistoryStore.inMemory()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for offset in 1...2_000 {
                    store.enqueue(.scanCache(ScanCacheEntry(path: "/ordered", sessionID: "s", fileID: 1,
                                                            size: Int64(offset), mtime: Self.now, offset: Int64(offset))))
                    if offset.isMultiple(of: 100) { await Task.yield() }
                }
            }
            for _ in 0..<4 {
                group.addTask { for _ in 0..<25 { await store.flush(); await Task.yield() } }
            }
        }
        await store.flush()
        #expect(await store.loadScanCache()["/ordered"]?.offset == 2_000)
        await store.close()
    }

    /// Regression: a flush that finds the buffer empty because another flush (or the drain task) already
    /// took it must still wait until that batch is committed.
    @Test func flushWaitsForABatchAlreadyBeingWritten() async throws {
        final class Flag: Sendable {
            private let value = Mutex(false)
            func set() { value.withLock { $0 = true } }
            var isSet: Bool { value.withLock { $0 } }
        }
        let store = HistoryStore.inMemory()
        let entered = Flag()
        let release = DispatchSemaphore(value: 0)
        try await store.database.writeWithoutTransaction { db in
            db.add(function: DatabaseFunction("test_block", argumentCount: 0, pure: false) { _ in
                entered.set()
                release.wait()   // blocks GRDB's writer queue, not a Swift concurrency thread
                return nil
            })
            try db.execute(sql: "CREATE TEMP TRIGGER block_scan AFTER INSERT ON scan_cache BEGIN SELECT test_block(); END")
        }

        store.enqueue(.scanCache(ScanCacheEntry(path: "/slow", sessionID: "s", fileID: 1, size: 1, mtime: Self.now, offset: 1)))
        let first = Task { await store.flush() }                // takes the buffer, then blocks mid-write
        while !entered.isSet { try await Task.sleep(for: .milliseconds(5)) }
        let secondDone = Flag()
        let second = Task { await store.flush(); secondDone.set() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!secondDone.isSet, "flush returned while an earlier batch was still being written")

        release.signal()
        await first.value
        await second.value
        #expect(secondDone.isSet)
        #expect(await store.loadScanCache().keys.contains("/slow"))
        await store.close()
    }

    @Test func aFailingOpDoesNotSinkTheBatch() async throws {
        let store = HistoryStore.inMemory()
        var bad = Self.task("bad", endedAt: Self.now)
        bad.snapshot.runs[1].startedAt = Date(timeIntervalSinceReferenceDate: .nan)   // JSON can't encode NaN
        store.enqueue(.finishedTask(Self.task("before", endedAt: Self.now)))
        store.enqueue(.finishedTask(bad))
        store.enqueue(.finishedTask(Self.task("after", endedAt: Self.now.addingTimeInterval(1))))
        await store.flush()
        #expect(await store.loadHistory(endedAfter: .distantPast).map(\.snapshot.id) == ["after", "before"])
    }
}
