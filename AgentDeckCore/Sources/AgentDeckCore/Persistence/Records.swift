import Foundation
import GRDB

// GRDB records for the four history tables (see `HistorySchema`). They are internal to the
// persistence layer. The rest of the package uses `RunDurationRow`, `StoredTask` and `ScanCacheEntry`.

/// Time columns hold `Date.timeIntervalSinceReferenceDate`, so dates round-trip exactly.
enum HistoryTime {
    static func column(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }
    static func date(_ column: Double) -> Date { Date(timeIntervalSinceReferenceDate: column) }
}

/// JSON coding for snapshot blobs. Output is deterministic and compact (sorted keys, no pretty printing).
/// Dates are numeric seconds since the reference date (`.deferredToDate`). That is the same compact numeric
/// form as `.secondsSince1970`, but it round-trips a `Date` exactly. Decoding ignores unknown keys, and
/// missing optional fields decode as nil, so additive snapshot fields need no migration.
enum SnapshotCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    /// Runs keep at most this many recent tools in storage.
    static let recentToolsLimit = 20
}

struct RunDurationRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "run_duration"

    var toolUseID: String
    var sessionID: String
    var agentType: String
    var modelFamily: String
    var startedAt: Double
    var endedAt: Double?
    var durationMs: Int64?
    var isExact: Bool
    var outcome: String?

    enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id", sessionID = "session_id", agentType = "agent_type"
        case modelFamily = "model_family", startedAt = "started_at", endedAt = "ended_at"
        case durationMs = "duration_ms", isExact = "is_exact", outcome
    }

    init(_ row: RunDurationRow) {
        toolUseID = row.toolUseID
        sessionID = row.sessionID
        agentType = row.agentType
        modelFamily = row.modelFamily.rawValue
        startedAt = HistoryTime.column(row.startedAt)
        endedAt = row.endedAt.map(HistoryTime.column)
        durationMs = row.durationMs.map(Int64.init)
        isExact = row.isExact
        outcome = row.outcome
    }

    var row: RunDurationRow {
        RunDurationRow(
            toolUseID: toolUseID, sessionID: sessionID, agentType: agentType,
            modelFamily: ModelFamily(rawValue: modelFamily) ?? .other,
            startedAt: HistoryTime.date(startedAt), endedAt: endedAt.map(HistoryTime.date),
            durationMs: durationMs.flatMap { Int(exactly: $0) }, isExact: isExact, outcome: outcome)
    }

    /// Merges a call row (no outcome) with its later result, and repeated reports of the same run:
    /// - A NULL never overwrites a known value, and `model_family = 'other'` (unknown) never overwrites a known family.
    /// - `ended_at`, `duration_ms` and `outcome` take the new values unless the stored row is exact and the
    ///   new one isn't. So an exact duration replaces a fallback one, never the other way round, and a
    ///   later exact report (a resumed run) replaces an earlier one.
    /// - `is_exact` is OR-merged, and `started_at` keeps the earliest value.
    static let upsertSQL = """
        INSERT INTO run_duration
          (tool_use_id, session_id, agent_type, model_family, started_at, ended_at, duration_ms, is_exact, outcome)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(tool_use_id) DO UPDATE SET
          session_id = excluded.session_id,
          agent_type = excluded.agent_type,
          model_family = CASE WHEN excluded.model_family = 'other'
                              THEN run_duration.model_family ELSE excluded.model_family END,
          started_at = MIN(run_duration.started_at, excluded.started_at),
          ended_at = COALESCE(CASE WHEN excluded.is_exact OR NOT run_duration.is_exact THEN excluded.ended_at END,
                              run_duration.ended_at, excluded.ended_at),
          duration_ms = COALESCE(CASE WHEN excluded.is_exact OR NOT run_duration.is_exact THEN excluded.duration_ms END,
                                 run_duration.duration_ms, excluded.duration_ms),
          outcome = COALESCE(CASE WHEN excluded.is_exact OR NOT run_duration.is_exact THEN excluded.outcome END,
                             run_duration.outcome, excluded.outcome),
          is_exact = run_duration.is_exact OR excluded.is_exact
        """

    var upsertArguments: StatementArguments {
        [toolUseID, sessionID, agentType, modelFamily, startedAt, endedAt, durationMs, isExact, outcome]
    }
}

