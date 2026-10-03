import SwiftUI
import AgentDeckCore

// Small @Observable objects with stable identity, one per task and per run.
// Updates assign only the fields that changed, so one agent's update
// invalidates only the views that read that agent's changed fields.

@MainActor @Observable
final class RunModel: Identifiable {
    let id: String
    let taskID: String
    private(set) var parentRunID: String?
    private(set) var agentID: String?
    private(set) var agentType: String
    private(set) var description: String
    private(set) var prompt: String
    private(set) var model: ModelInfo
    private(set) var status: RunStatus
    private(set) var isBackground: Bool
    private(set) var startedAt: Date
    private(set) var endedAt: Date?
    private(set) var lastActivityAt: Date
    private(set) var estimate: DurationEstimate?
    private(set) var toolCallCount: Int
    private(set) var currentActivity: String?
    private(set) var tokens: TokenUsage?
    private(set) var resultSummary: String?
    private(set) var recentTools: [ToolEvent]
    private(set) var depth: Int

    init(_ s: AgentRunSnapshot) {
        id = s.id
        taskID = s.taskID
        parentRunID = s.parentRunID
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

    func apply(_ s: AgentRunSnapshot) {
        assign(\.parentRunID, s.parentRunID)
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

    var isMain: Bool { parentRunID == nil }
    var displayName: String { isMain ? "Main agent" : agentType }

    func elapsed(at now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }

    func progress(at now: Date) -> Double? {
        guard let estimate, estimate.seconds > 0 else { return nil }
        return min(1, elapsed(at: now) / estimate.seconds)
    }

    func overrun(at now: Date) -> TimeInterval? {
        guard let estimate else { return nil }
        let over = elapsed(at: now) - estimate.seconds
        return over > 0 ? over : nil
    }

    var expectedEnd: Date? {
        guard !status.isFinished, let estimate else { return nil }
        return startedAt.addingTimeInterval(estimate.seconds)
    }
}

@MainActor @Observable
final class TaskModel: Identifiable {
    let id: String
    private(set) var source: String
    private(set) var projectName: String
    private(set) var projectPath: String
    private(set) var title: String
    private(set) var status: TaskStatus
    private(set) var startedAt: Date
    private(set) var lastActivityAt: Date
    private(set) var endedAt: Date?
    private(set) var mainModel: ModelInfo
    private(set) var gitBranch: String?
    /// Run ids, main agent first then subagents in start order.
    private(set) var runIDs: [String]
    /// The run models themselves, in `runIDs` order. Views read these instead of the
    /// store's dictionary so a new run elsewhere doesn't invalidate this task's views.
    private(set) var runs: [RunModel] = []
    /// Derived, kept here so cards don't need to read every run.
    private(set) var runningCount: Int
    private(set) var eta: Date?
    private(set) var modelFamilies: [ModelFamily]

    init(_ s: TaskSnapshot) {
        id = s.id
        source = s.source
        projectName = s.projectName
        projectPath = s.projectPath
        title = s.title
        status = s.status
        startedAt = s.startedAt
        lastActivityAt = s.lastActivityAt
        endedAt = s.endedAt
        mainModel = s.mainModel
        gitBranch = s.gitBranch
        runIDs = s.runs.map(\.id)
        runningCount = s.runningSubagents.count
        eta = s.eta
        modelFamilies = Self.families(s)
    }

    func apply(_ s: TaskSnapshot) {
        assign(\.source, s.source)
        assign(\.projectName, s.projectName)
        assign(\.projectPath, s.projectPath)
        assign(\.title, s.title)
        assign(\.status, s.status)
        assign(\.startedAt, s.startedAt)
        assign(\.lastActivityAt, s.lastActivityAt)
        assign(\.endedAt, s.endedAt)
        assign(\.mainModel, s.mainModel)
        assign(\.gitBranch, s.gitBranch)
        assign(\.runIDs, s.runs.map(\.id))
        assign(\.runningCount, s.runningSubagents.count)
        assign(\.eta, s.eta)
        assign(\.modelFamilies, Self.families(s))
    }

    private func assign<V: Equatable>(_ kp: ReferenceWritableKeyPath<TaskModel, V>, _ v: V) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    func setRuns(_ models: [RunModel]) {
        if models.count != runs.count || zip(models, runs).contains(where: { $0 !== $1 }) { runs = models }
    }

    var subagents: ArraySlice<RunModel> { runs.dropFirst() }

    private static func families(_ s: TaskSnapshot) -> [ModelFamily] {
        Array(Set(s.runs.map { $0.model.id == nil ? s.mainModel.family : $0.model.family })).sorted()
    }

    func elapsed(at now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }
}
