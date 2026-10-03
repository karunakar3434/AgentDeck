import Foundation
import Synchronization
import Testing
@testable import AgentDeckCore

/// The engine without FSEvents (architecture §15): a temporary fixture copy, `TestClock`, `FakeProbe`,
/// an in-memory history store; driven with `loadInitial()` / `handle(_:)`.
@Suite struct EngineTests {
    // MARK: Helpers

    /// Snapshots compared across engines: estimates depend on when each run finished, so they're dropped.
    static func normalized(_ s: TaskSnapshot?) -> TaskSnapshot? {
        guard var s else { return nil }
        for i in s.runs.indices { s.runs[i].estimate = nil }
        return s
    }

    static func append(_ data: Data, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    static func relativeMain(_ sid: String) -> String {
        let main = Fixtures.mainPath(sid)
        return String(main.dropFirst(Fixtures.root.path.count + 1))
    }

    /// Deterministic chunk sizes.
    struct LCG {
        var state: UInt64
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(upper)) + 1
        }
    }

    // MARK: Cold load

    @Test func coldLoadBuildsEveryFixtureTask() async throws {
        let h = try EngineHarness()
        defer { h.cleanup() }
        await h.engine.loadInitial()
        #expect(await h.engine.isInitialLoadComplete)
        let snaps = await h.engine.allSnapshots()
        #expect(Set(snaps.map(\.id)) == Set(Fixtures.allSessions))
        let byID = Dictionary(uniqueKeysWithValues: snaps.map { ($0.id, $0) })
        #expect(byID[Fixtures.f275]?.status == .waiting)            // sessions/3156.json, alive, "waiting"
        #expect(byID[Fixtures.f275]?.subagents.count == 9)
        #expect(byID[Fixtures.s08cb]?.status == .done)
        #expect(byID[Fixtures.bd324]?.subagents.count == 2)
        #expect(byID[Fixtures.s5d78]?.runs.count == 1)
        for snap in snaps {
            #expect(snap.source == "claude-code")
            #expect(snap.runs.first?.id == "main:\(snap.id)")
            #expect(snap.runs.first?.agentType == "main")
        }
    }

    @Test func coldLoadMatchesThePureReducer() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        for sid in Fixtures.allSessions {
            var engineSnap = await h.engine.snapshot(sid)
            var pure = Fixtures.snapshot(Fixtures.reduce(sid), historyWindow: 30 * 86_400)
            // Paths differ (temporary copy); everything else must match.
            engineSnap?.projectPath = pure.projectPath
            pure.projectName = engineSnap?.projectName ?? ""
            #expect(Self.normalized(engineSnap) == Self.normalized(pure), "\(sid)")
        }
    }

    @Test func historyWindowLimitsWhatIsLoaded() async throws {
        let h = try EngineHarness(historyWindow: 12 * 3600)
        defer { h.cleanup() }
        // Old sessions have old files: they aren't even parsed.
        let old = Timestamp.parse("2026-09-15T01:00:00Z")!
        for sid in [Fixtures.bd324, Fixtures.s5d78] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: h.path(Self.relativeMain(sid)))
        }
        await h.engine.loadInitial()
        let ids = Set(await h.engine.allSnapshots().map(\.id))
        #expect(ids == [Fixtures.f275, Fixtures.s08cb])
        #expect(await h.engine.sessionState(Fixtures.bd324) == nil)
        #expect(await h.engine.sessionState(Fixtures.s5d78) == nil)
    }

    // MARK: Incremental reads

    @Test func chunkedAppendEqualsOneShotParse() async throws {
        let sid = Fixtures.s5d78
        let incRoot = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-inc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: incRoot.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let inc = try EngineHarness(root: incRoot, alive: [])
        let one = try EngineHarness(alive: [])
        defer { inc.cleanup(); one.cleanup() }
        await inc.engine.loadInitial()

        let data = try Data(contentsOf: URL(fileURLWithPath: Fixtures.mainPath(sid)))
        let dest = inc.path(Self.relativeMain(sid))
        var rng = LCG(state: 42)
        var offset = 0
        var chunks = 0
        while offset < data.count {
            let n = min(rng.next(3000), data.count - offset)
            try Self.append(data.subdata(in: offset..<(offset + n)), to: dest)
            await inc.engine.handle([FSChange(path: dest)])
            offset += n
            chunks += 1
        }
        #expect(chunks > 50)
        #expect(await inc.engine.fileState(FileIO.realPath(dest))?.offset == Int64(data.count))

        await one.engine.loadInitial()
        inc.clock.advance(by: .seconds(121))
        one.clock.advance(by: .seconds(121))
        var a = await inc.engine.snapshot(sid)
        let b = await one.engine.snapshot(sid)
        a?.projectPath = b?.projectPath ?? ""
        #expect(a != nil)
        #expect(Self.normalized(a) == Self.normalized(b))
    }

    @Test func interleavedChunksAcrossAllFilesEqualOneShotParse() async throws {
        let sid = Fixtures.f275
        let incRoot = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-inc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: incRoot.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let inc = try EngineHarness(root: incRoot, alive: [])
        let one = try EngineHarness(alive: [])
        defer { inc.cleanup(); one.cleanup() }
        await inc.engine.loadInitial()

        // Every transcript split into chunks, merged in a random order that keeps each file's own order.
        let mainRel = Self.relativeMain(sid)
        let sessionRel = String(mainRel.dropLast(6))
        var queues: [(rel: String, chunks: [Data])] = []
        var rng = LCG(state: 7)
        func chunked(_ rel: String) throws -> (String, [Data]) {
            let data = try Data(contentsOf: Fixtures.root.appendingPathComponent(rel))
            var chunks: [Data] = []
            var o = 0
            while o < data.count {
                let n = min(rng.next(60_000), data.count - o)
                chunks.append(data.subdata(in: o..<(o + n)))
                o += n
            }
            return (rel, chunks)
        }
        queues.append(try chunked(mainRel))
        let subNames = try FileManager.default.contentsOfDirectory(atPath: Fixtures.subagentDir(sid)).sorted()
        for name in subNames {
            let rel = "\(sessionRel)/subagents/\(name)"
            if name.hasSuffix(".jsonl") { queues.append(try chunked(rel)) }
            else { queues.append((rel, [try Data(contentsOf: Fixtures.root.appendingPathComponent(rel))])) }
        }
        queues.append(("\(sessionRel)/custom-title.json",
                       [try Data(contentsOf: Fixtures.root.appendingPathComponent("\(sessionRel)/custom-title.json"))]))
        var steps = 0
        while !queues.isEmpty {
            let i = rng.next(queues.count) - 1
            let chunk = queues[i].chunks.removeFirst()
            let path = inc.path(queues[i].rel)
            if queues[i].rel.hasSuffix(".json") {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try chunk.write(to: URL(fileURLWithPath: path))
            } else {
                try Self.append(chunk, to: path)
            }
            await inc.engine.handle([FSChange(path: path)])
            if queues[i].chunks.isEmpty { queues.remove(at: i) }
            steps += 1
        }
        #expect(steps > 60)

        await one.engine.loadInitial()
        inc.clock.advance(by: .seconds(121))
        one.clock.advance(by: .seconds(121))
        var a = await inc.engine.snapshot(sid)
        let b = await one.engine.snapshot(sid)
        a?.projectPath = b?.projectPath ?? ""
        #expect(a?.subagents.count == 9)
        #expect(Self.normalized(a) == Self.normalized(b))
    }

    @Test func truncationResetsTheSession() async throws {
        let h = try EngineHarness(alive: [])
        let expected = try EngineHarness(alive: [])
        defer { h.cleanup(); expected.cleanup() }
        await h.engine.loadInitial()
        let main = h.path(Self.relativeMain(Fixtures.s08cb))
        let original = try Data(contentsOf: URL(fileURLWithPath: main))
        let prefix = Data(original.split(separator: 0x0A).prefix(60).joined(separator: [0x0A])) + Data([0x0A])

        // Truncate in place (same inode).
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: main))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: prefix)
        try handle.close()
        await h.engine.handle([FSChange(path: main)])

        // Same content, read once from scratch.
        try prefix.write(to: URL(fileURLWithPath: expected.path(Self.relativeMain(Fixtures.s08cb))))
        await expected.engine.loadInitial()
        h.clock.advance(by: .seconds(121))
        expected.clock.advance(by: .seconds(121))
        let a = await h.engine.snapshot(Fixtures.s08cb)
        let b = await expected.engine.snapshot(Fixtures.s08cb)
        #expect(a?.runs.first?.toolCallCount == b?.runs.first?.toolCallCount)
        #expect(Self.normalized(a) == Self.normalized(b))
        #expect(a?.status == .done)
        #expect(a?.runs.count == 3)   // main, the gmail call, the general-purpose call (its result is cut off)
    }

    @Test func replacedFileResetsTheSession() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let before = await h.engine.snapshot(Fixtures.s08cb)
        let main = h.path(Self.relativeMain(Fixtures.s08cb))
        let oldID = await h.engine.fileState(FileIO.realPath(main))?.fileID
        // Atomic replace: new inode, same bytes.
        let tmp = main + ".tmp"
        try FileManager.default.copyItem(atPath: main, toPath: tmp)
        _ = rename(tmp, main)
        await h.engine.handle([FSChange(path: main)])
        let after = await h.engine.snapshot(Fixtures.s08cb)
        #expect(await h.engine.fileState(FileIO.realPath(main))?.fileID != oldID)
        #expect(after?.runs.first?.toolCallCount == before?.runs.first?.toolCallCount)   // not double counted
        #expect(Self.normalized(after)?.runs == Self.normalized(before)?.runs)
    }

    @Test func movedSessionIsReboundKeepingOffsets() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let before = await h.engine.snapshot(Fixtures.s08cb)
        let oldMain = h.path(Self.relativeMain(Fixtures.s08cb))
        let oldDir = String(oldMain.dropLast(6))
        let newProject = h.path("projects/-Users-dev-moved")
        try FileManager.default.createDirectory(atPath: newProject, withIntermediateDirectories: true)
        let newMain = (newProject as NSString).appendingPathComponent("\(Fixtures.s08cb).jsonl")
        let newDir = String(newMain.dropLast(6))
        try FileManager.default.moveItem(atPath: oldMain, toPath: newMain)
        try FileManager.default.moveItem(atPath: oldDir, toPath: newDir)
        await h.engine.handle([FSChange(path: oldMain), FSChange(path: newMain), FSChange(path: oldDir), FSChange(path: newDir)])

        let real = FileIO.realPath(newMain)
        #expect(await h.engine.fileState(real)?.offset == Int64(try Data(contentsOf: URL(fileURLWithPath: newMain)).count))
        #expect(await h.engine.fileState(FileIO.realPath(h.root.path) + "/" + Self.relativeMain(Fixtures.s08cb)) == nil)
        let sub = FileIO.realPath((newDir as NSString).appendingPathComponent("subagents/agent-a140524516f2ac0a4.jsonl"))
        #expect(await h.engine.fileState(sub) != nil)

        // Growth at the new path is read incrementally.
        try Self.append(Data((SessionReducerTests.prompt("more", ts: "2026-10-02T23:59:50.000Z") + "\n").utf8), to: newMain)
        await h.engine.handle([FSChange(path: newMain)])
        let after = await h.engine.snapshot(Fixtures.s08cb)
        #expect(after?.runs.first?.toolCallCount == before?.runs.first?.toolCallCount)
        #expect(after?.status == .running)
        #expect(after?.runs.first?.prompt == "more")
        h.clock.advance(by: .seconds(5))
        await h.engine.timerFired()
        #expect(await h.engine.snapshot(Fixtures.s08cb) != nil)
    }

    // MARK: Liveness, time and scope

    @Test func processExitEndsTheWait() async throws {
        let h = try EngineHarness(alive: [3156])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        #expect(await h.engine.snapshot(Fixtures.f275)?.status == .waiting)
        h.probe.exit(3156)
        let done = await eventually { await h.engine.snapshot(Fixtures.f275)?.status == .done }
        #expect(done)
    }

    @Test func pidFileStatusChangeIsPickedUp() async throws {
        let h = try EngineHarness(alive: [3156])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let pidPath = h.path("sessions/3156.json")
        var json = try String(contentsOfFile: pidPath, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"status\":\"waiting\"", with: "\"status\":\"busy\"")
        try json.write(toFile: pidPath, atomically: true, encoding: .utf8)
        await h.engine.handle([FSChange(path: pidPath)])
        #expect(await h.engine.snapshot(Fixtures.f275)?.status == .running)
        try FileManager.default.removeItem(atPath: pidPath)
        await h.engine.handle([FSChange(path: pidPath)])
        #expect(await h.engine.snapshot(Fixtures.f275)?.status == .done)
        // The secret .key file next to pid files is never classified (never opened).
        #expect(PathClassifier(dataRoot: h.root).classify(h.path("sessions/3156.abc.key")) == .ignored)
    }

    @Test func orphanSubagentAppearsAfterGrace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-Users-dev-x"), withIntermediateDirectories: true)
        let h = try EngineHarness(root: root, alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let sid = "11111111-2222-3333-4444-555555555555"
        let main = h.path("projects/-Users-dev-x/\(sid).jsonl")
        try Self.append(Data((SessionReducerTests.prompt("Start", ts: "2026-10-02T23:59:50.000Z") + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let sub = h.path("projects/-Users-dev-x/\(sid)/subagents/agent-zz9.jsonl")
        try Self.append(Data((SessionReducerTests.subagentLine("zz9", ts: "2026-10-02T23:59:55.000Z") + "\n").utf8), to: sub)
        await h.engine.handle([FSChange(path: sub)])
        #expect(await h.engine.snapshot(sid)?.runs.count == 1)
        h.clock.advance(by: .seconds(5))
        let snap = await h.engine.snapshot(sid)
        #expect(snap?.runs.count == 2)
        #expect(snap?.run("agent:zz9")?.status == .running)
        #expect(snap?.run("agent:zz9")?.model.id == "claude-haiku-4-5-20251001")
        #expect(snap?.status == .running)
    }

    @Test func subagentFileBeforeMainIsNotDoubleCounted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-Users-dev-y"), withIntermediateDirectories: true)
        let h = try EngineHarness(root: root, alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let sid = "99999999-2222-3333-4444-555555555555"
        let sub = h.path("projects/-Users-dev-y/\(sid)/subagents/agent-q1.jsonl")
        try Self.append(Data((SessionReducerTests.subagentLine("q1", ts: "2026-10-02T23:59:55.000Z") + "\n").utf8), to: sub)
        await h.engine.handle([FSChange(path: sub)])
        #expect(await h.engine.snapshot(sid) == nil)          // no main transcript yet: not a task
        let main = h.path("projects/-Users-dev-y/\(sid).jsonl")
        let lines = [SessionReducerTests.prompt("Start", ts: "2026-10-02T23:59:50.000Z"),
                     SessionReducerTests.agentCall(id: "toolu_Q", ts: "2026-10-02T23:59:51.000Z")]
        try Self.append(Data((lines.joined(separator: "\n") + "\n").utf8), to: main)
        SessionReducerTests.writeMeta(AgentMetaJSON(type: "Explore", toolUseID: "toolu_Q"),
                                      to: h.path("projects/-Users-dev-y/\(sid)/subagents/agent-q1.meta.json"))
        await h.engine.handle([FSChange(path: main), FSChange(path: h.path("projects/-Users-dev-y/\(sid)/subagents/agent-q1.meta.json"))])
        let snap = await h.engine.snapshot(sid)
        #expect(snap?.subagents.count == 1)
        #expect(snap?.run("toolu_Q")?.agentID == "q1")
        #expect(snap?.run("toolu_Q")?.toolCallCount == 1)
        #expect(snap?.runs.first?.toolCallCount == 1)
    }

    @Test func windowExpiryEmitsRemoved() async throws {
        let h = try EngineHarness(alive: [3156], historyWindow: 3 * 3600)
        defer { h.cleanup() }
        let log = UpdateLog()
        let stream = await h.engine.updates()
        let consumer = Task { for await u in stream { log.append(u, at: h.clock.now()) } }
        defer { consumer.cancel() }
        #expect(await eventually { await h.engine.isInitialLoadComplete })
        await advanceFrame(h)
        #expect(await eventually { log.count == 1 })
        let first = try #require(log.updates.first?.0)
        #expect(first.initialLoadComplete)
        #expect(Set(first.changed.map(\.id)) == [Fixtures.f275, Fixtures.s08cb])

        // 08cb ended 2026-10-02T21:24:42Z: it leaves the 3 h window at 00:24:42Z.
        h.clock.advance(to: Timestamp.parse("2026-10-03T00:25:00Z")!)
        await advanceFrame(h)
        #expect(await eventually { log.count == 2 })
        #expect(log.updates.last?.0.removed == [Fixtures.s08cb])
        #expect(log.updates.last?.0.changed.isEmpty == true)
    }

    @Test func coalescerEmitsAtMostOneBatchPerFrameAndNoneWhenIdle() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        let log = UpdateLog()
        let stream = await h.engine.updates()
        let consumer = Task { for await u in stream { log.append(u, at: h.clock.now()) } }
        defer { consumer.cancel() }
        #expect(await eventually { await h.engine.isInitialLoadComplete })
        #expect(log.count == 0)          // nothing before the first 16 ms frame
        await advanceFrame(h)
        #expect(await eventually { log.count == 1 })
        #expect(log.updates[0].0.changed.count == 4)

        // A burst of 30 appends within one frame: one batch.
        let main = h.path(Self.relativeMain(Fixtures.s08cb))
        for i in 0..<30 {
            try Self.append(Data((SessionReducerTests.prompt("p\(i)", ts: "2026-10-02T23:59:\(10 + i).000Z") + "\n").utf8), to: main)
            await h.engine.handle([FSChange(path: main)])
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.count == 1)
        await advanceFrame(h)
        #expect(await eventually { log.count == 2 })
        #expect(log.updates[1].0.changed.map(\.id) == [Fixtures.s08cb])
        #expect(log.updates[1].0.changed.first?.runs.first?.prompt == "p29")

        // Idle: time passes, nothing is emitted (the UI computes elapsed time itself).
        for _ in 0..<60 { h.clock.advance(by: .milliseconds(16)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.count == 2)
        let times = log.updates.map(\.1)
        for (a, b) in zip(times, times.dropFirst()) { #expect(b.timeIntervalSince(a) >= 0.016) }
        #expect(await h.engine.batchesEmitted == 2)
    }

    /// Waits until a flush is sleeping on the test clock, then advances one 16 ms frame.
    func advanceFrame(_ h: EngineHarness) async {
        _ = await eventually(timeout: .seconds(15)) {
            guard let next = h.clock.nextDeadline else { return false }
            return next <= h.clock.now().addingTimeInterval(0.016)
        }
        h.clock.advance(by: .milliseconds(16))
    }

    // MARK: Hooks

    @Test func hookLineTriggersATranscriptRead() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        let hook = h.path("agentdeck/events.jsonl")
        try Self.append(Data(#"{"session_id":"old","transcript_path":"/nowhere.jsonl","hook_event_name":"Stop"}"#.utf8 + [0x0A]), to: hook)
        await h.engine.loadInitial()
        #expect(await h.engine.snapshot(Fixtures.s08cb)?.status == .done)

        let main = h.path(Self.relativeMain(Fixtures.s08cb))
        try Self.append(Data((SessionReducerTests.prompt("via hook", ts: "2026-10-02T23:59:58.000Z") + "\n").utf8), to: main)
        let event = #"{"session_id":"\#(Fixtures.s08cb)","transcript_path":"\#(main)","hook_event_name":"UserPromptSubmit"}"#
        let outside = #"{"session_id":"x","transcript_path":"/etc/passwd","hook_event_name":"Stop"}"#
        try Self.append(Data((outside + "\n" + event + "\n").utf8), to: hook)
        await h.engine.handle([FSChange(path: hook)])     // only the hook file changed
        let snap = await h.engine.snapshot(Fixtures.s08cb)
        #expect(snap?.status == .running)
        #expect(snap?.runs.first?.prompt == "via hook")
    }

    // MARK: History and estimates

    @Test func finishedTasksLoadFromHistoryWithoutParsing() async throws {
        let first = try EngineHarness(alive: [])
        defer { first.cleanup() }
        await first.engine.loadInitial()
        let expected = await first.engine.snapshot(Fixtures.s08cb)
        await first.engine.stop()

        // Same files and DB: tier 2 serves the stored snapshot.
        let second = EngineHarnessSharingHistory(first)
        await second.engine.loadInitial()
        #expect(await second.engine.sessionState(Fixtures.s08cb) == nil)
        #expect(await second.engine.snapshot(Fixtures.s08cb) == expected)

        // When the transcript grows (resumed), it is parsed from 0.
        let main = first.path(Self.relativeMain(Fixtures.s08cb))
        try Self.append(Data((SessionReducerTests.prompt("resume", ts: "2026-10-02T23:59:58.000Z") + "\n").utf8), to: main)
        await second.engine.handle([FSChange(path: main)])
        #expect(await second.engine.sessionState(Fixtures.s08cb) != nil)
        #expect(await second.engine.snapshot(Fixtures.s08cb)?.status == .running)
        #expect(await second.engine.snapshot(Fixtures.s08cb)?.subagents.count == 2)
    }

    @Test func deletedTranscriptKeepsTheTaskFromHistory() async throws {
        let first = try EngineHarness(alive: [])
        defer { first.cleanup() }
        await first.engine.loadInitial()
        _ = await first.engine.allSnapshots()
        await first.engine.stop()
        try FileManager.default.removeItem(atPath: first.path(Self.relativeMain(Fixtures.bd324)))
        let second = EngineHarnessSharingHistory(first)
        await second.engine.loadInitial()
        let snap = await second.engine.snapshot(Fixtures.bd324)
        #expect(snap?.status == .done)
        #expect(snap?.subagents.count == 2)
    }

    @Test func estimateScanAndEngineCountEachRunOnce() async throws {
        // Scanner alone (engine parsed nothing): 11 completed Agent runs across the fixtures.
        let scanOnly = try EngineHarness(alive: [])
        defer { scanOnly.cleanup() }
        await scanOnly.engine.prepare()
        let result = await scanOnly.engine.runEstimateScan()
        #expect(result.filesScanned == 4)
        #expect(result.rows == 12)
        #expect(result.samples.count == 11)
        let est = await scanOnly.engine.currentEstimator
        #expect(est.sampleCount(agentType: "localbiz-site-builder") == 5)
        #expect(est.sampleCount(agentType: "localbiz-qa") == 4)
        #expect(est.sampleCount(agentType: "general-purpose") == 1)
        #expect(est.sampleCount(agentType: "claude-code-guide") == 1)
        // A second scan skips unchanged files.
        #expect(await scanOnly.engine.runEstimateScan().filesScanned == 0)

        // Engine cold load, then the scan: the scan skips parsed files and nothing is counted twice.
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let afterLoad = await h.engine.currentEstimator
        #expect(afterLoad.sampleCount(agentType: "localbiz-site-builder") == 5)
        #expect(afterLoad.sampleCount(agentType: "localbiz-qa") == 4)
        let scan = await h.engine.runEstimateScan()
        #expect(scan.filesScanned == 0)
        #expect(await h.engine.currentEstimator.sampleCount(agentType: "localbiz-qa") == 4)
        let qa = afterLoad.estimate(agentType: "localbiz-qa", family: .opus)
        #expect(qa.confidence == .medium)
        #expect(qa.sampleCount == 4)
    }

    @Test func runsFinishedAtLoadUseTheOtherSamples() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let f275 = try #require(await h.engine.snapshot(Fixtures.f275))
        for run in f275.subagents {
            let estimate = try #require(run.estimate)
            // 4 localbiz-qa / 5 site-builder samples in the fixtures, minus the run's own.
            switch run.agentType {
            case "localbiz-qa": #expect(estimate.sampleCount == 3)
            case "localbiz-site-builder": #expect(estimate.sampleCount == 4)
            default: Issue.record("unexpected type \(run.agentType)")
            }
            #expect(estimate.confidence == .medium)
        }
        // The only general-purpose sample is the run's own: the built-in default, not its own duration.
        let gp = await h.engine.snapshot(Fixtures.s08cb)?.run("toolu_014VmCt9hdrzPCCUfBoz8GxZ")?.estimate
        #expect(gp == DurationEstimate(seconds: 180, confidence: .low, sampleCount: 0))
    }

    @Test func scanCompletionReEmitsChangedEstimates() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        let log = UpdateLog()
        let stream = await h.engine.updates()
        let consumer = Task { for await u in stream { log.append(u, at: h.clock.now()) } }
        defer { consumer.cancel() }
        #expect(await eventually { await h.engine.isInitialLoadComplete })
        await advanceFrame(h)
        #expect(await eventually { log.count == 1 })
        let before = try #require(log.updates[0].0.changed.first { $0.id == Fixtures.f275 })
        // The scan found three more localbiz-qa runs elsewhere.
        for i in 0..<3 {
            h.history.enqueue(.runDuration(RunDurationRow(
                toolUseID: "toolu_SCAN\(i)", sessionID: "other", agentType: "localbiz-qa", modelFamily: .opus,
                startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 1000),
                endedAt: Date(timeIntervalSince1970: 1_790_000_600 + Double(i) * 1000), durationMs: 600_000,
                isExact: true, outcome: "completed")))
        }
        await h.engine.scanFinished(EstimateScanner.Result())
        await advanceFrame(h)
        #expect(await eventually { log.count == 2 })
        let after = try #require(log.updates.last?.0.changed.first { $0.id == Fixtures.f275 })
        let qaBefore = before.subagents.first { $0.agentType == "localbiz-qa" }?.estimate
        let qaAfter = after.subagents.first { $0.agentType == "localbiz-qa" }?.estimate
        #expect(qaBefore?.sampleCount == 3)
        #expect(qaAfter?.sampleCount == 6)
    }

    @Test func watchedRunFreezesItsEstimateWhenItFinishes() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        let main = h.path(Self.relativeMain(Fixtures.s08cb))
        func result(_ id: String, aid: String, ms: Int, ts: String) -> String {
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"x"}]},"toolUseResult":{"status":"completed","agentId":"\#(aid)","agentType":"Explore","resolvedModel":"claude-haiku-4-5-20251001","totalDurationMs":\#(ms)},"timestamp":"\#(ts)"}"#
        }
        try Self.append(Data((SessionReducerTests.agentCall(id: "toolu_W1", ts: "2026-10-02T23:58:00.000Z") + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        #expect(await h.engine.snapshot(Fixtures.s08cb)?.run("toolu_W1")?.status == .queued)   // watched unfinished
        try Self.append(Data((result("toolu_W1", aid: "w1", ms: 42_000, ts: "2026-10-02T23:58:42.100Z") + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let w1 = await h.engine.snapshot(Fixtures.s08cb)?.run("toolu_W1")
        #expect(w1?.status == .done)
        #expect(w1?.estimate == DurationEstimate(seconds: 60, confidence: .low, sampleCount: 0))   // frozen
        // A run that finished unseen (call and result together) uses the other samples: W1's 42 s.
        let lines = [SessionReducerTests.agentCall(id: "toolu_W2", ts: "2026-10-02T23:59:00.000Z"),
                     result("toolu_W2", aid: "w2", ms: 30_000, ts: "2026-10-02T23:59:30.100Z")]
        try Self.append(Data((lines.joined(separator: "\n") + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let snap = await h.engine.snapshot(Fixtures.s08cb)
        #expect(snap?.run("toolu_W2")?.estimate == DurationEstimate(seconds: (42 + 60) / 2, confidence: .low, sampleCount: 1))
        #expect(snap?.run("toolu_W1")?.estimate?.seconds == 60)     // frozen estimates don't move
        #expect(await h.engine.currentEstimator.sampleCount(agentType: "Explore") == 2)
    }

    @Test func storedHistoryTasksRecomputeEstimates() async throws {
        let first = try EngineHarness(alive: [])
        defer { first.cleanup() }
        await first.engine.loadInitial()
        await first.engine.stop()
        for (i, seconds) in [100.0, 200, 300].enumerated() {
            first.history.enqueue(.runDuration(RunDurationRow(
                toolUseID: "toolu_GP\(i)", sessionID: "other", agentType: "general-purpose", modelFamily: .opus,
                startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
                durationMs: Int(seconds * 1000), isExact: true, outcome: "completed")))
        }
        await first.history.flush()
        let second = EngineHarnessSharingHistory(first)
        await second.engine.loadInitial()
        #expect(await second.engine.sessionState(Fixtures.s08cb) == nil)     // served from history
        let run = await second.engine.snapshot(Fixtures.s08cb)?.run("toolu_014VmCt9hdrzPCCUfBoz8GxZ")
        // Its own 38.7 s sample is left out: the median of the other three.
        #expect(run?.estimate == DurationEstimate(seconds: 200, confidence: .medium, sampleCount: 3))
    }

    @Test func liveFinishAddsOneSampleAndRedirtiesRunningRuns() async throws {
        let h = try EngineHarness(alive: [])
        defer { h.cleanup() }
        await h.engine.loadInitial()
        _ = await h.engine.allSnapshots()
        let before = await h.engine.currentEstimator.sampleCount(agentType: "Explore")
        let main = h.path(Self.relativeMain(Fixtures.s08cb))
        let lines = [
            SessionReducerTests.prompt("go", ts: "2026-10-02T23:59:00.000Z"),
            SessionReducerTests.agentCall(id: "toolu_LIVE", ts: "2026-10-02T23:59:01.000Z"),
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_LIVE","content":[{"type":"text","text":"done"}]}]},"toolUseResult":{"status":"completed","agentId":"alive1","agentType":"Explore","resolvedModel":"claude-haiku-4-5-20251001","totalDurationMs":42000,"content":[{"type":"text","text":"Found it"}]},"timestamp":"2026-10-02T23:59:43.500Z"}"#,
        ]
        try Self.append(Data((lines.joined(separator: "\n") + "\n").utf8), to: main)
        await h.engine.handle([FSChange(path: main)])
        let snap = await h.engine.snapshot(Fixtures.s08cb)
        let run = snap?.run("toolu_LIVE")
        #expect(run?.status == .done)
        #expect(run?.resultSummary == "Found it")
        #expect(run?.estimate?.seconds == 60)       // frozen before its own sample: the Explore default
        #expect(await h.engine.currentEstimator.sampleCount(agentType: "Explore") == before + 1)
        _ = await h.engine.snapshot(Fixtures.s08cb)
        #expect(await h.engine.currentEstimator.sampleCount(agentType: "Explore") == before + 1)
    }
}

/// A second engine over the first harness's files and history store.
struct EngineHarnessSharingHistory {
    let engine: TranscriptEngine
    init(_ first: EngineHarness) {
        engine = TranscriptEngine(configuration: first.configuration,
                                  environment: CoreEnvironment(clock: TestClock(now: first.clock.now()), probe: FakeProbe(),
                                                               history: first.history, watchFileSystem: false,
                                                               runsEstimateScan: false))
    }
}

/// Collected stream output with the test-clock time of receipt.
final class UpdateLog: Sendable {
    private let state = Mutex<[(DeckUpdate, Date)]>([])
    func append(_ update: DeckUpdate, at date: Date) { state.withLock { $0.append((update, date)) } }
    var updates: [(DeckUpdate, Date)] { state.withLock { $0 } }
    var count: Int { state.withLock { $0.count } }
}
