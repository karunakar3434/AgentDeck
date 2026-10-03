import Foundation

// Content tables for the mock simulator: projects, task prompts, agent types and
// the text they produce. Text that varies per run is written as closures.

enum MockModels {
    static let opus = "claude-opus-5-5"
    static let sonnet = "claude-sonnet-5-5"
    static let haiku = "claude-haiku-4-5-20251001"
    static let fable = "claude-fable-5-1"

    /// Main-agent model mix.
    static let main: MockWeights<String> = [(opus, 0.6), (fable, 0.2), (sonnet, 0.2)]

    /// "claude-sonnet-5-5" → "sonnet", as passed in an Agent call's `model` parameter.
    static func alias(for id: String) -> String {
        let family = ModelFamily(modelID: id)
        return family == .other ? id : family.rawValue
    }
}

enum MockToolKind: Sendable {
    case read, grep, glob, bash, inspect, edit, write, webFetch, webSearch, todo, docs, gmail
}

struct MockTaskTemplate: Sendable {
    let title: String
    let branch: String
    /// Files this task is mostly about; prompts and tool calls favor them.
    let files: [String]
    /// Short (1–3 word) parts of the work, used to vary subagent descriptions.
    let areas: [String]
    /// The rest of the user's first prompt.
    let details: String
    /// What the main agent asks when it stops for input.
    let question: String
    /// Set for work outside a code project (a Gmail check, a video pipeline): a lighter script whose
    /// waves use these agent types.
    var workflow: MockWorkflow? = nil
}

/// The shape of a workflow task, and the signals that put it in a workflow group.
struct MockWorkflow: Sendable {
    /// Agent types every wave draws from.
    var agents: [String]
    /// Skills the main agent runs (Skill tool) as it starts.
    var skills: [String] = []
    /// A skill run after the first wave: the task changes sidebar entry partway through.
    var laterSkill: String? = nil
    /// Agent types for waves after `laterSkill`.
    var laterAgents: [String] = []
    /// Tool calls (name, summary) the main agent makes after its agents finish.
    var tools: [(name: String, summary: String)] = []
}

struct MockProject: Sendable {
    let name: String
    let path: String
    /// The context line of agent prompts for work outside a repo; nil for a repo.
    let about: String?
    let files: [String]
    let tests: [String]
    /// Build and test commands.
    let commands: [String]
    /// Read-only shell commands.
    let inspect: [String]
    let searches: [String]
    let globs: [String]
    let urls: [String]
    let queries: [String]
    let tasks: [MockTaskTemplate]
    let readable: [String]

    init(name: String, path: String? = nil, about: String? = nil, files: [String], tests: [String],
         commands: [String], inspect: [String], searches: [String], globs: [String], urls: [String],
         queries: [String], tasks: [MockTaskTemplate]) {
        self.name = name
        self.path = path ?? "\(MockScript.home)/Projects/\(name)"
        self.about = about
        self.files = files
        self.tests = tests
        self.commands = commands
        self.inspect = inspect
        self.searches = searches
        self.globs = globs
        self.urls = urls
        self.queries = queries
        self.tasks = tasks
        self.readable = files + tests
    }
}

/// Items with relative weights, prepared once for fast weighted picks.
struct MockWeights<T: Sendable>: Sendable, ExpressibleByArrayLiteral {
    let items: [T]
    /// Running totals of the weights.
    let cumulative: [Double]

    init(_ pairs: [(T, Double)]) {
        precondition(!pairs.isEmpty)
        items = pairs.map(\.0)
        var total = 0.0
        cumulative = pairs.map { total += $0.1; return total }
    }

    init(arrayLiteral elements: (T, Double)...) { self.init(elements) }
}

/// What a finished run's result text can mention.
struct MockResultContext {
    let area: String
    let file: String
    let file2: String
    let test: String
    let n: Int
}

/// An agent type: its duration, tools, models and the text its runs produce.
final class MockAgentProfile: Sendable {
    let type: String
    /// Typical real-world duration; the scenario's time scale compresses it.
    let baseSeconds: Double
    /// Past runs the estimate is based on (drives confidence).
    let samples: Int
    let tools: MockWeights<MockToolKind>
    /// Resolved model mix; nil means "same as the parent agent".
    let models: MockWeights<String?>
    /// May launch its own subagents.
    let canNest: Bool
    /// Agent call descriptions, given an area ("Find token storage code").
    let descriptions: [@Sendable (String) -> String]
    /// First paragraph of the prompt, given an area.
    let job: @Sendable (String) -> String
    let guidance: String
    let report: String
    let results: [@Sendable (MockResultContext) -> String]

    init(type: String, baseSeconds: Double, samples: Int, tools: MockWeights<MockToolKind>,
         models: MockWeights<String?>, canNest: Bool, descriptions: [@Sendable (String) -> String],
         job: @escaping @Sendable (String) -> String, guidance: String, report: String,
         results: [@Sendable (MockResultContext) -> String]) {
        self.type = type
        self.baseSeconds = baseSeconds
        self.samples = samples
        self.tools = tools
        self.models = models
        self.canNest = canNest
        self.descriptions = descriptions
        self.job = job
        self.guidance = guidance
        self.report = report
        self.results = results
    }
}

/// Which kind of work a wave of subagents does; picks the agent-type mix.
enum MockStage: Sendable {
    case explore, plan, build, review, nested, stress
    /// The task's own workflow agents (`MockWorkflow.agents`).
    case workflow
}

enum MockScript {
    /// The simulated home folder (project paths live under it).
    static let home = "/Users/dev"

    // MARK: Agent types

