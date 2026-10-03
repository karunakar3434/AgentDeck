import Foundation

/// Per-scenario knobs.
struct MockTuning {
    /// Compresses agent durations (estimates and actuals) so a demo task finishes in minutes.
    var timeScale: Double
    /// Seconds between a running agent's tool calls.
    var toolInterval: ClosedRange<Double>
    /// > 1 favors the short end of `toolInterval`.
    var toolSkew: Double
    var maxActive: Int
    var historyCount: Int
    /// Finished tasks kept before the oldest are removed.
    var historyCap: Int
    var maxRunsPerTask: Int
    /// Chance that a general-purpose / software-engineer subagent launches children.
    var nestChance: Double
    var failChance: Double
    var cancelChance: Double
    var overrunChance: Double
    var queuedChance: Double
    var taskFailChance: Double
    /// Idle time before a finished turn's session closes.
    var closeDelay: ClosedRange<Double>
    /// Before the start date, each simulated tool call stands for this many, which keeps
    /// seeding history cheap. Counters and tokens still add up.
    var backfillStride: Int

    static let demo = MockTuning(
        timeScale: 0.2, toolInterval: 1...6, toolSkew: 1.6, maxActive: 6, historyCount: 6, historyCap: 24,
        maxRunsPerTask: 60, nestChance: 0.35, failChance: 0.08, cancelChance: 0.03, overrunChance: 0.25,
        queuedChance: 0.04, taskFailChance: 0.1, closeDelay: 20...90, backfillStride: 1)

    static let stress = MockTuning(
        timeScale: 0.5, toolInterval: 0.4...2.5, toolSkew: 1, maxActive: 20, historyCount: 30, historyCap: 60,
        maxRunsPerTask: 80, nestChance: 0.4, failChance: 0.08, cancelChance: 0.03, overrunChance: 0.25,
        queuedChance: 0.03, taskFailChance: 0.08, closeDelay: 5...30, backfillStride: 12)
}

/// The deterministic core of the mock: tasks, agents and a timed event queue.
///
/// Time is simulated seconds relative to `startDate` (negative = the past). Nothing
/// here reads the real clock; `MockSimulator` maps real time onto `advance(to:)`, and
/// tests can call it directly. Given the same seed, the same events happen in the
/// same order regardless of how `advance` is chunked.
final class MockWorld {
    typealias Scenario = MockAgentSource.Scenario

    let scenario: Scenario
    let startDate: Date
    let tuning: MockTuning
    /// Simulated seconds since `startDate` processed so far.
    private(set) var now: Double = 0

    private var rng: SeededRandom
    private var queue = MockEventQueue()
    /// Decides each task's sidebar entry, like the live source does.
    private var classifier: WorkflowClassifier
    /// Tasks by handle (creation order); nil once pruned. Events refer to tasks by
    /// handle so they stay plain data.
    private var slots: [MockTask?] = []
    private let catalog: [(MockProject, MockTaskTemplate)]
    private var recentTitles: [String] = []
    private(set) var activeCount = 0

    // Pending changes for the next update.
    private var dirtyOrder: [Int] = []
    private var removedOrder: [String] = []
    /// Done/failed task handles, oldest first, for pruning history.
    private var finishedOrder: [Int] = []

    init(scenario: Scenario, seed: UInt64, startDate: Date, tuning: MockTuning? = nil, rules: WorkflowRules = .defaults) {
        self.scenario = scenario
        self.startDate = startDate
        self.tuning = tuning ?? (scenario == .demo ? .demo : .stress)
        rng = SeededRandom(seed: seed)
        classifier = WorkflowClassifier(rules: rules, home: MockScript.home)
        let projects = scenario == .demo ? MockScript.demoProjects : MockScript.stressProjects
        catalog = projects.flatMap { p in p.tasks.map { (p, $0) } }
        seedInitialTasks()
        advance(to: 0)
    }

    // MARK: Public surface

    var hasChanges: Bool { !dirtyOrder.isEmpty || !removedOrder.isEmpty }
    var nextEventTime: Double? { queue.nextTime }

    /// Processes every event due at or before `time` (simulated seconds since `startDate`).
    func advance(to time: Double) {
        while let (t, event) = queue.pop(dueBy: time) {
            now = t
            handle(event, at: t)
        }
        now = max(now, time)
    }

    /// The changes since the last call, as one batch.
    func takeUpdate() -> DeckUpdate {
        var changed: [TaskSnapshot] = []
        changed.reserveCapacity(dirtyOrder.count)
        for handle in dirtyOrder {
            // Pruned tasks are skipped; they're in `removedOrder`.
            guard let task = slots[handle] else { continue }
            task.isDirty = false
            changed.append(task.snap)
        }
        let update = DeckUpdate(changed: changed, removed: removedOrder, initialLoadComplete: true)
        dirtyOrder.removeAll(keepingCapacity: true)
        removedOrder.removeAll(keepingCapacity: true)
        return update
    }

