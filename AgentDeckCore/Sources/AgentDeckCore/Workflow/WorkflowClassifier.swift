import Foundation

/// What a sidebar entry is.
public enum ProjectKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A workflow group from the rules.
    case workflow
    /// A real project folder, named after the folder.
    case folder
    /// No real project folder, and no group matched.
    case others
}

/// A task's sidebar entry.
public struct ProjectEntry: Sendable, Hashable {
    public var kind: ProjectKind
    public var name: String

    public init(kind: ProjectKind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static let others = ProjectEntry(kind: .others, name: WorkflowRules.othersName)
}

/// Decides which sidebar entry a task belongs to. Pure: the same signals, rules and home folder always give
/// the same entry. Each task goes in exactly one entry, decided in this order:
/// 1. The first workflow group with a matching rule (`WorkflowGroup` documents each rule).
/// 2. Otherwise its real project folder, named after the folder.
/// 3. Otherwise Others.
///
/// A session has no real project folder when its working folder is a Claude desktop scratch workspace,
/// a temporary folder, the home folder itself, or unknown. A Claude Code worktree stands for its
/// repository (`projectFolder`).
public struct WorkflowClassifier: Sendable {
    public let rules: WorkflowRules
    /// Expands "~" in folder patterns, and is never a real project folder itself.
    public let home: String
    private let groups: [CompiledGroup]

    public init(rules: WorkflowRules, home: String = NSHomeDirectory()) {
        self.rules = rules
        self.home = Self.standardized(home)
        let home = self.home
        groups = rules.activeGroups.map { CompiledGroup($0, home: home) }
    }

    public func classify(_ signals: TaskSignals) -> ProjectEntry {
        let folder = Self.standardized(signals.workingFolder)
        let real = Self.hasRealFolder(folder, home: home)
        let prepared = PreparedSignals(signals, folder: folder)
        for group in groups where group.matches(prepared, realFolder: real) {
            return ProjectEntry(kind: .workflow, name: group.name)
        }
        return real ? ProjectEntry(kind: .folder, name: Self.folderName(folder)) : .others
    }

    public static func classify(_ signals: TaskSignals, rules: WorkflowRules, home: String) -> ProjectEntry {
        WorkflowClassifier(rules: rules, home: home).classify(signals)
    }

    /// Folders that aren't a project: a Claude desktop scratch workspace, a temporary folder
    /// (`/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`), the home folder itself, `/`, or none.
    /// A worktree is judged by its repository (`projectFolder`).
    public static func hasRealFolder(_ path: String, home: String) -> Bool {
        let folder = projectFolder(path)
        guard !folder.isEmpty, folder != "/" else { return false }
        if folder.contains("/scratch-workspaces/") { return false }
        if temporaryRoots.contains(where: { isInside(folder, $0) }) { return false }
        return folder.caseInsensitiveCompare(standardized(home)) != .orderedSame
    }

    static let temporaryRoots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]

    /// The project folder's own name (last path component), so a worktree is named after its repository.
    public static func folderName(_ path: String) -> String {
        (projectFolder(path) as NSString).lastPathComponent
    }

    /// Where Claude Code puts a git worktree: `<repo>/.claude/worktrees/<name>` (`claude --worktree`,
    /// `EnterWorktree`, and the desktop app's worktree sessions).
    static let worktreesFolder = "/.claude/worktrees/"

    /// The folder a working folder counts as. A Claude Code worktree is a checkout of its repository, so it
    /// counts as the repository: `<repo>/.claude/worktrees/<name>/sub` is `<repo>/sub`. Read from the path
    /// alone, so it still works once the worktree is removed (history rows keep their path).
    public static func projectFolder(_ path: String) -> String {
        var folder = standardized(path)
        while let marker = folder.range(of: worktreesFolder, options: .caseInsensitive) {
            let name = folder[marker.upperBound...].prefix { $0 != "/" }
            guard !name.isEmpty else { break }
            folder = String(folder[..<marker.lowerBound]) + folder[name.endIndex...]
            if folder.isEmpty { return "/" }
        }
        return folder
    }

