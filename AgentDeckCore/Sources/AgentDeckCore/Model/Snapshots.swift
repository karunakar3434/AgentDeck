import Foundation

// Value-type snapshots that cross from the core actors to the UI.
// Everything here is Sendable and Hashable so the UI can diff cheaply.

public enum TaskStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// The main agent is mid-turn (generating or running tools).
    case running
    /// Blocked on the user: a permission prompt or a question is pending.
    case waiting
    /// The turn ended and the session is still open.
    case idle
    /// The session has ended (or has been quiet long enough to call it finished).
    case done
    /// The last turn ended on an error.
    case failed

    public var isActive: Bool { self == .running || self == .waiting }

    public var label: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting on you"
        case .idle: "Idle"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

public enum RunStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case queued, running, done, failed, cancelled

    public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Where the displayed model came from, most reliable first.
public enum ModelSource: String, Sendable, Hashable, Codable {
    /// `message.model` on the agent's own assistant messages.
    case transcript
    /// The Agent call's `model` parameter.
    case callParameter
    /// The agent definition's `model:` frontmatter.
    case definition
    /// Nothing more specific: the run uses its parent's model.
    case inherited
}

public struct ModelInfo: Sendable, Hashable, Codable {
    /// Full model id ("claude-opus-5-5") or alias ("sonnet"); nil when only "inherits parent" is known.
    public var id: String?
    public var source: ModelSource

    public init(id: String?, source: ModelSource) {
        self.id = id
        self.source = source
    }

    public var family: ModelFamily { ModelFamily(modelID: id) }
    public var displayName: String { id.map(ModelName.short) ?? "Inherits parent" }
}

public enum EstimateConfidence: String, Sendable, Hashable, Codable, Comparable {
    case low, medium, high

    public init(sampleCount: Int) {
        switch sampleCount {
        case 10...: self = .high
        case 3...: self = .medium
        default: self = .low
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        let order: [Self] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

public struct DurationEstimate: Sendable, Hashable, Codable {
    public var seconds: TimeInterval
    public var confidence: EstimateConfidence
    public var sampleCount: Int

    public init(seconds: TimeInterval, confidence: EstimateConfidence, sampleCount: Int) {
        self.seconds = seconds
        self.confidence = confidence
        self.sampleCount = sampleCount
    }

    /// Low-confidence estimates are shown with a leading "~".
    public var isApproximate: Bool { confidence == .low }
}

public struct TokenUsage: Sendable, Hashable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheCreation: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
    }

    public var total: Int { input + output + cacheRead + cacheCreation }

    public static func + (a: Self, b: Self) -> Self {
        .init(input: a.input + b.input, output: a.output + b.output,
              cacheRead: a.cacheRead + b.cacheRead, cacheCreation: a.cacheCreation + b.cacheCreation)
    }
}

/// One tool call made by an agent, for the inspector's live feed.
public struct ToolEvent: Sendable, Hashable, Codable, Identifiable {
    /// The tool_use id.
    public var id: String
    public var name: String
    /// One-line summary of the input, e.g. "npm test" for Bash or a file path for Read.
    public var summary: String
    public var startedAt: Date
    public var endedAt: Date?
    public var isError: Bool

    public init(id: String, name: String, summary: String, startedAt: Date, endedAt: Date? = nil, isError: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isError = isError
    }

