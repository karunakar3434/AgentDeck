import Foundation
import Darwin
import os

/// Logs how long after process start the main window first appeared.
enum LaunchMetrics {
    static let log = Logger(subsystem: "com.karun.AgentDeck", category: "launch")
    nonisolated(unsafe) private static var reported = false

    /// Wall-clock time the process was started, from the kernel.
    static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    @MainActor static func windowAppeared() {
        guard !reported, let start = processStart else { return }
        reported = true
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        log.notice("first window after \(ms, privacy: .public) ms")
        #if DEBUG
        try? "\(ms)\n".write(toFile: NSTemporaryDirectory() + "agentdeck-launch-ms.txt", atomically: true, encoding: .utf8)
        #endif
    }
}
