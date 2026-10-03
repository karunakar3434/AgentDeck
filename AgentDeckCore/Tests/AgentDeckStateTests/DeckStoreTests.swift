import Foundation
import Testing
import AgentDeckCore
@testable import AgentDeckState

// Builders for small, readable snapshots.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func run(_ id: String, task: String, parent: String? = nil, type: String = "Explore",
                 status: RunStatus = .running, model: String? = "claude-opus-5-5",
                 start: TimeInterval = 0, tools: Int = 0) -> AgentRunSnapshot {
    AgentRunSnapshot(
        id: id, taskID: task, parentRunID: parent, agentID: nil, agentType: parent == nil ? "main" : type,
        description: "desc \(id)", prompt: "prompt", model: ModelInfo(id: model, source: model == nil ? .inherited : .transcript),
        status: status, isBackground: false, startedAt: t0.addingTimeInterval(start), endedAt: status.isFinished ? t0.addingTimeInterval(start + 10) : nil,
        lastActivityAt: t0.addingTimeInterval(start), estimate: nil, toolCallCount: tools, currentActivity: nil,
        tokens: nil, resultSummary: nil, recentTools: [], depth: parent == nil ? 0 : 1)
}

private func task(_ id: String, status: TaskStatus = .running, project: String = "AgentDeck",
                  runs: [AgentRunSnapshot]? = nil, source: String = "claude-code") -> TaskSnapshot {
    let main = run("main:\(id)", task: id, status: status.isActive ? .running : .done)
    return TaskSnapshot(
        id: id, source: source, projectName: project, projectPath: "/p/\(project)", title: "Task \(id)", status: status,
        startedAt: t0, lastActivityAt: t0.addingTimeInterval(5), endedAt: status.isActive || status == .idle ? nil : t0.addingTimeInterval(60),
        mainModel: ModelInfo(id: "claude-opus-5-5", source: .transcript), gitBranch: "main", runs: runs ?? [main])
}

@MainActor
@Suite struct DeckStoreTests {