    static let profiles: [MockAgentProfile] = [
        MockAgentProfile(
            type: "Explore", baseSeconds: 45, samples: 23,
            tools: [(.read, 0.4), (.grep, 0.3), (.glob, 0.15), (.inspect, 0.15)],
            models: [(nil, 0.85), (MockModels.haiku, 0.15)], canNest: false,
            descriptions: [{ "Find \($0) code" }, { "Map \($0) usage" }, { "Locate \($0) entry points" }, { "Trace \($0) call sites" }],
            job: { "Find where \($0) is implemented and how it connects to the rest of the codebase. This is research only: don't edit any files." },
            guidance: "Use Grep and Glob first and only read the files that matter. Thoroughness: medium.",
            report: "a list of the relevant files with one line on what each does, the main entry points, and anything surprising",
            results: [
                { "Found \($0.n) relevant files. \($0.area) starts in \($0.file) and is wired up from \($0.file2). Nothing tests it yet." },
                { "\($0.area) lives mostly in \($0.file); \($0.file2) calls into it in two places. The pattern to follow is the one in \($0.file2)." },
                { "Mapped \($0.area) across \($0.n) files, most of the logic in \($0.file). Surprise: an older code path in \($0.file2) still runs." },
            ]),
        MockAgentProfile(
            type: "Plan", baseSeconds: 90, samples: 6,
            tools: [(.read, 0.45), (.grep, 0.3), (.glob, 0.25)],
            models: [(nil, 1)], canNest: false,
            descriptions: [{ "Plan \($0) changes" }, { "Design \($0) approach" }, { "Plan the \($0) work" }],
            job: { "Design an implementation plan for \($0). Break it into steps that can run in parallel where possible, and call out risks and open questions." },
            guidance: "Don't write code. Prefer extending existing types over adding new ones.",
            report: "a numbered plan with the files each step touches, which steps can run in parallel, and the open questions",
            results: [
                { "Proposed a \($0.n)-step plan. Steps 1–3 can run in parallel; \($0.area) depends on them. Main risk: \($0.file2) has no tests." },
                { "Plan ready: change \($0.file) first, then update the call sites in \($0.file2). Two open questions are listed at the end." },
            ]),
        MockAgentProfile(
            type: "general-purpose", baseSeconds: 150, samples: 14,
            tools: [(.read, 0.3), (.grep, 0.18), (.glob, 0.07), (.bash, 0.2), (.edit, 0.17), (.webFetch, 0.04), (.inspect, 0.04)],
            models: [(nil, 0.6), (MockModels.sonnet, 0.4)], canNest: true,
            descriptions: [{ "Handle \($0)" }, { "Investigate \($0)" }, { "Sort out \($0)" }, { "Update \($0)" }],
            job: { "Take care of \($0) end to end: work out what needs to change, make the change, and verify it." },
            guidance: "If a part of this is independent, hand it to a subagent so it runs in parallel.",
            report: "what you changed and why, how you verified it, and anything you left for later",
            results: [
                { "Handled \($0.area): changed \($0.file) and \($0.file2), verified with the existing tests (\($0.n) passing)." },
                { "\($0.area) is sorted. The root cause was in \($0.file); the fix is small and covered by a new test in \($0.test)." },
                { "Updated \($0.area) in \($0.n) files. One follow-up left: \($0.file2) still uses the old helper." },
            ]),
        MockAgentProfile(
            type: "claude-code-guide", baseSeconds: 100, samples: 1,
            tools: [(.docs, 0.6), (.read, 0.2), (.grep, 0.2)],
            models: [(MockModels.haiku, 1)], canNest: false,
            descriptions: [{ _ in "Check Claude Code docs" }, { _ in "Look up hooks docs" }, { _ in "Check subagent settings docs" }, { _ in "Look up settings precedence" }],
            job: { "Look up how Claude Code handles this in the official docs and summarize what applies to \($0)." },
            guidance: "Quote the exact setting names and link the pages you used.",
            report: "the relevant settings or behaviors with links, and whether anything in this repo conflicts",
            results: [
                { _ in "The docs cover this under sub-agents and settings. Nothing in this repo conflicts; links are in the report." },
                { "Found the relevant hook events and their payloads. The project settings already allow what \($0.area) needs." },
            ]),
        MockAgentProfile(
            type: "code-reviewer", baseSeconds: 120, samples: 11,
            tools: [(.read, 0.45), (.grep, 0.25), (.inspect, 0.18), (.bash, 0.12)],
            models: [(MockModels.sonnet, 0.6), (MockModels.opus, 0.4)], canNest: false,
            descriptions: [{ "Review \($0) changes" }, { "Review the \($0) diff" }, { "Check \($0) for regressions" }],
            job: { "Review the changes for \($0) on this branch. Look for bugs, missing error handling, and anything that doesn't match the patterns used elsewhere." },
            guidance: "Run `git diff main...HEAD` to see the changes. Only report issues you're confident about.",
            report: "a list of issues, most severe first, each with file, line and a suggested fix",
            results: [
                { "Reviewed \($0.n) files. Two issues: a missing error path in \($0.file) and an unhandled empty state in \($0.file2)." },
                { "No blocking issues. One suggestion: \($0.file2) duplicates logic that already exists in \($0.file)." },
                { "Found a real bug: \($0.file) can run twice during \($0.area), which double-counts. Suggested fix included." },
            ]),
        MockAgentProfile(
            type: "code-improver", baseSeconds: 100, samples: 4,
            tools: [(.read, 0.4), (.edit, 0.3), (.grep, 0.15), (.bash, 0.15)],
            models: [(MockModels.sonnet, 0.7), (nil, 0.3)], canNest: false,
            descriptions: [{ "Tidy up \($0)" }, { "Simplify \($0) code" }, { "Improve \($0) readability" }],
            job: { "Improve the readability and structure of the \($0) code without changing behavior." },
            guidance: "Small, safe edits only. Run the tests after each change.",
            report: "the changes you made, grouped by file, and confirmation that the tests still pass",
            results: [
                { "Simplified \($0.area): removed \($0.n) lines of duplicated logic in \($0.file) and renamed two confusing helpers. No behavior change." },
                { "Split the long function in \($0.file) into three and moved shared code to \($0.file2). Tests pass." },
            ]),
        MockAgentProfile(
            type: "test-writer", baseSeconds: 200, samples: 6,
            tools: [(.read, 0.3), (.write, 0.2), (.edit, 0.15), (.bash, 0.35)],
            models: [(MockModels.sonnet, 0.8), (nil, 0.2)], canNest: false,
            descriptions: [{ "Write \($0) tests" }, { "Add tests for \($0)" }, { "Cover \($0) edge cases" }],
            job: { "Write tests for \($0). Cover the happy path, the empty and error states, and the edge cases you find in the code." },
            guidance: "Follow the style of the existing tests. Don't change production code; if you find a bug, write a failing test and report it.",
            report: "the tests you added, which pass, and any that fail along with why",
            results: [
                { "Added \($0.n) tests in \($0.test). They cover the empty, error and happy paths; all pass." },
                { "Wrote \($0.n) tests for \($0.area) in \($0.test). One fails and shows a real bug in \($0.file)." },
            ]),
        MockAgentProfile(
            type: "software-engineer", baseSeconds: 300, samples: 9,
            tools: [(.read, 0.3), (.edit, 0.3), (.grep, 0.1), (.bash, 0.2), (.write, 0.1)],
            models: [(nil, 0.6), (MockModels.opus, 0.3), (MockModels.fable, 0.1)], canNest: true,
            descriptions: [{ "Implement \($0)" }, { "Build \($0)" }, { "Wire up \($0)" }, { "Refactor \($0)" }],
            job: { "Implement \($0). Make the smallest change that fits the existing patterns, and add or update tests as you go." },
            guidance: "Build and run the relevant tests before you report back. Use subagents for independent research or review.",
            report: "a summary of the change, the files touched, and the test results",
            results: [
                { "Implemented \($0.area) in \($0.file) and updated \($0.file2). Build is clean and \($0.n) tests pass." },
                { "\($0.area) is in place. Touched \($0.n) files; the main change is in \($0.file), with tests in \($0.test)." },
                { "Done with \($0.area). Had to adjust \($0.file2) as well because it assumed the old behavior." },
            ]),
        MockAgentProfile(
            type: "system-architect", baseSeconds: 100, samples: 2,
            tools: [(.read, 0.5), (.grep, 0.3), (.glob, 0.2)],
            models: [(MockModels.opus, 0.5), (MockModels.fable, 0.5)], canNest: false,
            descriptions: [{ "Design \($0) architecture" }, { "Assess \($0) structure" }],
            job: { "Assess how \($0) should be structured. Compare at most two designs and recommend one." },
            guidance: "Think about how this grows over the next year, but don't over-engineer it.",
            report: "the recommended design with a short type/module sketch, and why you rejected the alternative",
            results: [
                { "Recommended keeping \($0.area) in its own module behind a narrow interface; \($0.file) becomes a thin adapter." },
                { "Compared two designs for \($0.area). The event-based one wins: fewer moving parts and easier to test." },
            ]),
        MockAgentProfile(
            type: "docs-writer", baseSeconds: 100, samples: 3,
            tools: [(.read, 0.4), (.edit, 0.3), (.write, 0.2), (.grep, 0.1)],
            models: [(MockModels.haiku, 0.5), (MockModels.sonnet, 0.5)], canNest: false,
            descriptions: [{ "Document \($0)" }, { "Update \($0) docs" }, { "Write \($0) notes" }],
            job: { "Document \($0) for other developers: what it does, how to use it, and the gotchas." },
            guidance: "Keep it short and match the tone of the existing docs.",
            report: "the files you changed and a one-paragraph summary of what you documented",
            results: [
                { "Added a section on \($0.area) to the README and fixed two outdated examples." },
                { "Documented \($0.area) in docs/ and added doc comments to the public types in \($0.file)." },
            ]),
        MockAgentProfile(
            type: "researcher", baseSeconds: 100, samples: 1,
            tools: [(.webSearch, 0.35), (.webFetch, 0.4), (.read, 0.25)],
            models: [(MockModels.sonnet, 0.5), (MockModels.fable, 0.3), (nil, 0.2)], canNest: false,
            descriptions: [{ "Research \($0) options" }, { "Compare \($0) approaches" }, { "Research \($0) pitfalls" }],
            job: { "Research how other projects handle \($0). Find the current recommended approach and the common pitfalls." },
            guidance: "Prefer official docs and recent sources. Note the date of anything you rely on.",
            report: "two or three options with trade-offs, a recommendation, and links",
            results: [
                { "Compared 3 approaches for \($0.area). The simplest fits our constraints; links and trade-offs are in the report." },
                { "The current guidance for \($0.area) changed this year; the old approach still works but is deprecated." },
            ]),
        MockAgentProfile(
            type: "gmail-monitor", baseSeconds: 240, samples: 12,
            tools: [(.gmail, 0.75), (.read, 0.1), (.write, 0.15)],
            models: [(nil, 1)], canNest: false,
            descriptions: [{ "Check \($0) since yesterday" }, { "Review \($0) threads" }, { "Draft replies for \($0)" }],
            job: { "Go through \($0) in the user's Gmail. Flag what needs their attention and draft a reply where a real person expects one. Never send anything." },
            guidance: "Use the Gmail tools only, and mark what you report on as read.",
            report: "a short overview by category, the emails that need attention, and the IDs of the drafts you wrote",
            results: [
                { "\($0.n) emails in \($0.area); 2 need a reply and both have drafts. One calendar invite added." },
                { "Nothing urgent in \($0.area). \($0.n) newsletters and receipts marked as read." },
            ]),
        MockAgentProfile(
            type: "video-editor", baseSeconds: 200, samples: 7,
            tools: [(.bash, 0.6), (.read, 0.15), (.write, 0.25)],
            models: [(nil, 0.7), (MockModels.sonnet, 0.3)], canNest: false,
            descriptions: [{ "Trim the \($0) clips" }, { "Export \($0) for Instagram" }, { "Enhance \($0) footage" }],
            job: { "Edit \($0) with the ffmpeg in ~/Projects/Pubg_Tools/bin. Keep the original recordings untouched." },
            guidance: "Check every output with ffprobe before you report back.",
            report: "the files you wrote, each with its resolution, length and size",
            results: [
                { "Exported \($0.file): 1080×1920, 0:\(20 + $0.n * 4), 38 MB. \($0.area) is cut to the beat." },
                { "\($0.area) done: \($0.n) clips trimmed and joined into \($0.file2), HDR mapped to SDR." },
            ]),
    ]

