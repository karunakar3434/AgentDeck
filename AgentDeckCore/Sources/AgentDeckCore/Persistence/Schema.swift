import Foundation
import GRDB

/// Migrations for the history database (architecture §11).
///
/// Migrations are append-only and named (`v1`, `v2`, …). A migration is never edited once it has shipped.
///
/// All `DOUBLE` time columns hold `Date.timeIntervalSinceReferenceDate` (seconds since 2001-01-01 UTC),
/// not Unix time. That makes `Date` values round-trip bit for bit, so stored file mtimes compare equal (`==`)
/// to freshly `stat`ed ones. To read them as Unix time in the sqlite3 shell, add 978307200.
enum HistorySchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE run_duration (
                  tool_use_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, agent_type TEXT NOT NULL,
                  model_family TEXT NOT NULL DEFAULT 'other', started_at DOUBLE NOT NULL, ended_at DOUBLE,
                  duration_ms INTEGER, is_exact BOOLEAN NOT NULL DEFAULT 0,
                  outcome TEXT);
                CREATE INDEX run_duration_estimator ON run_duration(agent_type, ended_at DESC) WHERE outcome = 'completed';

                CREATE TABLE history_task (
                  id TEXT PRIMARY KEY, status TEXT NOT NULL, project_name TEXT NOT NULL,
                  started_at DOUBLE NOT NULL, ended_at DOUBLE NOT NULL, transcript_path TEXT NOT NULL,
                  file_id INTEGER NOT NULL, file_size INTEGER NOT NULL, file_mtime DOUBLE NOT NULL,
                  snapshot BLOB NOT NULL);
                CREATE INDEX history_task_ended ON history_task(ended_at DESC);

                CREATE TABLE history_run (
                  task_id TEXT NOT NULL REFERENCES history_task(id) ON DELETE CASCADE,
                  id TEXT NOT NULL, ord INTEGER NOT NULL, agent_type TEXT NOT NULL, status TEXT NOT NULL,
                  snapshot BLOB NOT NULL,
                  PRIMARY KEY (task_id, id));

                CREATE TABLE scan_cache (
                  path TEXT PRIMARY KEY, session_id TEXT NOT NULL, file_id INTEGER NOT NULL,
                  size INTEGER NOT NULL, mtime DOUBLE NOT NULL, offset INTEGER NOT NULL);
                """)
        }

        // Workflow groups: the signals each task's sidebar entry is decided from (JSON `TaskSignals`), so a
        // rule change reclassifies history without reading transcripts. Nullable, so an older build can
        // still write rows.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE history_task ADD COLUMN signals TEXT")
            try backfillSignals(db)
        }

        // Tasks saved with no known start: see `deleteUndatedTasks`.
        migrator.registerMigration("v3") { db in
            try deleteUndatedTasks(db)
        }

        return migrator
    }

    /// `started_at` of a task saved with no known start. Older builds built a session no line had dated (a
    /// main transcript of metadata lines only) with a 1970-01-01 start, so History showed it running for
    /// decades.
    static let undatedStart = HistoryTime.column(Date(timeIntervalSince1970: 0))

    /// v3: deletes the tasks saved with `undatedStart`. Such a row holds no conversation: no prompt, no runs, no
    /// working folder, only a title. It isn't repairable either, because it was saved over the row of the real
    /// task with the same id. Run rows go first: migrations run with foreign keys off, so the cascade wouldn't.
    static func deleteUndatedTasks(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM history_run WHERE task_id IN (SELECT id FROM history_task WHERE started_at <= ?)",
                       arguments: [undatedStart])
        try db.execute(sql: "DELETE FROM history_task WHERE started_at <= ?", arguments: [undatedStart])
    }

    /// v2: fills `signals` for rows written before it, from what each row kept: the working folder, the
    /// title, the agent types, and the Skill and tool names among each agent's recent tool calls
    /// (`TaskSignals(snapshot:)`). A row that can't be decoded keeps NULL; reads recover it the same way.
    static func backfillSignals(_ db: Database) throws {
        let decoder = SnapshotCoding.makeDecoder()
        let encoder = SnapshotCoding.makeEncoder()
        var runsByTask: [String: [AgentRunSnapshot]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT task_id, snapshot FROM history_run ORDER BY task_id, ord") {
            let blob: Data = row["snapshot"]
            guard let run = try? decoder.decode(AgentRunSnapshot.self, from: blob) else { continue }
            runsByTask[row["task_id"], default: []].append(run)
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, snapshot FROM history_task WHERE signals IS NULL") {
            let id: String = row["id"]
            let blob: Data = row["snapshot"]
            guard var snapshot = try? decoder.decode(TaskSnapshot.self, from: blob) else { continue }
            snapshot.runs = runsByTask[id] ?? []
            let signals = String(decoding: try encoder.encode(TaskSignals(snapshot: snapshot)), as: UTF8.self)
            try db.execute(sql: "UPDATE history_task SET signals = ? WHERE id = ?", arguments: [signals, id])
        }
    }

    /// The tables created by the migrations, for tests and diagnostics.
    static let tableNames: Set<String> = ["run_duration", "history_task", "history_run", "scan_cache"]
}
