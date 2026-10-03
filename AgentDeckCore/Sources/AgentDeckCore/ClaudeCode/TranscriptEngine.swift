import Foundation
import os

/// The only mutator of session state (architecture §1). Owns the file table, every `SessionState`, the pid
/// table, the agent-definition cache, the in-memory `Estimator`, the `UpdateCoalescer`, the sweep and
/// deadline timers and the stream continuation.
///
/// Reading, parsing and applying one file is a single synchronous step with no `await`, so actor
/// reentrancy can never interleave two reads of the same file. The engine yields only between files.
actor TranscriptEngine {
    static let logger = Logger(subsystem: "com.karun.AgentDeck", category: "TranscriptEngine")
    static let orphanGrace: TimeInterval = 5
    static let removalGrace: TimeInterval = 2
    static let samplesPerType = 50

    struct SessionFiles: Sendable {
        var main: String?
        /// agentId → path
        var metas: [String: String] = [:]
        var subagents: [String: String] = [:]
        var title: String?

        var all: [String] {
            var paths: [String] = []
            if let main { paths.append(main) }
            paths.append(contentsOf: metas.values.sorted())
            paths.append(contentsOf: subagents.values.sorted())
            if let title { paths.append(title) }
            return paths
        }
    }

    struct PidEntry: Sendable {
        var sessionID: String?
        var status: String?
        var procStart: String?
        var startedAt: Int64?
        var alive = false
        var watch: ExitWatch?
        var stat: FileStat?
    }

    // MARK: Configuration and dependencies

    let configuration: ClaudeCodeSource.Configuration
    let clock: any DeckClock
    let probe: any ProcessProbe
    let watchFileSystem: Bool
    let runsEstimateScan: Bool
    let classifier: PathClassifier
    /// Standardized data root.
    let rootPath: String
    var history: HistoryStore?
    var health: SourceHealth = .ok

    // MARK: Files

    var files: [String: FileState] = [:]
    var sessionFiles: [String: SessionFiles] = [:]
    /// Main transcript path per session id, from directory listings (sessions not necessarily loaded).
    var mainPathIndex: [String: String] = [:]
    /// Older duplicates of a relocated session's main file (newest mtime wins).
    var superseded: Set<String> = []
    /// Paths found missing, re-checked after the removal grace.
    var missingChecks: [String: Date] = [:]
    var projectDirMtimes: [String: Date] = [:]
    var subagentDirMtimes: [String: Date] = [:]
    var hookFile: FileState?
    var reader = IncrementalReader()
    let parser = LineParser()
    let sidecarDecoder = JSONDecoder()

    // MARK: Sessions

    var sessions: [String: SessionState] = [:]
    /// Finished tasks shown from the history DB without parsing (tier 2), by id.
    var storedTasks: [String: StoredTask] = [:]
    /// History rows loaded at start, consumed by the initial load.
    var storedHistory: [String: StoredTask] = [:]
    var pids: [Int32: PidEntry] = [:]
    var pidBySession: [String: Int32] = [:]
    var definitions: AgentDefinitions

    // MARK: Emission

    var coalescer = UpdateCoalescer()
    var continuation: AsyncStream<DeckUpdate>.Continuation?
    var stream: AsyncStream<DeckUpdate>?
    var lastStatus: [String: StatusRules.Result] = [:]
    var deadlines: [String: Date] = [:]
    var timerTask: Task<Void, Never>?
    var timerDeadline: Date?
    var flushTask: Task<Void, Never>?

    // MARK: Estimates and history

    var estimator = Estimator()
    /// The estimator's samples by type (for estimates that leave out a run's own sample).
    var samplesByType: [String: [DurationSample]] = [:]
    /// Bumps whenever the estimator changes.
    var estimatorGeneration = 0
    var exclusionCache: [String: (generation: Int, estimate: DurationEstimate)] = [:]
    /// Tool-use ids whose duration sample is in the in-memory estimator (live additions).
    var sampledRuns: Set<String> = []
    /// Last outcome written to `run_duration` per Agent run ("" = unfinished).
    var recordedRuns: [String: String] = [:]
    /// Last history signature written per finished task.
    var savedTasks: [String: String] = [:]
    /// Main transcripts parsed by the engine (the estimate scanner skips them).
    var parsedMainPaths: Set<String> = []
    /// Non-nil while the estimator is being rebuilt from the DB: live samples taken meanwhile.
    var samplesDuringReload: [DurationSample]?

    // MARK: Lifecycle

    var prepared = false
    var initialLoadStarted = false
    var initialLoadComplete = false
    /// Runs finishing from now on add live estimator samples (set once the cold load has recorded its rows).
    var liveSampling = false
    var stopped = false
    var watcher: FSEventsWatcher?
    var watcherPaths: [String] = []
    var watchTask: Task<Void, Never>?
    var sweepTask: Task<Void, Never>?
    var scanTask: Task<Void, Never>?
    var pruneTask: Task<Void, Never>?
    var startTask: Task<Void, Never>?
    /// Debug: when the first task and the load-complete batch were emitted.
    var firstEmissionAt: Date?

    init(configuration: ClaudeCodeSource.Configuration, environment: CoreEnvironment?) {
        self.configuration = configuration
        clock = environment?.clock ?? SystemClock()
        probe = environment?.probe ?? DarwinProcessProbe()
        history = environment?.history
        watchFileSystem = environment?.watchFileSystem ?? true
        runsEstimateScan = environment?.runsEstimateScan ?? true
        classifier = PathClassifier(dataRoot: configuration.dataRoot)
        rootPath = classifier.canonicalRoot
        definitions = AgentDefinitions(dataRoot: classifier.canonicalRoot)
    }

    deinit {
        // A source released without stop(): don't leave the FSEvents stream or timers running.
        watcher?.stop()
        for task in [watchTask, sweepTask, timerTask, flushTask, scanTask, pruneTask, startTask] { task?.cancel() }
        for entry in pids.values { entry.watch?.cancel() }
        continuation?.finish()
    }

    var projectsPath: String { (rootPath as NSString).appendingPathComponent("projects") }
    var sessionsPath: String { (rootPath as NSString).appendingPathComponent("sessions") }
    var hookPath: String { (rootPath as NSString).appendingPathComponent("agentdeck/events.jsonl") }

    // MARK: Stream and lifecycle

    /// Starts the engine on first call; later calls return the same stream.
    func updates() -> AsyncStream<DeckUpdate> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream.makeStream(of: DeckUpdate.self, bufferingPolicy: .bufferingOldest(1))
        self.stream = stream
        if stopped {
            continuation.finish()
            return stream
        }
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        startTask = Task { [weak self] in await self?.run() }
        return stream
    }

    private func run() async {
        await prepare()
        guard !stopped else { return }
        if watchFileSystem { ensureWatcher() }
        await loadInitial()
        guard !stopped else { return }
        if watchFileSystem {
            startSweeper()
            startPruning()
        }
        if runsEstimateScan { startEstimateScan() }
    }

    /// Opens the history store and loads estimator samples and window history (cold-load step 2).
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        if history == nil {
            try? FileManager.default.createDirectory(at: configuration.databaseURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            history = HistoryStore.shared(at: configuration.databaseURL)
        }
        guard let history else { return }
        let now = clock.now()
        async let samples = history.loadSamples(perTypeLimit: Self.samplesPerType)
        async let stored = history.loadHistory(endedAfter: now.addingTimeInterval(-configuration.historyWindow))
        setEstimatorSamples(await samples)
        for task in await stored where storedHistory[task.snapshot.id] == nil {
            storedHistory[task.snapshot.id] = task
        }
        updateHealth()
    }

    /// Health = the data folder exists, and the history DB opened (else `.degraded`). Reported in the next
    /// batch when degraded or changed.
    func updateHealth() {
        let new: SourceHealth
        if FileStat.of(path: rootPath)?.isDirectory != true {
            new = .degraded("Claude Code data folder not found: \(rootPath)")
        } else {
            new = history?.health ?? .ok
        }
        let changed = new != health
        health = new
        guard changed || new != .ok else { return }
        if coalescer.setHealth(new) { scheduleFlush() }
    }

    /// Idempotent: stops FSEvents, timers and the scanner, flushes pending DB writes, finishes the stream.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        watcher?.stop()
        watcher = nil
        for task in [watchTask, sweepTask, timerTask, flushTask, scanTask, pruneTask, startTask] { task?.cancel() }
        for entry in pids.values { entry.watch?.cancel() }
        continuation?.finish()
        continuation = nil
        await history?.flush()
    }

    // MARK: Test seams

    /// The current snapshot of a task (nil when unknown or out of scope).
    func snapshot(_ id: String) -> TaskSnapshot? {
        build(id, now: clock.now())
    }

    /// Every task in scope, by id.
    func allSnapshots() -> [TaskSnapshot] {
        let now = clock.now()
        let ids = Set(sessions.keys).union(storedTasks.keys)
        return ids.sorted().compactMap { build($0, now: now) }
    }

    func sessionState(_ id: String) -> SessionState? { sessions[id] }
    func fileState(_ path: String) -> FileState? { files[path] }
    var isInitialLoadComplete: Bool { initialLoadComplete }
    var currentEstimator: Estimator { estimator }
    var batchesEmitted: Int { coalescer.batchesEmitted }

    // MARK: Change handling

    /// Processes one FSEvents batch: pid files, main transcripts, metas, subagent transcripts, then
    /// titles/hooks/definitions/directories, yielding between files.
    func handle(_ changes: [FSChange]) async {
        guard !stopped else { return }
        if changes.contains(where: \.needsFullSweep) { await sweep(full: true) }
        var seen = Set<String>()
        var items: [(priority: Int, index: Int, path: String, role: FileRole)] = []
        for (index, change) in changes.enumerated() {
            let path = classifier.canonical(change.path)
            guard seen.insert(path).inserted else { continue }
            let role = classifier.classify(path)
            guard let priority = Self.priority(role) else { continue }
            items.append((priority, index, path, role))
        }
        items.sort { ($0.priority, $0.index) < ($1.priority, $1.index) }
        for item in items {
            guard !stopped else { return }
            process(item.path, role: item.role)
            await Task.yield()
        }
    }

    private static func priority(_ role: FileRole) -> Int? {
        switch role {
        case .pid: 0
        case .main: 1
        case .meta: 2
        case .subagent: 3
        case .title, .hook: 4
        case .agentDefinition: 5
        case .sessionDirectory, .projectDirectory, .watchedDirectory: 6
        case .ignored: nil
        }
    }

    /// One file or directory change (synchronous).
    func process(_ path: String, role: FileRole) {
        switch role {
        case .pid(let pid):
            readPidFile(path, pid: pid)
        case .main(let sid):
            handleMain(path, sessionID: sid)
        case .meta(let sid, let aid):
            guard ensureSessionLoaded(sid, childPath: path) else { return }
            readMeta(path, sessionID: sid, agentID: aid)
        case .subagent(let sid, let aid):
            guard ensureSessionLoaded(sid, childPath: path) else { return }
            if files[path] == nil {
                register(path, role: role)
                sessionFiles[sid, default: SessionFiles()].subagents[aid] = path
            }
            readTracked(path)
        case .title(let sid):
            guard ensureSessionLoaded(sid, childPath: path) else { return }
            readTitle(path, sessionID: sid)
        case .hook:
            readHook()
        case .agentDefinition:
            definitions.invalidateUserDefinitions()
            for (sid, s) in sessions where s.usedDefinitions { markDirty(sid) }
        case .sessionDirectory(let sid):
            guard sessions[sid] != nil else { return }
            scanSessionDirectory(sessionID: sid, directory: Self.sessionDirectory(for: path, sessionID: sid))
        case .projectDirectory:
            scanProjectDirectory(path, force: true)
        case .watchedDirectory:
            if watchFileSystem { ensureWatcher() }
        case .ignored:
            break
        }
    }

    /// `projects/<dir>/<sid>` for a path at or below it.
    static func sessionDirectory(for path: String, sessionID: String) -> String {
        var p = path
        while !p.isEmpty, (p as NSString).lastPathComponent != sessionID {
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p { break }
            p = parent
        }
        return p
    }

    // MARK: Main transcripts and relocation

    func handleMain(_ path: String, sessionID sid: String) {
        if superseded.contains(path) {
            guard let current = sessionFiles[sid]?.main, FileStat.of(path: current) == nil else { return }
            superseded.remove(path)
        }
        if storedTasks[sid] != nil, sessions[sid] == nil {
            // A stored (unparsed) task's transcript changed: parse it from 0 (resumed session).
            guard let st = FileStat.of(path: path), let stored = storedTasks[sid],
                  !Self.matches(stored, path: path, stat: st) else { return }
            storedTasks[sid] = nil
            loadSession(sid, mainPath: path)
            return
        }
        if files[path] != nil {
            readTracked(path)
            return
        }
        if let current = sessionFiles[sid]?.main, current != path {
            relocate(sid, from: current, to: path)
            return
        }
        guard FileStat.of(path: path) != nil else { return }
        mainPathIndex[sid] = path
        loadSession(sid, mainPath: path)
    }

    /// A known session's main file appeared at a new path (architecture §4 "Relocation").
    private func relocate(_ sid: String, from old: String, to new: String) {
        guard let newStat = FileStat.of(path: new), let oldFile = files[old] else {
            if files[old] == nil, FileStat.of(path: new) != nil {
                sessionFiles[sid]?.main = nil
                handleMain(new, sessionID: sid)
            }
            return
        }
        mainPathIndex[sid] = new
        if let oldStat = FileStat.of(path: old) {
            // Both exist: the newest mtime wins.
            if newStat.mtime > oldStat.mtime {
                superseded.insert(old)
                files[old] = nil
                sessionFiles[sid]?.main = new
                register(new, role: .main(sessionID: sid))
                resetSession(sid)
            } else {
                superseded.insert(new)
            }
            return
        }
        if newStat.fileID == oldFile.fileID {
            // Moved: rebind and keep the offset.
            var moved = oldFile
            moved.path = new
            moved.missingSince = nil
            files[old] = nil
            missingChecks[old] = nil
            files[new] = moved
            sessionFiles[sid]?.main = new
            if !rebindChildren(sid, oldMain: old, newMain: new) {
                resetSession(sid)
                return
            }
            readTracked(new)
        } else {
            // A copy at the new path: re-read the session from there.
            files[old] = nil
            missingChecks[old] = nil
            sessionFiles[sid]?.main = new
            register(new, role: .main(sessionID: sid))
            resetSession(sid)
        }
    }

    /// Moves sidecar/subagent file states under the new `<sid>/` directory. False when one can't be matched.
    private func rebindChildren(_ sid: String, oldMain: String, newMain: String) -> Bool {
        guard var sf = sessionFiles[sid] else { return true }
        let oldDir = String(oldMain.dropLast(6))
        let newDir = String(newMain.dropLast(6))
        func move(_ path: String) -> String? {
            guard path.hasPrefix(oldDir + "/"), var fs = files[path] else { return path }
            let target = newDir + path.dropFirst(oldDir.count)
            guard let st = FileStat.of(path: target), st.fileID == fs.fileID else { return nil }
            files[path] = nil
            missingChecks[path] = nil
            fs.path = target
            fs.missingSince = nil
            files[target] = fs
            return target
        }
        for (aid, p) in sf.metas { guard let t = move(p) else { return false }; sf.metas[aid] = t }
        for (aid, p) in sf.subagents { guard let t = move(p) else { return false }; sf.subagents[aid] = t }
        if let p = sf.title { guard let t = move(p) else { return false }; sf.title = t }
        sessionFiles[sid] = sf
        return true
    }

    /// Makes sure the session of a sidecar/subagent file is loaded (loading it from its main file if
    /// needed). False when the change should be ignored.
    private func ensureSessionLoaded(_ sid: String, childPath: String) -> Bool {
        if sessions[sid] != nil { return true }
        let dir = Self.sessionDirectory(for: childPath, sessionID: sid)
        let mainPath = dir + ".jsonl"
        if storedTasks[sid] != nil {
            storedTasks[sid] = nil
            loadSession(sid, mainPath: FileStat.of(path: mainPath) != nil ? mainPath : nil, sessionDirectory: dir)
            return false   // the full load read this file too
        }
        if FileStat.of(path: mainPath) != nil {
            mainPathIndex[sid] = mainPath
            loadSession(sid, mainPath: mainPath)
            return false
        }
        // Subagent activity before the main file exists: track it; the task shows once main appears.
        sessions[sid] = SessionState(id: sid)
        return true
    }

    // MARK: Session loading and reset

    /// Reads a whole session: main → metas → subagents → custom title, then shows remaining orphans.
    /// A session that already has state (subagent files seen first, or a main file that reappeared) is
    /// reset instead, so no file is folded in twice.
    func loadSession(_ sid: String, mainPath: String?, sessionDirectory: String? = nil) {
        let dir = sessionDirectory ?? mainPath.map { String($0.dropLast(6)) }
        let hadState = sessions[sid] != nil
        var sf = sessionFiles[sid] ?? SessionFiles()
        if let mainPath {
            sf.main = mainPath
            mainPathIndex[sid] = mainPath
            parsedMainPaths.insert(mainPath)
            register(mainPath, role: .main(sessionID: sid))
        }
        sessionFiles[sid] = sf
        if hadState {
            resetSession(sid)
        } else {
            sessions[sid] = SessionState(id: sid)
            if let mainPath { readTracked(mainPath) }
        }
        if let dir { scanSessionDirectory(sessionID: sid, directory: dir) }
        if var s = sessions[sid] {
            SessionReducer.promoteOrphans(&s, now: clock.now(), grace: Self.orphanGrace, force: true)
            sessions[sid] = s
        }
        recordScanCache(sid)
        markDirty(sid)
    }

    /// Registers and reads any untracked metas, subagent transcripts and the custom title under `<sid>/`.
    func scanSessionDirectory(sessionID sid: String, directory dir: String) {
        let subDir = (dir as NSString).appendingPathComponent("subagents")
        if let st = FileStat.of(path: subDir) { subagentDirMtimes[subDir] = st.mtime }
        var metas: [(String, String)] = []
        var transcripts: [(String, String)] = []
        for name in FileIO.list(subDir).sorted() {
            let path = (subDir as NSString).appendingPathComponent(name)
            switch classifier.classify(path) {
            case .meta(_, let aid): metas.append((aid, path))
            case .subagent(_, let aid): transcripts.append((aid, path))
            default: break
            }
        }
        for (aid, path) in metas where files[path] == nil { readMeta(path, sessionID: sid, agentID: aid) }
        for (aid, path) in transcripts where files[path] == nil {
            register(path, role: .subagent(sessionID: sid, agentID: aid))
            sessionFiles[sid, default: SessionFiles()].subagents[aid] = path
            readTracked(path)
        }
        let title = (dir as NSString).appendingPathComponent("custom-title.json")
        if files[title] == nil, FileStat.of(path: title) != nil { readTitle(title, sessionID: sid) }
    }

    /// Drops the session's state and re-reads all its files from 0 (replaced or truncated file).
    func resetSession(_ sid: String) {
        Self.logger.info("Resetting session \(sid, privacy: .public)")
        let sf = sessionFiles[sid] ?? SessionFiles()
        let growth = clock.now()
        sessions[sid] = SessionState(id: sid)
        sessions[sid]?.lastGrowthAt = growth
        for path in sf.all {
            guard var fs = files[path] else { continue }
            guard let st = FileStat.of(path: path) else {
                files[path] = nil
                continue
            }
            fs.fileID = st.fileID
            fs.offset = 0
            fs.size = 0
            fs.missingSince = nil
            files[path] = fs
        }
        if let main = sf.main, files[main] != nil { readTracked(main, allowReset: false) }
        for (aid, path) in sf.metas.sorted(by: { $0.key < $1.key }) where files[path] != nil {
            files[path] = nil
            readMeta(path, sessionID: sid, agentID: aid)
        }
        for path in sf.subagents.values.sorted() where files[path] != nil { readTracked(path, allowReset: false) }
        if let title = sf.title, files[title] != nil {
            files[title] = nil
            readTitle(title, sessionID: sid)
        }
        if var s = sessions[sid] {
            SessionReducer.promoteOrphans(&s, now: growth, grace: Self.orphanGrace, force: true)
            sessions[sid] = s
        }
        markDirty(sid)
    }

    @discardableResult
    func register(_ path: String, role: FileRole) -> Bool {
        guard files[path] == nil, let st = FileStat.of(path: path) else { return files[path] != nil }
        files[path] = FileState(path: path, role: role, fileID: st.fileID)
        return true
    }

    // MARK: Reading

    /// `readNewBytes` (architecture §4): reads new complete lines of a tracked transcript into its session.
    func readTracked(_ path: String, allowReset: Bool = true) {
        guard var fs = files[path], let sid = fs.role.sessionID, let owner = fs.role.owner else { return }
        let now = clock.now()
        let startOffset = fs.offset
        var s = sessions.removeValue(forKey: sid) ?? SessionState(id: sid)
        if owner == .main { s.mainSeen = true }
        var applied = 0
        let outcome = reader.read(&fs) { line in
            if let event = parser.parse(line) {
                SessionReducer.apply(event, owner: owner, to: &s, now: now)
                applied += 1
            }
        }
        if applied > 0, startOffset > 0 { s.lastGrowthAt = now }
        sessions[sid] = s
        files[path] = fs
        switch outcome {
        case .reset:
            if allowReset { resetSession(sid) }
        case .missing:
            if fs.missingSince == nil {
                fs.missingSince = now
                files[path] = fs
                missingChecks[path] = now.addingTimeInterval(Self.removalGrace)
                rescheduleTimer()
            }
        case .appended:
            if applied > 0 { markDirty(sid) }
        case .unchanged:
            break
        }
    }

    /// Re-reads a meta sidecar (small, whole). A file caught mid-write fails to decode and is retried later.
    func readMeta(_ path: String, sessionID sid: String, agentID aid: String) {
        guard let st = FileStat.of(path: path) else { return }
        if let fs = files[path], fs.fileID == st.fileID, fs.size == st.size, fs.mtime == st.mtime { return }
        guard let data = FileIO.readSmallFile(path, limit: 1 << 20),
              let meta = try? sidecarDecoder.decode(AgentMeta.self, from: data) else { return }
        files[path] = FileState(path: path, role: .meta(sessionID: sid, agentID: aid), fileID: st.fileID,
                                offset: st.size, size: st.size, mtime: st.mtime)
        sessionFiles[sid, default: SessionFiles()].metas[aid] = path
        var s = sessions.removeValue(forKey: sid) ?? SessionState(id: sid)
        SessionReducer.applyMeta(meta, agentID: aid, to: &s, now: clock.now())
        sessions[sid] = s
        markDirty(sid)
    }

    func readTitle(_ path: String, sessionID sid: String) {
        guard let st = FileStat.of(path: path) else { return }
        if let fs = files[path], fs.fileID == st.fileID, fs.size == st.size, fs.mtime == st.mtime { return }
        guard let data = FileIO.readSmallFile(path, limit: 64 * 1024),
              let file = try? sidecarDecoder.decode(CustomTitleFile.self, from: data) else { return }
        files[path] = FileState(path: path, role: .title(sessionID: sid), fileID: st.fileID,
                                offset: st.size, size: st.size, mtime: st.mtime)
        sessionFiles[sid, default: SessionFiles()].title = path
        if let title = file.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            sessions[sid, default: SessionState(id: sid)].customTitle = title
            markDirty(sid)
        }
    }

    // MARK: Pid files

    func readPidFile(_ path: String, pid: Int32) {
        guard let data = FileIO.readSmallFile(path, limit: 256 * 1024) else {
            if FileStat.of(path: path) == nil { removePid(pid) }
            return
        }
        guard let file = try? sidecarDecoder.decode(PidFile.self, from: data) else { return }   // mid-write
        var entry = pids[pid] ?? PidEntry()
        let oldSession = entry.sessionID
        entry.sessionID = file.sessionID
        entry.status = file.status
        entry.stat = FileStat.of(path: path)
        if entry.watch == nil || entry.procStart != file.procStart || entry.startedAt != file.startedAt {
            entry.watch?.cancel()
            entry.watch = nil
            entry.procStart = file.procStart
            entry.startedAt = file.startedAt
            entry.alive = probe.isAlive(pid: pid, procStart: file.procStart, startedAtMs: file.startedAt)
            if entry.alive {
                entry.watch = probe.watchExit(pid: pid) { [weak self] in
                    Task { await self?.processExited(pid) }
                }
            }
        }
        pids[pid] = entry
        rebuildPidIndex()
        if let oldSession, oldSession != file.sessionID { markDirty(oldSession) }
        if let sid = file.sessionID {
            // A process for a session that isn't parsed (old, or served from history): resumed, so parse it.
            if sessions[sid] == nil, initialLoadComplete, entry.alive,
               let main = mainPathIndex[sid] ?? storedTasks[sid]?.transcriptPath, FileStat.of(path: main) != nil {
                storedTasks[sid] = nil
                loadSession(sid, mainPath: main)
            }
            markDirty(sid)
        }
    }

    func removePid(_ pid: Int32) {
        guard let entry = pids.removeValue(forKey: pid) else { return }
        entry.watch?.cancel()
        rebuildPidIndex()
        if let sid = entry.sessionID { markDirty(sid) }
    }

    func processExited(_ pid: Int32) {
        guard var entry = pids[pid], entry.alive else { return }
        entry.alive = false
        entry.watch?.cancel()
        entry.watch = nil
        pids[pid] = entry
        rebuildPidIndex()
        if let sid = entry.sessionID { markDirty(sid) }
    }

    private func rebuildPidIndex() {
        var index: [String: Int32] = [:]
        for (pid, entry) in pids {
            guard let sid = entry.sessionID else { continue }
            if let existing = index[sid], let other = pids[existing] {
                // Prefer a live process, then the newest start.
                if other.alive && !entry.alive { continue }
                if other.alive == entry.alive, (other.startedAt ?? 0) >= (entry.startedAt ?? 0) { continue }
            }
            index[sid] = pid
        }
        pidBySession = index
    }

    func processState(for sid: String) -> ProcessState? {
        guard let pid = pidBySession[sid], let entry = pids[pid] else { return nil }
        return ProcessState(alive: entry.alive, status: entry.status)
    }

    // MARK: Emission

    func markDirty(_ sid: String) {
        if coalescer.markDirty(sid) { scheduleFlush() }
    }

    func scheduleFlush() {
        guard !stopped else { return }
        let interval = coalescer.interval
        flushTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: interval) } catch { return }
            await self?.flush()
        }
    }

    /// Builds dirty tasks and yields one batch (architecture §10).
    func flush() {
        flushTask = nil
        guard !stopped else { return }
        let now = clock.now()
        var built: [String: TaskSnapshot] = [:]
        for id in coalescer.dirty {
            if let s = build(id, now: now) { built[id] = s }
        }
        let result = coalescer.flush(into: continuation) { built[$0] }
        switch result {
        case .retry:
            scheduleFlush()
        case .terminated:
            Task { await self.stop() }
        case .emitted:
            if firstEmissionAt == nil, !built.isEmpty { firstEmissionAt = now }
        case .idle:
            break
        }
        rescheduleTimer()
    }

    /// The snapshot of one task, with transition side effects (estimates, history writes, deadlines).
    func build(_ id: String, now: Date) -> TaskSnapshot? {
        guard var s = sessions[id], s.mainSeen else {
            deadlines[id] = nil
            if let stored = storedTasks[id] {
                let end = stored.snapshot.endedAt ?? stored.snapshot.lastActivityAt
                guard StatusRules.storedInScope(stored.snapshot, now: now, historyWindow: configuration.historyWindow) else {
                    return nil
                }
                deadlines[id] = end.addingTimeInterval(configuration.historyWindow)
                return withCurrentEstimates(stored.snapshot)
            }
            return nil
        }
        let orphanDeadline = SessionReducer.promoteOrphans(&s, now: now, grace: Self.orphanGrace)
        let status = StatusRules.derive(s, process: processState(for: id), now: now,
                                        quietInterval: configuration.quietInterval,
                                        historyWindow: configuration.historyWindow)
        freezeEstimates(&s, status: status, now: now)
        let projectPath = s.projectPath
        let output = SnapshotBuilder.build(
            s, status: status,
            definitionModel: { type in self.definitions.model(for: type, projectPath: projectPath, now: now) },
            estimate: { type, family in self.estimator.estimate(agentType: type, family: family) },
            finishedEstimate: { runID, type, family, own in
                self.estimate(excluding: own, cacheKey: runID, agentType: type, family: family)
            })
        s.usedDefinitions = output.usedDefinitions
        sessions[id] = s
        recordTransitions(s, output.snapshot, status: status, now: now)
        lastStatus[id] = status
        var deadline = status.nextDeadline
        if let orphanDeadline { deadline = deadline.map { min($0, orphanDeadline) } ?? orphanDeadline }
        deadlines[id] = deadline
        return status.inScope ? output.snapshot : nil
    }

    /// Runs seen unfinished are marked as watched; a watched run that has just finished gets its live
    /// estimate frozen (before its own sample is added). Runs already finished when loaded are never frozen:
    /// their estimate is computed from the other samples (`estimate(excluding:)`), so it improves as the
    /// estimator learns (tier-3 scan, live finishes).
    private func freezeEstimates(_ s: inout SessionState, status: StatusRules.Result, now: Date) {
        let mainFamily = s.main.own.transcriptModel.map { ModelFamily(modelID: $0) } ?? .other
        let projectPath = s.projectPath
        for (id, run) in s.runs where run.frozenEstimate == nil {
            let finished = (status.runs[id] ?? run.baseStatus).isFinished
            if !finished {
                if !run.observedUnfinished { s.runs[id]?.observedUnfinished = true }
                continue
            }
            guard run.observedUnfinished else { continue }
            let model = ModelResolver.resolve(run, isMain: false) { type in
                self.definitions.model(for: type, projectPath: projectPath, now: now)
            }.model
            let family = model.id == nil ? mainFamily : model.family
            s.runs[id]?.frozenEstimate = estimator.estimate(agentType: run.agentType, family: family)
        }
    }

    /// A stored (history) snapshot with every finished run's estimate recomputed from the other samples.
    func withCurrentEstimates(_ snapshot: TaskSnapshot) -> TaskSnapshot {
        var snap = snapshot
        for i in snap.runs.indices.dropFirst() where snap.runs[i].status.isFinished {
            let r = snap.runs[i]
            let family = r.model.id == nil ? snap.mainModel.family : r.model.family
            var own: OwnSample?
            if r.status == .done, let end = r.endedAt {
                own = OwnSample(endedAt: end, seconds: end.timeIntervalSince(r.startedAt))
            }
            snap.runs[i].estimate = estimate(excluding: own, cacheKey: r.id, agentType: r.agentType, family: family)
        }
        return snap
    }

    /// The estimate for a type and family, leaving out the run's own sample when it is in the estimator
    /// (matched by end time and duration). Cached per run until the estimator changes.
    func estimate(excluding own: OwnSample?, cacheKey: String, agentType: String, family: ModelFamily) -> DurationEstimate {
        if let cached = exclusionCache[cacheKey], cached.generation == estimatorGeneration { return cached.estimate }
        var result = estimator.estimate(agentType: agentType, family: family)
        if let own, var samples = samplesByType[agentType], let index = Self.ownSampleIndex(own, in: samples) {
            samples.remove(at: index)
            result = Estimator(samples: samples).estimate(agentType: agentType, family: family)
        }
        exclusionCache[cacheKey] = (estimatorGeneration, result)
        return result
    }

    /// The sample recorded for a run: same end (±1 s) and the closest duration (within max(2 s, 5 %)).
    static func ownSampleIndex(_ own: OwnSample, in samples: [DurationSample]) -> Int? {
        var best: (index: Int, diff: Double)?
        for (i, sample) in samples.enumerated() where abs(sample.endedAt.timeIntervalSince(own.endedAt)) <= 1 {
            let diff = abs(sample.seconds - own.seconds)
            if diff <= max(2, own.seconds * 0.05), best.map({ diff < $0.diff }) ?? true { best = (i, diff) }
        }
        return best?.index
    }

    /// Replaces the estimator's samples (DB load or reload).
    func setEstimatorSamples(_ samples: [DurationSample]) {
        estimator = Estimator(samples: samples)
        samplesByType = Dictionary(grouping: samples, by: \.agentType)
        estimatorGeneration += 1
        exclusionCache.removeAll(keepingCapacity: true)
    }

    /// Adds one live sample (a run that finished while watched).
    private func addLiveSample(_ sample: DurationSample) {
        estimator.add(sample)
        var list = samplesByType[sample.agentType] ?? []
        list.append(sample)
        if list.count > Estimator.bucketCapacity * 2 {
            list.sort { $0.endedAt < $1.endedAt }
            list.removeFirst(list.count - Estimator.bucketCapacity * 2)
        }
        samplesByType[sample.agentType] = list
        estimatorGeneration += 1
        samplesDuringReload?.append(sample)
    }

    /// `run_duration` rows, live estimator samples and finished-task history (architecture §6, §9, §11).
    private func recordTransitions(_ s: SessionState, _ snapshot: TaskSnapshot, status: StatusRules.Result, now: Date) {
        guard let history else { return }
        var newSampleTypes: Set<String> = []
        for run in snapshot.runs.dropFirst() {
            guard let state = s.runs[run.id], state.isAgentCall else { continue }
            let outcome: String
            switch run.status {
            case .done: outcome = "completed"
            case .failed: outcome = "failed"
            case .cancelled: outcome = "cancelled"
            case .queued, .running: outcome = ""
            }
            guard recordedRuns[run.id] != outcome else { continue }
            recordedRuns[run.id] = outcome
            let family = run.model.id == nil ? snapshot.mainModel.family : run.model.family
            let durationMs = run.status.isFinished
                ? SnapshotBuilder.ownSeconds(state).map { Int(($0 * 1000).rounded()) } : nil
            history.enqueue(.runDuration(RunDurationRow(
                toolUseID: run.id, sessionID: s.id, agentType: run.agentType, modelFamily: family,
                startedAt: run.startedAt, endedAt: run.status.isFinished ? run.endedAt : nil,
                durationMs: durationMs, isExact: run.status.isFinished && state.exact?.durationMs != nil,
                outcome: outcome.isEmpty ? nil : outcome)))
            // Live finishes feed the in-memory estimator once per tool-use id; runs finished before the
            // load completed come from the DB (keyed by tool-use id) when the estimator is rebuilt.
            if liveSampling, run.status == .done, let durationMs, !sampledRuns.contains(run.id) {
                sampledRuns.insert(run.id)
                addLiveSample(DurationSample(agentType: run.agentType, family: family,
                                             seconds: Double(durationMs) / 1000, endedAt: run.endedAt ?? now))
                newSampleTypes.insert(run.agentType)
            }
        }
        if !newSampleTypes.isEmpty { redirtyEstimates(types: newSampleTypes, except: s.id) }

        // Finished tasks go to history (for tier-2 loads and DB-only display after the transcript is gone).
        if snapshot.status == .done || snapshot.status == .failed, status.inScope,
           let mainPath = sessionFiles[s.id]?.main, let fs = files[mainPath] {
            let signature = "\(snapshot.status.rawValue)|\(fs.size)|\(snapshot.lastActivityAt.timeIntervalSinceReferenceDate)|\(snapshot.runs.count)"
            if savedTasks[s.id] != signature {
                savedTasks[s.id] = signature
                history.enqueue(.finishedTask(StoredTask(snapshot: snapshot, transcriptPath: mainPath,
                                                         fileID: fs.fileID, fileSize: fs.size, fileMtime: fs.mtime)))
                recordScanCache(s.id)
            }
        }
    }

    /// Marks tasks whose estimates depend on these types dirty: running runs, and finished runs without a
    /// frozen estimate (including stored history tasks). `nil` = every task.
    func redirtyEstimates(types: Set<String>?, except: String? = nil) {
        for (sid, s) in sessions where sid != except {
            let affected = s.runs.values.contains { run in
                (types?.contains(run.agentType) ?? true) && run.frozenEstimate == nil
            }
            if affected { markDirty(sid) }
        }
        for (id, stored) in storedTasks where stored.snapshot.runs.dropFirst().contains(where: { types?.contains($0.agentType) ?? true }) {
            markDirty(id)
        }
    }

    /// Lets the estimate scanner skip a main transcript the engine has read.
    func recordScanCache(_ sid: String) {
        guard let history, let path = sessionFiles[sid]?.main, let fs = files[path] else { return }
        history.enqueue(.scanCache(ScanCacheEntry(path: path, sessionID: sid, fileID: fs.fileID,
                                                  size: fs.size, mtime: fs.mtime, offset: fs.offset)))
    }

    // MARK: Deadline timer

    /// One timer sleeping until the earliest deadline (status quiet thresholds, window expiry, orphan
    /// grace, removal grace). No deadlines, no timer.
    func rescheduleTimer() {
        guard !stopped else { return }
        let earliest = [deadlines.values.min(), missingChecks.values.min()].compactMap { $0 }.min()
        guard let earliest else {
            timerTask?.cancel()
            timerTask = nil
            timerDeadline = nil
            return
        }
        if timerTask != nil, timerDeadline == earliest { return }
        timerTask?.cancel()
        timerDeadline = earliest
        let delay = Duration.interval(earliest.timeIntervalSince(clock.now()))
        timerTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.timerFired()
        }
    }

    func timerFired() {
        timerTask = nil
        timerDeadline = nil
        let now = clock.now()
        for (sid, deadline) in deadlines where deadline <= now {
            deadlines[sid] = nil
            markDirty(sid)
        }
        for (path, due) in missingChecks where due <= now {
            missingChecks[path] = nil
            guard let fs = files[path], FileStat.of(path: path) == nil else {
                if files[path] != nil { files[path]?.missingSince = nil }
                continue
            }
            // Gone for good: forget the file, keep the session (history keeps finished tasks).
            files[path] = nil
            if let sid = fs.role.sessionID, var sf = sessionFiles[sid] {
                if sf.main == path { sf.main = nil }
                if sf.title == path { sf.title = nil }
                if let aid = fs.role.agentID {
                    if sf.subagents[aid] == path { sf.subagents[aid] = nil }
                    if sf.metas[aid] == path { sf.metas[aid] = nil }
                }
                sessionFiles[sid] = sf
            }
        }
        rescheduleTimer()
    }

    // MARK: Helpers

    static func matches(_ stored: StoredTask, path: String, stat: FileStat) -> Bool {
        stored.transcriptPath == path && stored.fileID == stat.fileID && stored.fileSize == stat.size
            && abs(stored.fileMtime.timeIntervalSince(stat.mtime)) < 0.001
    }
}
