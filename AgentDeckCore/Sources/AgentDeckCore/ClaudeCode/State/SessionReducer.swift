import Foundation

/// Folds transcript events into a `SessionState` (architecture §6). Pure: no I/O, no clock reads; the
/// caller passes `now` (local clock, used only for the orphan grace period).
///
/// R is the run that owns the file: the main file maps to the main run, `agent-<aid>.jsonl` to the run
/// linked to `aid`, else to `orphans[aid]`. Linking tolerates any arrival order of main lines, meta
/// sidecars, subagent lines and notifications.
enum SessionReducer {
    /// Pending notices kept per session (task ids), oldest dropped first.
    static let pendingNoticeLimit = 32
    static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    // MARK: Transcript lines

    static func apply(_ event: TranscriptEvent, owner: FileOwner, to s: inout SessionState, now: Date) {
        switch event {
        case .assistant(let e):
            applyAssistant(e, owner: owner, to: &s, now: now)
        case .user(let e):
            applyUser(e, owner: owner, to: &s, now: now)
        case .system(let subtype, let ctx):
            envelope(ctx, owner: owner, &s)
            withOwner(owner, &s, now: now) { r in
                ownLine(&r, ctx.timestamp, owner: owner)
                if subtype == "turn_duration" || subtype == "stop_hook_summary" {
                    r.own.phase = .ended(.normal)
                    closeAllTools(&r, at: ctx.timestamp)
                }
            }
        case .notices(let notices, let ts):
            for n in notices { applyNotice(n, at: ts, to: &s) }
        case .queuedPrompt(let text, let ts):
            guard owner == .main else { return }
            s.touch(ts)
            s.main.touch(ts)
            s.main.prompt = text
            s.main.own.phase = .midTurn
            if s.firstPrompt == nil { s.firstPrompt = titleLine(text) }
        case .peerReport(let agentID, let text):
            s.peerReports[agentID] = text
        case .customTitle(let t):
            if owner == .main { s.customTitle = t }
        case .aiTitle(let t):
            if owner == .main { s.aiTitle = t }
        case .relocated(let cwd):
            if owner == .main { s.relocatedCwd = cwd }
        case .costState:
            if owner == .main { s.closed = true }
        case .forkContextRef:
            withOwner(owner, &s, now: now) { r in
                r.own.isFork = true
                r.isFork = true
            }
        }
    }

    private static func applyAssistant(_ e: AssistantEvent, owner: FileOwner, to s: inout SessionState, now: Date) {
        let ts = e.context.timestamp
        envelope(e.context, owner: owner, &s)
        var calls: [ToolUse] = []
        let (ownerID, ownerDepth) = withOwner(owner, &s, now: now) { r -> (String, Int) in
            ownLine(&r, ts, owner: owner)
            if let model = e.model { r.own.transcriptModel = model }
            if let id = e.messageID, let usage = e.usage {
                if let old = r.own.usageByMessage[id] { r.own.usageTotal = subtract(r.own.usageTotal, old) }
                r.own.usageByMessage[id] = usage
                r.own.usageTotal = r.own.usageTotal + usage
            }
            if e.isAPIError {
                r.own.lastWasAPIError = true
                r.own.phase = .ended(.error)
                if owner != .main, let ts {
                    r.own.fallback = RunOutcome(status: .failed, endedAt: ts, signalAt: ts, durationMs: nil)
                    r.resultSummary = r.resultSummary ?? firstText(e)
                }
                return (r.id, r.depth)
            }
            r.own.lastWasAPIError = false
            var sawToolUse = false
            for block in e.blocks {
                switch block {
                case .toolUse(let t):
                    sawToolUse = true
                    r.own.toolCallCount += 1
                    let event = ToolEvent(id: t.id, name: t.name, summary: t.summary,
                                          startedAt: ts ?? r.lastActivityAt ?? now)
                    r.own.recentTools.append(event)
                    if r.own.recentTools.count > RunState.recentToolLimit {
                        r.own.recentTools.removeFirst(r.own.recentTools.count - RunState.recentToolLimit)
                    }
                    r.own.openTools.insert(t.id)
                    r.own.currentActivity = event.activityText
                    r.own.phase = .midTurn
                    if interactiveTools.contains(t.name) { r.own.interactivePending.insert(t.id) }
                    if let report = t.handbackMessage { r.own.handbackReport = report }
                    if t.agentCall != nil { calls.append(t) }
                case .text:
                    // Subagent fallback finish: a final text block with end_turn (older versions set it).
                    if owner != .main, e.stopReason == "end_turn", let ts {
                        r.own.fallback = RunOutcome(status: .done, endedAt: ts, signalAt: ts, durationMs: nil)
                    }
                case .other:
                    break
                }
            }
            if owner == .main, e.stopReason == "end_turn", !sawToolUse {
                r.own.phase = .ended(.normal)
            }
            return (r.id, r.depth)
        }
        for t in calls {
            guard let call = t.agentCall, s.runs[t.id] == nil else { continue }
            var run = RunState(id: t.id, parentRunID: ownerID, depth: ownerDepth + 1,
                               agentType: nonEmpty(call.subagentType) ?? "general-purpose",
                               description: call.description ?? "", prompt: call.prompt ?? "",
                               isBackground: call.runInBackground ?? false, callModel: nonEmpty(call.model),
                               startedAt: ts, isAgentCall: true)
            run.lastActivityAt = ts
            s.runs[t.id] = run
            s.order.append(t.id)
            if let aid = s.toolUseToAgent[t.id] { link(agentID: aid, toolUseID: t.id, in: &s) }
        }
    }