    @Test func appliesTasksAndBuildsIndexes() {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [
            task("a", runs: [run("main:a", task: "a"), run("x", task: "a", parent: "main:a")]),
            task("b", status: .done),
        ], initialLoadComplete: true))

        #expect(store.activeTaskIDs == ["a"])
        #expect(store.inactiveTaskIDs == ["b"])
        #expect(store.runningAgentCount == 2)
        #expect(store.tasks["a"]?.runs.map(\.runID) == ["main:a", "x"])
        #expect(store.runs[RunKey.make(task: "a", run: "x")]?.parentRunID == RunKey.make(task: "a", run: "main:a"))
        #expect(store.projects == ["AgentDeck"])
        #expect(store.agentTypes == ["Explore"])
    }

    @Test func modelsKeepIdentityAcrossUpdates() {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("x", task: "a", parent: "main:a")])]))
        let taskModel = store.tasks["a"]
        let runModel = store.runs[RunKey.make(task: "a", run: "x")]
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("x", task: "a", parent: "main:a", tools: 3)])]))
        #expect(store.tasks["a"] === taskModel)
        #expect(store.runs[RunKey.make(task: "a", run: "x")] === runModel)
        #expect(runModel?.toolCallCount == 3)
    }

    @Test func sameRunIDInTwoSessionsAreSeparateModels() {
        // A forked/resumed session can repeat Agent tool_use ids.
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [
            task("a", runs: [run("main:a", task: "a"), run("toolu_1", task: "a", parent: "main:a")]),
            task("b", runs: [run("main:b", task: "b"), run("toolu_1", task: "b", parent: "main:b", status: .done)]),
        ]))
        let ra = store.runs[RunKey.make(task: "a", run: "toolu_1")]
        let rb = store.runs[RunKey.make(task: "b", run: "toolu_1")]
        #expect(ra !== nil && rb !== nil && ra !== rb)
        #expect(ra?.status == .running && rb?.status == .done)
        store.apply(DeckUpdate(removed: ["b"]))
        #expect(store.runs[RunKey.make(task: "a", run: "toolu_1")] === ra)
    }

    @Test func runsMissingFromATaskAreDropped() {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("agent:orphan", task: "a", parent: "main:a")])]))
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("toolu_9", task: "a", parent: "main:a")])]))
        #expect(store.runs[RunKey.make(task: "a", run: "agent:orphan")] == nil)
        #expect(store.runs.count == 2)
        #expect(store.runningAgentCount == 2)
    }

    @Test func removedTasksDropTheirRuns() {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("x", task: "a", parent: "main:a")])]))
        store.apply(DeckUpdate(removed: ["a"]))
        #expect(store.tasks.isEmpty && store.runs.isEmpty && store.activeTaskIDs.isEmpty && store.runningAgentCount == 0)
    }

    @Test func modelsInUseUpdateWhenAModelResolvesLater() {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("x", task: "a", parent: "main:a", model: nil)])]))
        #expect(store.modelsInUse == [.opus])  // inherited → main model's family
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"),
                                                         run("x", task: "a", parent: "main:a", model: "claude-haiku-4-5-20251001")])]))
        #expect(store.modelsInUse == [.opus, .haiku])
    }

    @Test func resetClearsErrorAndGlanceCount() async throws {
        let store = DeckStore()
        var badge: [Int] = []
        store.onGlanceChange = { badge.append($0) }
        store.apply(DeckUpdate(changed: [task("a")], initialLoadComplete: true, health: .degraded("Data folder not found")))
        #expect(store.loadError == "Data folder not found")
        #expect(store.glanceRunningCount == 1)
        store.reset()
        #expect(store.loadError == nil)
        #expect(store.glanceRunningCount == 0)
        #expect(badge.last == 0)
    }

    @Test func glanceCountConvergesToTheTrueCount() async throws {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a")], initialLoadComplete: true))
        #expect(store.glanceRunningCount == 1)             // first change publishes at once
        store.apply(DeckUpdate(changed: [task("b")]))
        store.apply(DeckUpdate(changed: [task("c")]))
        #expect(store.runningAgentCount == 3)
        #expect(store.glanceRunningCount == 1)             // throttled…
        try await Task.sleep(for: .milliseconds(700))
        #expect(store.glanceRunningCount == 3)             // …then catches up
    }

    @Test func notifiesTaskFinishedOnlyAfterInitialLoad() {
        let store = DeckStore()
        var events: [DeckEvent] = []
        store.onEvent = { events.append($0) }
        store.apply(DeckUpdate(changed: [task("a")]))                           // still loading
        store.apply(DeckUpdate(changed: [task("a", status: .done)]))            // historical change
        #expect(events.isEmpty)
        store.apply(DeckUpdate(changed: [task("b")], initialLoadComplete: true))
        store.apply(DeckUpdate(changed: [task("b", status: .idle)]))
        store.apply(DeckUpdate(changed: [task("c", status: .failed)]))          // new task, already failed: no transition
        #expect(events == [.taskFinished(taskID: "b", failed: false)])
    }

    @Test func notifiesSubagentFailures() {
        let store = DeckStore()
        var events: [DeckEvent] = []
        store.onEvent = { events.append($0) }
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), run("x", task: "a", parent: "main:a", status: .failed)])],
                               initialLoadComplete: true))
        #expect(events.isEmpty)                                                  // failed before we were watching
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"),
                                                         run("x", task: "a", parent: "main:a", status: .failed),
                                                         run("y", task: "a", parent: "main:a"),
                                                         run("z", task: "a", parent: "main:a", status: .failed)])]))
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"),
                                                         run("x", task: "a", parent: "main:a", status: .failed),
                                                         run("y", task: "a", parent: "main:a", status: .failed),
                                                         run("z", task: "a", parent: "main:a", status: .failed)])]))
        #expect(events == [.subagentFailed(taskID: "a", runID: RunKey.make(task: "a", run: "z")),
                           .subagentFailed(taskID: "a", runID: RunKey.make(task: "a", run: "y"))])
    }

    @Test func idleTaskElapsedStopsAtLastActivity() {
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a", status: .idle)]))
        let later = t0.addingTimeInterval(3600)
        #expect(store.tasks["a"]?.elapsed(at: later) == 5)
        store.apply(DeckUpdate(changed: [task("a", status: .running)]))
        #expect(store.tasks["a"]?.elapsed(at: later) == 3600)
    }

    @Test func taskETAIsTheSlowestRunningSubagent() {
        var a = run("x", task: "a", parent: "main:a", start: 0)
        a.estimate = DurationEstimate(seconds: 60, confidence: .high, sampleCount: 12)
        var b = run("y", task: "a", parent: "main:a", start: 10)
        b.estimate = DurationEstimate(seconds: 120, confidence: .medium, sampleCount: 4)
        let store = DeckStore()
        store.apply(DeckUpdate(changed: [task("a", runs: [run("main:a", task: "a"), a, b])]))
        #expect(store.tasks["a"]?.eta == t0.addingTimeInterval(130))
    }
}
