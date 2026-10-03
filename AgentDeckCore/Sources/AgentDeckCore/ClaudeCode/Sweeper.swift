import Foundation

/// Fallback stat sweep and FSEvents stream management (architecture §4).
///
/// The sweep runs every 10 s while any task is active, otherwise every 60 s. Each sweep stats the files
/// of recently active sessions, lists `sessions/`, and stats the `projects/*` directories (their mtime
/// changes when a session file is created). Any change in (fileID, size, mtime) is handled as an event.
/// Idle cost is about 100 syscalls per minute.
enum Sweeper {
    static let activeInterval: TimeInterval = 10
    static let idleInterval: TimeInterval = 60
    static let pruneInterval: TimeInterval = 3600

    static func interval(anyActive: Bool) -> TimeInterval {
        anyActive ? activeInterval : idleInterval
    }

    /// The directories FSEvents watches: those of `projects`, `sessions`, `agents`, `agentdeck` that exist.
    static func watchedDirectories(root: String) -> [String] {
        ["projects", "sessions", "agents", "agentdeck"].compactMap { name in
            let path = (root as NSString).appendingPathComponent(name)
            return FileStat.of(path: path)?.isDirectory == true ? path : nil
        }
    }
}

extension TranscriptEngine {
    // MARK: FSEvents

    /// (Re)creates the FSEvents stream when the set of existing watched directories changed.
    func ensureWatcher() {
        guard !stopped else { return }
        let paths = Sweeper.watchedDirectories(root: rootPath)
        if paths == watcherPaths, watcher != nil || paths.isEmpty { return }
        watcher?.stop()
        watchTask?.cancel()
        watcher = nil
        watcherPaths = paths
        guard !paths.isEmpty else { return }
        let w = FSEventsWatcher(paths: paths)
        guard w.start() else {
            Self.logger.error("FSEvents unavailable; relying on the sweep")
            return
        }
        watcher = w
        let changes = w.changes
        watchTask = Task { [weak self] in
            for await batch in changes {
                guard let self else { return }
                await self.handle(batch)
            }
        }
    }

    // MARK: Sweep loop

    func startSweeper() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let interval = await self?.sweepInterval() else { return }
                do { try await clock.sleep(for: .interval(interval)) } catch { return }
                await self?.sweep()
            }
        }
    }

    func sweepInterval() -> TimeInterval {
        Sweeper.interval(anyActive: lastStatus.values.contains { $0.task.isActive })
    }

    func startPruning() {
        pruneTask?.cancel()
        let window = configuration.historyWindow
        pruneTask = Task(priority: .utility) { [weak self, clock] in
            while !Task.isCancelled {
                guard let history = await self?.history else { return }
                await history.prune(historyWindow: window, now: clock.now())
                do { try await clock.sleep(for: .interval(Sweeper.pruneInterval)) } catch { return }
            }
        }
    }

    /// One fallback sweep. `full` stats every tracked file and lists every project directory.
    func sweep(full: Bool = false) async {
        guard !stopped else { return }
        let now = clock.now()
        if watchFileSystem { ensureWatcher() }
        if health != .ok { updateHealth() }

        // sessions/: new, changed and removed pid files.
        var seenPids = Set<Int32>()
        for name in FileIO.list(sessionsPath) {
            let path = (sessionsPath as NSString).appendingPathComponent(name)
            guard case .pid(let pid) = classifier.classify(path) else { continue }
            seenPids.insert(pid)
            let st = FileStat.of(path: path)
            if pids[pid] == nil || pids[pid]?.stat != st { readPidFile(path, pid: pid) }
        }
        for pid in pids.keys where !seenPids.contains(pid) { removePid(pid) }

        // Recently active sessions: stat their files and subagent directories.
        var changed: [(String, FileRole)] = []
        for (sid, sf) in sessionFiles {
            let recent = full || pidBySession[sid].flatMap { pids[$0]?.alive } == true
                || (sessions[sid]?.lastActivityAt).map { now.timeIntervalSince($0) <= configuration.recentWindow } == true
            guard recent else { continue }
            for path in sf.all {
                guard let fs = files[path] else { continue }
                let st = FileStat.of(path: path)
                if st == nil {
                    if fs.missingSince == nil { changed.append((path, fs.role)) }
                } else if let st, st.fileID != fs.fileID || st.size != fs.size || st.mtime != fs.mtime {
                    changed.append((path, fs.role))
                }
            }
            if let main = sf.main {
                let subDir = (String(main.dropLast(6)) as NSString).appendingPathComponent("subagents")
                if let st = FileStat.of(path: subDir), subagentDirMtimes[subDir] != st.mtime {
                    subagentDirMtimes[subDir] = st.mtime
                    for name in FileIO.list(subDir) {
                        let path = (subDir as NSString).appendingPathComponent(name)
                        let role = classifier.classify(path)
                        if files[path] == nil, role != .ignored { changed.append((path, role)) }
                    }
                }
            }
        }

        // projects/*: a changed directory mtime means a new (or removed) session file.
        for dir in FileIO.list(projectsPath) {
            let dirPath = (projectsPath as NSString).appendingPathComponent(dir)
            guard let st = FileStat.of(path: dirPath), st.isDirectory else { continue }
            if full || projectDirMtimes[dirPath] != st.mtime {
                projectDirMtimes[dirPath] = st.mtime
                changed.append(contentsOf: newMainFiles(in: dirPath, now: now))
            }
        }

        if FileStat.of(path: hookPath) != nil {
            if hookFile == nil { registerHookAtEnd() } else { changed.append((hookPath, .hook)) }
        }

        for (path, role) in changed.sorted(by: { Self.sweepOrder($0.1) < Self.sweepOrder($1.1) }) {
            guard !stopped else { return }
            process(path, role: role)
            await Task.yield()
        }
    }

    /// Lists a project directory for main transcripts the engine should start tracking.
    func scanProjectDirectory(_ dirPath: String, force: Bool) {
        if let st = FileStat.of(path: dirPath) { projectDirMtimes[dirPath] = st.mtime }
        for (path, role) in newMainFiles(in: dirPath, now: clock.now()) { process(path, role: role) }
    }

    private func newMainFiles(in dirPath: String, now: Date) -> [(String, FileRole)] {
        var result: [(String, FileRole)] = []
        for name in FileIO.list(dirPath) where name.hasSuffix(".jsonl") {
            let path = (dirPath as NSString).appendingPathComponent(name)
            guard case .main(let sid) = classifier.classify(path), files[path] == nil, !superseded.contains(path),
                  let st = FileStat.of(path: path) else { continue }
            if mainPathIndex[sid] == nil { mainPathIndex[sid] = path }
            if let stored = storedTasks[sid] {
                if !Self.matches(stored, path: path, stat: st) { result.append((path, .main(sessionID: sid))) }
                continue
            }
            // New or resumed sessions only: older untouched files stay unloaded.
            let live = pidBySession[sid].flatMap { pids[$0]?.alive } == true
            if live || now.timeIntervalSince(st.mtime) <= configuration.historyWindow {
                result.append((path, .main(sessionID: sid)))
            }
        }
        return result
    }

    private static func sweepOrder(_ role: FileRole) -> Int {
        switch role {
        case .pid: 0
        case .main: 1
        case .meta: 2
        case .subagent: 3
        default: 4
        }
    }
}
