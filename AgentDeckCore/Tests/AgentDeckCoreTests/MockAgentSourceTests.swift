import Foundation
import Testing
@testable import AgentDeckCore

/// Serialized: some tests measure real-time emission gaps, which parallel CPU-heavy tests would skew.
@Suite(.serialized)
struct MockAgentSourceTests {
    let start = Date(timeIntervalSince1970: 1_790_985_600) // 2026-10-03T00:00:00Z

    // MARK: First update

    @Test(arguments: [MockAgentSource.Scenario.demo, .stress])
    func firstUpdateArrivesImmediatelyWithActiveAndFinishedTasks(scenario: MockAgentSource.Scenario) async throws {
        let source = MockAgentSource(scenario: scenario, seed: 1)
        let clock = ContinuousClock()
        let began = clock.now
        var iterator = await source.updates().makeAsyncIterator()
        let first = try #require(await iterator.next())
        let elapsed = clock.now - began
        await source.stop()

        // Typically 4–20 ms; the bound leaves room for a loaded machine running the suite in parallel.
        #expect(elapsed < .milliseconds(250))
        #expect(first.initialLoadComplete)
        #expect(first.health == .ok)
        #expect(first.removed.isEmpty)
        let active = first.changed.filter { $0.status.isActive }
        let finished = first.changed.filter { $0.status == .done || $0.status == .failed }
        #expect(active.count >= 4)
        #expect(finished.count >= 6)
        #expect(first.changed.allSatisfy { $0.source == "mock" })
        #expect(structuralProblems(first.changed) == [])
    }

    @Test func stressStartsWithTwentyActiveTasksOfFifteenRunsEach() async throws {
        let source = MockAgentSource(scenario: .stress, seed: 2)
        var iterator = await source.updates().makeAsyncIterator()
        let first = try #require(await iterator.next())
        await source.stop()

        let active = first.changed.filter { $0.status.isActive }
        #expect(active.count == 20)
        #expect(active.allSatisfy { $0.runs.count >= 15 })
        #expect(active.contains { $0.runs.contains { $0.depth == 2 } })
        #expect(first.changed.filter { !$0.status.isActive }.count >= 25)
        #expect(structuralProblems(first.changed) == [])
    }

    // MARK: Behavior over time

    @Test func acceleratedDemoProducesFailuresOverrunsFanOutAndNesting() async {
        let source = MockAgentSource(scenario: .demo, seed: 42, speed: 120, startDate: start)
        var latest: [String: TaskSnapshot] = [:]
        var failed = false, overran = false, fannedOut = false, nested = false
        await withWatchdog(source, seconds: 10) {
            for await update in await source.updates() {
                for task in update.changed {
                    latest[task.id] = task
                    let live = task.runs.filter { !$0.isMain && $0.startedAt >= start }
                    failed = failed || live.contains { $0.status == .failed }
                    overran = overran || live.contains { run in
                        run.status == .done && run.endedAt.map { run.overrun(at: $0) != nil } == true
                    }
                    fannedOut = fannedOut || largestBurst(of: live, within: 10) >= 5
                    nested = nested || live.contains { $0.depth == 2 }
                }
                if failed && overran && fannedOut && nested { break }
            }
        }
        await source.stop()

        #expect(failed, "a run started during the session should fail")
        #expect(overran, "a run should finish over its estimate")
        #expect(fannedOut, "a main agent should launch at least 5 subagents within seconds")
        #expect(nested, "a subagent should launch a child (depth 2)")
        #expect(structuralProblems(Array(latest.values)) == [])
    }

