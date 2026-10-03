import Foundation
import Synchronization
import Testing
@testable import AgentDeckCore

/// Read-only sanity check against the real `~/.claude` (AGENTDECK_LIVE=1 swift test --filter Live).
/// Uses a throwaway history database; prints a summary without any prompt text.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTDECK_LIVE"] == "1"))
struct LiveDataTests {
    struct Log {
        var firstTaskAt: Duration?
        var firstActiveAt: Duration?
        var loadCompleteAt: Duration?
        var tasks: [String: TaskSnapshot] = [:]
        var batches = 0
        var health: SourceHealth?
    }

    @Test func liveFirstUpdateSummary() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("agentdeck-live-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + suffix) }
        }
        var config = ClaudeCodeSource.Configuration(dataRoot: home.appendingPathComponent(".claude"), historyWindow: 24 * 3600)
        config.databaseURL = db
        let source = ClaudeCodeSource(configuration: config)

        let clock = ContinuousClock()
        let start = clock.now
        let log = Mutex(Log())
        let stream = await source.updates()
        let consumer = Task {
            for await update in stream {
                let t = clock.now - start
                log.withLock { l in
                    l.batches += 1
                    if l.firstTaskAt == nil, !update.changed.isEmpty { l.firstTaskAt = t }
                    if l.firstActiveAt == nil, update.changed.contains(where: { $0.status.isActive }) { l.firstActiveAt = t }
                    for s in update.changed { l.tasks[s.id] = s }
                    for id in update.removed { l.tasks[id] = nil }
                    if let h = update.health { l.health = h }
                    if update.initialLoadComplete, l.loadCompleteAt == nil { l.loadCompleteAt = t }
                }
            }
        }
        #expect(await eventually(timeout: .seconds(10)) { log.withLock { $0.loadCompleteAt != nil } })
        let atLoad = log.withLock { $0 }

        // Let the background scan and estimator reload finish, then measure 10 s of live watching.
        try await Task.sleep(for: .seconds(3))
        let batchesBefore = log.withLock { $0.batches }
        let cpuBefore = Self.cpuSeconds()
        let wallBefore = clock.now
        try await Task.sleep(for: .seconds(10))
        let cpu = Self.cpuSeconds() - cpuBefore
        let wall = (clock.now - wallBefore).timeInterval
        let batchesWatching = log.withLock { $0.batches } - batchesBefore
        let engine = source.engine
        let refreshed = await engine.allSnapshots()
        let estimator = await engine.currentEstimator
        await source.stop()
        consumer.cancel()

        func ms(_ d: Duration?) -> String { d.map { String(format: "%.0f ms", $0.timeInterval * 1000) } ?? "-" }
        print("LIVE first task: \(ms(atLoad.firstTaskAt)), first active task: \(ms(atLoad.firstActiveAt)), initialLoadComplete: \(ms(atLoad.loadCompleteAt)), batches until then: \(atLoad.batches), health: \(String(describing: atLoad.health))")
        print(String(format: "LIVE watching: %.3f s CPU over %.1f s wall (%.2f %% of one core), %d batches", cpu, wall, cpu / wall * 100, batchesWatching))
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "LIVE peak RSS of the whole test process: %.1f MB", Double(usage.ru_maxrss) / 1_048_576))
        print("LIVE tasks at load complete: \(atLoad.tasks.count); in scope at the end: \(refreshed.count)")
        let statusCounts = Dictionary(grouping: refreshed, by: \.status).mapValues(\.count)
        print("LIVE statuses: \(statusCounts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))")
        for s in refreshed.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) {
            let subs = s.subagents
            let runStatuses = Dictionary(grouping: subs, by: \.status).mapValues(\.count)
                .map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
            let models = Set(subs.map { "\($0.model.displayName)/\($0.model.source.rawValue)" }).sorted().joined(separator: ",")
            let estimates = subs.compactMap(\.estimate).map { "\($0.confidence.rawValue)(\($0.sampleCount))" }
            let estSummary = Dictionary(grouping: estimates, by: { $0 }).mapValues(\.count)
                .map { "\($0.key)x\($0.value)" }.sorted().joined(separator: ",")
            print("LIVE task \(s.id.prefix(8)) \(s.status.rawValue) project=\(s.projectName) main=\(s.mainModel.displayName) runs=\(subs.count) [\(runStatuses)] models=[\(models)] estimates=[\(estSummary)]")
            for r in subs where !r.status.isFinished {
                print("LIVE   active: type=\(r.agentType) \(r.status.rawValue) bg=\(r.isBackground) model=\(r.model.displayName)/\(r.model.source.rawValue) estimate=\(r.estimate.map { "\(Int($0.seconds))s \($0.confidence.rawValue)(\($0.sampleCount))" } ?? "-") tools=\(r.toolCallCount)")
            }
        }
        let types = ["Explore", "Plan", "general-purpose", "claude-code-guide", "localbiz-qa", "localbiz-site-builder"]
        print("LIVE estimator samples: " + types.map { "\($0)=\(estimator.sampleCount(agentType: $0))" }.joined(separator: " "))
        #expect(atLoad.loadCompleteAt != nil)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }
}