    private static func applyUser(_ e: UserEvent, owner: FileOwner, to s: inout SessionState, now: Date) {
        let ts = e.context.timestamp
        envelope(e.context, owner: owner, &s)
        var agentResults: [ToolResult] = []
        var cancelChildrenOf: String?
        withOwner(owner, &s, now: now) { r in
            ownLine(&r, ts, owner: owner)
            for result in e.toolResults {
                closeTool(&r, id: result.toolUseID, at: ts, isError: result.isError)
                r.own.interactivePending.remove(result.toolUseID)
                agentResults.append(result)
            }
            if !e.toolResults.isEmpty {
                r.own.phase = .midTurn
                r.own.lastWasAPIError = false
                if e.toolEndsTurn, owner != .main, let ts {
                    r.own.fallback = RunOutcome(status: .done, endedAt: ts, signalAt: ts, durationMs: nil)
                }
            }
            switch e.kind {
            case .prompt(let text):
                if owner == .main {
                    r.prompt = text
                    r.own.phase = .midTurn
                    r.own.lastWasAPIError = false
                } else {
                    if r.prompt.isEmpty { r.prompt = text }
                    if r.own.firstPrompt == nil { r.own.firstPrompt = titleLine(text) }
                }
            case .interrupt:
                r.own.phase = .ended(.interrupted)
                closeAllTools(&r, at: ts)
                r.own.interactivePending.removeAll()
                cancelChildrenOf = r.id
            case .notification, .peer:
                if owner == .main { r.own.phase = .midTurn }
            case .toolResults, .meta:
                break
            }
        }
        if owner == .main, case .prompt(let text) = e.kind, s.firstPrompt == nil {
            s.firstPrompt = titleLine(text)
        }
        for result in agentResults { applyAgentResult(result, at: ts, to: &s) }
        if let parent = cancelChildrenOf, let ts {
            for id in s.order {
                guard var run = s.runs[id], run.parentRunID == parent, !run.isBackground,
                      run.exact == nil, run.cancelled == nil, !run.baseStatus.isFinished else { continue }
                run.cancelled = RunOutcome(status: .cancelled, endedAt: ts, signalAt: ts, durationMs: nil)
                s.runs[id] = run
            }
        }
        for n in e.notices { applyNotice(n, at: ts, to: &s) }
        if let peer = e.peerReport { s.peerReports[peer.agentID] = peer.text }
    }

    // MARK: Agent results and notifications

    private static func applyAgentResult(_ result: ToolResult, at ts: Date?, to s: inout SessionState) {
        let tuid = result.toolUseID
        guard let existing = s.runs[tuid], existing.isAgentCall else { return }
        if let aid = result.agentResult?.agentID { link(agentID: aid, toolUseID: tuid, in: &s) }
        guard var run = s.runs[tuid] else { return }
        let signal = ts ?? run.lastActivityAt ?? run.startedAt ?? Date.distantPast
        if let ar = result.agentResult {
            if let model = nonEmpty(ar.resolvedModel) { run.resolvedModel = model }
            if run.agentType == "general-purpose", let type = nonEmpty(ar.agentType) { run.agentType = type }
            switch ar.status {
            case "async_launched":
                run.isBackground = true
                run.launched = true
            case "completed":
                run.exact = RunOutcome(status: .done,
                                       endedAt: exactEnd(startedAt: run.startedAt, durationMs: ar.totalDurationMs, signal: signal),
                                       signalAt: signal, durationMs: ar.totalDurationMs)
                run.exactUsage = ar.usage
                run.resultSummary = ar.text ?? run.resultSummary
                run.launched = true
            default:
                if result.isError {
                    run.exact = RunOutcome(status: .failed, endedAt: signal, signalAt: signal, durationMs: nil)
                }
            }
        } else if result.isError {
            run.exact = RunOutcome(status: .failed, endedAt: signal, signalAt: signal, durationMs: nil)
            run.resultSummary = result.errorText.flatMap(TextUtil.report)
        }
        run.touch(ts)
        s.runs[tuid] = run
    }