    /// "Bash: npm test"
    public var activityText: String { summary.isEmpty ? name : "\(name): \(summary)" }
}

/// A single agent run: the main agent of a task, or a subagent started by an Agent tool call.
public struct AgentRunSnapshot: Sendable, Hashable, Codable, Identifiable {
    /// For subagents, the Agent tool_use id; for the main agent, "main:<sessionId>".
    public var id: String
    public var taskID: String
    /// The run that started this one; nil for the main agent.
    public var parentRunID: String?
    /// Claude Code's agent id (links to subagents/agent-<id>.jsonl), when known.
    public var agentID: String?
    public var agentType: String
    /// The Agent call's short `description`.
    public var description: String
    /// The Agent call's full `prompt`.
    public var prompt: String
    public var model: ModelInfo
    public var status: RunStatus
    public var isBackground: Bool
    public var startedAt: Date
    public var endedAt: Date?
    public var lastActivityAt: Date
    public var estimate: DurationEstimate?
    public var toolCallCount: Int
    /// The latest tool call, e.g. "Bash: npm test".
    public var currentActivity: String?
    public var tokens: TokenUsage?
    /// Short summary of the result once finished.
    public var resultSummary: String?
    /// Most recent tool calls, oldest first (capped).
    public var recentTools: [ToolEvent]
    /// Nesting depth: 0 for the main agent, 1 for its subagents, and so on.
    public var depth: Int

    public init(id: String, taskID: String, parentRunID: String?, agentID: String?, agentType: String,
                description: String, prompt: String, model: ModelInfo, status: RunStatus, isBackground: Bool,
                startedAt: Date, endedAt: Date?, lastActivityAt: Date, estimate: DurationEstimate?,
                toolCallCount: Int, currentActivity: String?, tokens: TokenUsage?, resultSummary: String?,
                recentTools: [ToolEvent], depth: Int) {
        self.id = id
        self.taskID = taskID
        self.parentRunID = parentRunID
        self.agentID = agentID
        self.agentType = agentType
        self.description = description
        self.prompt = prompt
        self.model = model
        self.status = status
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt
        self.estimate = estimate
        self.toolCallCount = toolCallCount
        self.currentActivity = currentActivity
        self.tokens = tokens
        self.resultSummary = resultSummary
        self.recentTools = recentTools
        self.depth = depth
    }

    public var isMain: Bool { parentRunID == nil }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// 0...1 progress against the estimate; nil without an estimate.
    public func progress(at now: Date) -> Double? {
        guard let estimate, estimate.seconds > 0 else { return nil }
        return min(1, elapsed(at: now) / estimate.seconds)
    }

    /// Seconds past the estimate (positive only when over).
    public func overrun(at now: Date) -> TimeInterval? {
        guard let estimate else { return nil }
        let over = elapsed(at: now) - estimate.seconds
        return over > 0 ? over : nil
    }

    /// When this run is expected to finish (nil when finished or no estimate).
    public var expectedEnd: Date? {
        guard !status.isFinished, let estimate else { return nil }
        return startedAt.addingTimeInterval(estimate.seconds)
    }
}

/// A Claude Code session: one task with its main agent and subagents.
public struct TaskSnapshot: Sendable, Hashable, Codable, Identifiable {
    /// The session id.
    public var id: String
    /// Which adapter produced it ("claude-code", "mock").
    public var source: String
    public var projectName: String
    public var projectPath: String
    /// First user prompt, trimmed (or the session's custom title).
    public var title: String
    public var status: TaskStatus
    public var startedAt: Date
    public var lastActivityAt: Date
    /// Set when the task reached done or failed.
    public var endedAt: Date?
    public var mainModel: ModelInfo
    public var gitBranch: String?
    /// All runs, main agent first, then subagents in start order.
    public var runs: [AgentRunSnapshot]

    public init(id: String, source: String, projectName: String, projectPath: String, title: String,
                status: TaskStatus, startedAt: Date, lastActivityAt: Date, endedAt: Date?,
                mainModel: ModelInfo, gitBranch: String?, runs: [AgentRunSnapshot]) {
        self.id = id
        self.source = source
        self.projectName = projectName
        self.projectPath = projectPath
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.endedAt = endedAt
        self.mainModel = mainModel
        self.gitBranch = gitBranch
        self.runs = runs
    }

    public var subagents: ArraySlice<AgentRunSnapshot> { runs.dropFirst() }
    public var runningSubagents: [AgentRunSnapshot] { runs.filter { !$0.isMain && $0.status == .running } }

    /// When the slowest running subagent is expected to finish.
    public var eta: Date? { runningSubagents.compactMap(\.expectedEnd).max() }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}
