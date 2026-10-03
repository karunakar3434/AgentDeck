import Foundation
import Synchronization
import Testing
@testable import AgentDeckCore

/// Real FSEvents and the system clock, on a temporary data root.
@Suite struct FSEventsWatcherTests {
    @Test func watcherReportsFileWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-fse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FSEventsWatcher(paths: [FileIO.realPath(dir.path)])
        #expect(watcher.start())
        let seen = Mutex<[String]>([])
        let consumer = Task {
            for await batch in watcher.changes { seen.withLock { $0 += batch.map(\.path) } }
        }
        try await Task.sleep(for: .milliseconds(200))
        let file = dir.appendingPathComponent("a.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let target = FileIO.realPath(file.path)
        #expect(await eventually(timeout: .seconds(15)) { seen.withLock { $0.contains(target) } })
        watcher.stop()
        consumer.cancel()
    }

    @Test func sourceStreamsANewSessionWrittenAfterLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-live-\(UUID().uuidString)")
        let project = root.appendingPathComponent("projects/-Users-dev-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = ClaudeCodeSource.Configuration(dataRoot: root, historyWindow: 3600)
        config.databaseURL = root.appendingPathComponent("unused.sqlite")
        let source = ClaudeCodeSource(configuration: config, environment: CoreEnvironment(
            clock: SystemClock(), probe: FakeProbe(), history: .inMemory(), watchFileSystem: true, runsEstimateScan: false))
        let tasks = Mutex<[String: TaskSnapshot]>([:])
        let loaded = Mutex(false)
        let stream = await source.updates()
        let consumer = Task {
            for await update in stream {
                tasks.withLock { t in for s in update.changed { t[s.id] = s } }
                if update.initialLoadComplete { loaded.withLock { $0 = true } }
            }
        }
        #expect(await eventually(timeout: .seconds(15)) { loaded.withLock { $0 } })
        try await Task.sleep(for: .milliseconds(200))

        let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let now = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let line = SessionReducerTests.prompt("Ship it", ts: now) + "\n"
        try Data(line.utf8).write(to: project.appendingPathComponent("\(sid).jsonl"))
        let started = ContinuousClock.now
        #expect(await eventually(timeout: .seconds(15)) { tasks.withLock { $0[sid]?.status == .running } })
        let latency = ContinuousClock.now - started
        #expect(latency < .seconds(10))   // generous: the parallel suite can starve this; the live check measures real latency

        // A subagent starting: meta + transcript appear, linked by the Agent call.
        let call = SessionReducerTests.agentCall(id: "toolu_LIVE1", ts: now, background: true) + "\n"
        let handle = try FileHandle(forWritingTo: project.appendingPathComponent("\(sid).jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(call.utf8))
        try handle.close()
        let sub = project.appendingPathComponent("\(sid)/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(#"{"agentType":"Explore","description":"Look around","toolUseId":"toolu_LIVE1"}"#.utf8)
            .write(to: sub.appendingPathComponent("agent-live1.meta.json"))
        try Data((SessionReducerTests.subagentLine("live1", ts: now) + "\n").utf8)
            .write(to: sub.appendingPathComponent("agent-live1.jsonl"))
        #expect(await eventually(timeout: .seconds(15)) {
            tasks.withLock { $0[sid]?.run("toolu_LIVE1")?.agentID == "live1" && $0[sid]?.run("toolu_LIVE1")?.toolCallCount == 1 }
        })
        await source.stop()
        consumer.cancel()
    }
}