    static func profile(_ type: String) -> MockAgentProfile { profiles.first { $0.type == type }! }

    /// Agent-type mix for a wave.
    static func mix(for stage: MockStage) -> MockWeights<MockAgentProfile> {
        switch stage {
        case .explore: exploreMix
        case .plan: planMix
        case .build: buildMix
        case .review: reviewMix
        case .nested: nestedMix
        case .stress: stressMix
        case .workflow: buildMix    // unused: workflow waves draw from the template's agents
        }
    }

    private static func weights(_ items: [(String, Double)]) -> MockWeights<MockAgentProfile> {
        MockWeights(items.map { (profile($0.0), $0.1) })
    }

    private static let exploreMix = weights([("Explore", 0.8), ("claude-code-guide", 0.1), ("researcher", 0.1)])
    private static let planMix = weights([("Plan", 0.7), ("system-architect", 0.3)])
    private static let buildMix = weights([
        ("software-engineer", 0.34), ("general-purpose", 0.2), ("test-writer", 0.2),
        ("code-improver", 0.1), ("docs-writer", 0.08), ("researcher", 0.08),
    ])
    private static let reviewMix = weights([("code-reviewer", 0.75), ("code-improver", 0.25)])
    private static let nestedMix = weights([
        ("Explore", 0.4), ("code-reviewer", 0.2), ("test-writer", 0.2), ("researcher", 0.1), ("general-purpose", 0.1),
    ])
    private static let stressMix = weights([
        ("software-engineer", 0.2), ("general-purpose", 0.15), ("Explore", 0.15), ("test-writer", 0.12),
        ("code-reviewer", 0.12), ("code-improver", 0.06), ("Plan", 0.05), ("docs-writer", 0.05),
        ("researcher", 0.05), ("system-architect", 0.03), ("claude-code-guide", 0.02),
    ])

