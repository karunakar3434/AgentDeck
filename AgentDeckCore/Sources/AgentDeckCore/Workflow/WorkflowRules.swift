import Foundation

/// A workflow group: a sidebar entry for work that doesn't live in a project folder of its own, such as a
/// scheduled Gmail check or a video pipeline. A task joins the first group with any matching rule
/// (see `WorkflowClassifier`).
public struct WorkflowGroup: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Subagent types (`subagent_type`), e.g. "gmail-monitor". Matches when any agent of the task has one.
    public var agentTypes: [String]
    /// Skills, from Skill tool calls and slash commands. A name without a namespace matches it in any
    /// namespace: "morning" and "anthropic-skills:morning" match each other.
    public var skills: [String]
    /// Tool names. An MCP tool also matches by its own name on any server: "createScheduledPost" matches
    /// "mcp__<server>__createScheduledPost".
    public var tools: [String]
    /// Working-folder patterns. With a leading "/" or "~": that folder or anything inside it. Otherwise a
    /// folder name (`*` and `?` wildcards; "-", "_" and spaces are interchangeable) that the working folder
    /// or any of its parents has.
    public var folders: [String]
    /// Words in the task title, matched at the start of a word. Only used for sessions with no real
    /// project folder, so a project session that mentions one stays under its folder.
    public var titleKeywords: [String]

    public init(id: UUID = UUID(), name: String, agentTypes: [String] = [], skills: [String] = [],
                tools: [String] = [], folders: [String] = [], titleKeywords: [String] = []) {
        self.id = id
        self.name = name
        self.agentTypes = agentTypes
        self.skills = skills
        self.tools = tools
        self.folders = folders
        self.titleKeywords = titleKeywords
    }

    /// The name as shown and matched: trimmed.
    public var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when no rule is set, so the group never matches anything.
    public var hasNoRules: Bool {
        [agentTypes, skills, tools, folders, titleKeywords].allSatisfy { list in
            list.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    enum CodingKeys: String, CodingKey { case id, name, agentTypes, skills, tools, folders, titleKeywords }

    /// Lenient: a missing list is empty and a missing id is new, so saved rules survive added fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(UUID.self, .id) ?? UUID()
        name = c.lenient(String.self, .name) ?? ""
        agentTypes = c.lenient([String].self, .agentTypes) ?? []
        skills = c.lenient([String].self, .skills) ?? []
        tools = c.lenient([String].self, .tools) ?? []
        folders = c.lenient([String].self, .folders) ?? []
        titleKeywords = c.lenient([String].self, .titleKeywords) ?? []
    }
}

/// The workflow groups, in sidebar and matching order. Folder projects and Others aren't configured:
/// they follow from each task's working folder.
public struct WorkflowRules: Sendable, Hashable, Codable {
    /// The entry for sessions with no real project folder that match no group. Always shown, always last.
    public static let othersName = "Others"

    public var groups: [WorkflowGroup]

    public init(groups: [WorkflowGroup]) {
        self.groups = groups
    }

    /// The groups that take part in matching, in order: the first group of each name, skipping empty names
    /// and "Others" (reserved).
    public var activeGroups: [WorkflowGroup] {
        var seen = Set<String>()
        return groups.filter { group in
            let name = group.displayName
            guard !name.isEmpty, !Self.isReserved(name) else { return false }
            return seen.insert(name).inserted
        }
    }

    /// `activeGroups` names, in order.
    public var groupNames: [String] { activeGroups.map(\.displayName) }

    /// "Others", in any case.
    public static func isReserved(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(othersName) == .orderedSame
    }

    enum CodingKeys: String, CodingKey { case groups }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = c.lenient([WorkflowGroup].self, .groups) ?? []
    }

    /// GmailMonitor, PubgMontages and TradingBot, built from signals found in real transcripts
    /// (docs/data-sources.md §9). Fixed ids, so the defaults always equal themselves.
    public static let defaults = WorkflowRules(groups: [
        WorkflowGroup(
            id: UUID(uuidString: "D6F0C5A2-3B1E-4C7A-9E21-5A0B7C1D0001")!,
            name: "GmailMonitor",
            agentTypes: ["gmail-monitor"],
            skills: ["anthropic-skills:morning"],
            titleKeywords: ["Gmail", "morning brief"]),
        WorkflowGroup(
            id: UUID(uuidString: "D6F0C5A2-3B1E-4C7A-9E21-5A0B7C1D0002")!,
            name: "PubgMontages",
            agentTypes: ["video-editor"],
            skills: ["pubg-montage", "pubg-instagram-post", "video-enhance"],
            tools: ["createScheduledPost", "createScheduledPostForReview"],
            folders: ["~/Projects/Pubg_Tools"],
            titleKeywords: ["PUBG", "montage", "video", "Instagram", "reel"]),
        WorkflowGroup(
            id: UUID(uuidString: "D6F0C5A2-3B1E-4C7A-9E21-5A0B7C1D0003")!,
            name: "TradingBot",
            folders: ["multi-agent-trading-bot*"],
            titleKeywords: ["trading bot"]),
    ])
}
