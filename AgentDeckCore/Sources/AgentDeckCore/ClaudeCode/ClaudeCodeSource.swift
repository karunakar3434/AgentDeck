import Foundation

/// Live Claude Code tasks from the transcripts under `~/.claude` (read-only; architecture §3).
///
/// A let-only facade over `TranscriptEngine`. The first `updates()` call starts the engine: it opens the
/// history database, starts FSEvents and loads existing sessions in tiers (live first), emitting each task
/// as soon as it is parsed. `stop()` (or cancelling the consumer) stops everything and flushes history writes.
public final class ClaudeCodeSource: AgentSource {
    public struct Configuration: Sendable {
        /// Claude Code's config directory (`~/.claude`).
        public var dataRoot: URL
        /// Finished tasks older than this aren't emitted.
        public var historyWindow: TimeInterval
        /// The history database (created with its directory on first use).
        public var databaseURL: URL
        /// "Quiet for 2 min": no process and no growth for this long means done.
        public var quietInterval: TimeInterval = 120
        /// Tier-1 load scope and the fallback sweep's file scope.
        public var recentWindow: TimeInterval = 600

        public init(dataRoot: URL, historyWindow: TimeInterval) {
            self.dataRoot = dataRoot
            self.historyWindow = historyWindow
            self.databaseURL = Self.defaultDatabaseURL
        }

        /// `~/Library/Application Support/AgentDeck/agentdeck.sqlite`.
        public static var defaultDatabaseURL: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return base.appendingPathComponent("AgentDeck", isDirectory: true).appendingPathComponent("agentdeck.sqlite")
        }
    }

    public let configuration: Configuration
    let engine: TranscriptEngine

    public init(configuration: Configuration) {
        self.configuration = configuration
        engine = TranscriptEngine(configuration: configuration, environment: nil)
    }

    /// Tests: injected clock, process probe, history store, and FSEvents on/off.
    init(configuration: Configuration, environment: CoreEnvironment) {
        self.configuration = configuration
        engine = TranscriptEngine(configuration: configuration, environment: environment)
    }

    public func updates() async -> AsyncStream<DeckUpdate> {
        await engine.updates()
    }

    public func stop() async {
        await engine.stop()
    }
}

/// The engine's external dependencies (architecture §3 "Internal seams", §15).
struct CoreEnvironment: Sendable {
    var clock: any DeckClock
    var probe: any ProcessProbe
    var history: HistoryStore
    /// FSEvents, the fallback sweep and the hourly prune. Off in tests, which drive `handle(_:)` directly.
    var watchFileSystem: Bool
    /// Tier-3 background duration scan after the initial load.
    var runsEstimateScan: Bool = true

    init(clock: any DeckClock, probe: any ProcessProbe, history: HistoryStore, watchFileSystem: Bool,
         runsEstimateScan: Bool = true) {
        self.clock = clock
        self.probe = probe
        self.history = history
        self.watchFileSystem = watchFileSystem
        self.runsEstimateScan = runsEstimateScan
    }
}
