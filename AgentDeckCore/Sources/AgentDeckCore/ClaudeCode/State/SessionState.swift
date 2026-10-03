import Foundation

/// Which run a transcript file belongs to: the main file, or `subagents/agent-<agentId>.jsonl`.
enum FileOwner: Sendable, Hashable {
    case main
    case agent(String)
}

/// How a run's turn ended (main run status uses it; subagent `stop_reason` is unreliable).
enum RunPhase: Sendable, Hashable {
    case notStarted
    case midTurn
    case ended(EndKind)

    enum EndKind: Sendable, Hashable { case normal, interrupted, error }
}

/// A finish decision with its provenance.
struct RunOutcome: Sendable, Hashable {
    /// `.done`, `.failed` or `.cancelled`.
    var status: RunStatus
    var endedAt: Date
    /// Timestamp of the line that carried the signal. Own-file lines after it mean the run resumed.
    var signalAt: Date
    /// Exact duration (`totalDurationMs` / `<duration_ms>`), when known.
    var durationMs: Int?
}

/// State derived from a run's own transcript file (the main file for the main run).
struct OwnFileState: Sendable, Hashable {
    var hasLines = false
    var firstAt: Date?
    var lastAt: Date?
    /// Latest non-`<synthetic>` `message.model`.
    var transcriptModel: String?
    var phase: RunPhase = .notStarted
    var lastWasAPIError = false
    var openTools: Set<String> = []
    /// Pending `AskUserQuestion` / `ExitPlanMode` calls.
    var interactivePending: Set<String> = []
    /// Newest last, at most `RunState.recentToolLimit`.
    var recentTools: [ToolEvent] = []
    var toolCallCount = 0
    var currentActivity: String?
    var usageByMessage: [String: TokenUsage] = [:]
    var usageTotal = TokenUsage()
    /// Fallback finish (SubagentHandback result, end_turn text, API error line).
    var fallback: RunOutcome?
    /// A forked agent (`fork-context-ref` first line).
    var isFork = false
    /// First prompt in the run's own file (subagents without a call prompt).
    var firstPrompt: String?
    /// The latest `SubagentHandback` report in the run's own file.
    var handbackReport: String?
}

/// One agent run: the main agent or a subagent (architecture §6).
struct RunState: Sendable, Hashable {
    static let recentToolLimit = 20

    var id: String
    var parentRunID: String?
    var depth: Int
    var agentID: String?
    var agentType: String
    var description: String
    var prompt: String
    var isBackground: Bool
    var isFork: Bool
    /// The Agent call's `model` parameter.
    var callModel: String?
    /// `meta.json` `model` (may be "inherit").
    var metaModel: String?
    /// `toolUseResult.resolvedModel`.
    var resolvedModel: String?
    /// Agent call time; first own line for runs without a call.
    var startedAt: Date?
    var lastActivityAt: Date?
    /// `async_launched` seen.
    var launched = false
    /// Decisive outcome from the parent (Agent result, task notification).
    var exact: RunOutcome?
    /// Interrupted by the user while running in the foreground.
    var cancelled: RunOutcome?
    var exactUsage: TokenUsage?
    var resultSummary: String?
    var own = OwnFileState()
    var appliedNotices: Set<String> = []
    /// True for an Agent tool call (id = tool_use.id); false for main and `agent:` rows.
    var isAgentCall: Bool
    /// Estimate captured when the run finished while being watched (before its own sample was added).
    var frozenEstimate: DurationEstimate?
    /// The engine has built this run while it was unfinished (it is being watched live).
    var observedUnfinished = false

