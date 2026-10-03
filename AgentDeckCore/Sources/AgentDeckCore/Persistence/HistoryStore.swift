import Foundation
import GRDB
import os
import Synchronization

// MARK: - Operations and rows (architecture §11a)

/// A buffered write. Writes are applied in enqueue order.
enum HistoryOp: Sendable {
    /// Upsert, COALESCE-merging a call row with its later result (see `RunDurationRecord.upsertSQL`).
    case runDuration(RunDurationRow)
    /// Upsert the task row and replace its run rows.
    case finishedTask(StoredTask)
    /// Delete a task and its runs.
    case removeTask(id: String)
    /// Upsert the scan progress of one main transcript.
    case scanCache(ScanCacheEntry)
}

/// One Agent call's duration record: an estimator sample once `outcome == "completed"`.
struct RunDurationRow: Sendable, Hashable {
    var toolUseID: String
    var sessionID: String
    var agentType: String
    var modelFamily: ModelFamily
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Int?
    var isExact: Bool
    /// "completed" | "failed" | "cancelled" | nil while unfinished.
    var outcome: String?
}

/// A finished task with the transcript identity it was built from.
struct StoredTask: Sendable, Hashable {
    /// With runs (`recentTools` trimmed to 20 when stored). Its `projectName` is the entry when it was
    /// saved; the engine decides the entry again from `signals`.
    var snapshot: TaskSnapshot
    /// What the task's sidebar entry is decided from.
    var signals: TaskSignals
    var transcriptPath: String
    var fileID: UInt64
    var fileSize: Int64
    var fileMtime: Date

    /// `signals` defaults to what the snapshot alone tells (`TaskSignals(snapshot:)`).
    init(snapshot: TaskSnapshot, signals: TaskSignals? = nil, transcriptPath: String, fileID: UInt64,
         fileSize: Int64, fileMtime: Date) {
        self.snapshot = snapshot
        self.signals = signals ?? TaskSignals(snapshot: snapshot)
        self.transcriptPath = transcriptPath
        self.fileID = fileID
        self.fileSize = fileSize
        self.fileMtime = fileMtime
    }
}

/// How far the estimate scan has read one main transcript.
struct ScanCacheEntry: Sendable, Hashable {
    var path: String
    var sessionID: String
    var fileID: UInt64
    var size: Int64
    var mtime: Date
    var offset: Int64
}

private let logger = Logger(subsystem: "com.karun.AgentDeck", category: "HistoryStore")

// MARK: - Store

/// The SQLite history database (architecture §11): estimator samples, finished tasks, and scan progress.
///
/// - Writes are buffered. `enqueue` appends under a lock and never touches the database. One drain task
///   sleeps until something is enqueued, waits up to 1 s to batch more, then writes the whole buffer in one
///   transaction, in enqueue order. When idle it sits suspended on an `AsyncStream`, with no timers.
/// - Reads and writes go through GRDB's own queues (WAL `DatabasePool`, or a `DatabaseQueue` in memory),
///   never on the caller's thread. Writes run in a detached task, so cancelling a caller (for example a
///   stopping source) can't abandon a write midway.
/// - `close()` flushes and stops the drain task. The store stays usable: a later `enqueue` restarts the
///   drain task. That matters because `shared(at:)` hands the same instance to the next source after a switch.
/// - Errors are logged and swallowed, and reads return empty results. In a write batch, an op that fails on
///   its own data is dropped without affecting the rest. A database-wide failure (busy, disk full, I/O)
///   puts the batch back in the buffer (at most `maxBufferedOps`) to retry on the next tick.
///
/// Only `shared(at:)` stores live for the whole process. Call `flush()` or `close()` before releasing any
/// other store, because ops still in the buffer at deinit are dropped.
final class HistoryStore: Sendable {
    /// `.ok`, or `.degraded("…")` when the database file couldn't be opened and this store is in memory.
    let health: SourceHealth
    /// The database file, or nil for an in-memory store.
    let databasePath: String?
    /// The underlying GRDB connection. Exposed for tests and diagnostics; use the methods below otherwise.
    let database: any DatabaseWriter

    private let state = Mutex(DrainState())

    private struct DrainState {
        var buffer: [HistoryOp] = []
        /// Wakes the drain task; nil while it isn't running.
        var signal: AsyncStream<Void>.Continuation?
        var drainTask: Task<Void, Never>?
        /// Consecutive batches that failed with a database-wide error (throttles logging).
        var failureStreak = 0
    }

