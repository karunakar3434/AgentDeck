import Darwin
import Foundation
import os

/// Read progress of one incrementally read file (architecture §4 `FileState`).
struct FileState: Sendable, Hashable {
    var path: String
    var role: FileRole
    var fileID: UInt64
    /// Bytes consumed: just past the last complete line.
    var offset: Int64 = 0
    var size: Int64 = 0
    var mtime: Date = .distantPast
    /// Local clock time of the last growth (live reads only).
    var lastGrowthAt: Date?
    /// Set when the file was found missing (removal grace for relocations).
    var missingSince: Date?
}

/// Incremental line reader: reads `[offset, size)` in ≤ 1 MB chunks, hands complete lines to a callback
/// and never buffers a partial trailing line (it is re-read next time). Owns one reusable chunk buffer.
struct IncrementalReader {
    enum Outcome: Equatable {
        /// Nothing new.
        case unchanged
        /// New complete lines were read.
        case appended(lines: Int, bytes: Int64)
        /// The file was replaced (new identity) or truncated: the session must be reset.
        case reset
        /// The file is gone.
        case missing
    }

    static let chunkSize = 1 << 20
    static let maxLineLength = 64 << 20
    private static let logger = Logger(subsystem: "com.karun.AgentDeck", category: "FileTracker")

    private var buffer: [UInt8]
    let chunkSize: Int

    init(chunkSize: Int = IncrementalReader.chunkSize) {
        self.chunkSize = chunkSize
        buffer = [UInt8](repeating: 0, count: chunkSize)
    }

    /// Reads new complete lines of `file`. On `.reset` nothing is consumed and `file` is unchanged.
    mutating func read(_ file: inout FileState, onLine: (UnsafeRawBufferPointer) -> Void) -> Outcome {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        guard let st = FileStat.of(fd: fd) else { return .missing }
        file.missingSince = nil
        if st.fileID != file.fileID || st.size < file.offset { return .reset }
        file.size = st.size
        file.mtime = st.mtime
        if st.size == file.offset { return .unchanged }

        let end = st.size
        var position = file.offset
        var consumed = file.offset          // just past the last newline handed out
        var pending: [UInt8] = []           // a line spanning chunks
        var skippingLongLine = false
        var lines = 0
        let chunk = chunkSize
        let path = file.path

        readLoop: while position < end {
            let want = Int(min(Int64(chunk), end - position))
            let got: Int = buffer.withUnsafeMutableBytes { raw in
                var total = 0
                while total < want {
                    let n = pread(fd, raw.baseAddress! + total, want - total, off_t(position) + off_t(total))
                    if n < 0 {
                        if errno == EINTR { continue }
                        return total > 0 ? total : -1
                    }
                    if n == 0 { break }
                    total += n
                }
                return total
            }
            if got <= 0 { break }
            buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[0..<got])
                var start = 0
                while start < got {
                    guard let nl = memchr(bytes.baseAddress! + start, 0x0A, got - start) else { break }
                    let i = bytes.baseAddress!.distance(to: UnsafeRawPointer(nl))
                    if skippingLongLine {
                        skippingLongLine = false
                    } else if pending.isEmpty {
                        if i > start {
                            onLine(UnsafeRawBufferPointer(rebasing: bytes[start..<i]))
                            lines += 1
                        }
                    } else {
                        pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start..<i]))
                        pending.withUnsafeBytes { onLine($0) }
                        lines += 1
                        pending.removeAll(keepingCapacity: false)
                    }
                    start = i + 1
                    consumed = position + Int64(start)
                }
                if start < got, !skippingLongLine {
                    let rest = got - start
                    if pending.count + rest > Self.maxLineLength {
                        Self.logger.warning("Skipping a line over 64 MB in \(path, privacy: .public)")
                        pending.removeAll(keepingCapacity: false)
                        skippingLongLine = true
                    } else {
                        pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start..<got]))
                    }
                }
            }
            position += Int64(got)
            if got < want { break readLoop }
        }
        let bytes = consumed - file.offset
        file.offset = consumed
        return bytes > 0 ? .appended(lines: lines, bytes: bytes) : .unchanged
    }
}
