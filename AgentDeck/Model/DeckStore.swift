import SwiftUI
import AgentDeckCore

/// Main-actor mirror of the core's state. Receives coalesced `DeckUpdate`s and
/// applies them to long-lived `TaskModel`/`RunModel` objects.
@MainActor @Observable
final class DeckStore {
    private(set) var tasks: [String: TaskModel] = [:]
    private(set) var runs: [String: RunModel] = [:]

    /// Active (running/waiting) task ids, most recently started first.
    private(set) var activeTaskIDs: [String] = []
    /// Tasks that are no longer active, most recently ended first.
    private(set) var inactiveTaskIDs: [String] = []
    /// Ids of runs currently running, longest-running first.
    private(set) var runningRunIDs: [String] = []
    /// Distinct project names, sorted.
    private(set) var projects: [String] = []
    private(set) var agentTypes: [String] = []

    private(set) var initialLoadComplete = false
    private(set) var lastFinishedAt: Date?
    private(set) var loadError: String?

    // Header-strip aggregates.
    private(set) var runningAgentCount = 0
    private(set) var modelsInUse: [ModelFamily] = []

    /// Called when a task finishes or a subagent fails (for notifications).
    var onEvent: ((DeckEvent) -> Void)?

    func task(_ id: String) -> TaskModel? { tasks[id] }
    func run(_ id: String) -> RunModel? { runs[id] }

    func runs(of task: TaskModel) -> [RunModel] { task.runs }

    func setError(_ message: String?) { loadError = message }

    func reset() {
        tasks = [:]
        runs = [:]
        activeTaskIDs = []
        inactiveTaskIDs = []
        runningRunIDs = []
        projects = []
        agentTypes = []
        runningAgentCount = 0
        modelsInUse = []
        lastFinishedAt = nil
        initialLoadComplete = false
    }

    func apply(_ update: DeckUpdate) {
        var structureChanged = false

        for id in update.removed {
            if let t = tasks.removeValue(forKey: id) {
                for rid in t.runIDs { runs.removeValue(forKey: rid) }
                structureChanged = true
            }
        }
        var newRuns: [String: RunModel] = [:]

        for snap in update.changed {
            if let model = tasks[snap.id] {
                let oldStatus = model.status
                let oldRunIDs = model.runIDs
                model.apply(snap)
                if oldStatus != snap.status {
                    structureChanged = true
                    if update.initialLoadComplete || initialLoadComplete {
                        if snap.status == .done || snap.status == .idle, oldStatus.isActive {
                            onEvent?(.taskFinished(taskID: snap.id, failed: false))
                        } else if snap.status == .failed {
                            onEvent?(.taskFinished(taskID: snap.id, failed: true))
                        }
                    }
                }
                if oldRunIDs != model.runIDs { structureChanged = true }
            } else {
                tasks[snap.id] = TaskModel(snap)
                structureChanged = true
            }

            let previousRunIDs = Set(tasks[snap.id]?.runs.map(\.id) ?? [])
            var models: [RunModel] = []
            models.reserveCapacity(snap.runs.count)
            for r in snap.runs {
                if let model = runs[r.id] ?? newRuns[r.id] {
                    models.append(model)
                    let old = model.status
                    model.apply(r)
                    if old != r.status {
                        structureChanged = true
                        if r.status == .failed, initialLoadComplete, !r.isMain {
                            onEvent?(.subagentFailed(taskID: snap.id, runID: r.id))
                        }
                    }
                } else {
                    let model = RunModel(r)
                    newRuns[r.id] = model
                    models.append(model)
                    structureChanged = true
                }
            }
            // Drop runs that disappeared from this task (e.g. an orphan merged into its Agent run).
            for gone in previousRunIDs.subtracting(snap.runs.map(\.id)) { runs.removeValue(forKey: gone) }
            tasks[snap.id]?.setRuns(models)
        }
        if !newRuns.isEmpty { runs.merge(newRuns) { a, _ in a } }

        if update.initialLoadComplete && !initialLoadComplete { initialLoadComplete = true; structureChanged = true }
        if structureChanged { rebuildIndexes() }
    }

    private func rebuildIndexes() {
        var active: [TaskModel] = []
        var inactive: [TaskModel] = []
        var projectSet = Set<String>()
        for t in tasks.values {
            projectSet.insert(t.projectName)
            if t.status.isActive { active.append(t) } else { inactive.append(t) }
        }
        active.sort { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
        inactive.sort { ($0.endedAt ?? $0.lastActivityAt, $0.id) > ($1.endedAt ?? $1.lastActivityAt, $1.id) }
        setIfChanged(\.activeTaskIDs, active.map(\.id))
        setIfChanged(\.inactiveTaskIDs, inactive.map(\.id))
        setIfChanged(\.projects, projectSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        var running: [RunModel] = []
        var types = Set<String>()
        var families = Set<ModelFamily>()
        for r in runs.values {
            if !r.isMain { types.insert(r.agentType) }
            if r.status == .running {
                running.append(r)
                let fam = r.model.id == nil ? (tasks[r.taskID]?.mainModel.family ?? .other) : r.model.family
                families.insert(fam)
            }
        }
        running.sort { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        setIfChanged(\.runningRunIDs, running.map(\.id))
        setIfChanged(\.runningAgentCount, running.count)
        setIfChanged(\.modelsInUse, families.sorted())
        setIfChanged(\.agentTypes, types.sorted())
        let last = inactive.compactMap { $0.endedAt ?? $0.lastActivityAt }.max()
        setIfChanged(\.lastFinishedAt, last)
    }

    private func setIfChanged<V: Equatable>(_ kp: ReferenceWritableKeyPath<DeckStore, V>, _ v: V) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }
}

enum DeckEvent {
    case taskFinished(taskID: String, failed: Bool)
    case subagentFailed(taskID: String, runID: String)
}