    /// Applies a `<task-notification>`. Found by `tool-use-id` of an Agent run, else by `task-id` (agent id:
    /// forks, and runs resumed with SendMessage whose notice carries the SendMessage id). Unknown task ids
    /// wait in `pendingNotices` until their run appears. Idempotent per notice.
    static func applyNotice(_ n: TaskNotice, at ts: Date?, to s: inout SessionState) {
        var runID: String?
        if let tuid = n.toolUseID, let run = s.runs[tuid], run.isAgentCall {
            if let aid = n.taskID { link(agentID: aid, toolUseID: tuid, in: &s) }
            runID = tuid
        } else if let aid = n.taskID, let rid = s.agentToRun[aid], s.runs[rid] != nil {
            runID = rid
        }
        guard let runID, var run = s.runs[runID] else {
            if let aid = n.taskID { holdNotice(n, at: ts, taskID: aid, in: &s) }
            return
        }
        let identity = n.identity
        guard !run.appliedNotices.contains(identity) else { return }
        run.appliedNotices.insert(identity)
        let signal = ts ?? run.lastActivityAt ?? run.startedAt ?? Date.distantPast
        switch n.status {
        case "completed":
            run.exact = RunOutcome(status: .done,
                                   endedAt: exactEnd(startedAt: run.startedAt ?? run.own.firstAt, durationMs: n.durationMs, signal: signal),
                                   signalAt: signal, durationMs: n.durationMs)
            run.resultSummary = n.result ?? n.summary.flatMap(TextUtil.report)
        case "failed", "killed", "error", "stopped", "cancelled":
            run.exact = RunOutcome(status: .failed, endedAt: signal, signalAt: signal, durationMs: n.durationMs)
            run.resultSummary = n.summary.flatMap(TextUtil.report) ?? n.result
        default:
            break
        }
        run.isBackground = true
        run.launched = true
        run.touch(ts)
        s.runs[runID] = run
    }

    private static func holdNotice(_ n: TaskNotice, at ts: Date?, taskID: String, in s: inout SessionState) {
        var list = s.pendingNotices[taskID] ?? []
        guard !list.contains(where: { $0.notice.identity == n.identity }) else { return }
        list.append(.init(notice: n, at: ts))
        s.pendingNotices[taskID] = list
        if s.pendingNotices.count > pendingNoticeLimit, let drop = s.pendingNotices.keys.first(where: { $0 != taskID }) {
            s.pendingNotices[drop] = nil
        }
    }

    private static func flushPendingNotices(for agentID: String, in s: inout SessionState) {
        guard let list = s.pendingNotices.removeValue(forKey: agentID) else { return }
        for p in list { applyNotice(p.notice, at: p.at, to: &s) }
    }

    /// `startedAt + duration`, unless that is after the signal or more than 60 s before it (a resumed run,
    /// whose duration covers only the last segment): then the signal time.
    static func exactEnd(startedAt: Date?, durationMs: Int?, signal: Date) -> Date {
        guard let startedAt, let durationMs, durationMs >= 0 else { return signal }
        let end = startedAt.addingTimeInterval(Double(durationMs) / 1000)
        if end > signal || signal.timeIntervalSince(end) > 60 { return signal }
        return end
    }

    // MARK: Sidecars

