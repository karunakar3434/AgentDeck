import Foundation
import os

/// Tier-3 background duration scan (architecture §10): reads every main transcript whose `scan_cache` row
/// doesn't match, extracts one `run_duration` row per Agent call, and records its progress.
///
/// - Only main transcripts: `resolvedModel` is on the parent's result, and exact durations come from
///   `totalDurationMs` (foreground) and `<duration_ms>` (background notifications).
/// - Files the engine has parsed are skipped (the engine writes their rows and `scan_cache` itself).
/// - A changed file is re-read from 0, so every Agent call has its context; rows are upserts keyed by
///   tool-use id, so re-reading never duplicates samples.
/// - Uses its own `LineParser` in `.durations` mode (Agent lines, results and notifications only).
actor EstimateScanner {
    struct Result: Sendable {
        var filesScanned = 0
        var bytesRead: Int64 = 0
        var rows = 0
        /// Completed runs with a duration, with their tool-use ids.
        var samples: [(toolUseID: String, sample: DurationSample)] = []
    }

    static let batchSize = 200
    private static let logger = Logger(subsystem: "com.karun.AgentDeck", category: "EstimateScanner")

    let projectsPath: String
    let history: HistoryStore
    let skip: Set<String>
    private let parser = LineParser(mode: .durations)
    private var reader = IncrementalReader()

    init(projectsPath: String, history: HistoryStore, skip: Set<String>) {
        self.projectsPath = projectsPath
        self.history = history
        self.skip = skip
    }

    func run() async -> Result {
        var result = Result()
        let cache = await history.loadScanCache()
        var pending = 0
        for dir in FileIO.list(projectsPath).sorted() {
            let dirPath = (projectsPath as NSString).appendingPathComponent(dir)
            guard FileStat.of(path: dirPath)?.isDirectory == true else { continue }
            for name in FileIO.list(dirPath).sorted() where name.hasSuffix(".jsonl") {
                if Task.isCancelled { return result }
                let path = (dirPath as NSString).appendingPathComponent(name)
                guard !skip.contains(path), let st = FileStat.of(path: path), !st.isDirectory else { continue }
                if let c = cache[path], c.fileID == st.fileID, c.size == st.size, c.mtime == st.mtime { continue }
                let sessionID = String(name.dropLast(6))
                let (rows, consumed) = scan(path: path, sessionID: sessionID, stat: st)
                result.filesScanned += 1
                result.bytesRead += consumed
                for row in rows {
                    history.enqueue(.runDuration(row))
                    if row.outcome == "completed", let ms = row.durationMs {
                        result.samples.append((row.toolUseID, DurationSample(
                            agentType: row.agentType, family: row.modelFamily, seconds: Double(ms) / 1000,
                            endedAt: row.endedAt ?? row.startedAt.addingTimeInterval(Double(ms) / 1000))))
                    }
                }
                history.enqueue(.scanCache(ScanCacheEntry(path: path, sessionID: sessionID, fileID: st.fileID,
                                                          size: st.size, mtime: st.mtime, offset: consumed)))
                result.rows += rows.count
                pending += rows.count
                if pending >= Self.batchSize {
                    pending = 0
                    await history.flush()
                }
                await Task.yield()
            }
        }
        await history.flush()
        Self.logger.info("Scanned \(result.filesScanned) transcripts, \(result.rows) Agent calls")
        return result
    }

    /// Reads one main transcript from 0 and reduces it to duration rows. Returns the bytes consumed.
    private func scan(path: String, sessionID: String, stat: FileStat) -> ([RunDurationRow], Int64) {
        var file = FileState(path: path, role: .main(sessionID: sessionID), fileID: stat.fileID)
        var reducer = DurationReducer(sessionID: sessionID)
        let parser = self.parser
        _ = reader.read(&file) { line in
            if let event = parser.parse(line) { reducer.apply(event) }
        }
        return (reducer.rows(), file.offset)
    }
}

/// The scanner's ~10-line reducer: Agent calls, Agent results and notifications.
struct DurationReducer {
    struct Call {
        var agentType: String
        var startedAt: Date
        var callModel: String?
        var resolvedModel: String?
        var outcome: String?
        var endedAt: Date?
        var durationMs: Int?
        var isExact = false
    }

