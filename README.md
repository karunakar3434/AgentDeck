# AgentDeck

A native macOS app that shows, live, every Claude Code task on your Mac and the agents and subagents working on it. It's meant to sit beside your editor.

AgentDeck watches the transcripts Claude Code already writes under `~/.claude` and turns them into a live board: a card per running task, an agent tree and timeline per task, an inspector per agent, a history of finished work with actual-vs-estimated durations, and a running-agent count in the menu bar. There's no Claude Code plugin, no server, no account. It's a local build — ad-hoc signed, App Sandbox off, no App Store, no notarization.

## Privacy

AgentDeck only reads, and only from Claude Code's data folder (default `~/.claude`, changeable in Settings › Data):

| Path | Used for |
|---|---|
| `projects/**` — main and subagent `.jsonl` transcripts, `agent-*.meta.json`, `custom-title.json` | Tasks, agents, tool calls, models, durations |
| `sessions/<pid>.json` | Whether a session's process is busy, idle or waiting on you |
| `agents/*.md`, and `.claude/agents/*.md` inside each session's project folder | An agent definition's `model:` (a fallback for which model a subagent runs) |
| `agentdeck/events.jsonl` | Only if you install the [optional hook](#optional-hooks-for-lower-latency) |

It never writes anything under `~/.claude`, never opens `sessions/*.key` (those hold secrets), and makes no network connections. The only thing it writes is its history database, `~/Library/Application Support/AgentDeck/agentdeck.sqlite` (plus SQLite's `-wal`/`-shm` files). That database keeps copies of what the UI shows for finished tasks — titles, agent prompts, tool-call summaries, result summaries — the durations used for estimates, and the names each task's sidebar entry is decided from (working folder, skills, tools, agent types), so treat it with the same care as the transcripts.

Every on-disk format, and how each field in the UI is derived from it, is in [docs/data-sources.md](docs/data-sources.md).

## Requirements

| | |
|---|---|
| Mac | Apple silicon — the Makefile builds `arm64` only |
| macOS | 26 or later (deployment target 26.0) |
| Xcode | 26 or later with the Swift 6.2 toolchain (`AgentDeckCore/Package.swift` is `swift-tools-version: 6.2`). `xcodebuild` must point at Xcode, not the Command Line Tools — check with `xcode-select -p` |
| Network | Only for the first build, which fetches [GRDB.swift](https://github.com/groue/GRDB.swift) (pinned in `AgentDeckCore/Package.resolved`) |

Developed on a MacBook Air M2 with macOS 27 and Xcode 27.

## Build and run

Everything goes through the `Makefile`. Builds land in `build/` (gitignored).

```sh
make run        # Debug build, then open it
make install    # Release build, copied to /Applications/AgentDeck.app and opened
```

| Command | What it does |
|---|---|
| `make build` | Debug build into `build/Build/Products/Debug/` |
| `make run` | Debug build, quit any running AgentDeck, open the Debug app |
| `make mock` | Same, launched with `-mock` (simulated agents, see below) |
| `make stress` | Same, launched with `-mock -stress` (20 tasks × 15 agents) |
| `make release` | Release build into `build/Build/Products/Release/` |
| `make install` | Release build, quit any running AgentDeck, replace `/Applications/AgentDeck.app` with it (`ditto`), open it |
| `make uninstall` | Quit AgentDeck and delete `/Applications/AgentDeck.app` |
| `make test` | Run the core test suite (`swift test` in `AgentDeckCore/`) |
| `make clean` | Delete `build/` and clean the Swift package |
| `make debugctl` | Compile the debug remote control to `build/debugctl` (see [Debug remote control](#debug-remote-control)) |
| `make kill` | Quit any running AgentDeck |

`run`, `mock`, `stress` and `install` all run `pkill -x AgentDeck` first — that quits **every** copy, the installed one included, so the menu bar item disappearing for a moment is expected.

Use the Release build (`make install`) day to day. Debug builds accept [debug remote control](#debug-remote-control) commands from any local process; Release builds ignore them unless launched with `-automation`.

### Simulated agents

`-mock` swaps the Claude Code source for a simulator: a handful of realistic sessions with compressed durations (a task takes 1–4 minutes), new tasks arriving, failures, cancellations, nested subagents and overruns. It reads nothing from disk and never opens the history database. The window subtitle reads "Simulated agents" while it's on.

The demo starts with a task in every sidebar entry: a Gmail report and a morning brief (GmailMonitor), PUBG video work (PubgMontages), a `Multi-agent-trading-bot` repo (TradingBot), two code projects (AgentDeck, web-dashboard) and one-off scratch jobs (Others). The newest active task, "Cut last night's best moments", starts in Others and moves to PubgMontages about 20 s after launch, when it runs the `pubg-montage` skill. The simulator classifies with the same rules as the live source, so editing groups in Settings reclassifies simulated tasks too.

`-stress` keeps 20 tasks with about 15 agents each running. It only takes effect together with `-mock` — on its own it's ignored and you get the live source. `make stress` launches the Debug build that way:

```sh
make stress
```

Measure performance on the Release app instead — Debug numbers aren't representative:

```sh
make release
open -n build/Build/Products/Release/AgentDeck.app --args -mock -stress
```

You can also switch at runtime from the **Debug** menu, which is in every build, Release included: **Simulate Agents** (⌥⌘M) toggles the simulator, **Stress Test (20 tasks × 15 agents)** starts the stress scenario.

| Launch argument / variable | Effect |
|---|---|
| `-mock` | Start with the simulator (demo scenario) |
| `-mock -stress` | Start with the stress scenario |
| `-automation` | Release builds: accept debug remote control commands |
| `AGENTDECK_EXPERIMENT=nopulse,notree` | Switch parts of the UI off to measure their cost — see [Reproducing the numbers](#reproducing-the-numbers) |

### First launch

The first launch of a freshly built or copied binary is slower — about 1–1.6 s to the first window instead of ~0.5 s — while macOS verifies it. Later launches are back to normal.

On its first launch AgentDeck also scans every transcript on disk to learn how long your agents take (see [How estimates work](#how-estimates-work)). That runs at background priority after the window has loaded, and later launches only read transcripts that changed.

### Launch at login

Turn it on in **Settings › General › Launch at login**. AgentDeck first asks the system to register it with `SMAppService.mainApp`. This build is ad-hoc signed with no Team ID, so the system may refuse — if registering throws, or doesn't leave the item enabled, AgentDeck falls back to a per-user LaunchAgent it writes itself:

| | |
|---|---|
| File | `~/Library/LaunchAgents/com.karun.AgentDeck.login.plist` |
| `Label` | `com.karun.AgentDeck.login` |
| `ProgramArguments` | `/usr/bin/open -g -b com.karun.AgentDeck` (`-g` opens it in the background) |
| `RunAtLoad` / `ProcessType` | `true` / `Interactive` |

Turning the toggle off deletes that plist first, then unregisters the `SMAppService` item, so a failed unregister can't leave the LaunchAgent behind. The toggle shows on if either one is in place. launchd reads `~/Library/LaunchAgents` at login, so nothing visible happens until you next log in.

The LaunchAgent opens AgentDeck by bundle id, not by path, so it launches whichever copy macOS has registered — `/Applications/AgentDeck.app` after `make install`. The Debug and Release builds in `build/` share that bundle id, so with no copy in `/Applications`, login opens one of those instead, and nothing at all once `make clean` has removed them.

### Uninstall

1. Turn off **Settings › General › Launch at login** — otherwise the LaunchAgent stays behind and runs `open` at every login for an app that may no longer exist (or opens a leftover copy from `build/`).
2. `make uninstall`
3. Optionally remove everything else AgentDeck created:

   ```sh
   rm -rf ~/Library/Application\ Support/AgentDeck                  # history database
   defaults delete com.karun.AgentDeck                              # settings
   rm -f ~/Library/LaunchAgents/com.karun.AgentDeck.login.plist     # only if you skipped step 1
   ```

4. If you installed the hook, [remove it](#removing-the-hook).

## Using AgentDeck

### Views

The sidebar has **Active**, **History**, and **Projects**: the workflow groups in their configured order, then one entry per project folder (named after the folder), then **Others** — each badged with its number of active tasks. [Projects and workflow groups](#projects-and-workflow-groups) explains which entry a task lands in.

- **Active** — a header strip with live counts (active tasks, running agents, models in use, the longest-running agent) above one card per task that's running or waiting on you. A card shows the title, elapsed time, project, git branch, main model, an avatar per agent (as many as fit, up to 12, then "+N"), and the task's ETA — or "Waiting on you" when Claude needs an answer or a permission. Clicking the longest-running tile jumps to that agent.
- **Task detail** — click a card or press Return. A header with status, title, project entry, the real working folder (a workflow group's task still shows its scratch folder, say), branch, model and ETA, then the **agent tree** (main agent, subagents, nested subagents indented under their parent, a moon on background agents, the current tool call, elapsed time, a progress ring against the estimate) and a **timeline** drawn with Swift Charts: one bar per agent, a faint extension to its expected end, and a dashed "now" line. Click a row or a bar to inspect that agent.
- **Inspector** — the selected agent's status, model, start and end times, estimate with its confidence and sample count, tool-call count, tokens, full prompt, result summary and recent tool calls.
- **History** — tasks that are idle, done or failed, grouped Today / Yesterday / Earlier. Each row shows the total time, number of agents, how many ran over their estimate, and up to six actual-vs-estimated bars ("1m 10s / ~1m" — the dashed outline is the estimate, orange means over).
- **A project entry** — its active cards above its history.

A session whose turn has ended but which is still open is **idle**, not active — it moves to History and comes back to Active when you send the next prompt.

### Projects and workflow groups

Each task goes in exactly one sidebar entry, decided in this order:

1. The first **workflow group** with a matching rule.
2. Otherwise its **project folder** — one entry per folder, named after it, including folders you start using later.
3. Otherwise **Others**.

A session has no project folder when its working folder (its first `cwd`, or where the desktop app moved it) is a Claude desktop scratch workspace (`…/scratch-workspaces/…`, what the desktop app makes for a session started without a folder), a temporary folder (`/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`), or your home folder itself. Everything else is a project folder. A later `cd` doesn't count — otherwise an AgentDeck session that peeks into another repo would jump entries.

Workflow groups and Others are listed even with no tasks. A folder that shares a group's name, or is called Others, merges into that entry.

A group matches when any one of its rules does:

| Rule | Matches when | Example |
|---|---|---|
| Agent types | Any agent of the task has that `subagent_type` (any case) | `gmail-monitor` |
| Skills | The task ran that skill — a Skill tool call, or a typed slash command. A name without a namespace matches it in any namespace, so `morning` and `anthropic-skills:morning` match each other | `anthropic-skills:morning` |
| Tools | Any agent called that tool. An MCP tool also matches by its own name on any server | `createScheduledPost` matches `mcp__07c0f660-…__createScheduledPost` |
| Folders | With a leading `/` or `~`: the working folder is that folder or inside it. Otherwise a folder name (`*` and `?` wildcards; `-`, `_` and spaces read the same) that the working folder or any of its parents has | `~/Projects/Pubg_Tools`, `multi-agent-trading-bot*` |
| Title keywords | The title has the word, at the start of a word, any case — **only** for sessions with no project folder, so an AgentDeck session about Gmail stays under AgentDeck | `PUBG`, `morning brief` |

The defaults:

| Group | Rules |
|---|---|
| GmailMonitor | Agent type `gmail-monitor`; skill `anthropic-skills:morning`; title keywords `Gmail`, `morning brief` |
| PubgMontages | Agent type `video-editor`; skills `pubg-montage`, `pubg-instagram-post`, `video-enhance`; tools `createScheduledPost`, `createScheduledPostForReview` (Metricool); folder `~/Projects/Pubg_Tools`; title keywords `PUBG`, `montage`, `video`, `Instagram`, `reel` |
| TradingBot | Folder `multi-agent-trading-bot*` — the repo or anything inside it, wherever it's cloned, including GitHub's `-main` download suffix; title keyword `trading bot` |

Two of these are weaker than they look, and [docs/data-sources.md §9](docs/data-sources.md#9-sidebar-entries-workflow-groups-folders-others) has the evidence for all of them:

- **No scheduled-run marker.** The scheduled Gmail run has the same `entrypoint`, `promptSource` and `turnOrigin` as a session you typed into, so GmailMonitor goes by the `gmail-monitor` agent and the morning skill. A scheduled task that runs neither lands in Others.
- **`video` is a title keyword** because "Video quality enhancement" has none of the strict PubgMontages signals — it created the `video-enhance` skill and the `video-editor` agent but never ran either. Only scratch sessions are affected; a project session titled "video…" stays under its folder.

An entry can change while a task runs: a scratch session that calls `pubg-montage` halfway through moves from Others to PubgMontages at that moment. When the task finishes, its entry and the signals it was decided from are saved with its history row. Changing the rules reclassifies every task, history included, from those saved signals — nothing is re-read from `~/.claude`.

### Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘1 / ⌘2 | Active / History |
| ⌘K | Go to a task or agent (palette) |
| ⌘F | Search tasks and agents |
| ⌥⌘I | Show or hide the inspector |
| ⌘, | Settings |
| ↑ / ↓ | In a list: move the highlight. In an open task: select the previous or next agent (opens the inspector) |
| Return | Open the highlighted task, or the first one if nothing is highlighted |
| Esc | Close the inspector; press again to close the task |
| ⌥⌘M | Debug › Simulate Agents |

In the palette, ↑/↓ move the selection, Return opens it and Esc closes the palette. With nothing typed it lists Go to Active / Go to History, every task, and every running agent; typing fuzzy-matches task titles, project entries (workflow group, folder or Others), agent types and agent descriptions, with active tasks and running agents ranked higher.

The arrow keys, Return and Esc are handled by the task list and task view, so they don't do this while the search field or palette has focus.

### Search and filters

The toolbar search (⌘F) matches task titles, project entries, agent types and agent descriptions. The **Filter** menu narrows by project entry (in sidebar order), status, model family (Fable, Opus, Sonnet, Haiku, Other) and agent type. Choices in one category widen the match, choices across categories narrow it; a task matches a model or agent-type filter if any of its agents does. The filter icon fills and shows a count while filters are on, and **Clear Filters** resets them. Search and filters apply to Active, History and project views.

### Menu bar

The menu bar item shows a stack glyph (filled while anything runs) and the number of running agents — each running or waiting task's main agent counts as one, plus every running subagent. Click it for a popover listing those agents with elapsed time, a progress bar and the estimate. Clicking an agent opens its task with that agent in the inspector; **Open AgentDeck** brings the main window back, and the gear opens Settings.

The same count appears on the Dock icon and in the window subtitle. All three update at most twice a second (see [What keeps it fast](#what-keeps-it-fast)). The menu bar item, its count and the Dock badge can each be turned off in Settings › General.

### Notifications

Off by default. Turn them on in **Settings › Notifications**:

- **When a task finishes** — the task went from running or waiting to idle or done (that's the end of every turn, not only the end of the session), or it failed.
- **When a subagent fails**

Turning either on is when macOS asks for permission. Clicking a notification opens that task — even if the click launched AgentDeck, in which case it opens once the task has loaded. Nothing fires for changes during the initial load, so launching AgentDeck doesn't replay old finishes, and simulated tasks in mock mode never notify.

### Narrow windows

The window goes down to 420 × 420 pt, so it fits beside an editor. Below 640 pt wide the sidebar collapses, and the inspector slides over the task instead of taking a column — close it with its × button or Esc. The sidebar comes back when the window widens again. Cards reflow from several columns down to one.

### Settings

| Tab | Setting | Default | Notes |
|---|---|---|---|
| General | Launch at login | Off | See [Launch at login](#launch-at-login) |
| General | Show menu bar item | On | |
| General | Show running-agent count in the menu bar | On | Disabled while the item is hidden |
| General | Show running-agent count on the Dock icon | On | |
| Groups | Workflow groups and their rules | GmailMonitor, PubgMontages, TradingBot | See [Projects and workflow groups](#projects-and-workflow-groups) |
| Notifications | When a task finishes | Off | |
| Notifications | When a subagent fails | Off | |
| Data | Keep finished tasks for | 24 hours | 6 hours, 24 hours, 3 days, 7 days or 30 days |
| Data | Claude Code folder | `~/.claude` | **Choose…** to change, **Reset** to go back |

Changing either Data setting restarts the data source: the window empties, any open task closes, and everything reloads.

**Settings › Groups** lists the workflow groups in matching order, with Others pinned last. Expand a group to rename it, edit its rules, move it up or down, or delete it; **Add Group** adds one at the end. Each rule field takes comma-separated values. Edits reach the sidebar about 0.3 s after you stop typing — applying every keystroke would reshuffle tasks between entries while a rule is half typed. A group with no name, a duplicate name, the name Others, or no rules gets a warning and is skipped when matching. Folder projects and Others aren't configurable. The groups are saved in UserDefaults under `workflowRules` (JSON) with the other settings; while they equal the defaults the key is absent, so a later build's improved defaults still reach you. **Restore Default Groups…** puts the defaults back.

**Keep finished tasks for** controls what's shown, not what's deleted. The database keeps finished tasks for at least 7 days (longer if this setting is longer) and duration samples for 180 days, so shrinking the window to 6 hours and setting it back to 3 days brings the hidden tasks back.

## How it works

AgentDeck is a local Swift package and a SwiftUI app. The package's `AgentDeckCore` library does all the reading, parsing, session state and estimating; its `AgentDeckState` library holds the main-actor `DeckStore` and the observable models the views read; the app renders them. The design is in [docs/architecture.md](docs/architecture.md), the formats in [docs/data-sources.md](docs/data-sources.md).

### Task status

Each Claude Code session is a task. Its status comes from `sessions/<pid>.json` — which exists only while a Claude Code process is running, and says `busy`, `idle` or `waiting` — plus the transcript. The first matching rule wins:

| Status | Rule |
|---|---|
| Failed | The last turn ended on an API error line (`<synthetic>` model) with nothing after it |
| Waiting on you | The pid file says `waiting` (a permission prompt or other dialog), or an `AskUserQuestion` / `ExitPlanMode` call has no answer yet |
| Running | The pid file says `busy`; or, with no live process, the transcript is mid-turn and grew in the last 2 minutes; or any subagent is still running |
| Idle | The process is alive and none of the above applies |
| Done | The session closed (a `cost-state` line), or there's no live process and the session has been quiet for 2 minutes |

The pid file is the only reliable "waiting on you" signal — Claude Code writes nothing to the transcript while a permission prompt is open. A process counts as alive only if `kill(pid, 0)` succeeds **and** its start time matches the pid file, so a reused pid can't resurrect an old session. Sessions without a pid file (older versions, remote sessions) depend on the 2-minute quiet rule, so they can take up to 2 minutes to show Done.

### Which model an agent used

The first hit wins:

1. `message.model` on the agent's own transcript lines (`<synthetic>` is ignored)
2. `resolvedModel` on the Agent call's result — known within about a second of the launch
3. The Agent call's `model` parameter, or `model` in the subagent's `.meta.json`, unless it's `inherit`
4. The agent definition's `model:` frontmatter, unless it's `inherit` — `<project>/.claude/agents/<type>.md` before `~/.claude/agents/<type>.md`
5. Otherwise it inherits the main agent's model

Steps 1 and 2 report what actually ran, so they override what the call or the definition asked for.

### Update flow

1. **FSEvents** watches `projects/`, `sessions/`, `agents/` and `agentdeck/` with a 0.1 s latency. A fallback stat sweep runs every 10 s while any task is active (every 60 s otherwise) in case events are dropped, and process exits come from dispatch sources rather than polling.
2. One actor, `TranscriptEngine`, owns all session state. For each changed file it reads **only the new bytes**, starting at the byte offset it stopped at last time, classifies each line by type before decoding it (attachments and metadata, about 40 % of lines, are dropped without JSON decoding), and folds the events into the session.
3. Changed tasks are marked dirty, and an `UpdateCoalescer` sends at most one batch per 16 ms frame, holding only tasks whose snapshot actually changed. Nothing is sent while nothing changes. If the UI hasn't taken the previous batch yet, the next one waits and merges — the dirty set, not the batch, is the source of truth, so nothing is lost and nothing piles up.
4. On the main actor, `DeckStore` (in `AgentDeckState`) applies each batch to long-lived, small `@Observable` task and agent models, so a view redraws only when something it reads changed. Agent models are keyed by task as well as run (`RunKey.make(task:run:)`): the core's run ids are Agent `tool_use` ids, unique only within a session, and a forked or resumed session can repeat them.
5. Time is local: one `TimelineView` clock per window ticks once a second while anything runs, and only the small views that display time read it.

Cold launch is tiered so the window is useful at once: sessions with a live process and recently active ones first, newest first, then the rest of the history window — unchanged finished tasks come straight from the database without parsing — then the background estimate scan.

## How estimates work

Every subagent gets an estimate of how long it'll take. While it runs you see "of 3m" and a progress ring filling toward it; past the estimate it turns into "over by 1m 20s" in orange; once finished it reads "est 3m". The main agent has no estimate.

### Samples

A sample is the duration of one subagent run that finished **done** — failed and cancelled runs don't count. Durations are exact wherever Claude Code records them: `totalDurationMs` on a foreground Agent call's result, `<duration_ms>` in a background agent's `<task-notification>`. When AgentDeck parses a run that finished without either — or before either arrived — it times the run from its first to its last transcript line, and the exact value replaces that when it lands. The first-launch scan keeps exact durations only. Samples are keyed by the Agent call's `tool_use` id, so a run is never counted twice.

Samples are bucketed per agent type (`Explore`, `Plan`, `general-purpose`, your custom agents) and per agent type and model family (Fable, Opus, Sonnet, Haiku). A run's family is that of its resolved model, or the main agent's when it inherits. Each bucket keeps its newest 50 samples, so estimates follow how your agents behave now, not six months ago.

### The estimate

For an agent of type T on model family F:

1. **Pick a bucket.** Use the (T, F) bucket if F is known and the bucket holds at least 5 samples — the same agent can run very differently on Opus and on Haiku. Otherwise use T's bucket across all families.
2. **Compute the seconds** from the bucket's sample count *n*:

   | n | Estimate |
   |---|---|
   | 3 or more | The median (an even count averages the two middle values) |
   | 1–2 | (sum of the samples + default) / (n + 1) — the default counts as one extra sample |
   | 0 | The built-in default: `Explore` 60 s, `Plan` 120 s, `general-purpose` 180 s, any other type 150 s |

   The 1–2 sample blend stops one unusual run from taking over, while real data still pulls the estimate away from a generic default: a single 120 s `Explore` run gives (120 + 60) / 2 = 90 s.

3. **Set the confidence** from *n* of the bucket used:

   | n | Confidence | Shown as |
   |---|---|---|
   | 10 or more | High | `3m` |
   | 3–9 | Medium | `3m` |
   | 0–2 | Low | `~3m` |

The inspector spells it out, for example "~1m 30s · low confidence (1 run)".

### Learning

- **First launch:** once the window has loaded, a background scan reads every main transcript under `projects/` — all of them, not only those in the history window — for Agent calls and their exact durations, and stores one row per call in the database. Then every estimate is recomputed. The scan never opens subagent files: the resolved model and the exact durations are all on the parent's side.
- **Later launches:** the scan records how far it got in each transcript, so it only reads files that changed, and it skips the ones AgentDeck already parsed live.
- **While running:** each run that finishes done adds its sample straight away, and running agents of that type pick up the new estimate.
- The database keeps samples for 180 days, so they outlive Claude Code's own transcript cleanup (`cleanupPeriodDays`, default 30).

### Estimates on finished runs

- A run AgentDeck **watched** finish keeps the estimate it had at that moment, frozen before its own sample is added — so History compares it with what was actually predicted.
- A run that was **already finished** when AgentDeck loaded it (at launch, or from the database) gets an estimate computed from every other sample of its type, with its own sample left out. A run is never measured against itself, and these estimates improve as AgentDeck learns.

### Task ETA

A task's ETA is the latest expected end among its **running** subagents, where each one's expected end is its start time plus its estimate. Cards and the task header show "ETA 2m 10s" counting down, and "over by …" in orange once it's passed. Queued subagents and the main agent don't count, so a task with no running subagents shows no ETA.

## Optional hooks for lower latency

You don't need this. The transcripts already get changes to AgentDeck within about a second — FSEvents fires 0.1 s after a write, and the `.meta.json` sidecar Claude Code writes when a subagent starts gets new agents on screen about a second after their Agent call (see [Measured](#measured)). A hook adds a second, independent nudge: each event tells AgentDeck which transcript to re-read right now. Expect no visible difference on a healthy machine. It's a backstop for when FSEvents drops or coalesces events and the fallback sweep (every 10 s while tasks are active) would otherwise be the next chance.

AgentDeck never edits `~/.claude/settings.json`. You add the hook yourself, and you remove it the same way.

### What AgentDeck does with it

If `~/.claude/agentdeck/events.jsonl` exists, AgentDeck tails it like a transcript, starting from its current end. From each line it takes `transcript_path` and `agent_transcript_path`, resolves symlinks, and re-reads that file at once if it's inside `~/.claude/projects/`. Every other field and every other path is ignored. (If you've pointed AgentDeck at a different data folder, the file and the transcripts have to live under that folder instead.)

### Install

**1. Create the hook script.**

```sh
mkdir -p ~/.claude/agentdeck
cat > ~/.claude/agentdeck/hook.py <<'EOF'
# Claude Code hook for AgentDeck: appends one JSON line per event to events.jsonl.
# Keeps only the fields AgentDeck reads, prints nothing, and always exits 0.
import json, os, sys

try:
    event = json.load(sys.stdin)
    keys = ("hook_event_name", "session_id", "transcript_path", "agent_transcript_path")
    line = json.dumps({k: event[k] for k in keys if k in event}) + "\n"
    path = os.path.expanduser("~/.claude/agentdeck/events.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)
except Exception:
    pass
EOF
```

Why it's written this way:

- It keeps only the fields AgentDeck reads. The full `PostToolUse` payload of an Agent call carries the whole prompt and the agent's report — copying that into a second file would grow it fast and duplicate private text.
- It appends each line with a single `O_APPEND` write, so hooks from parallel subagents can't interleave half-lines. Each line is a few hundred bytes.
- It prints nothing. Whatever a `SessionStart` hook prints to stdout is added to Claude's context.
- It never fails. A `PreToolUse` hook exiting with status 2 blocks the tool call, so the script swallows every error, and the command below adds `|| true` in case the script itself goes missing (Python exits 2 for a missing file).

It needs nothing beyond `/usr/bin/python3`, which is there once Xcode or its Command Line Tools are installed — no `jq`.

**2. Add the hooks to `~/.claude/settings.json`.** Put this `"hooks"` key in the top-level object. If the file already has a `"hooks"` key, merge these event arrays into it instead — with two `"hooks"` keys, one silently wins and the other is ignored.

```json
{
  "hooks": {
    "SessionStart":  [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }],
    "SessionEnd":    [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }],
    "Stop":          [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }],
    "SubagentStop":  [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }],
    "PreToolUse":    [{ "matcher": "Agent", "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }],
    "PostToolUse":   [{ "matcher": "Agent", "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/agentdeck/hook.py || true", "async": true, "timeout": 10 }] }]
  }
}
```

- `"async": true` runs the hook in the background, so Claude Code never waits on it. The settings schema in the installed Claude Code (2.1.286) describes it as "If true, hook runs in background without blocking". Without it, each event would still only cost Python's startup, about 30 ms here.
- `"matcher": "Agent"` limits the tool hooks to Agent calls. Older Claude Code versions called that tool `Task` — use `"Agent|Task"` if you run one.
- The other five events have no matcher, so they fire for every agent type and session.

**3. Start a new Claude Code session.** Sessions that were already running may keep the hooks they started with.

**4. Check it.** Run something that launches a subagent and watch the file:

```sh
tail -f ~/.claude/agentdeck/events.jsonl
```

You should see `SubagentStart`, `PreToolUse`, `PostToolUse` and `SubagentStop` lines. If AgentDeck was already running when `~/.claude/agentdeck/` first appeared, it picks the folder up at its next fallback sweep — within a minute — or immediately after a relaunch.

The file only grows; AgentDeck never trims it, because it never writes under `~/.claude`. Emptying it is safe at any time — AgentDeck treats the truncation as a reset and carries on from the new end:

```sh
: > ~/.claude/agentdeck/events.jsonl
```

### Removing the hook

1. Delete the seven entries above from `"hooks"` in `~/.claude/settings.json` (and the `"hooks"` key itself if nothing else is left in it).
2. Then delete the folder:

   ```sh
   rm -rf ~/.claude/agentdeck
   ```

Do it in that order. If the script is gone while the hooks are still configured, every Agent call, stop and session start runs a failing command — the `|| true` keeps it harmless, but there's no reason to leave it running.

## Performance

### Targets

From [docs/architecture.md](docs/architecture.md): the window is interactive at once and the first live task shows in under 1 s; 20 tasks × 15 agents stay live; the core sends at most one update per 16 ms and none while idle; memory stays under 150 MB; idle CPU stays under 1 %.

### Measured

Release build on a MacBook Air M2, macOS 27:

| What | Result |
|---|---|
| CPU, no running agents | ~0.1 % |
| CPU, one live Claude Code session | ~0.8 % |
| Memory footprint | ~53–61 MB, peak ~71 MB |
| First window | ~0.5 s (≈1–1.6 s on the first launch after a build or copy) |
| First live task | ~0.13–0.36 s after start |
| Full initial load | ~0.4–0.8 s |
| New subagent appears | ~1 s after its Agent call: 0.8 s and 1.5 s from the call's transcript timestamp. The two Explore subagents of a second, concurrent `claude -p` session showed up while their elapsed time still read 0 s |

Stress mock (20 tasks × 15 agents), same build and Mac. Steady CPU while the stress world churns:

| Screen | CPU |
|---|---|
| Active (card grid) | ≈ 39 % |
| Task detail | ≈ 15 % |
| History | ≈ 11 % |

Frame intervals, judged against a 60 Hz budget (16.7 ms):

| Phase | p99 frame interval |
|---|---|
| Card list, idle and scrolling | ≈ 27–29 ms, no frame gap over 50 ms |
| Task detail, scrolling | ≈ 17 ms (max 24 ms) |
| Switching agents in the inspector | ≈ 30 ms, no frame gap over 50 ms |

Screen transitions are the known gap. Opening a task, going back to the list and showing the palette each still produce a single long frame, about 70–150 ms in stress.

**How frame pacing was measured.** Instruments' Animation Hitches template came back with empty frame and hitch tables on this machine — the `hitches` table exports with its schema and no rows — so the frame numbers come from the in-app frame meter, `AgentDeck/Debug/FrameMeter.swift`. It's a display link on the main window that records every frame interval and reports gaps over 25, 50 and 100 ms, p50, p99 and the maximum. Instruments' hang detection (the `potential-hangs` table from the same trace) and Time Profiler were used to find out *why* frames were slow.

### What keeps it fast

- **Flattened live content.** Task cards, agent rows, history rows, popover rows, header tiles and the timeline chart are wrapped in `.drawingGroup()`, so a change redraws one GPU-backed layer — on macOS, SwiftUI otherwise redraws the whole card on the CPU whenever anything in it changes.
- **Live parts outside the flattened layer.** On a task card, the elapsed time, the ETA and the avatar strip are overlays on top of the flattened card, and the strip is flattened into its own small layer. A clock tick or a new agent redraws only those, not the card. On an agent row, the timing column (elapsed time, progress ring, estimate) is likewise an overlay outside the row's layer.
- **Pulses in Core Animation.** A running status dot doesn't animate itself. It publishes its bounds through an anchor preference, and the nearest `.pulseHost()` draws a ring with a repeating `CABasicAnimation`. That runs in the render server with no per-frame work on the main thread, and it lets the content around the dot be flattened. Each container — a task card, the agent tree, the inspector header, the menu bar popover — has its own host, which consumes its dots' rings so they never reach an outer host. Hosts sit inside scroll views, so scrolling moves the rings with their layer instead of repositioning each one. Reduce Motion turns the pulses off.
- **Throttled glance counts.** The menu bar count, Dock badge and window subtitle change at most twice a second — AppKit re-lays out the status item and title bar on every change, which gets expensive when hundreds of agents churn.
- **One clock.** A single `TimelineView` per window drives `Clock.shared` in whole seconds — every second while anything runs, every 30 s otherwise (for "4m ago" labels) — and only the leaf views that display time read it. The timeline chart reads `Clock.shared.coarseNow` instead, which moves in 5 s steps: a minutes-wide chart doesn't need per-second precision, and Swift Charts rebuilds are costly.
- **Deferred and lazy work.** The timeline chart is built 300 ms after a task opens, once the open animation has finished, so building it doesn't drop that animation's frames. The agent tree and history use lazy stacks. The ⌘K palette takes a snapshot of its tasks and agents once each time it opens and ranks that snapshot as you type, so the list doesn't change under you while it's open. The core sends nothing while idle.

### Reproducing the numbers

The frame and CPU scripts drive the Release app in stress mock mode with `-automation`, through `build/debugctl`. They don't build anything, so build first:

```sh
make release debugctl
```

| Command | Measures |
|---|---|
| `scripts/frames.sh release` | Frame pacing per phase: idle list, scrolling, opening a task, inspector, switching agents, detail scroll, close and switch, palette |
| `scripts/frames-transitions.sh` | Frame pacing per screen transition, two rounds |
| `SCENARIO=-demo scripts/frames-transitions.sh` | The same in the normal demo. Any value other than `-stress` works — the app ignores arguments it doesn't know |
| `scripts/cpu-baseline.sh list` | CPU over 6 s in stress mock. The other states are `detail`, `history` and `hidden` (`hidden` uses AppleScript, so macOS asks once for Automation permission) |
| `scripts/profile.sh "Animation Hitches" 40` | A 40 s Instruments recording while a script scrolls, opens tasks, switches agents and toggles the inspector. Builds first, writes `profiles/<template>-<HHMMSS>.trace`, then deletes xctrace's kernel traces from `$TMPDIR` (see below). Templates: `"Animation Hitches"` (default), `"SwiftUI"`, `"Time Profiler"` |

Frame lines read `gaps>25ms=… gaps>50ms=… gaps>100ms=… p50=… p99=… max=…`, in milliseconds. The scripts also take experiment flags (`frames.sh` and `cpu-baseline.sh` as their second argument, `frames-transitions.sh` as its first) that switch parts of the UI off to show what they cost: `nopulse`, `notree`, `noinspector`, `nosidebar`, `nosubtitle`, `nomenubar`, `nodock`.

To summarize a Time Profiler trace:

```sh
scripts/profile.sh "Time Profiler" 40
T=$(ls -td profiles/time-profiler-*.trace | head -1)
xcrun xctrace export --input "$T" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > /tmp/tp.xml
python3 scripts/tp-summary.py /tmp/tp.xml AgentDeck 25
```

`tp-summary.py` prints CPU time per thread, the hottest leaf functions, the hottest inclusive functions and AgentDeck's own frames. An optional fourth argument restricts it to time windows in seconds, for example `"21.6-24.4,31.0-34.7"`. For a SwiftUI trace, export `table[@schema="swiftui-updates"]` instead and run `python3 scripts/swiftui-summary.py /tmp/swiftui.xml 30` for update counts and time per view. For hangs, export `table[@schema="potential-hangs"]` from an Animation Hitches trace.

**Instruments runs can fill the disk.** Each Animation Hitches recording leaves about 10 GB of kernel traces, `instruments*.ktrace`, in `$TMPDIR`, and xctrace doesn't remove them. `scripts/profile.sh` deletes them at the end of each run, but only if no other `xctrace` is still recording, and not at all if the script stopped early. After recording any other way (Instruments.app, your own `xctrace record`) or an interrupted script, check and clean up yourself once nothing is recording:

```sh
pgrep -lx xctrace; pgrep -lx Instruments      # both must print nothing
find "$TMPDIR" -maxdepth 1 -name 'instruments*.ktrace' -exec du -ch {} +
find "$TMPDIR" -maxdepth 1 -name 'instruments*.ktrace' -delete
```

Exports get big too — a 40 s SwiftUI trace came to about 1 GB of XML here — and `profiles/` is gitignored but never cleaned up, so delete old traces and exports before the disk fills mid-recording.

Other numbers:

- **Launch time:** the app logs the time to its first window.

  ```sh
  log show --last 5m --predicate 'subsystem == "com.karun.AgentDeck" AND category == "launch"'
  ```

- **Memory:** `footprint -p AgentDeck`
- **CPU of the live app:** sample its CPU time over a minute, the same way `cpu-baseline.sh` does:

  ```sh
  PID=$(pgrep -x AgentDeck); ps -o cputime= -p $PID; sleep 60; ps -o cputime= -p $PID
  ```

- **The engine alone against your real data:** `cd AgentDeckCore && AGENTDECK_LIVE=1 swift test --filter Live` reads `~/.claude` read-only with a throwaway database and prints the time to the first task and to load-complete, the engine's CPU over 10 s of watching, and per-task summaries without any prompt text.

### Debug remote control

Debug builds, and Release builds launched with `-automation`, listen for the distributed notification `com.karun.AgentDeck.debug`. `build/debugctl` (from `make debugctl`) sends one, so you can drive and screenshot the app from a terminal without Screen Recording or Accessibility permissions — snapshots are rendered by the app itself. Any process running as you can send these, and `snapshot` and `dump` write wherever they're told; that's why Release builds ignore them by default.

```sh
make run debugctl
build/debugctl section history
build/debugctl open 0
build/debugctl snapshot /tmp/agentdeck.png
```

| Command | Does |
|---|---|
| `snapshot [path] [main\|settings\|popover]` | Render a window to PNG (default `/tmp/agentdeck.png`, main window; `settings` needs the Settings window open) |
| `section active\|history`, `section project <name>` | Switch section |
| `open <i>`, `close` | Open the i-th task of the current list, close it |
| `inspect <i>` | Inspect the i-th agent of the open task (0 is the main agent) |
| `inspector on\|off`, `palette on\|off` | Show or hide them |
| `search <text>`, `highlight <i>` | Search, move the keyboard highlight |
| `filter status <status>`, `filter model <family>`, `filter clear` | Filters, using raw values (`running`, `opus`, …) |
| `key <chars> [cmd] [opt] [shift]`, `key up\|down\|return\|escape` | In-process key events to the main window |
| `scroll <dy> [x y]` | A synthesized scroll-wheel event |
| `resize <w> <h>`, `appearance dark\|light` | Window size; appearance (anything else follows the system) |
| `mock`, `mock stress`, `mock off` | Switch the data source |
| `meter start`, `meter stop [path]` | Frame meter (default `/tmp/agentdeck-meter.txt`) |
| `state [path]`, `dump [path]` | Counts and navigation state; every task (with its entry, entry kind and working folder) and agent with model, estimate and activity (defaults under `/tmp`) |
| `sidebar [path]` | The sidebar's project entries in order, each with its kind, active count and task count (default `/tmp/agentdeck-sidebar.txt`) |
| `settings [general\|groups\|notifications\|data]`, `quit` | Open Settings (on that tab), quit |

A few more (`menulabel`, `menubar`, `statusitem`, `windows`, `views`, `snapview`, `loginstatus`) inspect the menu bar item, windows and view tree — see `AgentDeck/Debug/DebugAutomation.swift`.

## Project layout

```
AgentDeck/                   The SwiftUI app (a folder-synchronized group)
  AgentDeckApp.swift         Scenes, menu commands and shortcuts, Debug menu
  Model/                     AppModel (source switching, -mock/-stress), Navigator, Notifier,
                             LoginItem, TaskQuery, LaunchMetrics
  Views/                     Active, Detail (agent tree, timeline), History, Inspector,
                             MenuBar, Settings, command palette, sidebar, toolbar
  Design/                    Theme, shared components (pulse host), clock and time views
  Debug/                     DebugAutomation (debugctl), FrameMeter, Experiments
AgentDeckCore/               Swift package with everything that isn't a view
  Sources/AgentDeckState/    DeckStore and the @Observable task and agent models (main actor)
  Sources/AgentDeckCore/
    ClaudeCode/              Engine, FSEvents, incremental reads, parsing, state, hook tail
    Workflow/                Workflow groups: rules, signals, the pure classifier
    Estimation/              Estimator, first-launch EstimateScanner
    Persistence/             GRDB history store and schema
    Mock/                    Simulator behind -mock / -stress
    Model/                   Snapshot types shared with the app
    Source/                  AgentSource protocol, UpdateCoalescer
    Support/                 Clocks, process probe, timestamps, file ids
  Tests/AgentDeckCoreTests/  Swift Testing suites and Fixtures/
  Tests/AgentDeckStateTests/ DeckStoreTests (Swift Testing)
docs/                        data-sources.md, architecture.md
scripts/                     debugctl, profiling, fixtures, app icon
Makefile
```

`AgentDeck.xcodeproj` uses a folder-synchronized group for `AgentDeck/`, so a new Swift file anywhere under `AgentDeck/` is compiled without touching `project.pbxproj`. `AgentDeckCore` is a local package whose two library products, `AgentDeckCore` and `AgentDeckState`, the app links, and SwiftPM picks up new files the same way. `scripts/make-icon.swift` regenerates the app icon into `AgentDeck/Assets.xcassets/AppIcon.appiconset` (`swift scripts/make-icon.swift` from the repo root).

## Testing

```sh
make test
```

That runs `swift test` in `AgentDeckCore/`: 248 tests, all written with Swift Testing, in two targets.

- **`AgentDeckCoreTests`** (234 tests in 19 suites) covers the line scanner and parser, the session reducer, status rules, model names, the estimator, the history store, the update coalescer, FSEvents, the engine (incremental reads, truncation and replacement resets, moved sessions, pid and window timing, hook lines, estimate bookkeeping), the mock, and workflow groups: `WorkflowClassifierTests` (the order, folder sessions staying put, title keywords, the TradingBot folder rule, temporary and home folders, skill and tool matching, the signals the reducer collects) and `WorkflowHistoryTests` (a scratch session moving to PubgMontages partway, a rule edit reclassifying history without transcripts, migrating stale `scratch-…` rows).
- **`AgentDeckStateTests`** (14 tests, `DeckStoreTests.swift`) covers `DeckStore` and the live models: indexes, the sidebar order (groups, folders, Others), model identity across updates, the same run id in two sessions staying two models, dropped runs and tasks, models in use, reset, the throttled glance count, finish and subagent-failure notifications, idle elapsed time and task ETA.

The app target has no tests of its own — the logic worth testing lives in the package.

The fixtures under `AgentDeckCore/Tests/AgentDeckCoreTests/Fixtures/` are sanitized real transcripts. To add one, pass session ids to the fixture script:

```sh
python3 scripts/make-fixtures.py <session-id> [<session-id> ...]
```

It copies those sessions from `~/.claude/projects` into `Fixtures/projects/`, keeping structure, ids, timestamps, models, tool names, statuses and token counts, and replacing free text (prompts, tool inputs and outputs, titles, thinking) with short deterministic tokens such as `txt-1a2b3c4d`. Equal strings stay equal across files, so links like "the subagent's first prompt equals the Agent call's prompt" stay testable. Home-directory paths become `/Users/dev`. Read the output before committing anyway — it's your private data going into the repo.

`LiveDataTests` is skipped unless `AGENTDECK_LIVE=1` is set (see [Reproducing the numbers](#reproducing-the-numbers)).

## Troubleshooting

### No tasks show up

- If Active says **Can't read sessions** — "Claude Code data folder not found: …" — the data folder doesn't exist. Set it in **Settings › Data › Claude Code folder**.
- AgentDeck doesn't read `CLAUDE_CONFIG_DIR`. It's a GUI app and never sees your shell's environment, so if you run Claude Code with `CLAUDE_CONFIG_DIR` set, choose that folder in Settings › Data (the Open panel shows hidden folders).
- A session whose turn has ended is **idle** and lives in History, not Active, until you send the next prompt.
- Finished tasks older than **Keep finished tasks for** are hidden.
- A filled filter icon or text in the search field hides tasks — use **Clear Filters** and clear the search.
- If the subtitle says "Simulated agents", mock mode is on — turn off **Debug › Simulate Agents** (⌥⌘M).

### Notifications don't appear

- Both are off until you turn one on in Settings › Notifications; that's when macOS asks for permission.
- If Settings shows "Notifications are turned off for AgentDeck in System Settings › Notifications", allow them there. A Focus mode can hold them back too.
- **When a task finishes** fires when a task leaves running or waiting. Tasks that finished before AgentDeck loaded them don't notify.

### Launch at login doesn't work

- An error under the toggle ("Couldn't update the login item: …") means the change failed: turning it on, neither `SMAppService` nor writing the LaunchAgent worked; turning it off, deleting the plist or unregistering failed (if only unregistering failed, the LaunchAgent is already gone).
- Check whether the LaunchAgent is there and what it runs:

  ```sh
  plutil -p ~/Library/LaunchAgents/com.karun.AgentDeck.login.plist
  ```

  It opens the app by bundle id, so make sure the copy you want is in `/Applications` (`make install`). If an older build wrote it with a path instead, turn the toggle off and on again to rewrite it.
- See which copy `open -b` resolves to by quitting AgentDeck and running `open -b com.karun.AgentDeck` yourself.
- If the system accepted the `SMAppService` registration instead, it's listed under System Settings › General › Login Items & Extensions.

### A task is in the wrong sidebar entry

- Groups are tried in order and the first match wins — a session that runs both the morning skill and `pubg-montage` lands in whichever group is higher in Settings › Groups.
- Title keywords never apply to a session with a project folder. If a project session should be in a group, add an agent type, skill, tool or folder rule instead.
- See what AgentDeck read: `build/debugctl dump` lists each task's entry, entry kind and working folder (Debug builds). For finished tasks the signals are in the database:

  ```sh
  sqlite3 -readonly ~/Library/Application\ Support/AgentDeck/agentdeck.sqlite "SELECT id, signals FROM history_task ORDER BY ended_at DESC"
  ```

- `history_task.project_name` isn't what the sidebar shows — it's the entry when the row was written, and rows from builds before workflow groups still hold the raw folder name there (`Scratch`, `scratch-2026-10-02-cfe996`). The entry is always worked out again from `signals`.

### Resetting the history database

```sh
pkill -x AgentDeck
rm -f ~/Library/Application\ Support/AgentDeck/agentdeck.sqlite*
```

The next launch creates a fresh database and runs the first-launch scan again. What you lose for good: finished tasks whose transcripts Claude Code has already deleted, and the duration samples from them — the scan can only relearn from what's still under `projects/`.

The glob also removes `-wal`, `-shm` and any `agentdeck.sqlite.broken-*` files. AgentDeck makes those itself: if the database is corrupt at launch, it's renamed to `agentdeck.sqlite.broken-<yyyyMMdd-HHmmss>` and replaced with a fresh one. Any other open failure (busy, permissions, a failed migration) leaves the file alone and runs that session on an in-memory database — history and learned samples from that session aren't kept — and reports the reason as a load error, shown in Active when nothing is running. The next launch tries the file again.

### The hook doesn't seem to do anything

- Check that `~/.claude/agentdeck/events.jsonl` grows while an agent runs (`tail -f`). If it doesn't, start a new Claude Code session and check `~/.claude/settings.json` parses.
- AgentDeck starts reading at the file's end, so lines written before it noticed the file never count. If you created the folder while AgentDeck was running, give it a minute or relaunch.
- On a healthy machine it shouldn't look any different — see [Optional hooks for lower latency](#optional-hooks-for-lower-latency).

### The build fails

- `xcodebuild` complaining that it requires Xcode means the Command Line Tools are selected: `sudo xcode-select -s /Applications/Xcode.app`.
- The first build needs network access to fetch GRDB. After that, builds work offline.