    /// `agent-<aid>.meta.json`: links by `toolUseId`; without one the agent is a child of main (`agent:<aid>`).
    static func applyMeta(_ meta: AgentMeta, agentID aid: String, to s: inout SessionState, now: Date) {
        s.metas[aid] = meta
        if let tuid = nonEmpty(meta.toolUseID) {
            s.toolUseToAgent[tuid] = aid
            if let run = s.runs[tuid], run.isAgentCall {
                link(agentID: aid, toolUseID: tuid, in: &s)
            } else if let rid = s.agentToRun[aid], s.runs[rid] != nil {
                fillFromMeta(meta, &s.runs[rid]!)
            } else {
                if s.orphans[aid] == nil {
                    s.orphans[aid] = makeOrphan(aid, &s)
                    s.orphanSince[aid] = now
                }
                fillFromMeta(meta, &s.orphans[aid]!)
            }
            return
        }
        let rowID = SessionState.agentRowID(aid)
        if let rid = s.agentToRun[aid], rid != rowID, s.runs[rid] != nil {
            fillFromMeta(meta, &s.runs[rid]!)    // already linked to an Agent call
            return
        }
        var row = s.orphans.removeValue(forKey: aid) ?? s.runs[rowID] ?? makeOrphan(aid, &s)
        s.orphanSince[aid] = nil
        fillFromMeta(meta, &row)
        row.isFork = row.isFork || (meta.isFork ?? false) || row.own.isFork
        if row.agentType == "general-purpose", let type = nonEmpty(meta.agentType) { row.agentType = type }
        if s.runs[rowID] == nil { s.order.append(rowID) }
        s.runs[rowID] = row
        s.agentToRun[aid] = rowID
        flushPendingNotices(for: aid, in: &s)
    }

    private static func fillFromMeta(_ meta: AgentMeta, _ r: inout RunState) {
        if let model = nonEmpty(meta.model) { r.metaModel = model }
        if !r.isAgentCall {
            if let type = nonEmpty(meta.agentType), r.agentType == "general-purpose" { r.agentType = type }
            if r.description.isEmpty { r.description = meta.description ?? meta.name ?? "" }
        }
        if meta.isFork == true { r.isFork = true }
        if meta.requestShape == "background" { r.isBackground = true }
    }

    // MARK: Linking

    /// Links `agentId` to the Agent run `toolUseId`, merging any orphan or `agent:` row for that agent.
    static func link(agentID aid: String, toolUseID tuid: String, in s: inout SessionState) {
        s.toolUseToAgent[tuid] = aid
        guard var run = s.runs[tuid], run.isAgentCall else { return }
        if let prev = s.agentToRun[aid] {
            if prev == tuid {
                if run.agentID == nil { s.runs[tuid]?.agentID = aid }
                return
            }
            guard prev.hasPrefix("agent:") else { return }    // already claimed by another Agent call
        }
        run.agentID = aid
        if let prev = s.agentToRun[aid], let row = s.runs[prev] {
            merge(row, into: &run)
            s.runs[prev] = nil
            s.order.removeAll { $0 == prev }
            reparent(from: prev, to: run, in: &s)
        }
        if let orphan = s.orphans.removeValue(forKey: aid) {
            merge(orphan, into: &run)
            reparent(from: orphan.id, to: run, in: &s)
        }
        s.orphanSince[aid] = nil
        if let meta = s.metas[aid] { fillFromMeta(meta, &run) }
        s.agentToRun[aid] = tuid
        s.runs[tuid] = run
        flushPendingNotices(for: aid, in: &s)
    }

    /// Moves own-file state (and anything learned before linking) from an orphan/row into the Agent run.
    private static func merge(_ source: RunState, into target: inout RunState) {
        if !target.own.hasLines {
            target.own = source.own
        }
        target.metaModel = target.metaModel ?? source.metaModel
        target.isFork = target.isFork || source.isFork || source.own.isFork
        if target.prompt.isEmpty { target.prompt = source.prompt }
        if target.exact == nil, let exact = source.exact {
            target.exact = exact
            target.resultSummary = target.resultSummary ?? source.resultSummary
            target.exactUsage = target.exactUsage ?? source.exactUsage
        }
        target.appliedNotices.formUnion(source.appliedNotices)
        target.touch(source.lastActivityAt)
    }

    private static func reparent(from oldID: String, to run: RunState, in s: inout SessionState) {
        for id in s.order where s.runs[id]?.parentRunID == oldID {
            s.runs[id]?.parentRunID = run.id
            s.runs[id]?.depth = run.depth + 1
        }
    }

    private static func makeOrphan(_ aid: String, _ s: inout SessionState) -> RunState {
        let meta = s.metas[aid]
        var r = RunState(id: SessionState.agentRowID(aid), parentRunID: s.main.id, depth: 1, agentID: aid,
                         agentType: nonEmpty(meta?.agentType) ?? "general-purpose",
                         description: meta?.description ?? meta?.name ?? "", isAgentCall: false)
        if let meta { fillFromMeta(meta, &r) }
        return r
    }