    @Test func demoLooksRealisticOverAnHour() {
        let world = MockWorld(scenario: .demo, seed: 21, startDate: start)
        var latest: [String: TaskSnapshot] = [:]
        var minActive = Int.max, maxActive = 0
        var sawWaiting = false, sawQueued = false, sawInheritedResolve = false
        var inheritedWhileRunning = Set<String>()
        for t in world.takeUpdate().changed { latest[t.id] = t }

        for step in 1...7200 {
            world.advance(to: Double(step) * 0.5)
            for task in world.takeUpdate().changed {
                latest[task.id] = task
                sawWaiting = sawWaiting || task.status == .waiting
                for run in task.runs {
                    sawQueued = sawQueued || run.status == .queued
                    if run.status == .running, run.model.id == nil, run.model.source == .inherited {
                        inheritedWhileRunning.insert(run.id)
                    } else if run.model.source == .transcript, inheritedWhileRunning.contains(run.id) {
                        sawInheritedResolve = true
                    }
                }
            }
            if step.isMultiple(of: 2) {
                let active = latest.values.count { $0.status.isActive }
                minActive = min(minActive, active)
                maxActive = max(maxActive, active)
            }
        }

        let newTasks = latest.values.filter { $0.startedAt >= start }
        let subagents = newTasks.flatMap { $0.runs.dropFirst() }
        let finished = subagents.filter(\.status.isFinished)
        let done = finished.filter { $0.status == .done && $0.estimate != nil }
        let failRate = Double(finished.count { $0.status == .failed }) / Double(finished.count)
        let overRate = Double(done.count { $0.overrun(at: $0.endedAt!) != nil }) / Double(done.count)
        let durations = newTasks.compactMap { t in t.runs[0].endedAt.map { $0.timeIntervalSince(t.startedAt) } }.sorted()
        let median = durations[durations.count / 2]

        #expect(newTasks.count >= 40, "new tasks keep starting")
        #expect((0.04...0.14).contains(failRate), "~8% of runs fail, got \(failRate)")
        #expect((0.15...0.40).contains(overRate), "~25% of runs go over, got \(overRate)")
        #expect((60...240).contains(median), "a demo task takes 1–4 minutes, median \(median)s")
        #expect(maxActive <= 6)
        #expect(minActive >= 1, "the demo never goes quiet")
        #expect(sawWaiting && sawQueued && sawInheritedResolve)
        #expect(subagents.contains { $0.model.source == .callParameter && $0.model.id == "sonnet" })
        #expect(subagents.contains(where: \.isBackground) && subagents.contains { !$0.isBackground })
        #expect(subagents.contains { $0.status == .cancelled })
        #expect(newTasks.contains { $0.status == .failed })
        #expect(newTasks.map { largestBurst(of: Array($0.runs.dropFirst()), within: 10) }.max()! >= 10)
        #expect(subagents.allSatisfy { (3...6).contains($0.description.split(separator: " ").count) })
        #expect(subagents.allSatisfy { $0.prompt.components(separatedBy: "\n\n").count >= 3 })
        #expect(finished.allSatisfy { $0.resultSummary?.isEmpty == false })
        let types = Set(subagents.map(\.agentType))
        #expect(types.isSuperset(of: ["Explore", "Plan", "general-purpose", "code-reviewer", "test-writer", "software-engineer"]))
        #expect(structuralProblems(Array(latest.values)) == [])
    }