    /// How long the drain task waits after the first enqueue before writing the batch.
    static let batchInterval: Duration = .seconds(1)
    /// The most ops kept while the database is unavailable. Beyond this, the oldest are dropped.
    static let maxBufferedOps = 5_000

    private init(database: any DatabaseWriter, path: String?, health: SourceHealth) {
        self.database = database
        self.databasePath = path
        self.health = health
    }

    deinit {
        state.withLock { state in
            state.signal?.finish()
            state.drainTask?.cancel()
        }
    }

    // MARK: Opening

    private static let registry = Mutex<[String: HistoryStore]>([:])

    /// The store for the database file at `url`: one instance per standardized path per process (thread safe).
    /// It opens and migrates synchronously on first use (about 10–20 ms), so call it off the main thread. If
    /// the file can't be opened, the store falls back as `open(at:)` describes.
    static func shared(at url: URL) -> HistoryStore {
        let key = url.standardizedFileURL.path
        return registry.withLock { stores in
            if let store = stores[key] { return store }
            let store = open(at: URL(fileURLWithPath: key))
            stores[key] = store
            return store
        }
    }

    /// An in-memory store (`DatabaseQueue`) for tests and as the fallback. Health `.ok`.
    static func inMemory() -> HistoryStore {
        HistoryStore(database: makeMemoryQueue(), path: nil, health: .ok)
    }

