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

        return migrator
    }

    /// The tables created by the migrations, for tests and diagnostics.
    static let tableNames: Set<String> = ["run_duration", "history_task", "history_run", "scan_cache"]
}