    /// Shows orphans that have waited `grace` seconds (or all, with `force`, at the end of a cold load) as
    /// `agent:<aid>` children of main. Returns the next time an orphan becomes due.
    @discardableResult
    static func promoteOrphans(_ s: inout SessionState, now: Date, grace: TimeInterval = 5, force: Bool = false) -> Date? {
        var next: Date?
        for (aid, since) in s.orphanSince {
            guard let orphan = s.orphans[aid] else {
                s.orphanSince[aid] = nil
                continue
            }
            guard orphan.own.hasLines else { continue }    // meta only: wait for lines or the call
            if force || now.timeIntervalSince(since) >= grace {
                s.orphans[aid] = nil
                s.orphanSince[aid] = nil
                s.runs[orphan.id] = orphan
                s.order.append(orphan.id)
                s.agentToRun[aid] = orphan.id
                flushPendingNotices(for: aid, in: &s)
            } else {
                let due = since.addingTimeInterval(grace)
                next = next.map { min($0, due) } ?? due
            }
        }
        return next
    }

    // MARK: Helpers

    @discardableResult
    private static func withOwner<T>(_ owner: FileOwner, _ s: inout SessionState, now: Date,
                                     _ body: (inout RunState) -> T) -> T {
        switch owner {
        case .main:
            return body(&s.main)
        case .agent(let aid):
            if let rid = s.agentToRun[aid], s.runs[rid] != nil {
                return body(&s.runs[rid]!)
            }
            if s.orphans[aid] == nil {
                s.orphans[aid] = makeOrphan(aid, &s)
                s.orphanSince[aid] = now
            }
            return body(&s.orphans[aid]!)
        }
    }

    /// Session-level effects of a user/assistant/system line.
    private static func envelope(_ ctx: LineContext, owner: FileOwner, _ s: inout SessionState) {
        s.touch(ctx.timestamp)
        if owner == .main { s.closed = false }
        if let cwd = nonEmpty(ctx.cwd) {
            if owner == .main {
                if s.firstCwd == nil { s.firstCwd = cwd }
            } else if s.fallbackCwd == nil {
                s.fallbackCwd = cwd
            }
        }
        if owner == .main, let branch = nonEmpty(ctx.gitBranch) { s.gitBranch = branch }
    }

    /// Run-level bookkeeping for a line in the run's own file, including resume detection: a line newer than
    /// the finish signal reopens a finished subagent.
    private static func ownLine(_ r: inout RunState, _ ts: Date?, owner: FileOwner) {
        r.own.hasLines = true
        if let ts {
            if owner != .main {
                if let e = r.exact, ts > e.signalAt {
                    r.exact = nil
                    r.resultSummary = nil
                    r.exactUsage = nil
                }
                if let c = r.cancelled, ts > c.signalAt { r.cancelled = nil }
                if let f = r.own.fallback, ts > f.signalAt { r.own.fallback = nil }
            }
            if r.own.firstAt.map({ ts < $0 }) ?? true { r.own.firstAt = ts }
            if r.own.lastAt.map({ ts > $0 }) ?? true { r.own.lastAt = ts }
        }
        r.touch(ts)
    }

    private static func closeTool(_ r: inout RunState, id: String, at ts: Date?, isError: Bool) {
        guard r.own.openTools.remove(id) != nil else { return }
        if let i = r.own.recentTools.lastIndex(where: { $0.id == id }) {
            r.own.recentTools[i].endedAt = ts ?? r.own.recentTools[i].startedAt
            r.own.recentTools[i].isError = isError
        }
    }

    private static func closeAllTools(_ r: inout RunState, at ts: Date?) {
        guard !r.own.openTools.isEmpty else { return }
        for i in r.own.recentTools.indices where r.own.recentTools[i].endedAt == nil
            && r.own.openTools.contains(r.own.recentTools[i].id) {
            r.own.recentTools[i].endedAt = ts ?? r.own.recentTools[i].startedAt
        }
        r.own.openTools.removeAll()
    }

    static func titleLine(_ text: String) -> String { TextUtil.firstLine(text, limit: 120) }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func firstText(_ e: AssistantEvent) -> String? {
        for block in e.blocks { if case .text(let t) = block { return TextUtil.report(t) } }
        return nil
    }

    private static func subtract(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input - b.input, output: a.output - b.output,
                   cacheRead: a.cacheRead - b.cacheRead, cacheCreation: a.cacheCreation - b.cacheCreation)
    }
}
