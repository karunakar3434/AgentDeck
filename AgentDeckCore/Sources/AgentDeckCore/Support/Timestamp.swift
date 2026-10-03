import Foundation

/// ISO-8601 timestamps as written by Claude Code (`2026-10-02T23:56:28.204Z`).
///
/// The fixed layout is parsed by hand (no allocation, no formatter); anything else falls back to
/// `Date.ISO8601FormatStyle`.
enum Timestamp {
    static func parse(_ string: String) -> Date? {
        var copy = string
        if let date = copy.withUTF8({ parseFixed($0) }) { return date }
        return fallback(string)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM|±HHMM)`.
    static func parseFixed(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
        let n = b.count
        guard n >= 20 else { return nil }
        func digit(_ i: Int) -> Int? {
            let c = b[i]
            return c >= 48 && c <= 57 ? Int(c - 48) : nil
        }
        func number(_ i: Int, _ count: Int) -> Int? {
            var v = 0
            for k in i..<(i + count) {
                guard let d = digit(k) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116 || b[10] == 32, b[13] == 58, b[16] == 58,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < n, b[i] == 46 {   // "."
            i += 1
            var scale = 0.1
            let start = i
            while i < n, let d = digit(i) {
                fraction += Double(d) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }
        guard i < n else { return nil }
        var offset = 0
        switch b[i] {
        case 90, 122:   // "Z"
            i += 1
        case 43, 45:    // "+" / "-"
            let sign = b[i] == 45 ? -1 : 1
            i += 1
            guard i + 2 <= n, let oh = number(i, 2) else { return nil }
            i += 2
            if i < n, b[i] == 58 { i += 1 }
            guard i + 2 <= n, let om = number(i, 2) else { return nil }
            i += 2
            offset = sign * (oh * 3600 + om * 60)
        default:
            return nil
        }
        guard i == n else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func fallback(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let d = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(trimmed, strategy: Date.ISO8601FormatStyle())
    }
}