    /// Gmail MCP calls (name, summary).
    static let gmailCalls: [(String, String)] = [
        ("mcp__gmail__search_threads", "in:inbox newer_than:1d"),
        ("mcp__gmail__get_thread", "thread 19a2f…"),
        ("mcp__gmail__create_draft", "Re: Thursday's delivery"),
        ("mcp__gcal__create_event", "Dentist, Tue 9:30 AM"),
    ]

    static let mainTools: MockWeights<MockToolKind> = [
        (.read, 0.3), (.grep, 0.18), (.glob, 0.08), (.bash, 0.16), (.inspect, 0.08), (.edit, 0.12), (.todo, 0.08),
    ]

    static let claudeDocs = [
        "https://code.claude.com/docs/en/sub-agents",
        "https://code.claude.com/docs/en/hooks",
        "https://code.claude.com/docs/en/settings",
        "https://code.claude.com/docs/en/sessions",
    ]

    // MARK: Prompts and results

    static let promptClosings = [
        "Use subagents to parallelize where it makes sense, and run the full test suite before you call it done.",
        "Work on the current branch and keep the diff focused. Don't push anything without asking me first.",
        "Ask me before changing anything outside this repo. Run the tests at the end.",
        "Plan first, then implement. I'd rather have a smaller change that's well tested.",
    ]

    static let mainResults: [@Sendable (Int) -> String] = [
        { "Done. The change touches \($0) files and the full test suite passes. I left one follow-up in the summary." },
        { _ in "All set: implemented, reviewed by a subagent, and tested. Nothing was pushed." },
        { _ in "Finished. Two subagents found the same root cause, so the fix is small; tests are green." },
        { _ in "Implemented and verified. One open question for you is at the end of the summary." },
    ]

    static let mainFailures = [
        "API Error: 529 Overloaded. The turn stopped before finishing.",
        "You've hit your session limit · resets 9:20pm",
        "API Error: Request timed out after 3 retries.",
    ]

    static let runFailures = [
        "Agent terminated early due to an API error: rate limit",
        "Agent terminated early due to an API error: 529 overloaded",
        "Agent terminated early due to an API error: request timed out",
        "Agent stopped after the same tool error three times in a row.",
    ]

    static let runCancellations = [
        "Cancelled by the user.",
        "Interrupted: the user stopped this agent.",
    ]

    static let cascadeCancellation = "Cancelled because its parent agent stopped."

    // MARK: Projects

    /// Two code projects, a repo that falls under a workflow group by its folder (TradingBot), and
    /// sessions without a project folder: the Gmail check, the PUBG pipeline and odd jobs (Others).
    static let demoProjects: [MockProject] = [agentDeck, webDashboard, tradingBot, gmailScratch, pubgScratch, oddJobs]
    static let stressProjects: [MockProject] = demoProjects + [iosClient, infra, paymentsAPI, dataPipeline]

    /// A Claude desktop scratch workspace (a session started without a project folder).
    static func scratchWorkspace(_ suffix: String) -> String {
        "\(home)/Library/Application Support/Claude/scratch-workspaces/9e5ecb1e/46b18842/scratch-2026-10-03-\(suffix)"
    }

    static let gmailScratch = MockProject(
        name: "scratch-2026-10-03-4be1f0", path: scratchWorkspace("4be1f0"),
        about: "Context: the user's daily Gmail check, in a folder made for this session.",
        files: ["gmail-report.md", "drafts.md"], tests: ["gmail-report.md"],
        commands: ["date", "ls -la"], inspect: ["ls -la", "cat gmail-report.md"],
        searches: ["needs reply"], globs: ["*.md"],
        urls: ["https://mail.google.com/mail/u/0/#inbox"], queries: ["gmail search operators newer_than"],
        tasks: [
            MockTaskTemplate(
                title: "Daily Gmail report", branch: "", files: ["gmail-report.md"],
                areas: ["Primary inbox", "Updates", "calendar invites", "receipts", "school emails"],
                details: "Run the gmail-monitor subagent for the last 24 hours and show me its full report.",
                question: "Should I send the two drafts?", workflow: MockWorkflow(agents: ["gmail-monitor"])),
            MockTaskTemplate(
                title: "Morning brief", branch: "", files: ["gmail-report.md"],
                areas: ["Primary inbox", "today's meetings", "Updates", "travel emails"],
                details: "Give me my morning brief: what's in the inbox and what's on today.",
                question: "Do you want the brief as a page?",
                workflow: MockWorkflow(agents: ["gmail-monitor"], skills: ["anthropic-skills:morning"])),
        ])

    static let pubgScratch = MockProject(
        name: "scratch-2026-10-03-91d7ac", path: scratchWorkspace("91d7ac"),
        about: "Context: the user's PUBG Mobile recordings, in a folder made for this session.",
        files: ["IMG_5033.mov", "montage-erangel.mp4", "reel-1080x1920.mp4"], tests: ["montage-erangel.mp4"],
        commands: ["~/Projects/Pubg_Tools/bin/ffprobe IMG_5033.mov", "~/Projects/Pubg_Tools/bin/ffmpeg -i IMG_5033.mov -ss 00:02:10 -t 12 clip-03.mp4",
                   "~/Projects/Pubg_Tools/bin/ffmpeg -i montage-erangel.mp4 -vf scale=1080:1920 reel-1080x1920.mp4"],
        inspect: ["ls -lh ~/Projects/Screen_Recordings", "du -sh ~/Downloads/*.mp4"],
        searches: ["kill feed"], globs: ["*.mov", "*.mp4"],
        urls: ["https://app.metricool.com/planner"], queries: ["instagram reels best time to post"],
        tasks: [
            MockTaskTemplate(
                title: "Video quality enhancement", branch: "", files: ["IMG_5033.mov"],
                areas: ["IMG_5033", "clutch round", "night match"],
                details: "This recording is low resolution. Upscale it and make it look sharper without changing the length.",
                question: "Keep the original frame rate?",
                workflow: MockWorkflow(agents: ["video-editor"], skills: ["video-enhance"])),
            MockTaskTemplate(
                title: "PUBG montage from Saturday's matches", branch: "", files: ["montage-erangel.mp4"],
                areas: ["Erangel squad", "sniper kills", "final circle"],
                details: "Find my best kills in Saturday's recordings and cut a montage to the usual track.",
                question: "Use the new track or last week's?",
                workflow: MockWorkflow(agents: ["video-editor"], skills: ["anthropic-skills:pubg-montage"])),
            MockTaskTemplate(
                title: "Schedule this week's Instagram reels", branch: "", files: ["reel-1080x1920.mp4"],
                areas: ["Saturday montage", "clutch clip", "sniper reel"],
                details: "Make vertical copies of the montages that aren't on Instagram yet and schedule them through Metricool.",
                question: "Post Saturday at 6:30 PM?",
                workflow: MockWorkflow(agents: ["video-editor"], skills: ["anthropic-skills:pubg-instagram-post"],
                                       tools: [("mcp__metricool__createScheduledPost", "Instagram reel · Sat 6:30 PM")])),
        ])

