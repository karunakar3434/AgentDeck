import Foundation

/// What a path under the data root is (architecture §4).
enum FileRole: Sendable, Hashable {
    /// `projects/<dir>/<sid>.jsonl`
    case main(sessionID: String)
    /// `projects/<dir>/<sid>/subagents/agent-<aid>.jsonl`
    case subagent(sessionID: String, agentID: String)
    /// `projects/<dir>/<sid>/subagents/agent-<aid>.meta.json`
    case meta(sessionID: String, agentID: String)
    /// `projects/<dir>/<sid>/custom-title.json`
    case title(sessionID: String)
    /// `sessions/<pid>.json` (`.key` files are never classified, so never opened)
    case pid(Int32)
    /// `agents/*.md`
    case agentDefinition
    /// `agentdeck/events.jsonl`
    case hook
    /// `projects/<dir>` (a new session file changes its listing)
    case projectDirectory
    /// `projects/<dir>/<sid>` or its `subagents` directory (a moved directory produces one event)
    case sessionDirectory(sessionID: String)
    /// Watched top-level directories themselves (`projects`, `sessions`, `agents`, `agentdeck`).
    case watchedDirectory
    case ignored

    var sessionID: String? {
        switch self {
        case .main(let s), .subagent(let s, _), .meta(let s, _), .title(let s), .sessionDirectory(let s): s
        default: nil
        }
    }

    var agentID: String? {
        switch self {
        case .subagent(_, let a), .meta(_, let a): a
        default: nil
        }
    }

    var owner: FileOwner? {
        switch self {
        case .main: .main
        case .subagent(_, let a): .agent(a)
        default: nil
        }
    }
}

/// Path → `FileRole` by string inspection only (no I/O).
struct PathClassifier: Sendable {
    /// The data root with symlinks resolved (FSEvents reports real paths), then as given.
    let roots: [String]
    /// The form every tracked path uses: the resolved root.
    var canonicalRoot: String { roots[0] }

    init(dataRoot: URL) {
        let given = Self.trim(dataRoot.standardizedFileURL.path)
        let real = Self.trim(FileIO.realPath(given))
        roots = real == given ? [real] : [real, given]
    }

    /// `path` rewritten under the canonical root when it uses another spelling of the root.
    func canonical(_ path: String) -> String {
        for root in roots.dropFirst() where path.hasPrefix(root) {
            let rest = path.dropFirst(root.count)
            if rest.isEmpty || rest.first == "/" { return canonicalRoot + rest }
        }
        return path
    }

    private static func trim(_ p: String) -> String {
        p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// Components below the data root, or nil when outside it.
    func relativeComponents(_ path: String) -> [Substring]? {
        for root in roots where path.hasPrefix(root) {
            let rest = path.dropFirst(root.count)
            if rest.isEmpty { return [] }
            guard rest.first == "/" else { continue }
            return rest.split(separator: "/", omittingEmptySubsequences: true)
        }
        return nil
    }

    func classify(_ path: String) -> FileRole {
        guard let c = relativeComponents(path), let top = c.first else { return .ignored }
        switch top {
        case "projects":
            return classifyProject(Array(c.dropFirst()))
        case "sessions":
            if c.count == 1 { return .watchedDirectory }
            guard c.count == 2, c[1].hasSuffix(".json") else { return .ignored }
            let stem = c[1].dropLast(5)
            guard !stem.isEmpty, stem.allSatisfy(\.isASCIIDigit), let pid = Int32(stem) else { return .ignored }
            return .pid(pid)
        case "agents":
            if c.count == 1 { return .watchedDirectory }
            return c.count == 2 && c[1].hasSuffix(".md") ? .agentDefinition : .ignored
        case "agentdeck":
            if c.count == 1 { return .watchedDirectory }
            return c.count == 2 && c[1] == "events.jsonl" ? .hook : .ignored
        default:
            return .ignored
        }
    }

    private func classifyProject(_ c: [Substring]) -> FileRole {
        switch c.count {
        case 0:
            return .watchedDirectory
        case 1:
            return .projectDirectory
        case 2:
            let name = c[1]
            if name.hasSuffix(".jsonl") {
                let sid = name.dropLast(6)
                return sid.isEmpty ? .ignored : .main(sessionID: String(sid))
            }
            if name.contains(".") || name == "memory" { return .ignored }
            return .sessionDirectory(sessionID: String(name))
        case 3:
            let sid = String(c[1])
            if c[2] == "custom-title.json" { return .title(sessionID: sid) }
            if c[2] == "subagents" { return .sessionDirectory(sessionID: sid) }
            return .ignored
        case 4:
            guard c[2] == "subagents", c[3].hasPrefix("agent-") else { return .ignored }
            let sid = String(c[1])
            let name = c[3]
            if name.hasSuffix(".meta.json") {
                let aid = name.dropFirst(6).dropLast(10)
                return aid.isEmpty ? .ignored : .meta(sessionID: sid, agentID: String(aid))
            }
            if name.hasSuffix(".jsonl") {
                let aid = name.dropFirst(6).dropLast(6)
                return aid.isEmpty ? .ignored : .subagent(sessionID: sid, agentID: String(aid))
            }
            return .ignored
        default:
            return .ignored
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
