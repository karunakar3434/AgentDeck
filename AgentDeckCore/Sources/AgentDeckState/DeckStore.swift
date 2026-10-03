import Foundation
import Observation
import AgentDeckCore

/// Main-actor mirror of the core's state. Receives coalesced `DeckUpdate`s and
/// applies them to long-lived `TaskModel`/`RunModel` objects.
@MainActor @Observable
public final class DeckStore {
    public init() {}

    public private(set) var tasks: [String: TaskModel] = [:]
    public private(set) var runs: [String: RunModel] = [:]

    /// Active (running/waiting) task ids, most recently started first.
    public private(set) var activeTaskIDs: [String] = []
    /// Tasks that are no longer active, most recently ended first.
    public private(set) var inactiveTaskIDs: [String] = []
    /// Ids of runs currently running, longest-running first.
    public private(set) var runningRunIDs: [String] = []
    /// The sidebar's project entries in order: workflow groups as configured, then folder projects
    /// alphabetically, then Others. Groups and Others are listed even with no tasks.
    public private(set) var projects: [String] = [WorkflowRules.othersName]
    /// Workflow group names, in the configured order (`setWorkflowGroups`).
    public private(set) var groupNames: [String] = []
    public private(set) var agentTypes: [String] = []

    public private(set) var initialLoadComplete = false
    public private(set) var lastFinishedAt: Date?
    public private(set) var loadError: String?

    // Header-strip aggregates.
    public private(set) var runningAgentCount = 0
    /// `runningAgentCount` throttled to at most two changes a second, for the menu bar item,
    /// Dock badge and window subtitle: AppKit re-lays out the status item and title bar on
    /// every change, which is expensive when hundreds of agents churn.
    public private(set) var glanceRunningCount = 0
    @ObservationIgnored private var glancePublishedAt = Date.distantPast
    @ObservationIgnored private var glancePending = false
    public private(set) var modelsInUse: [ModelFamily] = []
    /// The models behind `activeTaskIDs` / `inactiveTaskIDs`, same order. Lists iterate
    /// these instead of looking ids up in `tasks` (which changes on any insertion).
    public private(set) var activeTasks: [TaskModel] = []
    public private(set) var inactiveTasks: [TaskModel] = []
    public private(set) var activeCountByProject: [String: Int] = [:]
    /// The longest-running subagent (else main agent), for the header tile.
    public private(set) var longestRun: RunModel?
    /// Anything running or active. Changes only on idle ↔ live transitions.
    public private(set) var isLive = false

    /// Called when a task finishes or a subagent fails (for notifications).
    public var onEvent: ((DeckEvent) -> Void)?
    /// Called when `glanceRunningCount` changes (Dock badge).
    @ObservationIgnored public var onGlanceChange: ((Int) -> Void)?

    public func task(_ id: String) -> TaskModel? { tasks[id] }
    public func run(_ id: String) -> RunModel? { runs[id] }

    public func runs(of task: TaskModel) -> [RunModel] { task.runs }

    public func setError(_ message: String?) { if loadError != message { loadError = message } }

    /// Sets the configured workflow groups (names, in order); they're listed even before any task joins.
    public func setWorkflowGroups(_ names: [String]) {
        guard names != groupNames else { return }
        groupNames = names
        rebuildIndexes()
    }

    /// What a sidebar entry is, by name.
    public func projectKind(of name: String) -> ProjectKind {
        if name == WorkflowRules.othersName { return .others }
        return groupNames.contains(name) ? .workflow : .folder
    }

    public func reset() {
        loadError = nil
        tasks = [:]
        runs = [:]
        activeTaskIDs = []
        inactiveTaskIDs = []
        runningRunIDs = []
        projects = Self.sidebarProjects(groups: groupNames, folders: [])
        agentTypes = []
        runningAgentCount = 0
        glanceRunningCount = 0
        modelsInUse = []
        lastFinishedAt = nil
        initialLoadComplete = false
        activeTasks = []
        inactiveTasks = []
        activeCountByProject = [:]
        longestRun = nil
        isLive = false
        glancePublishedAt = .distantPast
        onGlanceChange?(0)
    }

