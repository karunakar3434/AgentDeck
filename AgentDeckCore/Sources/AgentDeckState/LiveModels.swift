import Foundation
import Observation
import AgentDeckCore

// Small @Observable objects with stable identity, one per task and per run.
// Updates assign only the fields that changed, so one agent's update
// invalidates only the views that read that agent's changed fields.

/// Run ids from the core (Agent tool_use ids) are only unique within a session, and a
/// forked or resumed session can repeat them, so the app keys runs by task as well.
public enum RunKey {
    public static func make(task: String, run: String) -> String { "\(task)/\(run)" }
}

@MainActor @Observable
public final class RunModel: Identifiable {
    /// `RunKey.make(task:run:)`.
    public let id: String
    /// The core's run id (Agent tool_use id, or "main:<session>").
    public let runID: String
    public let taskID: String
    public private(set) var parentRunID: String?
    public private(set) var agentID: String?
    public private(set) var agentType: String
    public private(set) var description: String
    public private(set) var prompt: String
    public private(set) var model: ModelInfo
    public private(set) var status: RunStatus
    public private(set) var isBackground: Bool
    public private(set) var startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var lastActivityAt: Date
    public private(set) var estimate: DurationEstimate?
    public private(set) var toolCallCount: Int
    public private(set) var currentActivity: String?
    public private(set) var tokens: TokenUsage?
    public private(set) var resultSummary: String?
    public private(set) var recentTools: [ToolEvent]
    public private(set) var depth: Int

    public init(_ s: AgentRunSnapshot) {
        id = RunKey.make(task: s.taskID, run: s.id)
        runID = s.id
        taskID = s.taskID
        parentRunID = s.parentRunID.map { RunKey.make(task: s.taskID, run: $0) }
        agentID = s.agentID
        agentType = s.agentType
        description = s.description
        prompt = s.prompt
        model = s.model
        status = s.status
        isBackground = s.isBackground
        startedAt = s.startedAt
        endedAt = s.endedAt
        lastActivityAt = s.lastActivityAt
        estimate = s.estimate
        toolCallCount = s.toolCallCount
        currentActivity = s.currentActivity
        tokens = s.tokens
        resultSummary = s.resultSummary
        recentTools = s.recentTools
        depth = s.depth
    }

    public func apply(_ s: AgentRunSnapshot) {
        assign(\.parentRunID, s.parentRunID.map { RunKey.make(task: s.taskID, run: $0) })
        assign(\.agentID, s.agentID)
        assign(\.agentType, s.agentType)
        assign(\.description, s.description)
        assign(\.prompt, s.prompt)
        assign(\.model, s.model)
        assign(\.status, s.status)
        assign(\.isBackground, s.isBackground)
        assign(\.startedAt, s.startedAt)
        assign(\.endedAt, s.endedAt)
        assign(\.lastActivityAt, s.lastActivityAt)
        assign(\.estimate, s.estimate)
        assign(\.toolCallCount, s.toolCallCount)
        assign(\.currentActivity, s.currentActivity)
        assign(\.tokens, s.tokens)
        assign(\.resultSummary, s.resultSummary)
        assign(\.recentTools, s.recentTools)
        assign(\.depth, s.depth)
    }

    private func assign<V: Equatable>(_ kp: ReferenceWritableKeyPath<RunModel, V>, _ v: V) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    public var isMain: Bool { parentRunID == nil }
    public var displayName: String { isMain ? "Main agent" : agentType }

    public func elapsed(at now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }

    public func progress(at now: Date) -> Double? {
        guard let estimate, estimate.seconds > 0 else { return nil }
        return min(1, elapsed(at: now) / estimate.seconds)
    }

    public func overrun(at now: Date) -> TimeInterval? {
        guard let estimate else { return nil }
        let over = elapsed(at: now) - estimate.seconds
        return over > 0 ? over : nil
    }

    public var expectedEnd: Date? {
        guard !status.isFinished, let estimate else { return nil }
        return startedAt.addingTimeInterval(estimate.seconds)
    }
}