    @Test func demoHasTasksForEveryWorkflowGroupFolderProjectsAndOthers() throws {
        let world = MockWorld(scenario: .demo, seed: 5, startDate: start)
        let first = world.takeUpdate().changed
        #expect(Set(first.map(\.projectName)).isSuperset(of: ["GmailMonitor", "PubgMontages", "TradingBot",
                                                               "AgentDeck", "web-dashboard", "Others"]))
        #expect(first.allSatisfy { $0.projectKind != nil })
        #expect(first.contains { $0.projectName == "TradingBot" && $0.projectPath.hasSuffix("/Multi-agent-trading-bot") })

        // The scratch task that runs the pubg-montage skill partway through moves from Others to PubgMontages.
        let moving = try #require(first.first { $0.title == "Cut last night's best moments" })
        #expect(moving.projectName == "Others")
        var moved = false
        for step in 1...1200 where !moved {
            world.advance(to: Double(step) * 0.5)
            moved = world.takeUpdate().changed.first { $0.id == moving.id }?.projectName == "PubgMontages"
        }
        #expect(moved)

        // New rules reclassify every task at once.
        var rules = WorkflowRules.defaults
        rules.groups[0].name = "Inbox"
        world.setRules(rules)
        #expect(world.takeUpdate().changed.contains { $0.projectName == "Inbox" })
        #expect(!world.snapshots.contains { $0.projectName == "GmailMonitor" })
    }

    @Test func stressKeepsTwentyTasksBusy() {
        let world = MockWorld(scenario: .stress, seed: 11, startDate: start)
        var minActive = Int.max
        var running: [Int] = []
        for second in 1...300 {
            world.advance(to: Double(second))
            let tasks = world.snapshots
            minActive = min(minActive, tasks.count { $0.status.isActive })
            running.append(tasks.reduce(0) { $0 + $1.runs.count { $0.status == .running } })
        }
        let average = running.reduce(0, +) / running.count
        #expect(minActive >= 18, "finished tasks are replaced")
        #expect(average >= 220, "about 300 runs stay live, average \(average)")
        #expect(running.min()! >= 150)
        #expect(structuralProblems(world.snapshots) == [])
    }

    @Test func sameSeedReplaysIdenticallyHoweverTimeIsChunked() {
        let a = MockWorld(scenario: .demo, seed: 99, startDate: start)
        let b = MockWorld(scenario: .demo, seed: 99, startDate: start)
        let c = MockWorld(scenario: .demo, seed: 100, startDate: start)
        a.advance(to: 240)
        c.advance(to: 240)
        for t in stride(from: 0.25, through: 240, by: 0.25) { b.advance(to: t) }
        #expect(a.snapshots == b.snapshots)
        #expect(a.snapshots != c.snapshots)
    }

    // MARK: Emission

    @Test func updatesCarryOnlyChangedTasksAndNothingWhileIdle() throws {
        let world = MockWorld(scenario: .stress, seed: 3, startDate: start)
        let initial = world.takeUpdate()
        let previous = Dictionary(uniqueKeysWithValues: initial.changed.map { ($0.id, $0) })
        #expect(!world.hasChanges)
        #expect(world.takeUpdate().isEmpty)

        let next = try #require(world.nextEventTime)
        world.advance(to: next - 0.001)
        #expect(!world.hasChanges, "nothing changes between events")
        world.advance(to: next)
        let update = world.takeUpdate()
        #expect(!update.changed.isEmpty)
        #expect(update.changed.count < initial.changed.count)
        #expect(update.changed.allSatisfy { previous[$0.id] != $0 })
    }

    @Test func emissionsAreCoalescedToAtMostOnePerFrame() async {
        let source = MockAgentSource(scenario: .stress, seed: 5)
        let clock = ContinuousClock()
        var times: [ContinuousClock.Instant] = []
        var changedCounts: [Int] = []
        var lastSeen: [String: TaskSnapshot] = [:]
        var unchangedResent = 0
        await withWatchdog(source, seconds: 5) {
            let end = clock.now + .milliseconds(600)
            for await update in await source.updates() {
                times.append(clock.now)
                changedCounts.append(update.changed.count)
                for task in update.changed {
                    if lastSeen[task.id] == task { unchangedResent += 1 }
                    lastSeen[task.id] = task
                }
                if clock.now >= end { break }
            }
        }
        await source.stop()

        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        // The source enforces 16 ms between batches; 2 ms of slack absorbs consumer scheduling jitter.
        #expect(gaps.allSatisfy { $0 >= .milliseconds(14) }, "min gap \(gaps.min() ?? .zero)")
        #expect(times.count >= 10, "stress changes every frame")
        let later = changedCounts.dropFirst()
        #expect(later.reduce(0, +) / max(1, later.count) < 15, "batches carry only the tasks that changed")
        #expect(unchangedResent == 0)
    }

    // MARK: Lifecycle

    @Test func stopFinishesTheStream() async {
        let source = MockAgentSource(scenario: .demo, seed: 7)
        let stream = await source.updates()
        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(150))
        await source.stop()
        #expect(await finishes(consumer, within: .seconds(2)))
        #expect(await consumer.value >= 1)

        // Idempotent, and later calls get the same, finished stream.
        await source.stop()
        var iterator = await source.updates().makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func cancellingTheConsumerEndsIteration() async {
        let source = MockAgentSource(scenario: .demo, seed: 8)
        let stream = await source.updates()
        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        #expect(await finishes(consumer, within: .seconds(2)))
        await source.stop()
    }

    @Test func stoppingBeforeConsumingYieldsAFinishedStream() async {
        let source = MockAgentSource(scenario: .demo, seed: 9)
        await source.stop()
        var iterator = await source.updates().makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

// MARK: - Helpers

/// Everything that breaks the snapshot contract, as readable strings (empty when consistent).
private func structuralProblems(_ tasks: [TaskSnapshot]) -> [String] {
    var problems: [String] = []
    for task in tasks {
        guard let main = task.runs.first else {
            problems.append("\(task.id): no runs")
            continue
        }
        if main.id != "main:\(task.id)" || main.agentType != "main" || main.parentRunID != nil
            || main.depth != 0 || main.estimate != nil {
            problems.append("\(task.id): runs[0] is not the main run")
        }
        if (task.status == .done || task.status == .failed) != (task.endedAt != nil) {
            problems.append("\(task.id): endedAt doesn't match status \(task.status)")
        }
        if task.status.isActive, main.status != .running {
            problems.append("\(task.id): active task with main run \(main.status)")
        }
        if !task.status.isActive, task.runs.contains(where: { !$0.status.isFinished }) {
            problems.append("\(task.id): \(task.status) task has unfinished runs")
        }
        var seen: [String: AgentRunSnapshot] = [:]
        for run in task.runs {
            if run.taskID != task.id { problems.append("\(run.id): taskID \(run.taskID) in task \(task.id)") }
            if seen[run.id] != nil { problems.append("\(run.id): duplicate run id") }
            if run.id != main.id {
                if let parentID = run.parentRunID, let parent = seen[parentID] {
                    if run.depth != parent.depth + 1 { problems.append("\(run.id): depth \(run.depth) under \(parent.depth)") }
                } else {
                    problems.append("\(run.id): parent missing from the task or listed after the child")
                }
                if run.depth > 2 { problems.append("\(run.id): depth \(run.depth)") }
                if run.estimate == nil { problems.append("\(run.id): subagent without estimate") }
            }
            if run.status.isFinished != (run.endedAt != nil) { problems.append("\(run.id): endedAt vs \(run.status)") }
            if run.recentTools.count > 30 { problems.append("\(run.id): \(run.recentTools.count) recent tools") }
            if run.currentActivity != run.recentTools.last?.activityText {
                problems.append("\(run.id): currentActivity isn't the latest tool")
            }
            if run.toolCallCount < run.recentTools.count { problems.append("\(run.id): toolCallCount too low") }
            seen[run.id] = run
        }
    }
    return problems
}

/// The most runs started within any `window`-second span.
private func largestBurst(of runs: [AgentRunSnapshot], within window: TimeInterval) -> Int {
    let starts = runs.filter { $0.depth == 1 }.map(\.startedAt).sorted()
    var best = 0, low = 0
    for high in starts.indices {
        while starts[high].timeIntervalSince(starts[low]) > window { low += 1 }
        best = max(best, high - low + 1)
    }
    return best
}

/// Runs `body` with a watchdog that stops the source after `seconds`, so a stuck stream can't hang the suite.
private func withWatchdog(_ source: MockAgentSource, seconds: Double, _ body: () async -> Void) async {
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await source.stop()
    }
    await body()
    watchdog.cancel()
}

/// Whether `task` completes within `limit`; cancels it otherwise.
private func finishes<T: Sendable>(_ task: Task<T, Never>, within limit: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { _ = await task.value; return true }
        group.addTask { try? await Task.sleep(for: limit); return false }
        let first = await group.next() ?? false
        task.cancel()
        group.cancelAll()
        return first
    }
}
