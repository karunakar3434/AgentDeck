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
    /// With runs (`recentTools` trimmed to 20 when stored).
    var snapshot: TaskSnapshot
    var transcriptPath: String
    var fileID: UInt64
    var fileSize: Int64
    var fileMtime: Date
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
/// - Errors are logged and swallowed. Reads return empty results, and a failing write batch is retried one
///   op per transaction, so one bad op can't sink the rest.
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
    }

    /// How long the drain task waits after the first enqueue before writing the batch.
    static let batchInterval: Duration = .seconds(1)

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
    /// - A corrupt or unreadable file (any failure other than busy, locked, permission, read-only, full,
    ///   out of memory, or can't-open) is renamed to `<name>.broken-<yyyyMMdd-HHmmss>` (with its `-wal`/`-shm`)
    ///   and a fresh database is created.
    /// - If that also fails, the store is in memory with `health = .degraded`.
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

    /// Environmental failures, where renaming the file wouldn't help or would hide a transient condition.
    private static func shouldQuarantine(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }   // e.g. creating the directory failed
        let keep: [ResultCode] = [.SQLITE_BUSY,.SQLITE_LOCKED, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_FULL,
                                     .SQLITE_NOMEM, .SQLITE_CANTOPEN, .SQLITE_AUTH]
        return !keep.contains(error.resultCode)
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
            if state.drainTask == nil {
                startDrainTask(&state)
                state.signal?.yield()
            } else if state.buffer.count == 1 {
                state.signal?.yield()   // a non-empty buffer already has a wake-up pending
            }
        }
    }

    /// Writes everything enqueued before this call; on return it is committed. Also done automatically about
    /// 1 s after an enqueue. Even with an empty buffer this waits its turn on the serialized writer, so a batch
    /// the drain task already took is committed before `flush()` returns.
    @concurrent func flush() async {
        await Task.detached(priority: .utility) { [self] in await writeBuffer() }.value
    }

    /// Flushes and stops the drain task. Idempotent. The store stays usable, and a later `enqueue`
    /// restarts the drain task.
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
                Self.apply(ops, in: db)
            }
        } catch {
            logger.error("History write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Applies a batch in one transaction. If that fails, retries each op in its own transaction, dropping
    /// (and logging) only the ops that still fail.
    private static func apply(_ ops: [HistoryOp], in db: Database) {
        let encoder = SnapshotCoding.makeEncoder()
        do {
            try db.inTransaction {
                for op in ops { try apply(op, in: db, encoder: encoder) }
                return .commit
            }
        } catch {
            guard ops.count > 1 else {
                logger.error("Dropped a history write: \(String(describing: error), privacy: .public)")
                return
            }
            // Isolate the failing op(s) so the rest of the batch still lands.
            var dropped = 0
            var lastError = error
            for op in ops {
                do {
                    try db.inTransaction {
                        try apply(op, in: db, encoder: encoder)
                        return .commit
                    }
                } catch {
                    dropped += 1
                    lastError = error
                }
            }
            if dropped > 0 {
                logger.error("Dropped \(dropped) of \(ops.count) history writes: \(String(describing: lastError), privacy: .public)")
            }
        }
    }

    private static func apply(_ op: HistoryOp, in db: Database, encoder: JSONEncoder) throws {
        switch op {
        case .runDuration(let row):
            let record = RunDurationRecord(row)
            try db.execute(sql: RunDurationRecord.upsertSQL, arguments: record.upsertArguments)
        case .finishedTask(let task):
            let (taskRecord, runRecords) = try task.records(encoder: encoder)
            try taskRecord.upsert(db)
            try db.execute(sql: "DELETE FROM history_run WHERE task_id = ?", arguments: [taskRecord.id])
            for run in runRecords {
                try run.insert(db, onConflict: .ignore)    // a duplicate run id keeps its first occurrence
            }
        case .removeTask(let id):
            try db.execute(sql: "DELETE FROM history_task WHERE id = ?", arguments: [id])
        case .scanCache(let entry):
            try ScanCacheRecord(entry).upsert(db)
        }
    }

    // MARK: Reads

    /// Completed samples (`outcome = 'completed'`, duration known), newest first, at most `perTypeLimit` per
    /// agent type. `seconds = duration_ms / 1000`. A row without `ended_at` uses `started_at + duration`.
    @concurrent func loadSamples(perTypeLimit: Int) async -> [DurationSample] {
        guard perTypeLimit > 0 else { return [] }
        do {
            return try await database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT agent_type, model_family, duration_ms, end_time FROM (
                      SELECT tool_use_id, agent_type, model_family, duration_ms,
                             COALESCE(ended_at, started_at + duration_ms / 1000.0) AS end_time,
                             ROW_NUMBER() OVER (
                               PARTITION BY agent_type
                               ORDER BY COALESCE(ended_at, started_at + duration_ms / 1000.0) DESC, tool_use_id
                             ) AS rank
                      FROM run_duration
                      WHERE outcome = 'completed' AND duration_ms IS NOT NULL)
                    WHERE rank <= ?
                    ORDER BY end_time DESC, agent_type, tool_use_id
                    """, arguments: [perTypeLimit])
                return rows.map { row in
                    let durationMs: Int64 = row["duration_ms"]
                    let family: String = row["model_family"]
                    return DurationSample(agentType: row["agent_type"],
                                          family: ModelFamily(rawValue: family) ?? .other,
                                          seconds: Double(durationMs) / 1000,
                                          endedAt: HistoryTime.date(row["end_time"]))
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
