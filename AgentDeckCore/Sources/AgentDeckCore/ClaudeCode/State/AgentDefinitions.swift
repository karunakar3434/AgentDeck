import Foundation

/// Agent definition `model:` frontmatter, cached per directory (architecture §8).
///
/// Lookup order: `<projectPath>/.claude/agents` (wins, per the Claude Code docs), then `<dataRoot>/agents`.
/// The user directory is invalidated by FSEvents (`invalidateUserDefinitions`); project directories are
/// revalidated on lookup when their entry is older than 30 s (list the directory and compare mtimes).
/// Only reads; a missing directory caches as empty.
struct AgentDefinitions: Sendable {
    static let projectRevalidateInterval: TimeInterval = 30

    struct Directory: Sendable {
        /// name → model (nil when the file has no `model:`).
        var models: [String: String?]
        /// file name → mtime, for revalidation.
        var signature: [String: Date]
        var checkedAt: Date
    }

    let userDirectory: String
    private var user: Directory?
    private var projects: [String: Directory] = [:]

    init(dataRoot: String) {
        userDirectory = (dataRoot as NSString).appendingPathComponent("agents")
    }

    mutating func invalidateUserDefinitions() {
        user = nil
    }

    /// The definition's model for `agentType` (raw, may be "inherit"), project definitions first.
    mutating func model(for agentType: String, projectPath: String?, now: Date) -> String? {
        if let projectPath, !projectPath.isEmpty {
            let dir = (projectPath as NSString).appendingPathComponent(".claude/agents")
            let entry = projectDirectory(dir, now: now)
            if let found = entry.models[agentType] { return found }
        }
        if user == nil { user = Self.load(userDirectory, now: now) }
        if let found = user?.models[agentType] { return found }
        return nil
    }

    private mutating func projectDirectory(_ dir: String, now: Date) -> Directory {
        if var cached = projects[dir] {
            if now.timeIntervalSince(cached.checkedAt) < Self.projectRevalidateInterval { return cached }
            let signature = Self.signature(dir)
            if signature == cached.signature {
                cached.checkedAt = now
                projects[dir] = cached
                return cached
            }
        }
        let loaded = Self.load(dir, now: now)
        projects[dir] = loaded
        return loaded
    }

    private static func signature(_ dir: String) -> [String: Date] {
        var sig: [String: Date] = [:]
        for name in FileIO.list(dir) where name.hasSuffix(".md") {
            if let st = FileStat.of(path: (dir as NSString).appendingPathComponent(name)) { sig[name] = st.mtime }
        }
        return sig
    }

    static func load(_ dir: String, now: Date) -> Directory {
        var models: [String: String?] = [:]
        var sig: [String: Date] = [:]
        for name in FileIO.list(dir) where name.hasSuffix(".md") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let st = FileStat.of(path: path), !st.isDirectory else { continue }
            sig[name] = st.mtime
            guard let data = FileIO.readSmallFile(path, limit: 256 * 1024) else { continue }
            let stem = String(name.dropLast(3))
            let parsed = parseFrontmatter(String(decoding: data, as: UTF8.self))
            models[parsed.name ?? stem] = parsed.model
        }
        return Directory(models: models, signature: sig, checkedAt: now)
    }

    /// `name:` and `model:` from a leading `---` block. Values may be quoted.
    static func parseFrontmatter(_ text: String) -> (name: String?, model: String?) {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).makeIterator()
        guard let first = lines.next(), first.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?
        var model: String?
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "name": name = value.isEmpty ? nil : value
            case "model": model = value.isEmpty ? nil : value
            default: break
            }
        }
        return (name, model)
    }
}