    let sessionID: String
    var mainModel: String?
    var calls: [String: Call] = [:]
    var order: [String] = []
    var agentToCall: [String: String] = [:]
    /// Notices already applied (each arrives up to three times; the first delivery's time counts).
    var appliedNotices: Set<String> = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .assistant(let e):
            if let model = e.model { mainModel = model }
            for case .toolUse(let t) in e.blocks {
                guard let call = t.agentCall, calls[t.id] == nil, let ts = e.context.timestamp else { continue }
                calls[t.id] = Call(agentType: call.subagentType.flatMap { $0.isEmpty ? nil : $0 } ?? "general-purpose",
                                   startedAt: ts, callModel: call.model)
                order.append(t.id)
            }
        case .user(let e):
            let ts = e.context.timestamp
            for r in e.toolResults {
                guard var call = calls[r.toolUseID] else { continue }
                if let ar = r.agentResult {
                    if let aid = ar.agentID { agentToCall[aid] = r.toolUseID }
                    if let m = ar.resolvedModel, !m.isEmpty { call.resolvedModel = m }
                    if ar.status == "completed" {
                        let signal = ts ?? call.startedAt
                        call.outcome = "completed"
                        call.durationMs = ar.totalDurationMs
                        call.isExact = ar.totalDurationMs != nil
                        call.endedAt = SessionReducer.exactEnd(startedAt: call.startedAt, durationMs: ar.totalDurationMs, signal: signal)
                    }
                } else if r.isError {
                    call.outcome = "failed"
                    call.endedAt = ts
                }
                calls[r.toolUseID] = call
            }
            for n in e.notices { apply(n, at: ts) }
        case .notices(let notices, let ts):
            for n in notices { apply(n, at: ts) }
        default:
            break
        }
    }

    private mutating func apply(_ n: TaskNotice, at ts: Date?) {
        guard !appliedNotices.contains(n.identity) else { return }
        var id: String?
        if let tuid = n.toolUseID, calls[tuid] != nil {
            id = tuid
            if let aid = n.taskID { agentToCall[aid] = tuid }
        } else if let aid = n.taskID {
            id = agentToCall[aid]
        }
        guard let id, var call = calls[id] else { return }
        appliedNotices.insert(n.identity)
        let signal = ts ?? call.startedAt
        switch n.status {
        case "completed":
            call.outcome = "completed"
            call.durationMs = n.durationMs
            call.isExact = n.durationMs != nil
            call.endedAt = SessionReducer.exactEnd(startedAt: call.startedAt, durationMs: n.durationMs, signal: signal)
        case "failed", "killed", "error", "stopped", "cancelled":
            call.outcome = "failed"
            call.durationMs = n.durationMs
            call.endedAt = signal
        default:
            return
        }
        calls[id] = call
    }

    func rows() -> [RunDurationRow] {
        order.compactMap { id in
            guard let c = calls[id] else { return nil }
            let family = ModelFamily(modelID: c.resolvedModel ?? usable(c.callModel) ?? mainModel)
            return RunDurationRow(toolUseID: id, sessionID: sessionID, agentType: c.agentType, modelFamily: family,
                                  startedAt: c.startedAt, endedAt: c.endedAt, durationMs: c.durationMs,
                                  isExact: c.isExact, outcome: c.outcome)
        }
    }

    private func usable(_ model: String?) -> String? {
        guard let m = model, !m.isEmpty, m.lowercased() != "inherit" else { return nil }
        return m
    }
}

extension TranscriptEngine {
    /// Tier 3: the background duration scan, then an estimator rebuild from the DB.
    func startEstimateScan() {
        guard let history, scanTask == nil else { return }
        let scanner = EstimateScanner(projectsPath: projectsPath, history: history, skip: parsedMainPaths)
        scanTask = Task(priority: .background) { [weak self] in
            let result = await scanner.run()
            guard !Task.isCancelled, result.rows > 0 else { return }
            await self?.scanFinished(result)
        }
    }

    /// Rebuilds the estimator from the DB (the scan's rows are there, keyed by tool-use id) and re-dirties
    /// every task whose estimates depend on it.
    func scanFinished(_ result: EstimateScanner.Result) async {
        sampledRuns.formUnion(result.samples.map(\.toolUseID))
        await reloadEstimator()
    }

    /// Runs the scan to completion (tests).
    func runEstimateScan() async -> EstimateScanner.Result {
        guard let history else { return EstimateScanner.Result() }
        let scanner = EstimateScanner(projectsPath: projectsPath, history: history, skip: parsedMainPaths)
        let result = await scanner.run()
        if result.rows > 0 { await scanFinished(result) }
        return result
    }
}