    /// Opens (creating the parent directory if needed) and migrates the database at `url`, without the
    /// shared registry. Prefer `shared(at:)`; this exists for tests that reopen a file.
    /// - Only a corrupt file (`SQLITE_CORRUPT`, `SQLITE_NOTADB`) is renamed to
    ///   `<name>.broken-<yyyyMMdd-HHmmss>` (with its `-wal`/`-shm`) and replaced by a fresh database.
    /// - Any other failure leaves the file untouched and gives an in-memory store with `health = .degraded`:
    ///   busy or locked, permissions, can't open, disk full, a failed migration, a parent path that isn't a
    ///   directory. The next launch tries the file again.
    /// - The same in-memory fallback applies if recreating after a rename fails.
    static func open(at url: URL) -> HistoryStore {
        let fileURL = url.standardizedFileURL
        var failure: any Error
        do {
            return HistoryStore(database: try openPool(at: fileURL), path: fileURL.path, health: .ok)
        } catch {
            failure = error
            logger.error("Opening \(fileURL.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }

        if shouldQuarantine(failure) {
            do {
                let moved = try quarantine(fileURL)
                logger.warning("Moved the unreadable history database to \(moved.path, privacy: .public)")
                return HistoryStore(database: try openPool(at: fileURL), path: fileURL.path, health: .ok)
            } catch {
                failure = error
                logger.error("Recreating \(fileURL.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }

        let reason = "History database unavailable (\(describe(failure))); history won't be saved this session."
        return HistoryStore(database: makeMemoryQueue(), path: nil, health: .degraded(reason))
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = "AgentDeck.History"
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 2
        config.busyMode = .timeout(2)
        return config
    }

    private static func openPool(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        do {
            try HistorySchema.migrator.migrate(pool)
        } catch {
            try? pool.close()
            throw error
        }
        return pool
    }

    private static func makeMemoryQueue() -> DatabaseQueue {
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(configuration: configuration())
        } catch {
            fatalError("Can't open an in-memory SQLite database: \(error)")
        }
        do {
            try HistorySchema.migrator.migrate(queue)
        } catch {
            logger.fault("Migrating the in-memory history database failed: \(String(describing: error), privacy: .public)")
        }
        return queue
    }

    /// Only real corruption justifies moving the user's file aside.
    private static func shouldQuarantine(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }   // e.g. creating the directory failed
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Renames the database and its `-wal`/`-shm` files to `<name>.broken-<yyyyMMdd-HHmmss>[-n]`.
    private static func quarantine(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.path).broken-\(formatter.string(from: Date()))"
        var destination = base
        var attempt = 1
        while fileManager.fileExists(atPath: destination) {
            attempt += 1
            destination = "\(base)-\(attempt)"
        }
        try fileManager.moveItem(atPath: url.path, toPath: destination)
        for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: url.path + suffix) {
            try? fileManager.moveItem(atPath: url.path + suffix, toPath: destination + suffix)
        }
        return URL(fileURLWithPath: destination)
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? DatabaseError { return error.message ?? "\(error.resultCode)" }
        return error.localizedDescription
    }

    // MARK: Writes

    /// Appends `op` to the write buffer. Synchronous; never blocks on I/O.
    func enqueue(_ op: HistoryOp) {
        state.withLock { state in
            state.buffer.append(op)
            // Otherwise a non-empty buffer already has a wake-up pending.
            if state.drainTask == nil || state.buffer.count == 1 { scheduleDrain(&state) }
        }
    }

    /// Writes everything enqueued before this call. It also happens automatically about 1 s after an enqueue.
    /// - On return the batch is committed. If the database is unavailable (locked by another process, disk
    ///   full, I/O error), the batch is back at the front of the buffer instead, and the drain task retries it
    ///   on its next tick. A flush never waits more than one busy timeout (2 s) on a locked database.
    /// - Even with an empty buffer, this waits its turn on the serialized writer, so a batch the drain task
    ///   already took is settled before `flush()` returns.
    @concurrent func flush() async {
        await Task.detached(priority: .utility) { [self] in await writeBuffer() }.value
    }

    /// Flushes and stops the drain task. Idempotent. The store stays usable: a later `enqueue` restarts the
    /// drain task. So does a flush that fails, so buffered ops keep being retried.
    @concurrent func close() async {
        let (task, signal) = state.withLock { state in
            defer { state.drainTask = nil; state.signal = nil }
            return (state.drainTask, state.signal)
        }
        signal?.finish()
        task?.cancel()    // interrupts the batching sleep; a write already started still completes
        await task?.value
        await flush()
    }

    /// Ops waiting to be written (for tests and diagnostics).
    var pendingOpCount: Int { state.withLock { $0.buffer.count } }

    /// Starts the drain task if needed and wakes it.
    private func scheduleDrain(_ state: inout DrainState) {
        if state.drainTask == nil { startDrainTask(&state) }
        state.signal?.yield()
    }

    private func startDrainTask(_ state: inout DrainState) {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.signal = continuation
        state.drainTask = Task.detached(priority: .utility) { [weak self] in
            for await _ in signals {
                try? await Task.sleep(for: HistoryStore.batchInterval)
                guard let self else { return }
                await self.flush()
            }
        }
    }

    /// Takes the buffer inside the write access. GRDB serializes writes, so concurrent flushes commit
    /// batches in enqueue order, and an op stays buffered until a write actually starts.
    private func writeBuffer() async {
        do {
            try await database.writeWithoutTransaction { db in
                let ops = self.state.withLock { state in
                    defer { state.buffer = [] }
                    return state.buffer
                }
                guard !ops.isEmpty else { return }
                let prepared = Self.prepare(ops)
                guard !prepared.isEmpty else { return }
                do {
                    try Self.write(prepared, in: db)
                    self.recordSuccess()
                } catch {
                    self.requeue(prepared.map(\.op), after: error)
                }
            }
        } catch {
            // No write access, so nothing was taken from the buffer. Try again on the next tick.
            logger.error("History write failed: \(String(describing: error), privacy: .public)")
            state.withLock { state in
                if !state.buffer.isEmpty { scheduleDrain(&state) }
            }
        }
    }

    /// An op with its SQL-ready records.
    private struct PreparedOp {
        enum Write {
            case runDuration(RunDurationRecord)
            case finishedTask(HistoryTaskRecord, [HistoryRunRecord])
            case removeTask(String)
            case scanCache(ScanCacheRecord)
        }
        var op: HistoryOp
        var write: Write
    }

    /// Encodes the JSON snapshots before any transaction opens. Ops that can't be encoded (for example a
    /// non-finite date) are dropped and logged here, so they can't fail a batch or come back on a retry.
    private static func prepare(_ ops: [HistoryOp]) -> [PreparedOp] {
        let encoder = SnapshotCoding.makeEncoder()
        var prepared: [PreparedOp] = []
        prepared.reserveCapacity(ops.count)
        var dropped = 0
        var lastError: (any Error)?
        for op in ops {
            let write: PreparedOp.Write
            switch op {
            case .runDuration(let row):
                write = .runDuration(RunDurationRecord(row))
            case .finishedTask(let task):
                do {
                    let (taskRecord, runRecords) = try task.records(encoder: encoder)
                    write = .finishedTask(taskRecord, runRecords)
                } catch {
                    dropped += 1
                    lastError = error
                    continue
                }
            case .removeTask(let id):
                write = .removeTask(id)
            case .scanCache(let entry):
                write = .scanCache(ScanCacheRecord(entry))
            }
            prepared.append(PreparedOp(op: op, write: write))
        }
        if let lastError {
            logger.error("Dropped \(dropped) history writes that can't be encoded: \(String(describing: lastError), privacy: .public)")
        }
        return prepared
    }

    /// Writes a batch in one IMMEDIATE transaction, so a locked database costs at most one busy timeout.
    /// Each op runs in a savepoint:
    /// - An op-specific error (constraint, too big, type mismatch) rolls back only that op, which is dropped
    ///   and logged.
    /// - Any other error is database-wide. It rolls back the whole batch and is rethrown so the caller can
    ///   requeue the batch.
    private static func write(_ prepared: [PreparedOp], in db: Database) throws {
        var dropped = 0
        var lastError: (any Error)?
        try db.inTransaction(.immediate) {
            for item in prepared {
                do {
                    try db.inSavepoint {
                        try apply(item.write, in: db)
                        return .commit
                    }
                } catch let error where isOpSpecific(error) {
                    dropped += 1
                    lastError = error
                }
            }
            return .commit
        }
        if let lastError {
            logger.error("Dropped \(dropped) of \(prepared.count) history writes: \(String(describing: lastError), privacy: .public)")
        }
    }

    /// Errors caused by one op's data rather than by the state of the database.
    private static func isOpSpecific(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else { return true }
        return [ResultCode.SQLITE_CONSTRAINT, .SQLITE_TOOBIG, .SQLITE_MISMATCH].contains(error.resultCode)
    }

    private static func apply(_ write: PreparedOp.Write, in db: Database) throws {
        switch write {
        case .runDuration(let record):
            try db.execute(sql: RunDurationRecord.upsertSQL, arguments: record.upsertArguments)
        case .finishedTask(let task, let runs):
            try task.upsert(db)
            try db.execute(sql: "DELETE FROM history_run WHERE task_id = ?", arguments: [task.id])
            for run in runs {
                try run.insert(db, onConflict: .ignore)    // a duplicate run id keeps its first occurrence
            }
        case .removeTask(let id):
            try db.execute(sql: "DELETE FROM history_task WHERE id = ?", arguments: [id])
        case .scanCache(let record):
            try record.upsert(db)
        }
    }

    /// Puts a batch that hit a database-wide error back at the front of the buffer, ahead of anything
    /// enqueued since. The buffer is capped at `maxBufferedOps` by dropping the oldest ops, and the drain
    /// task's next tick retries.
    private func requeue(_ ops: [HistoryOp], after error: any Error) {
        let (dropped, streak) = state.withLock { (state: inout DrainState) -> (Int, Int) in
            state.buffer.insert(contentsOf: ops, at: 0)
            let overflow = max(0, state.buffer.count - Self.maxBufferedOps)
            if overflow > 0 { state.buffer.removeFirst(overflow) }
            state.failureStreak += 1
            scheduleDrain(&state)
            return (overflow, state.failureStreak)
        }
        if streak == 1 || streak.isMultiple(of: 60) {
            logger.error("History write failed (attempt \(streak)); keeping \(ops.count) ops for retry: \(String(describing: error), privacy: .public)")
        }
        if dropped > 0 {
            logger.error("History write buffer is full; dropped the \(dropped) oldest ops")
        }
    }

    private func recordSuccess() {
        let streak = state.withLock { state in
            defer { state.failureStreak = 0 }
            return state.failureStreak
        }
        if streak > 0 {
            logger.notice("History writes recovered after \(streak) failed attempts")
        }
    }

    // MARK: Reads

    /// Completed samples (`outcome = 'completed'`, duration known), newest first: the newest `perTypeLimit`
    /// per agent type plus the newest `perTypeLimit` per (agent type, model family), with family `other`
    /// excluded because the estimator keeps no bucket for it. This is the same data the estimator's
    /// type and family buckets hold, so an `Estimator` rebuilt from it matches the live one. A rarely used
    /// family's bucket isn't lost behind newer runs of another family. That gives up to
    /// `perTypeLimit × (families + 1)` rows per type. `seconds = duration_ms / 1000`. A row without
    /// `ended_at` uses `started_at + duration`.
    @concurrent func loadSamples(perTypeLimit: Int) async -> [DurationSample] {
        await loadSampleRows(perTypeLimit: perTypeLimit).map(\.sample)
    }

    /// `loadSamples(perTypeLimit:)` with each sample's tool-use id (same rows, same order), so a caller can
    /// tell which runs the estimator already holds.
    @concurrent func loadSampleRows(perTypeLimit: Int) async -> [(toolUseID: String, sample: DurationSample)] {
        guard perTypeLimit > 0 else { return [] }
        do {
            return try await database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT tool_use_id, agent_type, model_family, duration_ms, end_time FROM (
                      SELECT tool_use_id, agent_type, model_family, duration_ms, end_time,
                             ROW_NUMBER() OVER (PARTITION BY agent_type
                                                ORDER BY end_time DESC, tool_use_id) AS type_rank,
                             ROW_NUMBER() OVER (PARTITION BY agent_type, model_family
                                                ORDER BY end_time DESC, tool_use_id) AS family_rank
                      FROM (
                        SELECT tool_use_id, agent_type, model_family, duration_ms,
                               COALESCE(ended_at, started_at + duration_ms / 1000.0) AS end_time
                        FROM run_duration
                        WHERE outcome = 'completed' AND duration_ms IS NOT NULL))
                    WHERE type_rank <= ?1 OR (model_family <> 'other' AND family_rank <= ?1)
                    ORDER BY end_time DESC, agent_type, tool_use_id
                    """, arguments: [perTypeLimit])
                return rows.map { row in
                    let durationMs: Int64 = row["duration_ms"]
                    let family: String = row["model_family"]
                    let sample = DurationSample(agentType: row["agent_type"],
                                                family: ModelFamily(rawValue: family) ?? .other,
                                                seconds: Double(durationMs) / 1000,
                                                endedAt: HistoryTime.date(row["end_time"]))
                    return (toolUseID: row["tool_use_id"], sample: sample)
                }
            }
        } catch {
            logger.error("Loading samples failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Finished tasks with `ended_at >= endedAfter`, newest `ended_at` first, each with its runs in stored
    /// order. A task whose row, or any of whose run rows, fails to decode is skipped as a whole, so the
    /// engine rebuilds it from the transcript (if any) rather than showing it with runs missing.
    @concurrent func loadHistory(endedAfter: Date) async -> [StoredTask] {
        let cutoff = HistoryTime.column(endedAfter)
        do {
            return try await database.read { db in
                let tasks = try HistoryTaskRecord.fetchAll(db, sql: """
                    SELECT * FROM history_task WHERE ended_at >= ? ORDER BY ended_at DESC, id
                    """, arguments: [cutoff])
                guard !tasks.isEmpty else { return [] }
                let runs = try HistoryRunRecord.fetchAll(db, sql: """
                    SELECT history_run.* FROM history_run
                    JOIN history_task ON history_task.id = history_run.task_id
                    WHERE history_task.ended_at >= ?
                    ORDER BY history_run.task_id, history_run.ord
                    """, arguments: [cutoff])
                let runsByTask = Dictionary(grouping: runs, by: \.taskID)
                let decoder = SnapshotCoding.makeDecoder()
                var skipped = 0
                let stored = tasks.compactMap { task in
                    let result = StoredTask(task: task, runs: runsByTask[task.id] ?? [], decoder: decoder)
                    if result == nil { skipped += 1 }
                    return result
                }
                if skipped > 0 {
                    logger.warning("Skipped \(skipped) history tasks that failed to decode")
                }
                return stored
            }
        } catch {
            logger.error("Loading history failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Every scan-cache row, keyed by path.
    @concurrent func loadScanCache() async -> [String: ScanCacheEntry] {
        do {
            return try await database.read { db in
                let records = try ScanCacheRecord.fetchAll(db)
                return Dictionary(records.map { ($0.path, $0.entry) }, uniquingKeysWith: { first, _ in first })
            }
        } catch {
            logger.error("Loading the scan cache failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    // MARK: Maintenance

    /// Deletes (§11):
    /// - `history_task` rows that ended before `now − max(historyWindow, 7 days)`, which cascades to their runs.
    ///   The floor stops a brief window shrink from deleting history.
    /// - `run_duration` rows older than 180 days, by `ended_at` (or `started_at` when unfinished).
    /// - `scan_cache` rows whose file no longer exists.
    @concurrent func prune(historyWindow: TimeInterval, now: Date) async {
        let day: TimeInterval = 86_400
        let taskCutoff = HistoryTime.column(now.addingTimeInterval(-max(historyWindow, 7 * day)))
        let sampleCutoff = HistoryTime.column(now.addingTimeInterval(-180 * day))
        do {
            let paths = try await database.read { db in
                try String.fetchAll(db, sql: "SELECT path FROM scan_cache")
            }
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
            try await database.write { db in
                try db.execute(sql: "DELETE FROM history_task WHERE ended_at < ?", arguments: [taskCutoff])
                try db.execute(sql: "DELETE FROM run_duration WHERE COALESCE(ended_at, started_at) < ?",
                               arguments: [sampleCutoff])
                for path in missing {
                    try db.execute(sql: "DELETE FROM scan_cache WHERE path = ?", arguments: [path])
                }
            }
        } catch {
            logger.error("Pruning history failed: \(String(describing: error), privacy: .public)")
        }
    }
}