    /// Every task, oldest first (tests and debugging).
    var snapshots: [TaskSnapshot] {
        slots.compactMap { $0?.snap }.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    func date(_ t: Double) -> Date { startDate.addingTimeInterval(t) }

    /// Reclassifies every task under new rules; changed ones go out in the next update.
    func setRules(_ rules: WorkflowRules) {
        guard rules != classifier.rules else { return }
        classifier = WorkflowClassifier(rules: rules, home: MockScript.home)
        for case let task? in slots { reclassify(task) }
    }

    // MARK: Events

    private func handle(_ event: MockEvent, at t: Double) {
        switch event {
        case .spawn:
            if activeCount < tuning.maxActive { startTask(at: t) }
            queue.push(.spawn, at: t + rng.uniform(20...50))
        case .spawnOnce:
            if activeCount < tuning.maxActive { startTask(at: t) }
        case .mainStep(let h):
            if let task = slots[h] { mainStep(task, at: t) }
        case .tool(let h, let i):
            if let task = slots[h] { toolTick(task, i, at: t) }
        case let .launch(h, parent, stage, queued, background):
            if let task = slots[h] { launch(task, parent: parent, stage: stage, queued: queued, background: background, at: t) }
        case .begin(let h, let i):
            if let task = slots[h], task.snap.runs[i].status == .queued, task.mode != .ended { begin(task, i, at: t) }
        case .finish(let h, let i):
            if let task = slots[h] { finishRun(task, i, at: t) }
        case .close(let h):
            guard let task = slots[h], task.snap.status == .idle else { return }
            task.snap.status = .done
            task.snap.endedAt = date(t)
            markDirty(task)
            taskFinished(task)
        }
    }

    // MARK: Seeding

    private func seedInitialTasks() {
        switch scenario {
        case .demo:
            // Finished tasks from the past few hours, one of them failed. Some are fixed so every workflow
            // group, both folder projects and Others have a task from the start.
            let hoursAgo = [4.6, 3.5, 2.6, 1.7, 1.0, 0.4]
            let finishedTitles = ["Daily Gmail report", "Fix flaky checkout tests", "Video quality enhancement", nil,
                                  "Summarize the lease agreement PDF", nil]
            // The newest active one starts in Others and moves to PubgMontages when it runs the pubg-montage skill.
            let activeTitles = ["Fix the timeline chart jumping when a subagent finishes", nil,
                                "Backtest the momentum strategy on 2025 data", "Cut last night's best moments"]
            recentTitles = (finishedTitles + activeTitles).compactMap { $0 }    // random picks don't repeat them
            for (k, h) in hoursAgo.prefix(tuning.historyCount).enumerated() {
                startTask(at: -(h + rng.uniform(-0.15...0.15)) * 3600, history: true, failed: k == 2 ? true : nil,
                          title: finishedTitles[k])
            }
            // Active tasks at different stages; they keep going for a while after launch.
            for (k, secondsAgo) in [100.0, 62, 30, 8].enumerated() {
                let title = activeTitles[k]
                startTask(at: -(secondsAgo + rng.uniform(-4...4)), failed: title == nil ? nil : false,
                          notBefore: rng.uniform(15...50), title: title)
            }
            queue.push(.spawn, at: rng.uniform(15...35))
        case .stress:
            for _ in 0..<tuning.historyCount {
                startTask(at: -rng.uniform(0.25...6) * 3600, history: true)
            }
            for _ in 0..<tuning.maxActive {
                startTask(at: -rng.uniform(15...120), notBefore: rng.uniform(20...60), sustainUntil: rng.uniform(20...360))
            }
        }
    }

    // MARK: Tasks

    @discardableResult
    private func startTask(at t: Double, history: Bool = false, failed: Bool? = nil,
                           notBefore: Double? = nil, sustainUntil: Double? = nil, title: String? = nil) -> MockTask {
        let (project, template) = title.flatMap(template(titled:)) ?? pickTemplate()
        let id = rng.uuid()
        let mainModel = rng.pick(MockModels.main)
        let model = ModelInfo(id: mainModel, source: .transcript)
        let d = date(t)
        let prompt = "\(template.title)\n\n\(template.details)\n\n\(rng.pick(MockScript.promptClosings))"
        let main = AgentRunSnapshot(
            id: "main:\(id)", taskID: id, parentRunID: nil, agentID: nil, agentType: "main",
            description: template.title, prompt: prompt, model: model, status: .running, isBackground: false,
            startedAt: d, endedAt: nil, lastActivityAt: d, estimate: nil, toolCallCount: 0, currentActivity: nil,
            tokens: nil, resultSummary: nil, recentTools: [], depth: 0)
        let snap = TaskSnapshot(
            id: id, source: "mock", projectName: project.name, projectPath: project.path, title: template.title,
            status: .running, startedAt: d, lastActivityAt: d, endedAt: nil, mainModel: model,
            gitBranch: template.branch.isEmpty ? nil : template.branch, runs: [main])
        let task = MockTask(handle: slots.count, project: project, template: template, isHistory: history, snap: snap,
                           mainMeta: MockRunMeta(profile: nil, parent: nil, area: "", files: ("", ""), resolvedModel: mainModel),
                           areas: template.areas.shuffled(using: &rng))
        let fails = failed ?? rng.chance(tuning.taskFailChance)
        switch scenario {
        case .demo:
            task.phases = template.workflow.map { workflowScript($0, failed: fails) } ?? demoScript(failed: fails)
        case .stress:
            task.phases = stressScript(failed: fails)
            task.sustainUntil = sustainUntil ?? t + (history ? rng.uniform(0...30) : rng.uniform(120...360))
        }
        task.notBefore = notBefore
        reclassify(task)
        slots.append(task)
        activeCount += 1
        markDirty(task)
        queue.push(.mainStep(task.handle), at: t)
        return task
    }

    private func pickTemplate() -> (MockProject, MockTaskTemplate) {
        var candidates = catalog.filter { !recentTitles.contains($0.1.title) }
        if candidates.isEmpty { candidates = catalog }
        return use(rng.pick(candidates))
    }

    private func template(titled title: String) -> (MockProject, MockTaskTemplate)? {
        catalog.first { $0.1.title == title }.map(use)
    }

    private func use(_ pick: (MockProject, MockTaskTemplate)) -> (MockProject, MockTaskTemplate) {
        recentTitles.append(pick.1.title)
        if recentTitles.count > min(12, catalog.count - 4) { recentTitles.removeFirst() }
        return pick
    }

    /// A typical session: explore, maybe plan, fan out the build, review, finish.
    private func demoScript(failed: Bool) -> [MockPhase] {
        var p: [MockPhase] = [.work(rng.uniform(4...9))]
        p += [.wave(.explore, count: rng.weighted([(1, 0.4), (2, 0.35), (3, 0.25)])), .join]
        let planned = rng.chance(0.5)
        if planned { p += [.work(rng.uniform(2...5)), .wave(.plan, count: 1), .join] }
        if rng.chance(planned ? 0.5 : 0.2) {
            p.append(.waitUser(rng.uniform(10...40), planned ? .planApproval : .question))
        }
        let fanOut = rng.chance(0.75) ? 5 + Int((10 * pow(rng.unit(), 1.8)).rounded()) : rng.int(2...4)
        p += [.work(rng.uniform(3...7)), .wave(.build, count: fanOut)]
        if rng.chance(0.25) { p.append(.waitUser(rng.uniform(10...40), .permission)) }
        p += [.join, .work(rng.uniform(2...6))]
        if rng.chance(0.7) {
            p += [.wave(.review, count: rng.weighted([(1, 0.7), (2, 0.3)])), .join, .work(rng.uniform(2...5))]
        }
        if failed { p = Array(p.prefix(rng.int(3...p.count))) }
        p.append(.end(failed: failed))
        return p
    }

    /// Work outside a code project: skills, one to three of its own agents, maybe a skill that changes
    /// what the task is about and more agents, then the closing tool calls.
    private func workflowScript(_ w: MockWorkflow, failed: Bool) -> [MockPhase] {
        var p: [MockPhase] = w.skills.map { .skill($0) }
        p += [.work(rng.uniform(4...9)), .wave(.workflow, count: rng.int(1...3)), .join]
        if let later = w.laterSkill {
            p += [.work(rng.uniform(3...6)), .skill(later), .wave(.workflow, count: rng.int(1...2)), .join]
        }
        p.append(.work(rng.uniform(2...5)))
        p += w.tools.map { .tool($0.name, $0.summary) }
        if failed { p = Array(p.prefix(rng.int(min(2, p.count)...p.count))) }
        p.append(.end(failed: failed))
        return p
    }

    /// Stress: one big wave kept topped up until `sustainUntil`, then drain and finish.
    private func stressScript(failed: Bool) -> [MockPhase] {
        var p: [MockPhase] = [.work(rng.uniform(1.5...4)), .wave(.stress, count: 14)]
        if rng.chance(0.12) { p.append(.waitUser(rng.uniform(10...30), .permission)) }
        p += [.join, .work(rng.uniform(1...3)), .end(failed: failed)]
        return p
    }

    private func mainStep(_ task: MockTask, at t: Double) {
        guard task.mode != .ended else { return }
        if task.snap.status == .waiting {
            task.snap.status = .running
            endOpenTool(task, 0, at: t)
            markDirty(task)
        }
        guard task.phaseIndex < task.phases.count else { return }
        let phase = task.phases[task.phaseIndex]
        task.phaseIndex += 1
        switch phase {
        case .work(let seconds):
            task.mode = .working
            armTool(task, 0, at: t + rng.uniform(0.3...1.2))
            queue.push(.mainStep(task.handle), at: t + seconds)
        case let .wave(stage, count):
            task.mode = .blocked
            let spacing: ClosedRange<Double> = switch stage {
            case .build: 0.15...0.8
            case .stress: 0.1...0.45
            default: 0.3...1.5
            }
            let background = rng.chance(backgroundChance(stage))
            var at = t + rng.uniform(0.2...0.8)
            for i in 0..<count {
                let queued = (i >= 8 && rng.chance(0.7)) || rng.chance(tuning.queuedChance)
                let bg = rng.chance(0.1) ? !background : background
                queue.push(.launch(task.handle, parent: 0, stage: stage, queued: queued, background: bg), at: at)
                at += rng.uniform(spacing)
            }
            task.meta[0].openChildren += count
            queue.push(.mainStep(task.handle), at: at)
        case .join:
            if task.meta[0].openChildren == 0 {
                task.mode = .blocked
                queue.push(.mainStep(task.handle), at: t + rng.uniform(0.8...2.5))
            } else {
                task.mode = .awaiting
            }
        case let .waitUser(seconds, reason):
            task.mode = .blocked
            task.snap.status = .waiting
            let (name, summary) = waitingTool(task, reason)
            appendTool(task, 0, name: name, summary: summary, at: t)
            queue.push(.mainStep(task.handle), at: t + seconds)
        case .skill(let name):
            task.mode = .blocked
            appendTool(task, 0, name: "Skill", summary: name, at: t)
            if task.skills.insert(name).inserted { reclassify(task) }
            queue.push(.mainStep(task.handle), at: t + rng.uniform(1...3))
        case let .tool(name, summary):
            task.mode = .blocked
            appendTool(task, 0, name: name, summary: summary, at: t)
            queue.push(.mainStep(task.handle), at: t + rng.uniform(1...3))
        case .end(let failed):
            if let notBefore = task.notBefore, t < notBefore {
                // Seeded tasks keep working past launch so the deck starts busy.
                task.phaseIndex -= 1
                task.mode = .working
                armTool(task, 0, at: t + rng.uniform(0.3...1.2))
                queue.push(.mainStep(task.handle), at: notBefore + rng.uniform(0...3))
                return
            }
            endTask(task, failed: failed, at: t)
        }
    }

    private func endTask(_ task: MockTask, failed: Bool, at t: Double) {
        task.mode = .ended
        for i in 1..<task.snap.runs.count where !task.snap.runs[i].status.isFinished {
            finishRun(task, i, at: t, as: .cancelled, summary: MockScript.cascadeCancellation)
        }
        let d = date(t)
        let summary = failed
            ? rng.pick(MockScript.mainFailures)
            : rng.pick(MockScript.mainResults)(rng.int(3...14))
        endOpenTool(task, 0, at: t)
        task.snap.runs[0].status = failed ? .failed : .done
        task.snap.runs[0].endedAt = d
        task.snap.runs[0].lastActivityAt = d
        task.snap.runs[0].resultSummary = summary
        task.snap.status = failed ? .failed : .idle
        task.snap.lastActivityAt = d
        activeCount -= 1
        markDirty(task)
        if failed {
            task.snap.endedAt = d
            taskFinished(task)
        } else {
            queue.push(.close(task.handle), at: t + rng.uniform(tuning.closeDelay))
        }
        guard !task.isHistory else { return }
        switch scenario {
        case .demo:
            if activeCount < 3 { queue.push(.spawnOnce, at: t + rng.uniform(3...8)) }
        case .stress:
            queue.push(.spawnOnce, at: t + rng.uniform(0.5...2))
        }
    }

    private func taskFinished(_ task: MockTask) {
        finishedOrder.append(task.handle)
        while finishedOrder.count > tuning.historyCap {
            let old = finishedOrder.removeFirst()
            if let pruned = slots[old] { removedOrder.append(pruned.id) }
            slots[old] = nil
        }
    }

    // MARK: Runs

    private func launch(_ task: MockTask, parent p: Int, stage: MockStage, queued: Bool, background: Bool, at t: Double) {
        let parentID = task.snap.runs[p].id
        let depth = task.snap.runs[p].depth + 1
        guard task.mode != .ended, task.snap.runs[p].status == .running else {
            // The parent stopped before it got to this call.
            task.meta[p].openChildren -= 1
            return
        }
        let profile = stage == .workflow ? workflowProfile(task) : rng.pick(MockScript.mix(for: stage))
        let estimate = DurationEstimate(seconds: (profile.baseSeconds * tuning.timeScale).rounded(),
                                        confidence: EstimateConfidence(sampleCount: profile.samples),
                                        sampleCount: profile.samples)
        let project = task.project
        let area = task.nextArea()
        let focus = task.template.files
        let file = rng.chance(0.8) ? rng.pick(focus) : rng.pick(project.files)
        var file2 = rng.chance(0.6) ? rng.pick(focus) : rng.pick(project.files)
        if file2 == file { file2 = focus.count > 1 ? focus[(focus.firstIndex(of: file).map { $0 + 1 } ?? 0) % focus.count] : rng.pick(project.files) }

        // Model: usually resolved from the transcript; sometimes only the call
        // parameter or definition is known; sometimes "inherits" until the first message.
        let parentModel = task.meta[p].resolvedModel
        var resolved = rng.pick(profile.models) ?? parentModel
        let model: ModelInfo
        let modelRoll = rng.unit()
        if modelRoll < 0.10 {
            let alias = rng.chance(0.8) ? "sonnet" : "haiku"
            resolved = alias == "sonnet" ? MockModels.sonnet : MockModels.haiku
            model = ModelInfo(id: alias, source: .callParameter)
        } else if modelRoll < 0.25 {
            resolved = parentModel
            model = ModelInfo(id: nil, source: .inherited)
        } else if modelRoll < 0.28 {
            model = ModelInfo(id: MockModels.alias(for: resolved), source: .definition)
        } else {
            model = ModelInfo(id: resolved, source: .transcript)
        }

        var meta = MockRunMeta(profile: profile, parent: p, area: area, files: (file, file2), resolvedModel: resolved)
        let factor = rng.chance(tuning.overrunChance) ? rng.uniform(1.03...1.6) : rng.uniform(0.4...0.97)
        meta.plannedSeconds = estimate.seconds * factor
        let outcomeRoll = rng.unit()
        if outcomeRoll < tuning.failChance {
            meta.outcome = .failed
            meta.cutFraction = rng.uniform(0.2...0.9)
        } else if outcomeRoll < tuning.failChance + tuning.cancelChance {
            meta.outcome = .cancelled
            meta.cutFraction = rng.uniform(0.3...0.9)
        }
        if profile.canNest, depth == 1, rng.chance(tuning.nestChance) {
            meta.childCount = rng.weighted([(1, 0.45), (2, 0.35), (3, 0.2)])
        }

        let description = rng.pick(profile.descriptions)(area)
        let context = project.about ?? "Context: this is the \(project.name) repo (\(project.path)) on branch \(task.template.branch)."
        let prompt = """
            \(profile.job(area))

            \(context) The user asked: "\(task.template.title)". \(task.template.details)

            Start with \(file) and \(file2). \(profile.guidance)

            Report back with \(profile.report). Keep it under 300 words and include file paths.
            """
        let runID = rng.toolUseID()
        let agentID = "a" + rng.hex16()

        appendTool(task, p, name: "Agent", summary: description, at: t)
        let d = date(t)
        task.snap.runs.append(AgentRunSnapshot(
            id: runID, taskID: task.id, parentRunID: parentID, agentID: agentID, agentType: profile.type,
            description: description, prompt: prompt, model: model, status: queued ? .queued : .running,
            isBackground: background, startedAt: d, endedAt: nil, lastActivityAt: d, estimate: estimate,
            toolCallCount: 0, currentActivity: nil, tokens: nil, resultSummary: nil, recentTools: [], depth: depth))
        task.meta.append(meta)
        if task.agentTypes.insert(profile.type).inserted { reclassify(task) }
        let i = task.snap.runs.count - 1
        if queued {
            queue.push(.begin(task.handle, i), at: t + rng.uniform(2...8))
        } else {
            begin(task, i, at: t)
        }
        markDirty(task)
    }

    private func begin(_ task: MockTask, _ i: Int, at t: Double) {
        let d = date(t)
        task.snap.runs[i].status = .running
        task.snap.runs[i].startedAt = d
        task.snap.runs[i].lastActivityAt = d
        let meta = task.meta[i]
        var end = t + meta.plannedSeconds * (meta.outcome == .done ? 1 : meta.cutFraction)
        if let until = task.sustainUntil, end > until + 30 {
            // Stress: wrap up soon after the task stops topping up, so load doesn't sag while it drains.
            end = max(until + rng.uniform(5...30), t + rng.uniform(5...15))
        }
        queue.push(.finish(task.handle, i), at: end)
        // Runs that only "inherit" show no model until their first message arrives.
        let firstTool = task.snap.runs[i].model.id == nil ? rng.uniform(3...7) : rng.uniform(0.6...2.5)
        armTool(task, i, at: t + firstTool)
        if meta.childCount > 0 {
            var at = t + meta.plannedSeconds * rng.uniform(0.12...0.35)
            for _ in 0..<meta.childCount where at < end - 1 {
                queue.push(.launch(task.handle, parent: i, stage: .nested, queued: false, background: rng.chance(0.5)), at: at)
                task.meta[i].openChildren += 1
                at += rng.uniform(0.3...1.2)
            }
        }
        markDirty(task)
    }

    private func finishRun(_ task: MockTask, _ i: Int, at t: Double, as override: RunStatus? = nil, summary: String? = nil) {
        guard !task.snap.runs[i].status.isFinished else { return }
        let meta = task.meta[i]
        let status = override ?? meta.outcome
        if status == .done, meta.openChildren > 0 {
            // Wait for the children; the last one to finish reschedules this.
            task.meta[i].awaitingChildren = true
            return
        }
        let d = date(t)
        let wasQueued = task.snap.runs[i].status == .queued
        let text = summary ?? resultSummary(task, meta, status)
        let fallbackTokens = TokenUsage(input: rng.int(3...12), output: rng.int(200...900),
                                        cacheRead: rng.int(0...4000), cacheCreation: rng.int(9_000...22_000))
        endOpenTool(task, i, at: t)
        mutateRun(task, i) { r in
            r.status = status
            r.endedAt = d
            r.lastActivityAt = d
            r.resultSummary = text
            if status == .done {
                if r.model.id == nil { r.model = ModelInfo(id: meta.resolvedModel, source: .transcript) }
                if r.tokens == nil { r.tokens = fallbackTokens }
            }
        }
        if !wasQueued, d > task.snap.lastActivityAt { task.snap.lastActivityAt = d }
        markDirty(task)

        if status != .done {
            for j in (i + 1)..<task.snap.runs.count where task.meta[j].parent == i {
                finishRun(task, j, at: t, as: .cancelled, summary: MockScript.cascadeCancellation)
            }
        }
        // Stress keeps each task's load up by replacing finished subagents.
        if scenario == .stress, meta.parent == 0, task.mode != .ended, let until = task.sustainUntil, t < until,
           task.snap.runs.count < tuning.maxRunsPerTask {
            task.meta[0].openChildren += 1
            queue.push(.launch(task.handle, parent: 0, stage: .stress, queued: false, background: rng.chance(0.75)),
                       at: t + rng.uniform(0.3...3))
        }
        if let p = meta.parent { childFinished(task, parent: p, at: t) }
    }

    private func childFinished(_ task: MockTask, parent p: Int, at t: Double) {
        task.meta[p].openChildren -= 1
        guard task.meta[p].openChildren == 0 else { return }
        if p == 0 {
            if task.mode == .awaiting {
                task.mode = .blocked
                queue.push(.mainStep(task.handle), at: t + rng.uniform(0.8...2.5))
            }
        } else if task.meta[p].awaitingChildren {
            task.meta[p].awaitingChildren = false
            queue.push(.finish(task.handle, p), at: t + rng.uniform(1.5...5))
        }
    }

    private func resultSummary(_ task: MockTask, _ meta: MockRunMeta, _ status: RunStatus) -> String? {
        switch status {
        case .done:
            guard let profile = meta.profile else { return nil }
            let context = MockResultContext(area: meta.area, file: meta.files.0, file2: meta.files.1,
                                            test: rng.pick(task.project.tests), n: rng.int(2...9))
            let text = rng.pick(profile.results)(context)
            // Sentences may start with the (lowercase) area.
            guard let first = text.utf8.first, first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") else { return text }
            return text.prefix(1).uppercased() + text.dropFirst()
        case .failed: return rng.pick(MockScript.runFailures)
        case .cancelled: return rng.pick(MockScript.runCancellations)
        case .queued, .running: return nil
        }
    }

    // MARK: Tool calls

    private func armTool(_ task: MockTask, _ i: Int, at t: Double) {
        guard !task.meta[i].toolArmed else { return }
        task.meta[i].toolArmed = true
        queue.push(.tool(task.handle, i), at: t)
    }

    private func toolTick(_ task: MockTask, _ i: Int, at t: Double) {
        task.meta[i].toolArmed = false
        guard task.mode != .ended, task.snap.runs[i].status == .running else { return }
        if i == 0, task.mode != .working { return }
        let meta = task.meta[i]
        let (name, summary) = toolCall(rng.pick(meta.profile?.tools ?? MockScript.mainTools), task, meta)
        let stride = t < 0 ? tuning.backfillStride : 1
        appendTool(task, i, name: name, summary: summary, at: t, calls: stride)
        let r = tuning.toolInterval
        let interval = r.lowerBound + (r.upperBound - r.lowerBound) * pow(rng.unit(), tuning.toolSkew)
        armTool(task, i, at: t + interval * Double(stride))
    }

    private func toolCall(_ kind: MockToolKind, _ task: MockTask, _ meta: MockRunMeta) -> (String, String) {
        let project = task.project
        // Mostly the files this run (or task) is about, sometimes anything in the project.
        let roll = rng.unit()
        let ownFile = meta.files.0.isEmpty ? nil : (rng.chance(0.5) ? meta.files.0 : meta.files.1)
        let focusFile = roll < 0.4 ? ownFile ?? rng.pick(task.template.files)
            : roll < 0.65 ? rng.pick(task.template.files) : nil
        switch kind {
        case .read: return ("Read", focusFile ?? rng.pick(project.readable))
        case .grep: return ("Grep", rng.pick(project.searches))
        case .glob: return ("Glob", rng.pick(project.globs))
        case .bash: return ("Bash", rng.pick(project.commands))
        case .inspect: return ("Bash", rng.pick(project.inspect))
        case .edit: return ("Edit", focusFile ?? rng.pick(project.files))
        case .write:
            let isTests = meta.profile?.type == "test-writer"
            return ("Write", rng.pick(isTests ? project.tests : project.files))
        case .webFetch: return ("WebFetch", rng.pick(project.urls))
        case .webSearch: return ("WebSearch", rng.pick(project.queries))
        case .todo: return ("TodoWrite", "\(rng.int(3...7)) todos")
        case .docs: return ("WebFetch", rng.pick(MockScript.claudeDocs))
        case .gmail: return rng.pick(MockScript.gmailCalls)
        }
    }

    /// The agent type for a workflow wave: the template's, or its later ones once the later skill ran.
    private func workflowProfile(_ task: MockTask) -> MockAgentProfile {
        let w = task.template.workflow
        let later = w?.laterSkill.map(task.skills.contains) == true && w?.laterAgents.isEmpty == false
        let types = (later ? w?.laterAgents : w?.agents) ?? ["general-purpose"]
        return MockScript.profile(rng.pick(types))
    }

    /// Puts the task in its sidebar entry from what it has done so far, as the live source would.
    private func reclassify(_ task: MockTask) {
        let signals = TaskSignals(workingFolder: task.project.path, title: task.snap.title,
                                  agentTypes: Array(task.agentTypes), skills: Array(task.skills), tools: Array(task.tools))
        let entry = classifier.classify(signals)
        guard entry.name != task.snap.projectName || entry.kind != task.snap.projectKind else { return }
        task.snap.projectName = entry.name
        task.snap.projectKind = entry.kind
        markDirty(task)
    }

    private func waitingTool(_ task: MockTask, _ reason: MockWaitReason) -> (String, String) {
        switch reason {
        case .question: return ("AskUserQuestion", task.template.question)
        case .planApproval: return ("ExitPlanMode", "Plan ready for review")
        case .permission:
            return rng.weighted([
                (("Bash", "git push -u origin \(task.template.branch)"), 0.4),
                (("Bash", rng.pick(task.project.commands)), 0.3),
                (("Edit", rng.pick(task.template.files)), 0.15),
                (("WebFetch", rng.pick(task.project.urls)), 0.15),
            ])
        }
    }

    /// Starts a tool call: ends the previous one, updates counters, activity and tokens.
    private func appendTool(_ task: MockTask, _ i: Int, name: String, summary: String, at t: Double, calls: Int = 1) {
        let d = date(t)
        let event = ToolEvent(id: rng.toolUseID(), name: name, summary: summary, startedAt: d)
        let errorRoll = rng.unit()
        let first = task.snap.runs[i].tokens == nil
        let delta = first
            ? TokenUsage(input: rng.int(3...12), output: rng.int(80...600), cacheRead: rng.int(0...4000),
                         cacheCreation: rng.int(9_000...22_000))
            : TokenUsage(input: rng.int(1...8) * calls, output: rng.int(60...700) * calls,
                         cacheRead: rng.int(2_000...9_000) * calls, cacheCreation: rng.int(300...4_000) * calls)
        let resolved = task.meta[i].resolvedModel
        mutateRun(task, i) { r in
            if let last = r.recentTools.indices.last, r.recentTools[last].endedAt == nil {
                r.recentTools[last].endedAt = d
                let errorRate = switch r.recentTools[last].name {
                case "Bash": 0.08
                case "Edit", "Read", "WebFetch": 0.02
                default: 0.0
                }
                r.recentTools[last].isError = errorRoll < errorRate
            }
            r.recentTools.append(event)
            if r.recentTools.count > 30 { r.recentTools.removeFirst(r.recentTools.count - 30) }
            r.toolCallCount += calls
            r.currentActivity = event.activityText
            r.lastActivityAt = d
            r.tokens = (r.tokens ?? TokenUsage()) + delta
            // The first assistant message reveals the model.
            if r.model.id == nil { r.model = ModelInfo(id: resolved, source: .transcript) }
        }
        if d > task.snap.lastActivityAt { task.snap.lastActivityAt = d }
        markDirty(task)
        if task.tools.insert(name).inserted { reclassify(task) }
    }

    private func endOpenTool(_ task: MockTask, _ i: Int, at t: Double) {
        guard let last = task.snap.runs[i].recentTools.indices.last,
              task.snap.runs[i].recentTools[last].endedAt == nil else { return }
        task.snap.runs[i].recentTools[last].endedAt = date(t)
    }

    private func mutateRun(_ task: MockTask, _ i: Int, _ body: (inout AgentRunSnapshot) -> Void) {
        body(&task.snap.runs[i])
    }

    private func markDirty(_ task: MockTask) {
        guard !task.isDirty else { return }
        task.isDirty = true
        dirtyOrder.append(task.handle)
    }

    private func backgroundChance(_ stage: MockStage) -> Double {
        switch stage {
        case .explore: 0.4
        case .plan, .review: 0.25
        case .build: 0.8
        case .nested: 0.5
        case .stress: 0.75
        case .workflow: 0.3
        }
    }
}

// MARK: - Simulation state

/// A scheduled step. Tasks are referenced by handle and runs by index, so events are plain data.
enum MockEvent {
    case spawn
    case spawnOnce
    case mainStep(Int)
    case tool(Int, Int)
    case launch(Int, parent: Int, stage: MockStage, queued: Bool, background: Bool)
    case begin(Int, Int)
    case finish(Int, Int)
    case close(Int)
}

enum MockWaitReason { case permission, question, planApproval }

enum MockPhase {
    /// The main agent makes tool calls.
    case work(Double)
    /// The main agent launches `count` subagents a fraction of a second apart.
    case wave(MockStage, count: Int)
    /// Wait for every direct subagent to finish.
    case join
    /// Blocked on the user (permission prompt, question, plan approval).
    case waitUser(Double, MockWaitReason)
    /// The main agent runs a skill (Skill tool call).
    case skill(String)
    /// The main agent makes one specific tool call (name, summary).
    case tool(String, String)
    case end(failed: Bool)
}

enum MockMainMode {
    /// Making tool calls.
    case working
    /// Not making tool calls (launching agents, waiting on the user).
    case blocked
    /// Waiting for subagents to finish.
    case awaiting
    case ended
}

/// Simulation-only facts about a run, parallel to `TaskSnapshot.runs`.
struct MockRunMeta {
    /// nil for the main agent.
    var profile: MockAgentProfile?
    /// Index of the parent run in the task.
    var parent: Int?
    var area: String
    var files: (String, String)
    /// The model the transcript will report.
    var resolvedModel: String
    var outcome: RunStatus = .done
    var plannedSeconds: Double = 0
    /// For failed/cancelled runs, how far through `plannedSeconds` they stop.
    var cutFraction: Double = 1
    var childCount = 0
    /// Children launched or scheduled that haven't finished.
    var openChildren = 0
    var awaitingChildren = false
    var toolArmed = false
}

/// A live task: its snapshot (mutated in place) plus the main agent's script.
final class MockTask {
    let handle: Int
    let id: String
    let project: MockProject
    let template: MockTaskTemplate
    /// Seeded history: doesn't trigger replacement tasks.
    let isHistory: Bool
    var snap: TaskSnapshot
    var meta: [MockRunMeta]
    /// Changed since the last update.
    var isDirty = false
    var phases: [MockPhase] = []
    var phaseIndex = 0
    var mode: MockMainMode = .blocked
    /// The task doesn't end before this time.
    var notBefore: Double?
    /// Stress: replace finished subagents until this time.
    var sustainUntil: Double?
    /// Workflow signals so far.
    var skills: Set<String> = []
    var tools: Set<String> = []
    var agentTypes: Set<String> = []
    private let areas: [String]
    private var areaCursor = 0

    init(handle: Int, project: MockProject, template: MockTaskTemplate, isHistory: Bool, snap: TaskSnapshot,
         mainMeta: MockRunMeta, areas: [String]) {
        self.handle = handle
        self.id = snap.id
        self.project = project
        self.template = template
        self.isHistory = isHistory
        self.snap = snap
        self.meta = [mainMeta]
        self.areas = areas
    }

    /// Cycles through the task's areas so parallel subagents get different descriptions.
    func nextArea() -> String {
        defer { areaCursor += 1 }
        return areas[areaCursor % areas.count]
    }
}
