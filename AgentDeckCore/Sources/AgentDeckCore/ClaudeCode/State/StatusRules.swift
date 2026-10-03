import Foundation

/// What the pid file says about a session's process.
struct ProcessState: Sendable, Hashable {
    /// The pid file exists and `ProcessProbe.isAlive` confirmed the process.
    var alive: Bool
    /// `busy` | `idle` | `waiting`.
    var status: String?
}

/// Pure status derivation (architecture §7, data-sources §5).
enum StatusRules {
    struct Result: Sendable, Equatable {
        var task: TaskStatus
        /// Set on done/failed (= `lastActivityAt`).
        var endedAt: Date?
        var mainRun: RunStatus
        /// Final status per subagent run id, after time-based overrides.
        var runs: [String: RunStatus]
        /// End time for runs cancelled by an override (session closed, or no process and quiet).
        var overrideEndedAt: [String: Date]
        /// When the derivation can next change by time alone (quiet threshold, window expiry).
        var nextDeadline: Date?
        /// Whether the task is emitted (architecture §3 "Emission scope").
        var inScope: Bool
    }

    static func derive(_ s: SessionState, process: ProcessState?, now: Date,
                       quietInterval: TimeInterval, historyWindow: TimeInterval) -> Result {
        let alive = process?.alive ?? false
        let quietRef = max(s.lastActivityAt ?? .distantPast, s.lastGrowthAt ?? .distantPast)
        let quietLong = now.timeIntervalSince(quietRef) >= quietInterval
        let cancelAll = s.closed || (!alive && quietLong)

        var runs: [String: RunStatus] = [:]
        var overrideEnded: [String: Date] = [:]
        var anySubagentActive = false
        for (id, run) in s.runs {
            var status = run.baseStatus
            if !status.isFinished && cancelAll {
                status = .cancelled
                overrideEnded[id] = run.lastActivityAt ?? run.startedAt ?? quietRef
            }
            if status == .running || status == .queued { anySubagentActive = true }
            runs[id] = status
        }

        let main = s.main.own
        let task: TaskStatus
        if main.lastWasAPIError {
            task = .failed
        } else if alive && process?.status == "waiting" {
            task = .waiting
        } else if !main.interactivePending.isEmpty && !s.closed && (alive || !quietLong) {
            task = .waiting
        } else if alive && process?.status == "busy" {
            task = .running
        } else if !alive && !s.closed && main.phase == .midTurn && !quietLong {
            task = .running
        } else if anySubagentActive {
            task = .running
        } else if alive {
            task = .idle
        } else if s.closed || quietLong {
            task = .done
        } else {
            task = .idle    // transient: no process, turn ended, quiet < 2 min; done at the deadline
        }

        let mainRun: RunStatus
        switch task {
        case .running, .waiting: mainRun = .running
        case .idle, .done: mainRun = .done
        case .failed: mainRun = .failed
        }

        let finished = task == .done || task == .failed
        let endedAt = finished ? (s.lastActivityAt ?? quietRef) : nil

        var deadline: Date?
        if !alive && !s.closed && !quietLong {
            deadline = quietRef.addingTimeInterval(quietInterval)
        }
        var inScope = true
        if !alive && finished, let end = endedAt {
            let expiry = end.addingTimeInterval(historyWindow)
            if expiry <= now {
                inScope = false
            } else {
                deadline = deadline.map { min($0, expiry) } ?? expiry
            }
        }
        return Result(task: task, endedAt: endedAt, mainRun: mainRun, runs: runs, overrideEndedAt: overrideEnded,
                      nextDeadline: deadline, inScope: inScope)
    }

    /// Scope check for a stored (history) snapshot.
    static func storedInScope(_ snapshot: TaskSnapshot, now: Date, historyWindow: TimeInterval) -> Bool {
        (snapshot.endedAt ?? snapshot.lastActivityAt).addingTimeInterval(historyWindow) > now
    }
}
