import Foundation

/// `SessionState` + derived status → `TaskSnapshot` (pure apart from the injected lookups).
enum SnapshotBuilder {
    static let source = "claude-code"

    struct Output {
        var snapshot: TaskSnapshot
        var status: StatusRules.Result
        /// Model resolution consulted agent definitions.
        var usedDefinitions: Bool
    }

    /// - Parameters:
    ///   - definitionModel: agent definition `model:` for a type (project first, then user).
    ///   - estimate: the live estimate for an unfinished run (type, family).
    ///   - finishedEstimate: the estimate for a finished run that wasn't watched finishing (no frozen
    ///     estimate), computed without the run's own sample: run id (= tool-use id), type, family.
    static func build(_ s: SessionState, status: StatusRules.Result,
                      definitionModel: (String) -> String?,
                      estimate: (String, ModelFamily) -> DurationEstimate?,
                      finishedEstimate: (String, String, ModelFamily) -> DurationEstimate?) -> Output {
        var usedDefinitions = false
        let mainResolution = ModelResolver.resolve(s.main, isMain: true, definitionModel: definitionModel)
        let mainModel = mainResolution.model
        let title = taskTitle(s)
        let projectPath = s.projectPath ?? ""
        let startedAt = s.startedAt ?? s.lastActivityAt ?? Date(timeIntervalSince1970: 0)
        let lastActivity = s.lastActivityAt ?? startedAt

        var runs: [AgentRunSnapshot] = []
        runs.reserveCapacity(s.runs.count + 1)
        let main = s.main
        runs.append(AgentRunSnapshot(
            id: main.id, taskID: s.id, parentRunID: nil, agentID: nil, agentType: "main",
            description: title, prompt: main.prompt, model: mainModel, status: status.mainRun, isBackground: false,
            startedAt: startedAt, endedAt: status.mainRun.isFinished ? (main.lastActivityAt ?? lastActivity) : nil,
            lastActivityAt: main.lastActivityAt ?? lastActivity, estimate: nil,
            toolCallCount: main.own.toolCallCount,
            currentActivity: status.mainRun.isFinished ? nil : main.own.currentActivity,
            tokens: tokens(main.own.usageTotal), resultSummary: nil, recentTools: main.own.recentTools, depth: 0))

        // Subagents: by (startedAt, file order).
        var orderIndex: [String: Int] = [:]
        for (i, id) in s.order.enumerated() { orderIndex[id] = i }
        let sorted = s.runs.values.sorted { a, b in
            let sa = a.effectiveStartedAt ?? .distantFuture, sb = b.effectiveStartedAt ?? .distantFuture
            if sa != sb { return sa < sb }
            return (orderIndex[a.id] ?? .max) < (orderIndex[b.id] ?? .max)
        }
        let visible = Set(s.runs.keys)
        for run in sorted {
            let resolution = ModelResolver.resolve(run, isMain: false, definitionModel: definitionModel)
            if resolution.usedDefinitions { usedDefinitions = true }
            let runStatus = status.runs[run.id] ?? run.baseStatus
            let started = run.effectiveStartedAt ?? lastActivity
            var endedAt: Date?
            if runStatus.isFinished {
                if let e = status.overrideEndedAt[run.id] {
                    endedAt = e
                } else if let o = run.outcome {
                    // Exact durations: startedAt + duration (the start may have become known after the signal).
                    endedAt = o.durationMs != nil
                        ? SessionReducer.exactEnd(startedAt: run.effectiveStartedAt, durationMs: o.durationMs, signal: o.signalAt)
                        : o.endedAt
                } else {
                    endedAt = run.lastActivityAt ?? started
                }
                if let e = endedAt, e < started { endedAt = started }
            }
            var est: DurationEstimate?
            let family = resolution.model.id == nil ? mainModel.family : resolution.model.family
            if !runStatus.isFinished {
                est = estimate(run.agentType, family)
            } else if let frozen = run.frozenEstimate {
                est = frozen
            } else {
                est = finishedEstimate(run.id, run.agentType, family)
            }
            // The agent's own report first; a failure's reason first for failed runs.
            var summary: String?
            if runStatus.isFinished {
                let peer = run.agentID.flatMap { s.peerReports[$0] }
                summary = runStatus == .failed
                    ? run.resultSummary ?? run.own.handbackReport ?? peer
                    : run.own.handbackReport ?? peer ?? run.resultSummary
            }
            let parent = run.parentRunID.flatMap { visible.contains($0) || $0 == main.id ? $0 : nil } ?? main.id
            runs.append(AgentRunSnapshot(
                id: run.id, taskID: s.id, parentRunID: parent, agentID: run.agentID, agentType: run.agentType,
                description: run.description, prompt: run.prompt, model: resolution.model, status: runStatus,
                isBackground: run.isBackground, startedAt: started, endedAt: endedAt,
                lastActivityAt: max(run.lastActivityAt ?? started, started), estimate: est,
                toolCallCount: run.own.toolCallCount,
                currentActivity: runStatus.isFinished ? nil : run.own.currentActivity,
                tokens: run.exactUsage ?? tokens(run.own.usageTotal), resultSummary: summary,
                recentTools: run.own.recentTools, depth: parent == main.id ? 1 : run.depth))
        }

        let snapshot = TaskSnapshot(
            id: s.id, source: source, projectName: projectName(projectPath), projectPath: projectPath, title: title,
            status: status.task, startedAt: startedAt, lastActivityAt: lastActivity, endedAt: status.endedAt,
            mainModel: mainModel, gitBranch: s.gitBranch, runs: runs)
        return Output(snapshot: snapshot, status: status, usedDefinitions: usedDefinitions)
    }

    /// Custom/AI title when present, else the first human prompt (one line, ≤ 120 chars).
    static func taskTitle(_ s: SessionState) -> String {
        for candidate in [s.customTitle, s.aiTitle, s.firstPrompt] {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                return TextUtil.firstLine(c, limit: 120)
            }
        }
        return "Untitled session"
    }

    /// Last path component of the project path; Claude desktop scratch workspaces share one name.
    static func projectName(_ path: String) -> String {
        if path.contains("/scratch-workspaces/") { return "Scratch" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "Unknown project" : name
    }

    /// The duration recorded as this run's sample: exact, else its own first-to-last line span.
    static func ownSeconds(_ run: RunState) -> Double? {
        if let ms = run.exact?.durationMs { return Double(ms) / 1000 }
        if let first = run.own.firstAt, let last = run.own.lastAt, last > first {
            return (last.timeIntervalSince(first) * 1000).rounded() / 1000
        }
        return nil
    }

    private static func tokens(_ usage: TokenUsage) -> TokenUsage? {
        usage.total > 0 ? usage : nil
    }
}