    static let oddJobs = MockProject(
        name: "scratch-2026-10-03-0c5e2a", path: scratchWorkspace("0c5e2a"),
        about: "Context: a one-off job in a folder made for this session.",
        files: ["lease.pdf", "notes.md", "IMG_6120.mov"], tests: ["notes.md"],
        commands: ["pdftotext lease.pdf -", "ls -la"], inspect: ["ls -la"],
        searches: ["termination"], globs: ["*.pdf", "*.md"],
        urls: ["https://www.consumerfinance.gov/"], queries: ["lease early termination clause"],
        tasks: [
            MockTaskTemplate(
                title: "Summarize the lease agreement PDF", branch: "", files: ["lease.pdf"],
                areas: ["renewal terms", "fees and deposits", "termination clause"],
                details: "Read lease.pdf and tell me what I'm agreeing to, especially anything unusual.",
                question: "Do you want this as a checklist?", workflow: MockWorkflow(agents: ["general-purpose"])),
            // Starts in Others; the pubg-montage skill partway through moves it to PubgMontages.
            MockTaskTemplate(
                title: "Cut last night's best moments", branch: "", files: ["IMG_6120.mov"],
                areas: ["last night's recording", "squad wipe", "final circle"],
                details: "IMG_6120.mov is last night's game. Find the best moments first; then we'll decide what to make.",
                question: "Turn these into a montage?",
                workflow: MockWorkflow(agents: ["general-purpose"], laterSkill: "anthropic-skills:pubg-montage",
                                       laterAgents: ["video-editor"])),
        ])

    static let tradingBot = MockProject(
        name: "Multi-agent-trading-bot",
        files: ["agents/risk_manager.py", "agents/momentum.py", "backtest/engine.py", "data/loader.py",
                "orders/book.py", "config/strategies.yaml", "pyproject.toml"],
        tests: ["tests/test_backtest.py", "tests/test_risk_manager.py"],
        commands: ["pytest -q", "ruff check .", "python -m backtest.run --strategy momentum --year 2025"],
        inspect: ["git log --oneline -15", "git diff --stat", "ls agents"],
        searches: ["def on_signal", "class RiskManager", "max_drawdown", "TODO(risk)"],
        globs: ["agents/**/*.py", "tests/**/*.py"],
        urls: ["https://www.backtrader.com/docu/", "https://docs.alpaca.markets/"],
        queries: ["position sizing kelly criterion", "backtest lookahead bias"],
        tasks: [
            MockTaskTemplate(
                title: "Backtest the momentum strategy on 2025 data", branch: "feature/momentum-2025",
                files: ["agents/momentum.py", "backtest/engine.py", "data/loader.py"],
                areas: ["momentum signals", "data loading", "slippage model", "results report"],
                details: "Run the momentum agent against all of 2025 with realistic slippage and report drawdown, Sharpe and win rate.",
                question: "Include crypto pairs in the backtest?"),
            MockTaskTemplate(
                title: "Add a risk-manager agent that can veto trades", branch: "feature/risk-veto",
                files: ["agents/risk_manager.py", "orders/book.py", "config/strategies.yaml"],
                areas: ["veto rules", "exposure limits", "agent messaging", "order book"],
                details: "The strategy agents trade without any limit. Add a risk-manager agent that sees every order first and can block it.",
                question: "Should a veto be logged to Slack?"),
        ])

    static let agentDeck = MockProject(
        name: "AgentDeck",
        files: [
            "AgentDeck/Views/Active/TaskCard.swift", "AgentDeck/Views/Detail/TimelineChart.swift",
            "AgentDeck/Model/DeckStore.swift", "AgentDeck/Views/MenuBar/MenuBarViews.swift",
            "AgentDeckCore/Sources/AgentDeckCore/Model/Snapshots.swift",
            "AgentDeckCore/Sources/AgentDeckCore/Estimates/DurationEstimator.swift",
            "AgentDeckCore/Sources/AgentDeckCore/ClaudeCode/TranscriptParser.swift",
            "AgentDeck/Design/Theme.swift", "AgentDeck/Views/Settings/SettingsView.swift", "AgentDeck/AgentDeckApp.swift",
        ],
        tests: [
            "AgentDeckCore/Tests/AgentDeckCoreTests/DurationEstimatorTests.swift",
            "AgentDeckCore/Tests/AgentDeckCoreTests/TranscriptParserTests.swift",
            "AgentDeckCore/Tests/AgentDeckCoreTests/DeckStoreTests.swift",
        ],
        commands: ["swift build", "swift test", "swift test --filter DurationEstimatorTests", "make build",
                   "xcodebuild -scheme AgentDeck -quiet build"],
        inspect: ["git log --oneline -15", "git diff --stat", "ls AgentDeck/Views", "git status --short"],
        searches: ["func apply(", "TimelineChart", "DurationEstimate(", "@Observable", "MenuBarExtra", "estimate.seconds"],
        globs: ["**/*.swift", "AgentDeck/Views/**/*.swift", "AgentDeckCore/Tests/**/*Tests.swift"],
        urls: ["https://developer.apple.com/documentation/swiftui/menubarextra",
               "https://developer.apple.com/documentation/charts", "https://code.claude.com/docs/en/sub-agents"],
        queries: ["SwiftUI Charts animate domain changes", "MenuBarExtra window refresh rate", "FSEvents latency vs DispatchSource"],
        tasks: [
            MockTaskTemplate(
                title: "Add a compact density option to the task cards", branch: "feature/compact-cards",
                files: ["AgentDeck/Views/Active/TaskCard.swift", "AgentDeck/Views/Settings/SettingsView.swift", "AgentDeck/Design/Theme.swift"],
                areas: ["task card layout", "density setting", "header strip", "card typography", "settings toggle", "agent rows"],
                details: "Some people run 10+ sessions at once and the cards get too tall. Add a Compact option in Settings → Appearance that drops the prompt preview and shrinks the agent rows. It should animate when toggled and remember the choice.",
                question: "Should compact mode also hide the per-agent progress rings?"),
            MockTaskTemplate(
                title: "Fix the timeline chart jumping when a subagent finishes", branch: "fix/timeline-jump",
                files: ["AgentDeck/Views/Detail/TimelineChart.swift", "AgentDeck/Model/DeckStore.swift", "AgentDeckCore/Sources/AgentDeckCore/Model/Snapshots.swift"],
                areas: ["timeline layout", "bar animation", "x-axis domain", "run ordering", "chart scale"],
                details: "When a subagent finishes, every bar in the timeline shifts left for a frame and then snaps back. I think the domain is recomputed from the running runs only. Keep the domain stable and only ever extend it.",
                question: "Is it okay if the time axis never shrinks while the task is open?"),
            MockTaskTemplate(
                title: "Show the estimated finish time in the menu bar", branch: "feature/menubar-eta",
                files: ["AgentDeck/Views/MenuBar/MenuBarViews.swift", "AgentDeckCore/Sources/AgentDeckCore/Estimates/DurationEstimator.swift", "AgentDeck/Model/DeckStore.swift"],
                areas: ["menu bar label", "ETA formatting", "estimate aggregation", "refresh timer", "settings option"],
                details: "Next to the running-agent count in the menu bar, show when the slowest running agent is expected to finish (\"~4m\"). Hide it when nothing has an estimate.",
                question: "Do you want the ETA as a clock time (3:42 PM) or a countdown (~4m)?"),
            MockTaskTemplate(
                title: "Speed up the initial transcript scan for large projects", branch: "perf/initial-scan",
                files: ["AgentDeckCore/Sources/AgentDeckCore/ClaudeCode/TranscriptParser.swift", "AgentDeckCore/Sources/AgentDeckCore/ClaudeCode/TranscriptScanner.swift", "AgentDeckCore/Sources/AgentDeckCore/Persistence/HistoryStore.swift"],
                areas: ["transcript parser", "line skipping", "file reading", "SQLite inserts", "scan concurrency", "JSON decoding"],
                details: "The first scan takes about 6 s on my machine with a 10 MB transcript. Profile it, then make it faster without changing the results. Skip huge tool_result lines before decoding them.",
                question: "Can I add a small benchmark target to the package?"),
            MockTaskTemplate(
                title: "Add keyboard shortcuts for switching sections", branch: "feature/section-shortcuts",
                files: ["AgentDeck/AgentDeckApp.swift", "AgentDeck/Views/Sidebar.swift", "AgentDeck/Views/CommandPalette.swift"],
                areas: ["command menu", "sidebar selection", "shortcut handling", "palette integration", "help text"],
                details: "⌘1 for Active, ⌘2 for History, ⌘3 and up for projects in sidebar order. They should show up in the View menu and in the command palette.",
                question: "⌘3 is currently Show Inspector. Should I move that to ⌥⌘I?"),
        ])