    init(id: String, parentRunID: String?, depth: Int, agentID: String? = nil, agentType: String,
         description: String = "", prompt: String = "", isBackground: Bool = false, isFork: Bool = false,
         callModel: String? = nil, startedAt: Date? = nil, isAgentCall: Bool) {
        self.id = id
        self.parentRunID = parentRunID
        self.depth = depth
        self.agentID = agentID
        self.agentType = agentType
        self.description = description
        self.prompt = prompt
        self.isBackground = isBackground
        self.isFork = isFork
        self.callModel = callModel
        self.startedAt = startedAt
        self.lastActivityAt = startedAt
        self.isAgentCall = isAgentCall
    }

    /// The outcome currently in force: exact beats cancellation beats fallback.
    var outcome: RunOutcome? { exact ?? cancelled ?? own.fallback }

    /// Status from transcript signals only (time-based overrides are applied by `StatusRules`).
    var baseStatus: RunStatus {
        if let outcome { return outcome.status }
        if launched || own.hasLines { return .running }
        return .queued
    }

    var effectiveStartedAt: Date? { startedAt ?? own.firstAt }

    mutating func touch(_ ts: Date?) {
        guard let ts else { return }
        if lastActivityAt.map({ ts > $0 }) ?? true { lastActivityAt = ts }
    }
}

/// Everything known about one session (task).
struct SessionState: Sendable {
    let id: String
    var mainSeen = false
    /// First cwd of the main transcript.
    var firstCwd: String?
    /// First cwd of any subagent line (used only while the main file has none).
    var fallbackCwd: String?
    /// Latest `relocatedCwd`.
    var relocatedCwd: String?
    var gitBranch: String?
    var customTitle: String?
    var aiTitle: String?
    /// First human prompt, one line, ≤ 120 chars.
    var firstPrompt: String?
    var startedAt: Date?
    var lastActivityAt: Date?
    /// Local clock time of the last live growth of any file (not set by the cold load).
    var lastGrowthAt: Date?
    /// `cost-state` seen with no main-file activity line after it.
    var closed = false

    var main: RunState
    /// Subagent runs by run id (tool_use id, or `agent:<agentId>`).
    var runs: [String: RunState] = [:]
    /// Run ids in creation (file) order.
    var order: [String] = []
    /// agentId → run id, once both are known.
    var agentToRun: [String: String] = [:]
    /// toolUseId → agentId from meta, results and notifications (also before the run exists).
    var toolUseToAgent: [String: String] = [:]
    /// Subagent files with no run yet, by agentId.
    var orphans: [String: RunState] = [:]
    /// Local clock time each orphan was first seen (5 s grace before showing it).
    var orphanSince: [String: Date] = [:]
    /// Notices whose run isn't known yet, by task id (bounded).
    var pendingNotices: [String: [PendingNotice]] = [:]
    /// Meta sidecars applied, by agentId.
    var metas: [String: AgentMeta] = [:]
    /// Model resolution used agent definitions (re-dirty when they change).
    var usedDefinitions = false
    /// Peer handback reports delivered to the parent, by sending agent id (latest wins).
    var peerReports: [String: String] = [:]

    struct PendingNotice: Sendable {
        var notice: TaskNotice
        var at: Date?
    }

    init(id: String) {
        self.id = id
        main = RunState(id: Self.mainRunID(id), parentRunID: nil, depth: 0, agentType: "main", isAgentCall: false)
    }

    static func mainRunID(_ sessionID: String) -> String { "main:\(sessionID)" }
    static func agentRowID(_ agentID: String) -> String { "agent:\(agentID)" }

    var projectPath: String? { relocatedCwd ?? firstCwd ?? fallbackCwd }

    var title: String? { customTitle ?? aiTitle ?? firstPrompt }

    /// The run with `id` (main, subagent or visible orphan row).
    func run(_ id: String) -> RunState? {
        id == main.id ? main : runs[id]
    }

    mutating func touch(_ ts: Date?) {
        guard let ts else { return }
        if startedAt.map({ ts < $0 }) ?? true { startedAt = ts }
        if lastActivityAt.map({ ts > $0 }) ?? true { lastActivityAt = ts }
    }
}