    /// Trimmed, without trailing slashes (except `/` itself).
    static func standardized(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `path` is `folder` or inside it, ignoring case (the default macOS volume is case-insensitive).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        guard path.count >= folder.count else { return false }
        let p = path.lowercased(), f = folder.lowercased()
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    // MARK: Matching

    /// A task's signals, lowercased once per classification.
    private struct PreparedSignals {
        var agentTypes: Set<String>
        var skills: [SkillName]
        /// Full names and, for MCP tools, the tool's own name after the last "__".
        var tools: Set<String>
        var folder: String
        /// The working folder and each parent's name, normalized for name patterns.
        var folderNames: [String]
        var title: String

        init(_ s: TaskSignals, folder: String) {
            agentTypes = Set(s.agentTypes.map { $0.lowercased() })
            skills = s.skills.map(SkillName.init)
            var tools = Set<String>()
            for name in s.tools {
                let lower = name.lowercased()
                tools.insert(lower)
                if let r = lower.range(of: "__", options: .backwards) { tools.insert(String(lower[r.upperBound...])) }
            }
            self.tools = tools
            self.folder = folder
            folderNames = folder.split(separator: "/").map { CompiledGroup.normalizedName($0) }
            title = s.title.lowercased()
        }
    }

    /// "anthropic-skills:morning" → namespace "anthropic-skills", bare "morning".
    private struct SkillName: Sendable {
        var full: String
        var bare: String
        var hasNamespace: Bool

        init(_ raw: String) {
            full = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if full.hasPrefix("/") { full.removeFirst() }
            if let colon = full.lastIndex(of: ":") {
                bare = String(full[full.index(after: colon)...])
                hasNamespace = true
            } else {
                bare = full
                hasNamespace = false
            }
        }

        /// Equal, or equal without the namespace when either side has none.
        func matches(_ other: SkillName) -> Bool {
            full == other.full || ((!hasNamespace || !other.hasNamespace) && bare == other.bare)
        }
    }

    private struct CompiledGroup: Sendable {
        let name: String
        let agentTypes: Set<String>
        let skills: [SkillName]
        let tools: [String]
        /// Absolute folders ("~" expanded).
        let folderPaths: [String]
        /// Normalized folder-name globs.
        let folderNames: [String]
        let keywords: [String]

        init(_ g: WorkflowGroup, home: String) {
            func clean(_ list: [String]) -> [String] {
                list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            name = g.displayName
            agentTypes = Set(clean(g.agentTypes).map { $0.lowercased() })
            skills = clean(g.skills).map(SkillName.init)
            tools = clean(g.tools).map { $0.lowercased() }
            var paths: [String] = []
            var names: [String] = []
            for pattern in clean(g.folders) {
                if pattern == "~" || pattern.hasPrefix("~/") {
                    paths.append(WorkflowClassifier.standardized(home + pattern.dropFirst()))
                } else if pattern.hasPrefix("/") {
                    paths.append(WorkflowClassifier.standardized(pattern))
                } else {
                    names.append(Self.normalizedName(Substring(pattern)))
                }
            }
            folderPaths = paths
            folderNames = names
            keywords = clean(g.titleKeywords).map { $0.lowercased() }
        }

        func matches(_ s: PreparedSignals, realFolder: Bool) -> Bool {
            if !agentTypes.isDisjoint(with: s.agentTypes) { return true }
            for rule in skills where s.skills.contains(where: rule.matches) { return true }
            if tools.contains(where: s.tools.contains) { return true }
            if folderPaths.contains(where: { WorkflowClassifier.isInside(s.folder, $0) }) { return true }
            for pattern in folderNames where s.folderNames.contains(where: { Self.glob(pattern, $0) }) {
                return true
            }
            if !realFolder, keywords.contains(where: { Self.containsWord(s.title, $0) }) { return true }
            return false
        }

        /// Lowercased, with "_" and spaces read as "-".
        static func normalizedName(_ name: Substring) -> String {
            String(name.lowercased().map { $0 == "_" || $0 == " " ? "-" : $0 })
        }

        /// `*` matches any run of characters, `?` one character.
        static func glob(_ pattern: String, _ text: String) -> Bool {
            let p = Array(pattern), t = Array(text)
            var pi = 0, ti = 0
            var star = -1, mark = 0
            while ti < t.count {
                if pi < p.count, p[pi] == "*" {
                    star = pi
                    mark = ti
                    pi += 1
                } else if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                    pi += 1
                    ti += 1
                } else if star >= 0 {
                    pi = star + 1
                    mark += 1
                    ti = mark
                } else {
                    return false
                }
            }
            while pi < p.count, p[pi] == "*" { pi += 1 }
            return pi == p.count
        }

        /// `keyword` occurs in `text` at the start of a word (both lowercased).
        static func containsWord(_ text: String, _ keyword: String) -> Bool {
            var range = text.startIndex..<text.endIndex
            while let hit = text.range(of: keyword, range: range) {
                if hit.lowerBound == text.startIndex { return true }
                let before = text[text.index(before: hit.lowerBound)]
                if !before.isLetter && !before.isNumber { return true }
                range = text.index(after: hit.lowerBound)..<text.endIndex
            }
            return false
        }
    }
}