    static let webDashboard = MockProject(
        name: "web-dashboard",
        files: [
            "src/pages/settings/SettingsPage.tsx", "src/components/auth/OAuthButton.tsx", "src/lib/auth/session.ts",
            "src/api/client.ts", "src/pages/checkout/CheckoutForm.tsx", "src/hooks/useCart.ts",
            "src/components/table/DataTable.tsx", "src/pages/reports/ReportsView.tsx", "package.json", "vite.config.ts",
        ],
        tests: ["src/pages/checkout/__tests__/CheckoutForm.test.tsx", "src/lib/auth/__tests__/session.test.ts", "e2e/checkout.spec.ts"],
        commands: ["npm test", "npm run lint", "npx vitest run src/pages/checkout", "npx tsc --noEmit",
                   "npx playwright test e2e/checkout.spec.ts", "npm run build"],
        inspect: ["git diff --stat", "git log --oneline -20", "ls src/components", "npm ls react"],
        searches: ["useSession(", "OAuthProvider", "data-testid=\"checkout", "TODO(auth)", "export function DataTable", "waitFor("],
        globs: ["src/**/*.tsx", "src/**/*.test.ts*", "e2e/**/*.spec.ts"],
        urls: ["https://authjs.dev/getting-started/providers/github", "https://vitest.dev/guide/mocking",
               "https://playwright.dev/docs/test-retries", "https://react.dev/blog"],
        queries: ["playwright flaky test network idle", "OAuth PKCE single page app", "react 20 migration guide"],
        tasks: [
            MockTaskTemplate(
                title: "Add OAuth login to the settings screen", branch: "feature/oauth-settings",
                files: ["src/pages/settings/SettingsPage.tsx", "src/components/auth/OAuthButton.tsx", "src/lib/auth/session.ts", "src/lib/auth/pkce.ts"],
                areas: ["OAuth provider client", "callback handler", "token storage", "settings login button", "session refresh", "error states", "auth flow"],
                details: "Users should be able to connect their GitHub and Google accounts from Settings → Account. Use the PKCE flow, keep tokens in the existing session store, and show the connected state with a disconnect button.",
                question: "Which providers should ship first: GitHub and Google, or Microsoft too?"),
            MockTaskTemplate(
                title: "Fix flaky checkout tests", branch: "fix/flaky-checkout-tests",
                files: ["src/pages/checkout/CheckoutForm.tsx", "src/hooks/useCart.ts", "src/test/mocks/payments.ts"],
                areas: ["checkout form", "payment mock", "network waits", "cart fixtures", "retry config", "Vitest config"],
                details: "CheckoutForm.test.tsx and e2e/checkout.spec.ts fail about one run in five on CI, never locally. Find the actual race instead of adding retries.",
                question: "One fix needs a data-testid on the pay button. Okay to touch the component?"),
            MockTaskTemplate(
                title: "Migrate the billing page to the new table component", branch: "chore/billing-datatable",
                files: ["src/pages/billing/BillingPage.tsx", "src/components/table/DataTable.tsx", "src/components/billing/InvoiceTable.tsx"],
                areas: ["billing table", "column definitions", "table sorting", "table pagination", "row actions", "empty states"],
                details: "Replace the legacy InvoiceTable with DataTable. Keep sorting, pagination and the row action menu working, and delete the old component once nothing imports it.",
                question: "The old table supports column resizing and DataTable doesn't. Drop it or add it to DataTable?"),
            MockTaskTemplate(
                title: "Add CSV export to the reports view", branch: "feature/reports-csv",
                files: ["src/pages/reports/ReportsView.tsx", "src/lib/export/csv.ts", "src/api/client.ts"],
                areas: ["export button", "CSV serializer", "date range filter", "large exports", "download handling"],
                details: "Add an Export CSV button to ReportsView that exports the currently filtered rows. Exports over 50k rows should stream instead of building one big string.",
                question: "Should the export include hidden columns?"),
            MockTaskTemplate(
                title: "Investigate slow first paint on the dashboard home", branch: "perf/home-first-paint",
                files: ["src/pages/home/HomePage.tsx", "vite.config.ts", "src/components/charts/RevenueChart.tsx"],
                areas: ["bundle size", "data fetching", "chart rendering", "font loading", "page hydration"],
                details: "Lighthouse says first contentful paint is 3.8 s on the home page. Find out what's blocking it and fix the top two causes.",
                question: "Lazy-loading the charts shifts the layout slightly. Is that acceptable?"),
        ])

