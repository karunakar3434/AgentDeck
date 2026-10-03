import Foundation

/// What a task's sidebar entry is decided from, all read from its transcripts. Stored with each history
/// row, so changing the rules reclassifies history without reading a transcript again.
public struct TaskSignals: Sendable, Hashable, Codable {
    /// Each list keeps at most this many distinct names (each at most `TextUtil.fieldLimit` characters).
    public static let listLimit = 128

    /// The session's working folder: its first `cwd`, or the latest `relocatedCwd`.
    public var workingFolder: String
    public var title: String
    /// Distinct subagent types, sorted.
    public var agentTypes: [String]
    /// Distinct skills: the Skill tool's `skill`, and slash commands without the "/". Sorted.
    public var skills: [String]
    /// Distinct names of the tools any agent of the task called, sorted.
    public var tools: [String]

    public init(workingFolder: String, title: String, agentTypes: [String] = [], skills: [String] = [],
                tools: [String] = []) {
        self.workingFolder = workingFolder
        self.title = title
        self.agentTypes = Self.distinct(agentTypes)
        self.skills = Self.distinct(skills)
        self.tools = Self.distinct(tools)
    }

    /// What a snapshot alone tells (history rows written before signals were stored): the working folder,
    /// the title, the agent types, and the Skill and tool names among each agent's recent tool calls.
    public init(snapshot: TaskSnapshot) {
        var skills: [String] = []
        var tools: [String] = []
        for run in snapshot.runs {
            for tool in run.recentTools {
                tools.append(tool.name)
                if tool.name == "Skill", !tool.summary.isEmpty { skills.append(tool.summary) }
            }
        }
        self.init(workingFolder: snapshot.projectPath, title: snapshot.title,
                  agentTypes: snapshot.runs.filter { !$0.isMain }.map(\.agentType), skills: skills, tools: tools)
    }

    /// Sorted, de-duplicated, empty names dropped, each clamped, at most `listLimit`.
    static func distinct(_ names: some Sequence<String>) -> [String] {
        var set = Set<String>()
        for name in names where !name.isEmpty {
            // Names already clamped by the reducer skip the character count.
            set.insert(name.utf8.count > TextUtil.fieldLimit ? TextUtil.clamp(name, limit: TextUtil.fieldLimit) : name)
        }
        return Array(set.sorted().prefix(listLimit))
    }

    enum CodingKeys: String, CodingKey { case workingFolder, title, agentTypes, skills, tools }

    /// Lenient, like the snapshot blobs: missing fields are empty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workingFolder = c.lenient(String.self, .workingFolder) ?? ""
        title = c.lenient(String.self, .title) ?? ""
        agentTypes = c.lenient([String].self, .agentTypes) ?? []
        skills = c.lenient([String].self, .skills) ?? []
        tools = c.lenient([String].self, .tools) ?? []
    }
}
