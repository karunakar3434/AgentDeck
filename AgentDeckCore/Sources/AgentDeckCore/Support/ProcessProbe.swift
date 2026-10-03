import Darwin
import Dispatch
import Foundation
import Synchronization

/// Process liveness for `sessions/<pid>.json` (architecture §4 "Liveness").
protocol ProcessProbe: Sendable {
    /// True when `pid` exists and its start time matches the pid file (guards against pid reuse).
    func isAlive(pid: Int32, procStart: String?, startedAtMs: Int64?) -> Bool
    /// Calls `onExit` once when the process exits. Cancel the returned watch to stop watching.
    func watchExit(pid: Int32, _ onExit: @escaping @Sendable () -> Void) -> ExitWatch
}

/// A cancellable process-exit watch.
final class ExitWatch: Sendable {
    private let onCancel: Mutex<(@Sendable () -> Void)?>

    init(cancel: @escaping @Sendable () -> Void) {
        onCancel = Mutex(cancel)
    }

    /// Idempotent.
    func cancel() {
        let handler = onCancel.withLock { h -> (@Sendable () -> Void)? in
            defer { h = nil }
            return h
        }
        handler?()
    }
}

/// `kill(pid, 0)` + `proc_pidinfo` start time, and `DispatchSource` process-exit sources (no polling).
struct DarwinProcessProbe: ProcessProbe {
    func isAlive(pid: Int32, procStart: String?, startedAtMs: Int64?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        guard let started = Self.startTime(of: pid) else { return true }   // can't check: trust kill()
        return Self.startMatches(processStart: started, procStart: procStart, startedAtMs: startedAtMs)
    }

    func watchExit(pid: Int32, _ onExit: @escaping @Sendable () -> Void) -> ExitWatch {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        let box = SourceBox(source)
        let fired = Mutex(false)
        let fire: @Sendable () -> Void = {
            let first = fired.withLock { f -> Bool in
                defer { f = true }
                return !f
            }
            if first { onExit() }
        }
        source.setEventHandler {
            fire()
            box.source.cancel()
        }
        source.activate()
        // The process may have exited before the source was armed.
        if kill(pid, 0) != 0 && errno == ESRCH {
            fire()
            source.cancel()
        }
        return ExitWatch { box.source.cancel() }
    }

    /// The process start time (seconds since 1970), or nil when unavailable.
    static func startTime(of pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }

    /// `procStart` is a ctime string. Claude Code writes it in UTC on this Mac (data-sources §5 example);
    /// local time is accepted too. `startedAt` (ms) is the fallback, within ±30 s.
    static func startMatches(processStart: TimeInterval, procStart: String?, startedAtMs: Int64?) -> Bool {
        if procStart == nil && startedAtMs == nil { return true }
        if let procStart, let parsed = CTime.parse(procStart) {
            if abs(parsed.utc - processStart.rounded(.down)) <= 1 || abs(parsed.local - processStart.rounded(.down)) <= 1 {
                return true
            }
        }
        if let startedAtMs, abs(Double(startedAtMs) / 1000 - processStart) <= 30 { return true }
        return false
    }

    private final class SourceBox: @unchecked Sendable {
        let source: any DispatchSourceProcess
        init(_ source: any DispatchSourceProcess) { self.source = source }
    }
}

/// Parses `Fri Oct  2 23:56:27 2026` (C `ctime` layout, English names) without locale-dependent APIs.
enum CTime {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Seconds since 1970 interpreting the fields as UTC and as local time.
    static func parse(_ string: String) -> (utc: TimeInterval, local: TimeInterval)? {
        let parts = string.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 5,
              let month = months.firstIndex(of: parts[1].lowercased()),
              let day = Int(parts[2]), let year = Int(parts[4])
        else { return nil }
        let hms = parts[3].split(separator: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let s = Int(hms[2]) else { return nil }
        let days = Timestamp.daysFromCivil(year: year, month: month + 1, day: day)
        let utc = TimeInterval(days * 86_400 + h * 3600 + m * 60 + s)
        // Local: subtract the zone offset in effect at that moment (approximated at the UTC instant).
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: utc)))
        return (utc, utc - offset)
    }
}