    static let iosClient = MockProject(
        name: "ios-client",
        files: [
            "App/Sources/Orders/OrderHistoryView.swift", "App/Sources/Orders/OrderHistoryViewModel.swift",
            "App/Sources/Networking/APIClient.swift", "App/Sources/Persistence/OrderStore.swift",
            "App/Sources/Auth/SignInView.swift", "App/Sources/Media/PhotoPicker.swift",
            "App/Sources/Onboarding/OnboardingFlow.swift", "App/Resources/Localizable.xcstrings", "App/Sources/AppDelegate.swift",
        ],
        tests: ["App/Tests/OrderHistoryViewModelTests.swift", "App/Tests/APIClientTests.swift", "App/Tests/PhotoPickerTests.swift"],
        commands: ["xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17'",
                   "swift test --filter OrderStoreTests", "swiftlint lint --quiet", "xcodebuild -scheme App build"],
        inspect: ["git log --oneline -10", "xcrun simctl list devices booted", "git diff --stat", "ls App/Sources"],
        searches: ["URLSession.shared", "completion: @escaping", "func fetchOrders", "UIImagePickerController", "String(localized:", "@MainActor"],
        globs: ["App/Sources/**/*.swift", "App/Tests/**/*.swift", "**/*.xcstrings"],
        urls: ["https://developer.apple.com/documentation/authenticationservices",
               "https://developer.apple.com/documentation/swiftdata", "https://developer.apple.com/documentation/xcode/localization"],
        queries: ["SwiftData offline cache sync conflicts", "PHPickerViewController rotation crash", "Sign in with Apple token revocation"],
        tasks: [
            MockTaskTemplate(
                title: "Implement offline mode for the order history screen", branch: "feature/offline-orders",
                files: ["App/Sources/Orders/OrderHistoryView.swift", "App/Sources/Orders/OrderHistoryViewModel.swift", "App/Sources/Persistence/OrderStore.swift"],
                areas: ["order cache", "launch sync", "offline banner", "SwiftData models", "conflict handling", "sync scheduler"],
                details: "Order history should load instantly from a local cache and say so when it's offline. Sync in the background on launch and when connectivity comes back. Server data wins on conflicts.",
                question: "How long should cached orders be kept: 30 days or forever?"),
            MockTaskTemplate(
                title: "Fix crash when rotating on the photo picker", branch: "fix/photo-picker-rotation",
                files: ["App/Sources/Media/PhotoPicker.swift", "App/Sources/Media/PhotoGridLayout.swift", "App/Sources/AppDelegate.swift"],
                areas: ["photo picker", "rotation handling", "layout constraints", "picker presentation", "size classes"],
                details: "Crashlytics shows an NSInternalInconsistencyException when rotating while the photo picker is open (iPad only). Stack trace is in the ticket. Fix it and add a regression test.",
                question: "Okay to replace the custom picker with PHPickerViewController?"),
            MockTaskTemplate(
                title: "Add Sign in with Apple", branch: "feature/siwa",
                files: ["App/Sources/Auth/SignInView.swift", "App/Sources/Auth/AuthService.swift", "App/Sources/Auth/Keychain.swift"],
                areas: ["auth button", "credential handling", "keychain storage", "token revocation", "account linking", "sign-in errors"],
                details: "Add Sign in with Apple next to the existing email login. Link to existing accounts by verified email, store the credential in the keychain, and handle revocation on launch.",
                question: "Should accounts with a matching email be linked automatically or after a confirmation?"),
            MockTaskTemplate(
                title: "Move networking to async/await", branch: "refactor/async-networking",
                files: ["App/Sources/Networking/APIClient.swift", "App/Sources/Networking/Endpoint.swift", "App/Sources/Orders/OrderHistoryViewModel.swift"],
                areas: ["API client", "request builders", "error mapping", "call sites", "retry logic", "response decoding"],
                details: "APIClient still uses completion handlers everywhere. Convert it to async/await, keep the public behavior the same, and update the call sites. No new dependencies.",
                question: "Can I drop the iOS 16 code path while I'm in there?"),
            MockTaskTemplate(
                title: "Localize the onboarding flow into German and Japanese", branch: "feature/onboarding-l10n",
                files: ["App/Sources/Onboarding/OnboardingFlow.swift", "App/Resources/Localizable.xcstrings", "App/Sources/Onboarding/WelcomeView.swift"],
                areas: ["string catalog", "onboarding screens", "plural rules", "layout overflow", "date formatting"],
                details: "Move all onboarding strings into the string catalog and add German and Japanese. German strings will be long, so check that nothing truncates on the smallest device.",
                question: "Do you have reviewed translations, or should I draft them for a translator?"),
        ])

    static let infra = MockProject(
        name: "infra",
        files: [
            "terraform/envs/staging/main.tf", "terraform/modules/rds/main.tf", "terraform/modules/eks/variables.tf",
            "k8s/payments/deployment.yaml", "k8s/payments/values-staging.yaml", ".github/workflows/ci.yml",
            ".github/workflows/deploy.yml", "monitoring/alerts/api-gateway.yaml", "scripts/rotate-db-creds.sh",
        ],
        tests: ["tests/terraform/staging_test.go", "tests/policies/opa_test.rego"],
        commands: ["terraform plan -out=staging.tfplan", "terraform validate", "tflint --recursive",
                   "helm template payments k8s/payments -f k8s/payments/values-staging.yaml", "go test ./tests/terraform/..."],
        inspect: ["kubectl get pods -n payments-staging", "gh run list --workflow ci.yml --limit 20", "git diff --stat", "terraform state list"],
        searches: ["aws_db_instance", "secretsmanager", "p99", "cache-dependency-path", "cluster_version", "aws_eks_node_group"],
        globs: ["terraform/**/*.tf", "k8s/**/*.yaml", ".github/workflows/*.yml"],
        urls: ["https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance",
               "https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html",
               "https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows"],
        queries: ["EKS 1.34 upgrade breaking changes", "GitHub Actions cache restore keys monorepo", "Secrets Manager rotation RDS postgres"],
        tasks: [
            MockTaskTemplate(
                title: "Set up a staging environment for the payments service", branch: "infra/payments-staging",
                files: ["terraform/envs/staging/main.tf", "k8s/payments/values-staging.yaml", ".github/workflows/deploy.yml"],
                areas: ["VPC module", "RDS instance", "EKS namespace", "Helm values", "deploy workflow", "DNS records"],
                details: "Payments only has prod. Add a staging environment that mirrors it at a smaller size, deploys on every merge to main, and runs the smoke tests after deploy.",
                question: "Should staging share the prod VPC or get its own?"),
            MockTaskTemplate(
                title: "Rotate the database credentials and move them to Secrets Manager", branch: "infra/rotate-db-creds",
                files: ["terraform/modules/rds/main.tf", "scripts/rotate-db-creds.sh", "k8s/payments/deployment.yaml"],
                areas: ["secret definitions", "rotation lambda", "app config", "IAM policies", "rollout plan"],
                details: "The RDS password is in a Kubernetes secret that hasn't been rotated in a year. Move it to Secrets Manager with automatic rotation every 30 days and update the apps to read it from there.",
                question: "Is a 5 minute window with dual credentials acceptable during rotation?"),
            MockTaskTemplate(
                title: "Cut CI time in half", branch: "ci/faster-pipeline",
                files: [".github/workflows/ci.yml", ".github/actions/setup/action.yml", "Dockerfile"],
                areas: ["dependency caching", "job sharding", "Docker layers", "workflow graph", "flaky jobs"],
                details: "CI takes 24 minutes on average. Find where the time goes and get it under 12 without dropping any checks.",
                question: "Can I split the e2e job into 4 shards? It costs more runner minutes."),
            MockTaskTemplate(
                title: "Add alerts for p99 latency on the API gateway", branch: "infra/latency-alerts",
                files: ["monitoring/alerts/api-gateway.yaml", "monitoring/dashboards/api-gateway.json", "docs/runbooks/api-latency.md"],
                areas: ["alert rules", "latency dashboards", "latency runbook", "paging policy", "alert routing"],
                details: "Page the on-call when p99 latency stays above 800 ms for 10 minutes, and warn in Slack above 500 ms. Add a dashboard and a short runbook.",
                question: "Should the alert page during weekends too?"),
            MockTaskTemplate(
                title: "Upgrade the EKS cluster to 1.34", branch: "infra/eks-1-34",
                files: ["terraform/modules/eks/variables.tf", "terraform/modules/eks/main.tf", "k8s/payments/deployment.yaml"],
                areas: ["cluster version", "node groups", "cluster addons", "manifest API versions", "upgrade runbook"],
                details: "We're two versions behind. Upgrade staging first, check for removed APIs in our manifests, then write the runbook for prod.",
                question: "Okay to schedule the prod upgrade for Tuesday morning?"),
        ])

