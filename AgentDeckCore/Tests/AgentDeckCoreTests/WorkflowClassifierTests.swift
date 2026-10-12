import Foundation
import Testing
@testable import AgentDeckCore

/// The pure classifier (workflow group, then real folder, then Others) and the signals the parser and
/// reducer collect for it.
@Suite struct WorkflowClassifierTests {
    static let home = Fixtures.home
    static func scratch(_ suffix: String = "cfe996") -> String {
        "/Users/dev/Library/Application Support/Claude/scratch-workspaces/9e5ecb1e/46b18842/scratch-2026-10-02-\(suffix)"
    }

    static func entry(_ folder: String, title: String = "Untitled", agents: [String] = [], skills: [String] = [],
                      tools: [String] = [], rules: WorkflowRules = .defaults) -> ProjectEntry {
        let signals = TaskSignals(workingFolder: folder, title: title, agentTypes: agents, skills: skills, tools: tools)
        return WorkflowClassifier.classify(signals, rules: rules, home: home)
    }

    static func folder(_ name: String) -> ProjectEntry { ProjectEntry(kind: .folder, name: name) }
    static func group(_ name: String) -> ProjectEntry { ProjectEntry(kind: .workflow, name: name) }

    // MARK: Order

    @Test func workflowRuleThenFolderThenOthers() {
        // 1. A matching workflow rule wins, even over a real folder.
        #expect(Self.entry("/Users/dev/Projects/AgentDeck", agents: ["Explore", "gmail-monitor"]) == Self.group("GmailMonitor"))
        // 2. Otherwise the real folder.
        #expect(Self.entry("/Users/dev/Projects/AgentDeck", agents: ["Explore"]) == Self.folder("AgentDeck"))
        // 3. Otherwise Others.
        #expect(Self.entry(Self.scratch(), agents: ["Explore"]) == .others)

        // When two groups match, the first in order wins.
        let both = TaskSignals(workingFolder: Self.scratch(), title: "t", agentTypes: ["gmail-monitor", "video-editor"])
        var rules = WorkflowRules.defaults
        #expect(WorkflowClassifier(rules: rules, home: Self.home).classify(both) == Self.group("GmailMonitor"))
        rules.groups.swapAt(0, 1)
        #expect(WorkflowClassifier(rules: rules, home: Self.home).classify(both) == Self.group("PubgMontages"))
    }

