import Foundation

/// The tiered cold load (architecture §10). The window is up at once; tasks arrive progressively:
/// live-pid and recent sessions first (tier 1), then the rest of the history window (tier 2, from stored
/// snapshots when the transcript is unchanged), then `initialLoadComplete`. Tier 3 (the duration scan)
/// starts afterwards in the background.
extension TranscriptEngine {
    struct MainCandidate: Sendable {
        var sessionID: String
        var path: String
        var stat: FileStat
    }

    func loadInitial() async {
        guard !initialLoadStarted else { return }
        initialLoadStarted = true
        await prepare()
        guard !stopped else { return }
        let now = clock.now()

        // Step 4: pid files (liveness, exit sources).
        for name in FileIO.list(sessionsPath) {
            let path = (sessionsPath as NSString).appendingPathComponent(name)
            if case .pid(let pid) = classifier.classify(path) { readPidFile(path, pid: pid) }
        }
        registerHookAtEnd()

        // Step 5: list projects/*/ one level.
        let candidates = listMainCandidates()
        for c in candidates.values { mainPathIndex[c.sessionID] = c.path }

        // Tier 1: live-pid sessions, then mtime within recentWindow, newest first.
        let liveSessions = Set(pids.values.filter(\.alive).compactMap(\.sessionID))
        var tier1: [MainCandidate] = []
        var tier2: [MainCandidate] = []
        for c in candidates.values {
            let age = now.timeIntervalSince(c.stat.mtime)
            if liveSessions.contains(c.sessionID) || age <= configuration.recentWindow {
                tier1.append(c)
            } else if age <= configuration.historyWindow {
                tier2.append(c)
            }
        }
        tier1.sort { a, b in
            let la = liveSessions.contains(a.sessionID), lb = liveSessions.contains(b.sessionID)
            if la != lb { return la }
            return a.stat.mtime > b.stat.mtime
        }
        tier2.sort { $0.stat.mtime > $1.stat.mtime }

        for c in tier1 {
            guard !stopped else { return }
            if files[c.path] == nil, sessions[c.sessionID] == nil { loadSession(c.sessionID, mainPath: c.path) }
            await Task.yield()
        }

        // Tier 2: the rest of the window; unchanged finished sessions come from history without parsing.
        for c in tier2 {
            guard !stopped else { return }
            guard files[c.path] == nil, sessions[c.sessionID] == nil else { continue }
            if let stored = storedHistory[c.sessionID], Self.matches(stored, path: c.path, stat: c.stat) {
                storedTasks[c.sessionID] = stored
                markDirty(c.sessionID)
                continue
            }
            loadSession(c.sessionID, mainPath: c.path)
            await Task.yield()
        }

        // DB-only finished tasks (transcript gone or outside the listing) still within the window.
        for (id, stored) in storedHistory where sessions[id] == nil && storedTasks[id] == nil {
            storedTasks[id] = stored
            markDirty(id)
        }
        storedHistory = [:]

        // Record run rows and history for every loaded session, rebuild the estimator from the DB, then
        // announce the load: the load-complete batch already carries estimates from every known sample.
        for id in coalescer.dirty { _ = build(id, now: clock.now()) }
        liveSampling = true
        await reloadEstimator()
        initialLoadComplete = true
        if coalescer.markLoadComplete() { scheduleFlush() }
    }

    /// Every `projects/<dir>/<sid>.jsonl`; for a session id in two directories the preferred copy wins
    /// (`prefers`: one holding a conversation, else the newest mtime).
    func listMainCandidates() -> [String: MainCandidate] {
        var result: [String: MainCandidate] = [:]
        for dir in FileIO.list(projectsPath) {
            let dirPath = (projectsPath as NSString).appendingPathComponent(dir)
            guard let dirStat = FileStat.of(path: dirPath), dirStat.isDirectory else { continue }
            projectDirMtimes[dirPath] = dirStat.mtime
            for name in FileIO.list(dirPath) where name.hasSuffix(".jsonl") {
                let path = (dirPath as NSString).appendingPathComponent(name)
                guard case .main(let sid) = classifier.classify(path), let st = FileStat.of(path: path),
                      !st.isDirectory else { continue }
                if let existing = result[sid] {
                    if prefers(path, st, over: existing.path, existing.stat) {
                        superseded.insert(existing.path)
                        result[sid] = MainCandidate(sessionID: sid, path: path, stat: st)
                    } else {
                        superseded.insert(path)
                    }
                } else {
                    result[sid] = MainCandidate(sessionID: sid, path: path, stat: st)
                }
            }
        }
        return result
    }

    /// Rebuilds the estimator from the history DB, where `run_duration` is keyed by tool-use id, so runs
    /// reported by both the engine and the scanner count once. Live samples taken meanwhile are kept.
    /// - Parameter afterFlush: test seam, run between the flush and the DB read (to reproduce a run
    ///   finishing mid-reload).
    func reloadEstimator(afterFlush: (@Sendable () async -> Void)? = nil) async {
        guard let history else { return }
        samplesDuringReload = []
        await history.flush()
        await afterFlush?()
        let rows = await history.loadSampleRows(perTypeLimit: Self.samplesPerType)
        // Live finishes recorded while the DB was read may or may not be in `rows`; keyed by tool-use id
        // they count once, with the live value winning.
        setEstimatorSamples(rows + (samplesDuringReload ?? []))
        samplesDuringReload = nil
        // Every estimate may have changed: running runs, and finished runs shown with the other samples.
        redirtyEstimates(types: nil)
    }
}
