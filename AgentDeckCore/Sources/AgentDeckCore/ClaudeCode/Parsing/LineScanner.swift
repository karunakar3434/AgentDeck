import Foundation

/// What a transcript line is, decided from its first bytes (architecture §5, stage 1).
enum LineKind: Sendable, Equatable {
    case user, assistant, system, queueOperation, queuedCommand
    case customTitle, aiTitle, relocated, costState, forkContextRef
    /// No decisive key within the scan limit: decode the envelope to find out.
    case decode
    /// Not needed: never decoded.
    case skip
}

/// A byte-level prefilter over the top-level JSON object. It walks keys at depth 1 (tracking strings,
/// escapes and nesting, skipping whitespace) and stops at the first decisive key:
/// - `type`: its value decides (metadata lines have it first; user/system lines a few keys in).
/// - `attachment`: comes before `type` on attachment lines; the attachment's own `type` decides, and only
///   `queued_command` is kept.
/// - `message`: assistant lines put `message` before `type`.
/// No allocation; at most `limit` bytes are examined.
enum LineScanner {
    static let limit = 4096

    static func classify(_ bytes: UnsafeRawBufferPointer) -> LineKind {
        var s = Cursor(bytes: bytes, end: min(bytes.count, limit))
        s.skipWhitespace()
        guard s.consume(0x7B) else { return .decode }            // {
        var attachmentTyped = false
        while true {
            s.skipWhitespace()
            guard let c = s.peek() else { return .decode }
            if c == 0x7D { return .decode }                        // }
            guard let key = s.readString() else { return .decode }
            s.skipWhitespace()
            guard s.consume(0x3A) else { return .decode }          // :
            s.skipWhitespace()
            if s.equals(key, "type") {
                guard let value = s.readString() else { return .decode }
                if s.equals(value, "attachment") {
                    attachmentTyped = true                         // keep looking for the attachment object
                } else {
                    return kind(forType: value, in: s)
                }
            } else if s.equals(key, "attachment") {
                return attachmentKind(&s)
            } else if s.equals(key, "message"), !attachmentTyped {
                return .assistant
            } else {
                guard s.skipValue() else { return .decode }
            }
            s.skipWhitespace()
            guard let next = s.peek() else { return .decode }
            if next == 0x2C { s.index += 1; continue }             // ,
            return .decode
        }
    }

    private static func attachmentKind(_ s: inout Cursor) -> LineKind {
        guard s.consume(0x7B) else { return .skip }
        s.skipWhitespace()
        guard let key = s.readString() else { return .decode }
        guard s.equals(key, "type") else { return .decode }
        s.skipWhitespace()
        guard s.consume(0x3A) else { return .decode }
        s.skipWhitespace()
        guard let value = s.readString() else { return .decode }
        return s.equals(value, "queued_command") ? .queuedCommand : .skip
    }

    private static func kind(forType value: Range<Int>, in s: Cursor) -> LineKind {
        switch value.count {
        case 4 where s.equals(value, "user"): return .user
        case 6 where s.equals(value, "system"): return .system
        case 9 where s.equals(value, "assistant"): return .assistant
        case 15 where s.equals(value, "queue-operation"): return .queueOperation
        case 12 where s.equals(value, "custom-title"): return .customTitle
        case 8 where s.equals(value, "ai-title"): return .aiTitle
        case 9 where s.equals(value, "relocated"): return .relocated
        case 10 where s.equals(value, "cost-state"): return .costState
        case 16 where s.equals(value, "fork-context-ref"): return .forkContextRef
        default: return .skip
        }
    }

    struct Cursor {
        let bytes: UnsafeRawBufferPointer
        let end: Int
        var index = 0

        init(bytes: UnsafeRawBufferPointer, end: Int) {
            self.bytes = bytes
            self.end = end
        }

        func peek() -> UInt8? { index < end ? bytes[index] : nil }

        mutating func consume(_ c: UInt8) -> Bool {
            guard index < end, bytes[index] == c else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < end {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        /// Reads a JSON string at the cursor; returns the range of its raw contents (escapes not decoded).
        mutating func readString() -> Range<Int>? {
            guard consume(0x22) else { return nil }
            let start = index
            while index < end {
                let c = bytes[index]
                if c == 0x5C { index += 2; continue }              // backslash: skip the escaped byte
                if c == 0x22 {
                    let range = start..<index
                    index += 1
                    return range
                }
                index += 1
            }
            return nil
        }

        /// Skips any JSON value. False when the scan limit is reached first.
        mutating func skipValue() -> Bool {
            guard let c = peek() else { return false }
            switch c {
            case 0x22:
                return readString() != nil
            case 0x7B, 0x5B:
                var depth = 0
                while index < end {
                    let b = bytes[index]
                    switch b {
                    case 0x22:
                        guard readString() != nil else { return false }
                        continue
                    case 0x7B, 0x5B:
                        depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default:
                        break
                    }
                    index += 1
                }
                return false
            default:
                while index < end {
                    switch bytes[index] {
                    case 0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D: return true
                    default: index += 1
                    }
                }
                return false
            }
        }

        func equals(_ range: Range<Int>, _ literal: StaticString) -> Bool {
            guard range.count == literal.utf8CodeUnitCount else { return false }
            let p = literal.utf8Start
            var i = 0
            for k in range {
                if bytes[k] != p[i] { return false }
                i += 1
            }
            return true
        }
    }
}

/// `memmem` over a byte buffer.
@inline(__always)
func bytesContain(_ haystack: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
    guard let base = haystack.baseAddress, haystack.count >= needle.utf8CodeUnitCount else { return false }
    return memmem(base, haystack.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
}