    static let paymentsAPI = MockProject(
        name: "payments-api",
        files: ["internal/charge/service.go", "internal/charge/handler.go", "internal/ledger/ledger.go",
                "internal/webhooks/stripe.go", "cmd/server/main.go", "internal/store/postgres.go"],
        tests: ["internal/charge/service_test.go", "internal/ledger/ledger_test.go"],
        commands: ["go test ./...", "go vet ./...", "golangci-lint run", "go test -race ./internal/charge/..."],
        inspect: ["git log --oneline -15", "git diff --stat", "ls internal"],
        searches: ["func (s *Service) Charge", "idempotency", "ctx.Done()", "ledger.Entry", "FOR UPDATE"],
        globs: ["**/*.go", "internal/**/*_test.go"],
        urls: ["https://docs.stripe.com/webhooks", "https://pkg.go.dev/context"],
        queries: ["idempotency keys payments api design", "postgres advisory locks vs select for update"],
        tasks: [
            MockTaskTemplate(
                title: "Make charge creation idempotent", branch: "feature/idempotent-charges",
                files: ["internal/charge/handler.go", "internal/charge/service.go", "internal/store/postgres.go"],
                areas: ["idempotency keys", "charge handler", "key storage", "replay responses", "key expiry"],
                details: "Clients retry on timeouts and we sometimes charge twice. Accept an Idempotency-Key header and replay the original response for repeats within 24 hours.",
                question: "Should keys be scoped per merchant or global?"),
            MockTaskTemplate(
                title: "Fix the race in the ledger balance check", branch: "fix/ledger-race",
                files: ["internal/ledger/ledger.go", "internal/store/postgres.go"],
                areas: ["balance check", "row locking", "ledger entries", "balance queries"],
                details: "Two concurrent debits can both pass the balance check. Fix it at the database level and add a test that reproduces the race.",
                question: "SELECT … FOR UPDATE adds latency under load. Acceptable?"),
            MockTaskTemplate(
                title: "Handle Stripe webhook retries", branch: "feature/webhook-retries",
                files: ["internal/webhooks/stripe.go", "internal/store/postgres.go"],
                areas: ["webhook handler", "event dedupe", "signature checks", "retry backoff"],
                details: "Stripe retries webhooks for up to 3 days. Make the handler safe to call repeatedly and record which events we've processed.",
                question: "Keep processed event ids for 7 days or 30?"),
        ])

    static let dataPipeline = MockProject(
        name: "data-pipeline",
        files: ["pipeline/ingest/events.py", "pipeline/transform/sessions.py", "pipeline/load/warehouse.py",
                "dags/daily_rollup.py", "pyproject.toml", "pipeline/quality/checks.py"],
        tests: ["tests/test_sessions.py", "tests/test_events.py"],
        commands: ["pytest -q", "ruff check .", "mypy pipeline", "python -m pipeline.cli backfill --days 3"],
        inspect: ["git log --oneline -15", "git diff --stat", "ls pipeline"],
        searches: ["def sessionize", "partition_by", "TODO(perf)", "read_parquet", "groupby("],
        globs: ["pipeline/**/*.py", "tests/**/*.py"],
        urls: ["https://docs.pola.rs/user-guide/", "https://airflow.apache.org/docs/"],
        queries: ["polars vs duckdb sessionization performance", "airflow backfill idempotent tasks"],
        tasks: [
            MockTaskTemplate(
                title: "Port the sessionization step from pandas to Polars", branch: "perf/polars-sessions",
                files: ["pipeline/transform/sessions.py", "pyproject.toml"],
                areas: ["sessionize function", "window logic", "type casts", "output parity", "memory use"],
                details: "Sessionization takes 40 minutes and 30 GB of RAM in pandas. Port it to Polars with identical output and measure the difference.",
                question: "Is a 0.01% difference from float rounding acceptable?"),
            MockTaskTemplate(
                title: "Backfill the March events after the schema change", branch: "chore/march-backfill",
                files: ["pipeline/ingest/events.py", "pipeline/load/warehouse.py"],
                areas: ["schema migration", "backfill job", "partition rewrite", "row counts"],
                details: "The March schema change dropped the device column for two weeks. Backfill it from the raw logs without double-counting.",
                question: "Run the backfill tonight or over the weekend?"),
            MockTaskTemplate(
                title: "Add data quality checks to the daily rollup", branch: "feature/rollup-quality",
                files: ["dags/daily_rollup.py", "pipeline/quality/checks.py"],
                areas: ["null checks", "row count drift", "freshness alerts", "quality report"],
                details: "Fail the daily rollup when row counts drift more than 20% day over day or when key columns are null, and post a short report to Slack.",
                question: "Should a failed check block the downstream dashboards?"),
        ])
}