struct HistoryTaskRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "history_task"

    var id: String
    var status: String
    var projectName: String
    var startedAt: Double
    var endedAt: Double
    var transcriptPath: String
    var fileID: Int64
    var fileSize: Int64
    var fileMtime: Double
    /// JSON `TaskSnapshot` with `runs = []`.
    var snapshot: Data

    enum CodingKeys: String, CodingKey {
        case id, status, projectName = "project_name", startedAt = "started_at", endedAt = "ended_at"
        case transcriptPath = "transcript_path", fileID = "file_id", fileSize = "file_size"
        case fileMtime = "file_mtime", snapshot
    }
}

struct HistoryRunRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "history_run"

    var taskID: String
    var id: String
    var ord: Int
    var agentType: String
    var status: String
    /// JSON `AgentRunSnapshot` with at most 20 `recentTools`.
    var snapshot: Data

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id", id, ord, agentType = "agent_type", status, snapshot
    }
}

struct ScanCacheRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scan_cache"

    var path: String
    var sessionID: String
    var fileID: Int64
    var size: Int64
    var mtime: Double
    var offset: Int64

    enum CodingKeys: String, CodingKey {
        case path, sessionID = "session_id", fileID = "file_id", size, mtime, offset
    }

    init(_ entry: ScanCacheEntry) {
        path = entry.path
        sessionID = entry.sessionID
        fileID = Int64(bitPattern: entry.fileID)
        size = entry.size
        mtime = HistoryTime.column(entry.mtime)
        offset = entry.offset
    }

    var entry: ScanCacheEntry {
        ScanCacheEntry(path: path, sessionID: sessionID, fileID: UInt64(bitPattern: fileID), size: size,
                       mtime: HistoryTime.date(mtime), offset: offset)
    }
}

extension StoredTask {
    /// The task row (snapshot without runs) and one row per run, `ord` = index in `snapshot.runs`.
    /// `fileID` is stored as its bit pattern: it can exceed `Int64.max` (`st_dev << 48`).
    func records(encoder: JSONEncoder) throws -> (task: HistoryTaskRecord, runs: [HistoryRunRecord]) {
        var header = snapshot
        header.runs = []
        let task = HistoryTaskRecord(
            id: snapshot.id, status: snapshot.status.rawValue, projectName: snapshot.projectName,
            startedAt: HistoryTime.column(snapshot.startedAt),
            endedAt: HistoryTime.column(snapshot.endedAt ?? snapshot.lastActivityAt),
            transcriptPath: transcriptPath, fileID: Int64(bitPattern: fileID), fileSize: fileSize,
            fileMtime: HistoryTime.column(fileMtime), snapshot: try encoder.encode(header))
        let runs = try snapshot.runs.enumerated().map { index, run in
            var run = run
            if run.recentTools.count > SnapshotCoding.recentToolsLimit {
                run.recentTools = Array(run.recentTools.suffix(SnapshotCoding.recentToolsLimit))
            }
            return HistoryRunRecord(taskID: snapshot.id, id: run.id, ord: index, agentType: run.agentType,
                                    status: run.status.rawValue, snapshot: try encoder.encode(run))
        }
        return (task, runs)
    }

    /// Reassembles a stored task; nil when the task row or any of its run rows fails to decode.
    init?(task: HistoryTaskRecord, runs: [HistoryRunRecord], decoder: JSONDecoder) {
        guard var snapshot = try? decoder.decode(TaskSnapshot.self, from: task.snapshot) else { return nil }
        var decoded: [AgentRunSnapshot] = []
        decoded.reserveCapacity(runs.count)
        for row in runs {
            guard let run = try? decoder.decode(AgentRunSnapshot.self, from: row.snapshot) else { return nil }
            decoded.append(run)
        }
        snapshot.runs = decoded
        self.init(snapshot: snapshot, transcriptPath: task.transcriptPath,
                  fileID: UInt64(bitPattern: task.fileID), fileSize: task.fileSize,
                  fileMtime: HistoryTime.date(task.fileMtime))
    }
}
