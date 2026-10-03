import Foundation

/// Compact, allocation-light duration strings for timers ("4s", "1m 20s", "2h 05m").
public enum DurationText {
    /// "0:42", "12:05", "1:02:09" — fixed-width style for running timers.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h):\(pad(m)):\(pad(sec))" }
        return "\(m):\(pad(sec))"
    }

    /// "42s", "1m 20s", "2h 05m" — human style for estimates and deltas.
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(pad(m))m" }
        return sec == 0 ? "\(m)m" : "\(m)m \(pad(sec))s"
    }

    /// "4m ago", "just now", "3h ago", "2d ago".
    public static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    private static func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
}