    public func apply(_ update: DeckUpdate) {
        var structureChanged = false
        switch update.health {
        case .ok?: setError(nil)
        case .degraded(let message)?: setError(message)
        case nil: break
        }

        for id in update.removed {
            if let t = tasks.removeValue(forKey: id) {
                for rid in t.runIDs { runs.removeValue(forKey: rid) }
                structureChanged = true
            }
        }
        var newRuns: [String: RunModel] = [:]

        let notify = update.initialLoadComplete || initialLoadComplete
        for snap in update.changed {
            if let model = tasks[snap.id] {
                let oldStatus = model.status
                let oldRunIDs = model.runIDs
                let oldEntry = (model.projectName, model.projectKind)
                model.apply(snap)
                // A task can change entry while it runs (a skill or agent that matches a workflow group).
                if oldEntry != (model.projectName, model.projectKind) { structureChanged = true }
                if oldStatus != snap.status {
                    structureChanged = true
                    if notify {
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
            var keys: [String] = []
            keys.reserveCapacity(snap.runs.count)
            for r in snap.runs {
                let key = RunKey.make(task: snap.id, run: r.id)
                keys.append(key)
                if let model = runs[key] ?? newRuns[key] {
                    models.append(model)
                    let old = (model.status, model.model.id, model.agentType)
                    model.apply(r)
                    if old.0 != r.status {
                        structureChanged = true
                        if r.status == .failed, notify, !r.isMain {
                            onEvent?(.subagentFailed(taskID: snap.id, runID: key))
                        }
                    } else if old.1 != r.model.id || old.2 != r.agentType {
                        // "Models in use" and the agent-type filter list depend on these.
                        structureChanged = true
                    }
                } else {
                    let model = RunModel(r)
                    newRuns[key] = model
                    models.append(model)
                    structureChanged = true
                    // A run can arrive already failed (e.g. the Agent call errored at once). Only
                    // after the initial load, so historical failures don't notify.
                    if r.status == .failed, initialLoadComplete, !r.isMain {
                        onEvent?(.subagentFailed(taskID: snap.id, runID: key))
                    }
                }
            }
            // Drop runs that disappeared from this task (e.g. an orphan merged into its Agent run).
            for gone in previousRunIDs.subtracting(keys) { runs.removeValue(forKey: gone) }
            tasks[snap.id]?.setRuns(models)
        }
        if !newRuns.isEmpty { runs.merge(newRuns) { a, _ in a } }

        if update.initialLoadComplete && !initialLoadComplete { initialLoadComplete = true; structureChanged = true }
        if structureChanged { rebuildIndexes() }
    }

    private func rebuildIndexes() {
        var active: [TaskModel] = []
        var inactive: [TaskModel] = []
        var folders = Set<String>()
        for t in tasks.values {
            if t.projectKind == .folder { folders.insert(t.projectName) }
            if t.status.isActive { active.append(t) } else { inactive.append(t) }
        }
        active.sort { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
        inactive.sort { ($0.endedAt ?? $0.lastActivityAt, $0.id) > ($1.endedAt ?? $1.lastActivityAt, $1.id) }
        setIfChanged(\.activeTaskIDs, active.map(\.id))
        setIfChanged(\.inactiveTaskIDs, inactive.map(\.id))
        setIfChangedByIdentity(\.activeTasks, active)
        setIfChangedByIdentity(\.inactiveTasks, inactive)
        setIfChanged(\.activeCountByProject, Dictionary(active.map { ($0.projectName, 1) }, uniquingKeysWith: +))
        setIfChanged(\.projects, Self.sidebarProjects(groups: groupNames, folders: folders))

        var running: [RunModel] = []
        var types = Set<String>()
        var families = Set<ModelFamily>()
        for r in runs.values {
            if !r.isMain { types.insert(r.agentType) }
            if r.status == .running {
                running.append(r)
                let fam = r.model.id == nil ? FamilyCache.family(tasks[r.taskID]?.mainModel.id) : FamilyCache.family(r.model.id)
                families.insert(fam)
            }
        }
        running.sort { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        setIfChanged(\.runningRunIDs, running.map(\.id))
        let longest = running.first { !$0.isMain } ?? running.first
        if longestRun !== longest { longestRun = longest }
        setIfChanged(\.isLive, !running.isEmpty || !active.isEmpty)
        setIfChanged(\.runningAgentCount, running.count)
        scheduleGlanceUpdate()
        setIfChanged(\.modelsInUse, families.sorted())
        setIfChanged(\.agentTypes, types.sorted())
        let last = inactive.compactMap { $0.endedAt ?? $0.lastActivityAt }.max()
        setIfChanged(\.lastFinishedAt, last)
    }

    /// Groups in order, then folders alphabetically (a folder named like a group or "Others" merges into
    /// that entry), then Others.
    static func sidebarProjects(groups: [String], folders: Set<String>) -> [String] {
        let reserved = Set(groups).union([WorkflowRules.othersName])
        let sortedFolders = folders.subtracting(reserved).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return groups + sortedFolders + [WorkflowRules.othersName]
    }

    private func scheduleGlanceUpdate() {
        guard glanceRunningCount != runningAgentCount, !glancePending else { return }
        let wait = 0.5 - Date().timeIntervalSince(glancePublishedAt)
        if wait <= 0 { publishGlance(); return }
        glancePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            glancePending = false
            publishGlance()
        }
    }

    private func publishGlance() {
        glancePublishedAt = Date()
        guard glanceRunningCount != runningAgentCount else { return }
        glanceRunningCount = runningAgentCount
        onGlanceChange?(glanceRunningCount)
    }

    private func setIfChangedByIdentity<T: AnyObject>(_ kp: ReferenceWritableKeyPath<DeckStore, [T]>, _ v: [T]) {
        let old = self[keyPath: kp]
        if old.count != v.count || zip(old, v).contains(where: { $0 !== $1 }) { self[keyPath: kp] = v }
    }

    private func setIfChanged<V: Equatable>(_ kp: ReferenceWritableKeyPath<DeckStore, V>, _ v: V) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }
}

public enum DeckEvent: Sendable, Equatable {
    case taskFinished(taskID: String, failed: Bool)
    case subagentFailed(taskID: String, runID: String)
}

/// Memoized `ModelFamily(modelID:)`: there are only a handful of distinct model ids,
/// and resolving one lowercases and scans the string.
@MainActor
public enum FamilyCache {
    private static var cache: [String: ModelFamily] = [:]

    public static func family(_ id: String?) -> ModelFamily {
        guard let id else { return .other }
        if let f = cache[id] { return f }
        let f = ModelFamily(modelID: id)
        cache[id] = f
        return f
    }
}