@MainActor @Observable
public final class TaskModel: Identifiable {
    public let id: String
    public private(set) var source: String
    /// The sidebar entry: a workflow group, the project folder's name, or "Others".
    public private(set) var projectName: String
    public private(set) var projectKind: ProjectKind
    /// The real working folder, whatever the entry.
    public private(set) var projectPath: String
    public private(set) var title: String
    public private(set) var status: TaskStatus
    public private(set) var startedAt: Date
    public private(set) var lastActivityAt: Date
    public private(set) var endedAt: Date?
    public private(set) var mainModel: ModelInfo
    public private(set) var gitBranch: String?
    /// Run ids, main agent first then subagents in start order.
    public private(set) var runIDs: [String]
    /// The run models themselves, in `runIDs` order. Views read these instead of the
    /// store's dictionary so a new run elsewhere doesn't invalidate this task's views.
    public private(set) var runs: [RunModel] = []
    /// Derived, kept here so cards don't need to read every run.
    public private(set) var runningCount: Int
    public private(set) var eta: Date?
    public private(set) var modelFamilies: [ModelFamily]

    public init(_ s: TaskSnapshot) {
        id = s.id
        source = s.source
        projectName = s.projectName
        projectKind = s.projectKind ?? .folder
        projectPath = s.projectPath
        title = s.title
        status = s.status
        startedAt = s.startedAt
        lastActivityAt = s.lastActivityAt
        endedAt = s.endedAt
        mainModel = s.mainModel
        gitBranch = s.gitBranch
        runIDs = s.runs.map { RunKey.make(task: s.id, run: $0.id) }
        runningCount = s.runningSubagents.count
        eta = s.eta
        modelFamilies = Self.families(s)
    }

    public func apply(_ s: TaskSnapshot) {
        assign(\.source, s.source)
        assign(\.projectName, s.projectName)
        assign(\.projectKind, s.projectKind ?? .folder)
        assign(\.projectPath, s.projectPath)
        assign(\.title, s.title)
        assign(\.status, s.status)
        assign(\.startedAt, s.startedAt)
        assign(\.lastActivityAt, s.lastActivityAt)
        assign(\.endedAt, s.endedAt)
        assign(\.mainModel, s.mainModel)
        assign(\.gitBranch, s.gitBranch)
        assign(\.runIDs, s.runs.map { RunKey.make(task: s.id, run: $0.id) })
        assign(\.runningCount, s.runningSubagents.count)
        assign(\.eta, s.eta)
        assign(\.modelFamilies, Self.families(s))
    }

    private func assign<V: Equatable>(_ kp: ReferenceWritableKeyPath<TaskModel, V>, _ v: V) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    public func setRuns(_ models: [RunModel]) {
        if models.count != runs.count || zip(models, runs).contains(where: { $0 !== $1 }) {
            runs = models
            treeOrderValid = false
        }
    }

    @ObservationIgnored private var treeOrderValid = false
    @ObservationIgnored private var cachedTreeOrder: [RunModel] = []

    /// Depth-first order (each run followed by its children, children by start time), as the
    /// agent tree shows it. Cached until the run list changes.
    public var runsInTreeOrder: [RunModel] {
        _ = runs  // register the dependency
        if !treeOrderValid {
            cachedTreeOrder = Self.treeOrder(runs)
            treeOrderValid = true
        }
        return cachedTreeOrder
    }

    public static func treeOrder(_ all: [RunModel]) -> [RunModel] {
        var children: [String: [RunModel]] = [:]
        var roots: [RunModel] = []
        let ids = Set(all.map(\.id))
        for r in all {
            if let p = r.parentRunID, ids.contains(p) { children[p, default: []].append(r) } else { roots.append(r) }
        }
        var out: [RunModel] = []
        out.reserveCapacity(all.count)
        func visit(_ r: RunModel) {
            out.append(r)
            for c in (children[r.id] ?? []).sorted(by: { $0.startedAt < $1.startedAt }) { visit(c) }
        }
        for r in roots.sorted(by: { ($0.isMain ? 0 : 1, $0.startedAt) < ($1.isMain ? 0 : 1, $1.startedAt) }) { visit(r) }
        return out
    }

    public var subagents: ArraySlice<RunModel> { runs.dropFirst() }

    private static func families(_ s: TaskSnapshot) -> [ModelFamily] {
        var set = Set<ModelFamily>()
        let main = FamilyCache.family(s.mainModel.id)
        for r in s.runs { set.insert(r.model.id == nil ? main : FamilyCache.family(r.model.id)) }
        return set.sorted()
    }

    /// Running and waiting tasks count up; idle, done and failed ones stop at their end
    /// (or last activity, for idle sessions whose process is still open).
    public func elapsed(at now: Date) -> TimeInterval {
        let end = endedAt ?? (status.isActive ? now : lastActivityAt)
        return max(0, end.timeIntervalSince(startedAt))
    }
}