    @Test func realFolderSessionStaysUnderItsFolder() {
        let agentDeck = Self.entry("/Users/dev/Projects/AgentDeck", title: "AgentDeck macOS app",
                                   agents: ["Explore", "software-engineer", "code-reviewer"],
                                   skills: ["anthropic-skills:my-writing-style"],
                                   tools: ["Agent", "Bash", "Read", "mcp__ccd_session__mark_chapter"])
        #expect(agentDeck == Self.folder("AgentDeck"))
        #expect(Self.entry("/Users/dev/Projects/AgentDeck/", title: "Trailing slash") == Self.folder("AgentDeck"))
        #expect(Self.entry("/Users/dev/localbiz", title: "Localbiz continuation",
                           agents: ["localbiz-qa", "localbiz-site-builder"]) == Self.folder("localbiz"))
        // A folder started later gets its own entry, named after the folder.
        #expect(Self.entry("/Users/dev/Projects/new-thing") == Self.folder("new-thing"))
    }

    @Test func worktreeSessionsStayUnderTheirRepository() {
        // `claude --worktree` and the desktop app's worktree sessions: <repo>/.claude/worktrees/<name>.
        let worktree = "/Users/dev/ai-engineer-course/.claude/worktrees/cool-chaplygin-f89812"
        #expect(Self.entry(worktree, title: "Close stale open sessions") == Self.folder("ai-engineer-course"))
        #expect(WorkflowClassifier.projectFolder(worktree) == "/Users/dev/ai-engineer-course")
        #expect(Self.entry("/Users/dev/Projects/AgentDeck/.Claude/Worktrees/fix-login/") == Self.folder("AgentDeck"))
        // A folder inside a worktree is named like the same folder in the main checkout.
        #expect(Self.entry("/Users/dev/Projects/AgentDeck/.claude/worktrees/fix-login/AgentDeckCore")
                == Self.folder("AgentDeckCore"))
        // Title keywords still don't apply: the worktree is a real folder.
        #expect(Self.entry("/Users/dev/Projects/AgentDeck/.claude/worktrees/x", title: "PUBG montage") == Self.folder("AgentDeck"))
        // Folder rules match the repository.
        #expect(Self.entry("/Users/dev/Projects/Multi-agent-trading-bot/.claude/worktrees/x") == Self.group("TradingBot"))
        #expect(Self.entry("/Users/dev/Projects/Pubg_Tools/.claude/worktrees/x") == Self.group("PubgMontages"))
        // A worktree of the home folder is the home folder.
        #expect(Self.entry("/Users/dev/.claude/worktrees/x") == .others)
        #expect(Self.entry("/.claude/worktrees/x") == .others)
        // Only that layout counts.
        #expect(Self.entry("/Users/dev/Projects/AgentDeck/.claude/worktrees") == Self.folder("worktrees"))
        #expect(Self.entry("/Users/dev/Projects/AgentDeck-worktrees/fix-login") == Self.folder("fix-login"))
        #expect(WorkflowClassifier.projectFolder("") == "")
    }

    @Test func titleKeywordDoesNotPullARealFolderSessionIntoAGroup() {
        let title = "Show the Gmail unread count next to the PUBG montage preview"
        #expect(Self.entry("/Users/dev/Projects/AgentDeck", title: title) == Self.folder("AgentDeck"))
        #expect(Self.entry(Self.scratch(), title: title) == Self.group("GmailMonitor"))
        // Keywords match at the start of a word, ignoring case.
        #expect(Self.entry(Self.scratch(), title: "Freelance invoices") == .others)            // not "reel"
        #expect(Self.entry(Self.scratch(), title: "Instagram reels for Saturday") == Self.group("PubgMontages"))
        #expect(Self.entry(Self.scratch(), title: "Your MORNING BRIEF, Tuesday") == Self.group("GmailMonitor"))
        #expect(Self.entry(Self.scratch(), title: "Notmorning brief") == .others)
    }

    @Test func tradingBotFolderRule() {
        let bot = Self.group("TradingBot")
        #expect(Self.entry("/Users/dev/Projects/Multi-agent-trading-bot") == bot)
        #expect(Self.entry("/Users/dev/Projects/multi-agent-trading-bot") == bot)
        // Any parent folder, and "-", "_" and spaces read the same.
        #expect(Self.entry("/Users/dev/Projects/Multi_Agent_Trading_Bot/backend/agents") == bot)
        #expect(Self.entry("/Users/dev/Code/multi agent trading bot") == bot)
        // A GitHub download's suffix still matches the wildcard.
        #expect(Self.entry("/Users/dev/Downloads/multi-agent-trading-bot-main") == bot)
        // Other folders don't.
        #expect(Self.entry("/Users/dev/Projects/trading-bot") == Self.folder("trading-bot"))
        #expect(Self.entry("/Users/dev/Projects/my-multi-agent-trading-bot") == Self.folder("my-multi-agent-trading-bot"))
        // The repo's sessions go to TradingBot whatever they do.
        #expect(Self.entry("/Users/dev/Projects/Multi-agent-trading-bot", title: "Fix the Gmail alerts",
                           agents: ["Explore"]) == bot)
    }

    @Test func temporaryAndHomeFoldersLandInOthers() {
        for folder in [
            "/tmp", "/tmp/notes", "/private/tmp/claude-501/-Users-dev-Projects-AgentDeck/fb4572c1/scratchpad/second-session",
            "/private/var/folders/kd/2mt6kkd121dghvdktmwfzdg80000gn/T/tmp.cO4pZBs8FI", "/var/folders/kd/T/x",
            "/Users/dev", "/Users/dev/", "/users/DEV", "/", "", Self.scratch(),
        ] {
            #expect(Self.entry(folder, title: "Make two Agent calls", agents: ["Explore"]) == .others, "\(folder)")
            #expect(!WorkflowClassifier.hasRealFolder(folder, home: Self.home), "\(folder)")
        }
        // Lookalikes are real folders.
        #expect(Self.entry("/tmpfiles/report") == Self.folder("report"))
        #expect(Self.entry("/Users/dev/voice-assistant") == Self.folder("voice-assistant"))
        #expect(Self.entry("/Users/devon") == Self.folder("devon"))
    }

    // MARK: Rules

    @Test func skillToolAndFolderPathRules() {
        // A skill without a namespace matches it in any namespace, both ways.
        #expect(Self.entry(Self.scratch(), skills: ["morning"]) == Self.group("GmailMonitor"))
        #expect(Self.entry(Self.scratch(), skills: ["anthropic-skills:pubg-montage"]) == Self.group("PubgMontages"))
        #expect(Self.entry(Self.scratch(), skills: ["someone-else:morning"]) == .others)
        // An MCP tool matches by its own name on any server.
        #expect(Self.entry(Self.scratch(), tools: ["mcp__07c0f660-e970-4f41__createScheduledPostForReview"])
                == Self.group("PubgMontages"))
        #expect(Self.entry(Self.scratch(), tools: ["mcp__07c0f660-e970-4f41__getScheduledPosts"]) == .others)
        // "~" patterns: the folder and anything inside it, ignoring case.
        #expect(Self.entry("/Users/dev/Projects/Pubg_Tools") == Self.group("PubgMontages"))
        #expect(Self.entry("/Users/dev/projects/pubg_tools/scripts") == Self.group("PubgMontages"))
        #expect(Self.entry("/Users/dev/Projects/Pubg_Tools2") == Self.folder("Pubg_Tools2"))
        // Agent types ignore case too.
        #expect(Self.entry("/Users/dev/Projects/AgentDeck", agents: ["Video-Editor"]) == Self.group("PubgMontages"))
    }

    @Test func groupsWithoutAUsableNameOrAnyRuleNeverMatch() {
        let rules = WorkflowRules(groups: [
            WorkflowGroup(name: "  ", agentTypes: ["Explore"]),
            WorkflowGroup(name: "others", agentTypes: ["Explore"]),
            WorkflowGroup(name: " Research ", agentTypes: ["researcher"]),
            WorkflowGroup(name: "Research", agentTypes: ["Explore"]),
            WorkflowGroup(name: "Empty"),
        ])
        #expect(rules.groupNames == ["Research", "Empty"])
        #expect(Self.entry(Self.scratch(), agents: ["Explore"], rules: rules) == .others)
        #expect(Self.entry(Self.scratch(), agents: ["researcher"], rules: rules) == Self.group("Research"))
        #expect(Self.entry(Self.scratch(), title: "Empty", rules: rules) == .others)
    }

    @Test func defaultsSortTheRealSessions() {
        // Each session's signals as its transcript has them (docs/data-sources.md §9).
        #expect(Self.entry(Self.scratch(), title: "Daily Gmail report", agents: ["gmail-monitor"],
                           tools: ["Agent"]) == Self.group("GmailMonitor"))
        #expect(Self.entry(Self.scratch(), title: "Gmail monitor subagent", agents: ["general-purpose", "gmail-monitor"],
                           tools: ["Agent", "Bash", "ToolSearch", "Write", "mcp__scheduled-tasks__create_scheduled_task"])
                == Self.group("GmailMonitor"))
        // No PUBG skill or video-editor run in this one: its title decides.
        #expect(Self.entry(Self.scratch("3535d5"), title: "Video quality enhancement",
                           skills: ["agents", "anthropic-skills:skill-creator"],
                           tools: ["Bash", "Edit", "Read", "SendUserFile", "Skill", "Write"]) == Self.group("PubgMontages"))
        #expect(Self.entry(Self.scratch("44420f"), title: "Task execution dashboard UI") == .others)
        #expect(Self.entry("/private/tmp/claude-501/-Users-dev-Projects-AgentDeck/fb4572c1/scratchpad/second-session",
                           title: "Make two Agent tool calls in the same message", agents: ["Explore"]) == .others)
        #expect(Self.entry("/Users/dev/localbiz", title: "Language toggle for Azteca website",
                           skills: ["localbiz-pipeline"]) == Self.folder("localbiz"))
    }

    @Test func rulesDecodeLeniently() throws {
        let rules = WorkflowRules.defaults
        #expect(try JSONDecoder().decode(WorkflowRules.self, from: JSONEncoder().encode(rules)) == rules)
        // A saved group with fields missing (an older or newer build) still loads.
        let partial = #"{"groups":[{"name":"Inbox","agentTypes":["gmail-monitor"],"future":1}]}"#
        let decoded = try JSONDecoder().decode(WorkflowRules.self, from: Data(partial.utf8))
        #expect(decoded.groupNames == ["Inbox"])
        #expect(decoded.groups[0].skills.isEmpty && decoded.groups[0].folders.isEmpty)
    }

    // MARK: Signals

    private static func reduce(_ lines: [String], into s: inout SessionState) {
        let parser = LineParser()
        for line in lines {
            if let e = parser.parse(Data(line.utf8)) { SessionReducer.apply(e, owner: .main, to: &s, now: Fixtures.now) }
        }
    }

    @Test func reducerCollectsSkillsSlashCommandsAndToolNames() {
        var s = SessionState(id: "s1")
        s.mainSeen = true
        Self.reduce([
            SessionReducerTests.prompt("Cut last night's clips", ts: "2026-10-02T23:00:00.000Z"),
            SessionReducerTests.toolCall("Skill", id: "toolu_S1", ts: "2026-10-02T23:00:01.000Z",
                                         input: #"{"skill":"anthropic-skills:pubg-montage","args":"Saturday"}"#),
            SessionReducerTests.toolCall("mcp__07c0f660__createScheduledPost", id: "toolu_M1", ts: "2026-10-02T23:00:02.000Z",
                                         input: #"{"text":"reel"}"#),
            // A typed slash command: no Skill tool call, only the command echo.
            #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-message>morning</command-message>\n<command-name>/morning</command-name>\n<command-args>today</command-args>"},"timestamp":"2026-10-02T23:00:03.000Z","origin":{"kind":"human"}}"#,
        ], into: &s)
        #expect(s.skills == ["anthropic-skills:pubg-montage", "morning"])
        #expect(s.toolNames == ["Skill", "mcp__07c0f660__createScheduledPost"])
        #expect(s.main.prompt == "Cut last night's clips", "a command echo isn't a prompt")

        // Both skills match a group; GmailMonitor (the /morning command) comes first.
        let snap = Fixtures.snapshot(s)
        #expect(snap.projectName == "GmailMonitor")
        #expect(snap.projectKind == .workflow)
    }

    @Test func signalListsAreCapped() {
        var s = SessionState(id: "s1")
        let lines = (0..<(TaskSignals.listLimit + 10)).map { i in
            SessionReducerTests.toolCall("mcp__srv__tool\(i)", id: "toolu_\(i)", ts: "2026-10-02T23:00:00.000Z", input: "{}")
        }
        Self.reduce(lines, into: &s)
        #expect(s.toolNames.count == TaskSignals.listLimit)
        let long = String(repeating: "x", count: 1000)
        #expect(TaskSignals(workingFolder: "/a", title: "t", skills: [long, long, ""]).skills.map(\.count)
                == [TextUtil.fieldLimit])
    }

    @Test func storedSnapshotsGiveBackTheirSignals() {
        // History rows from before signals were stored: what the snapshot kept is enough.
        let s = Fixtures.reduce(Fixtures.s08cb)
        let snap = Fixtures.snapshot(s)
        let recovered = TaskSignals(snapshot: snap)
        #expect(recovered.workingFolder == snap.projectPath)
        #expect(recovered.title == snap.title)
        #expect(recovered.agentTypes == ["general-purpose", "gmail-monitor"])
        #expect(Fixtures.classifier.classify(recovered) == Self.group("GmailMonitor"))
    }
}
