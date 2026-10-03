import Darwin
import Foundation

/// Identity, size and modification time of a file, from `stat`/`fstat`.
struct FileStat: Sendable, Hashable {
    /// `UInt64(st_ino) ^ (UInt64(st_dev) << 48)` with bit 63 cleared, so it fits an SQLite INTEGER.
    var fileID: UInt64
    var size: Int64
    var mtime: Date
    var isDirectory: Bool

    init(_ st: stat) {
        fileID = Self.fileID(dev: st.st_dev, ino: st.st_ino)
        size = Int64(st.st_size)
        mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9)
        isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func fileID(dev: dev_t, ino: ino_t) -> UInt64 {
        (UInt64(ino) ^ (UInt64(UInt32(bitPattern: dev)) << 48)) & 0x7FFF_FFFF_FFFF_FFFF
    }

    /// `stat` (follows symlinks). Nil when the path doesn't exist or can't be read.
    static func of(path: String) -> FileStat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileStat(st)
    }

    static func of(fd: Int32) -> FileStat? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return FileStat(st)
    }
}

enum FileIO {
    /// Reads a whole small file (sidecars, pid files). Nil when missing or larger than `limit`.
    static func readSmallFile(_ path: String, limit: Int = 1 << 20) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let st = FileStat.of(fd: fd), !st.isDirectory, st.size <= Int64(limit) else { return nil }
        var data = Data(count: Int(st.size))
        let count = data.count
        var total = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while total < count {
                let got = pread(fd, base + total, count - total, off_t(total))
                if got < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if got == 0 { break }
                total += got
            }
            return true
        }
        guard ok else { return nil }
        if total < count { data.removeSubrange(total...) }
        return data
    }

    /// Names in a directory (no "." / ".."). Empty when missing.
    static func list(_ directory: String) -> [String] {
        guard let dir = opendir(directory) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: bytes.baseAddress!)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// The path with symlinks resolved, or the standardized path when it doesn't exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
