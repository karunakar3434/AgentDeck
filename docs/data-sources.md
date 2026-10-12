# Data sources

What AgentDeck reads, where it lives, and how each field in the UI is derived.
Everything here was checked against the files on this Mac (Claude Code 2.1.173–2.1.286,
mostly 2.1.284/2.1.286, desktop app and CLI) and against the Claude Code docs
(code.claude.com/docs: sessions, sub-agents, hooks, agent-teams). Where the two
disagree, this document follows the files.

Sample lines below are real but sanitized: `…` replaces private text and long values,
ids are shortened.

## 1. Where things are

| Path | What | Used for |
|---|---|---|
| `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | Main session transcript | Tasks, main agent, Agent calls |
| `~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/agent-<agentId>.jsonl` | One file per subagent run | Subagent activity, model, completion |
| `~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/agent-<agentId>.meta.json` | Sidecar written when the subagent starts | **The live link** from subagent to the Agent call |
| `~/.claude/projects/<encoded-cwd>/<sessionId>/custom-title.json` | `{"customTitle":"…"}` | Task title (desktop sessions) |
| `~/.claude/projects/<encoded-cwd>/<sessionId>/tool-results/*` | Large tool outputs, images | Not read |
| `~/.claude/projects/<encoded-cwd>/<sessionId>.desktop-released.json` | `{"v":1,"releasedAt":…,"reason":"delete"}` | Not read (may sit next to a live `.jsonl`) |
| `~/.claude/projects/<encoded-cwd>/memory/` | Auto-memory | Not read |
| `~/.claude/sessions/<pid>.json` | One file per **running** Claude Code process | Liveness and busy / idle / waiting state |
| `~/.claude/agents/*.md`, `<project>/.claude/agents/*.md` | Agent definitions | `model:` frontmatter fallback |
| `/private/tmp/claude-<uid>/<encoded-cwd>/<sessionId>/tasks/<agentId>.output` | Symlink to the subagent `.jsonl` | Not needed (same file) |

Size on this Mac: 102 MB in `projects/`, 62 `.jsonl` files (16 main, 46 subagent);
largest file 10.2 MB. 18 files changed in the last 24 h. Retention is `cleanupPeriodDays`
(default 30) in `settings.json`; `CLAUDE_CONFIG_DIR` moves the whole tree.

### Directory name encoding

The directory name is the session's starting cwd with every non-alphanumeric character
replaced by `-` (`/Users/dev/Projects/AgentDeck` → `-Users-dev-Projects-AgentDeck`,
spaces too). The encoding is lossy, so **the real path is read from the `cwd` field** of
the first line that has one, never decoded from the directory name. That `cwd` is the
task's working folder; which sidebar entry the task lands in is §9.

Two complications seen on disk:
- **Sessions can move.** After a `change_directory` the desktop app moves the `.jsonl` to
  the new project dir and appends `{"type":"relocated","sessionId":…,"relocatedCwd":…}`.
  Tasks are keyed by `sessionId`, not by path. `relocatedCwd` updates the project.
- **`cwd` changes line to line** when Bash runs `cd`. The task's project uses the first `cwd`
  (or the latest `relocatedCwd`).

## 2. Main transcript lines

One JSON object per line, appended as the session runs. Line `type` counts across all files:

| type | main | subagent | Notes |
|---|---|---|---|
| `assistant` | 1735 | 4326 | One content block per line |
| `user` | 986 | 3083 | Prompts and tool results |
| `attachment` | 987 | 2431 | System context (reminders, queued commands) |
| `system` | 244 | – | Turn boundaries, errors, compaction |
| `queue-operation` | 413 | – | Prompt and notification queue |
| `last-prompt`, `custom-title`, `agent-name`, `ai-title`, `atis-latch`, `mode`, `permission-mode`, `cost-state`, `bridge-session`, `relocated` | | – | Metadata, no `uuid`/`timestamp` |
| `file-history-snapshot`, `file-history-delta` | | – | Skipped |
| `fork-context-ref` | – | 1 | First line of a forked agent |

`summary` and `progress` lines **do not exist** in these versions (older docs and blog
posts mention them). Subagent activity is only visible in the subagent's own file.

Common envelope on `user` / `assistant` / `attachment` / `system` lines:
`parentUuid, isSidechain, type, uuid, timestamp, userType, entrypoint ("claude-desktop" | "cli"),
cwd, sessionId, version, gitBranch`, plus `agentId` in subagent files.

Timestamps are ISO-8601 with milliseconds (`2026-10-02T23:56:28.204Z`). They are **not**
strictly monotonic in file order (queue operations interleave), so state uses max().

### User prompt

```json
{"parentUuid":null,"isSidechain":false,"promptId":"56ede9b5-…","type":"user",
 "message":{"role":"user","content":"…(11174 chars)"},"uuid":"bae29393-…",
 "timestamp":"2026-10-02T23:56:28.204Z","permissionMode":"auto","origin":{"kind":"human"},
 "promptSource":"sdk","turnOrigin":"human","turnPosition":{"promptIndex":1,"turnIndex":1},
 "userType":"external","entrypoint":"claude-desktop","cwd":"/Users/dev/…",
 "sessionId":"fb4572c1-…","version":"2.1.286","gitBranch":"HEAD"}
```

A real human prompt is a `user` line whose `message.content` is a string (or `text` blocks),
with `isMeta` absent/false, and `origin.kind == "human"` when `origin` is present. Other `user`
lines with string content are system-made: `isMeta:true` reminders, `origin.kind` `"peer"`
(subagent handback), `"task-notification"`, `"coordinator"`, or
`"[Request interrupted by user]"`.

### Assistant message (streamed: one line per content block)

```json
{"parentUuid":"fc0ddadd-…","isSidechain":false,"type":"assistant","uuid":"b151433a-…",
 "timestamp":"2026-10-02T23:56:35.582Z","requestId":"req_011Cfe…","apiBlockIndex":1,
 "message":{"model":"claude-opus-5-5","id":"msg_011CfeKE…","type":"message","role":"assistant",
  "content":[{"type":"tool_use","id":"toolu_01X9aq…","name":"Bash",
              "input":{"command":"…","description":"…"},"caller":{"type":"direct"}}],
  "stop_reason":"tool_use","usage":{"input_tokens":2,"cache_creation_input_tokens":34550,
  "cache_read_input_tokens":40756,"output_tokens":577,…}},
 "effort":"xhigh", …envelope}
```

- Every line has exactly one block: `text`, `thinking` (text usually empty, signature only), or `tool_use`.
- One API response = several lines sharing `message.id` and `requestId`. Usage must be
  counted **once per `message.id`** (take the last line seen for that id).
- **`stop_reason` and `usage` are unreliable per line.** In main files they are the final
  values copied to every line. In subagent files (2.1.284+) `stop_reason` is usually `null`
  and `usage.output_tokens` is the message_start value.
- Models seen: `claude-opus-5-5`, `claude-sonnet-5`, `claude-sonnet-5-5`, `claude-sonnet-4-6`,
  `claude-haiku-4-5-20251001`, and `<synthetic>` (see errors).

### Tool result

```json
{"type":"user","parentUuid":"b151433a-…","sourceToolAssistantUUID":"b151433a-…",
 "message":{"role":"user","content":[{"tool_use_id":"toolu_01X9aq…","type":"tool_result",
   "content":"…","is_error":false}]},
 "toolUseResult":{"stdout":"…","stderr":"","interrupted":false,…}, …envelope}
```

`toolUseResult` is the structured result (shape depends on the tool). In subagent files most
tool results have no `toolUseResult`.

### Errors and interrupts

```json
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,
 "message":{"model":"<synthetic>","id":"<uuid>","content":[{"type":"text",
   "text":"You've hit your session limit · resets 9:20pm (…)"}],"stop_reason":"stop_sequence"}, …}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}, …}
```

- `model:"<synthetic>"` is never a real model and is ignored for model detection.
- `isAbortedMidStream:true` marks a partial message.
- `"[Request interrupted by user for tool use]"` follows a tool_result with `is_error:true`
  and `toolDenialKind:"user-rejected"`.
- `system` / `subtype:"api_error"` lines are retries (`retryAttempt`, `maxRetries`), not failures.

### Turn boundaries and session end

```json
{"type":"system","subtype":"stop_hook_summary","hookCount":2,"level":"suggestion", …}   // desktop
{"type":"system","subtype":"turn_duration","durationMs":5336,"messageCount":20,
 "pendingBackgroundAgentCount":1, …}                                                    // CLI
{"type":"cost-state","sessionId":"08cb7b8e-…","totalCostUSD":1.82,"totalDuration":9977361,
 "startTime":1790975493149,"modelUsage":{"claude-opus-5-5":{…}}}                         // process exit
```

- A finished turn ends with an `assistant` text block (`stop_reason:"end_turn"`) followed by
  `system/stop_hook_summary` (desktop) or `system/turn_duration` (CLI).
- When the process exits it appends `last-prompt` and `cost-state`. Every session without a
  live process ended this way. **`cost-state` is the "session closed" marker.**
- `system/compact_boundary` marks a compaction; the next user line has `isCompactSummary:true`
  and is not a new prompt.

### Titles

| Source | Where | Notes |
|---|---|---|
| `custom-title` line / `<sessionId>/custom-title.json` | Desktop sessions | What the desktop sidebar shows |
| `ai-title` line | CLI sessions | Generated title |
| First human prompt | All | Can be very long (pasted specs) |

**Adjustment to the spec:** the task title is the custom/AI title when one exists, else the
first human prompt trimmed to one line (~120 chars). The first prompt is kept as the
task's subtitle.

## 3. Subagent runs

### The Agent tool call (parent transcript)

Only `name:"Agent"` appears in these versions (older versions used `Task`; both are accepted).

```json
{"type":"tool_use","id":"toolu_018qrq…","name":"Agent","caller":{"type":"direct"},
 "input":{"description":"…(36 chars)","subagent_type":"claude-code-guide",
          "prompt":"…(2442 chars)","run_in_background":true}}
{"type":"tool_use","id":"toolu_01PxT4…","name":"Agent",
 "input":{"description":"…","subagent_type":"general-purpose","model":"sonnet",
          "prompt":"…","run_in_background":true}}
```

Input keys seen: `description` (50/50), `prompt` (50), `subagent_type` (50),
`run_in_background` (49; true 43), `model` (4, always an alias like `"sonnet"`).
The docs also list `name` and `isolation`; neither appears here.

### The tool_result: three shapes

**Background launch** (`run_in_background`, 40 of 45): returns immediately.

```json
"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"af4448711daf1ca74",
  "description":"…","resolvedModel":"claude-haiku-4-5-20251001","prompt":"…",
  "outputFile":"/private/tmp/claude-501/…/tasks/af4448711daf1ca74.output","canReadOutputFile":true}
```

**Foreground completion** (5 of 45): written only when the agent finishes.

```json
"toolUseResult":{"status":"completed","agentId":"a140524516f2ac0a4","agentType":"general-purpose",
  "resolvedModel":"claude-opus-5-5","totalDurationMs":38698,"totalTokens":115853,
  "totalToolUseCount":10,"usage":{…},"content":[{"type":"text","text":"…"}],
  "handbackReport":{"text":"…"},"toolStats":{…}}
```

**Failure at launch**: `tool_result.is_error:true`, `toolUseResult` is a plain string,
e.g. `"Error: Agent type 'gmail-monitor' not found. Available agents: …"`.

### How a background agent's finish reaches the parent

Not through the tool_result. The parent gets a `<task-notification>` block, recorded as a
`queue-operation` (`operation:"enqueue"`, in `content`), then either an `attachment` of type
`queued_command` (`commandMode:"task-notification"`) or a `user` line with
`origin.kind:"task-notification"`:

```xml
<task-notification>
<task-id>af4448711daf1ca74</task-id>              <!-- agentId -->
<tool-use-id>toolu_018qrq…</tool-use-id>          <!-- the Agent tool_use.id -->
<output-file>…</output-file>
<status>completed</status>                         <!-- completed | failed -->
<summary>Agent "…" finished</summary>             <!-- or: Agent "…" failed: <reason> -->
<result>…</result>
<usage><subagent_tokens>106553</subagent_tokens><tool_uses>18</tool_uses><duration_ms>186693</duration_ms></usage>
</task-notification>
```

The same `task-id` can notify again after the agent is resumed with `SendMessage`; the
resumed agent appends to the same `agent-<id>.jsonl`. Bash/Monitor background tasks use the
same envelope with `task-id` `b<8 chars>` and no `<tool-use-id>` for an Agent call, and are ignored.

Before the notification, the agent's handback report usually arrives as a `user` line (or
`queued_command` attachment) with `origin:{kind:"peer", from:<agentId>, name:<agentType>, handback:true}`.

### Subagent transcript and sidecar

```json
// subagents/agent-af4448711daf1ca74.meta.json
{"agentType":"claude-code-guide","description":"…","toolUseId":"toolu_018qrq…",
 "spawnDepth":1,"requestShape":"background","requestNonInteractive":true}
// first line of subagents/agent-af4448711daf1ca74.jsonl
{"parentUuid":null,"isSidechain":true,"agentId":"af4448711daf1ca74","promptId":"56ede9b5-…",
 "type":"user","message":{"role":"user","content":"…(== Agent input.prompt)"},
 "timestamp":"2026-10-02T23:57:07.533Z","sessionId":"fb4572c1-… (parent session)", …}
```

Meta keys: `agentType`, `description`, `toolUseId` (45/46), `spawnDepth` (always 1 here),
`requestShape` (`background` | `foreground`), `requestNonInteractive`, optional `model`
(`"sonnet"`, `"inherit"`), `isFork`, `name`.

Every subagent line has `isSidechain:true`, `agentId` equal to the file's id, and `sessionId`
equal to the **parent** session.

### Linking a subagent file to the Agent call

Checked on all 45 Agent calls that spawned an agent:

| Link | Matched | Available while running? |
|---|---|---|
| `meta.json` `toolUseId` == parent `tool_use.id` | 45/45 | **Yes, foreground and background** |
| parent `toolUseResult.agentId` → `agent-<agentId>.jsonl` | 45/45 | Background yes; foreground only at the end |
| `<task-notification>` `task-id` + `tool-use-id` | all finished background | At completion |
| subagent first prompt == `input.prompt` | 45/45 | Yes, but fragile |

AgentDeck links by **`meta.json.toolUseId`** (primary), confirmed by `toolUseResult.agentId`
and the notification. A subagent file whose meta has no `toolUseId` (a `/btw` fork:
`agentType:"fork"`, first line `fork-context-ref`) is shown as a child of the main agent.

### When does a subagent finish

| Signal | Means |
|---|---|
| Parent tool_result with `toolUseResult.status:"completed"` | Foreground run done; `totalDurationMs` is exact |
| Parent tool_result with `is_error:true` | Failed (launch error or crash) |
| `<task-notification>` `status completed` / `failed` | Background run done / failed; `duration_ms` is exact |
| Subagent file: `SubagentHandback` tool_result with `toolEndsTurn:true`, or a final `text` block with `stop_reason:"end_turn"` | Done (fallback before the notification lands) |
| Subagent file: `<synthetic>` error line | Failed (e.g. rate limit) |
| Parent `"[Request interrupted by user]"` while a foreground run has no result, or session closed (`cost-state`) with the run unfinished | Cancelled |
| New lines appended to a finished run's file | Resumed: running again |

### Nesting

No nested subagents exist on this Mac: no `Agent` tool_use appears in any subagent file and
`spawnDepth` is always 1. The design still supports it: an `Agent` tool_use inside a
subagent file creates a child run whose `parentRunID` is that subagent, linked the same way
through `meta.json.toolUseId`, which is expected to be in the same `subagents/` directory.

## 4. Which model a run used

Resolution order (first hit wins):

1. **`message.model` on the run's own assistant lines** (skip `<synthetic>`). For a subagent this is
   its own file; for the main agent, the main file. Reliable even with `model: inherit`.
2. **`toolUseResult.resolvedModel`** on the Agent result. Present on both background launches and
   foreground completions, so it is known within a second of launch, before the subagent's first
   assistant line.
3. **The Agent call's `model` parameter** (`"sonnet"`, …), or `meta.json.model` when not `"inherit"`.
4. **The agent definition's frontmatter** `model:` when not `inherit`. Project definitions
   (`<project>/.claude/agents/<type>.md`) take precedence over user ones (`~/.claude/agents/<type>.md`),
   matching the Claude Code docs.
5. Otherwise **"inherits parent"**: the main agent's current model.

The docs give the runtime order as call parameter > frontmatter > `CLAUDE_CODE_SUBAGENT_MODEL`
> parent. Steps 1–2 report what actually ran, so they override it. Built-in defaults are not
documented; the transcripts show `claude-code-guide` resolving to `claude-haiku-4-5-20251001` and
Explore to the parent model.

Agent definitions on this Mac (`~/.claude/agents/`): 10 use `inherit`, 4 `sonnet`
(localbiz-curator, -researcher, -scout, -web-auditor), 3 `opus` (localbiz-qa, -site-builder,
-site-designer). No project has `.claude/agents/`.

## 5. Is a session running, waiting on me, idle or done

`~/.claude/sessions/<pid>.json` exists for every running Claude Code process and is removed on exit:

```json
{"pid":3156,"sessionId":"fb4572c1-…","cwd":"/Users/dev/…","startedAt":1790985387487,
 "procStart":"Fri Oct  2 23:56:27 2026","version":"2.1.286","kind":"interactive",
 "entrypoint":"claude-desktop","name":"…","status":"busy","updatedAt":1790985388548,
 "statusUpdatedAt":1790985388036}
```

`status` is `"busy"`, `"idle"` or `"waiting"`. With `"waiting"` there is a `waitingFor` string.
The Claude Code binary sets it for a permission or other dialog (`topDialogWaitingFor`),
`"input needed"` (MCP elicitation), `"worker request"`, `"sandbox request"` and `"dialog open"`.
**Nothing about a pending permission prompt is written to the transcript**, so this file is the
only reliable "waiting on me" signal. The `.key` files next to it are secrets and are never read.
`session-env/` holds empty directories and says nothing about liveness.

Task status, in order:

| Status | Rule |
|---|---|
| failed | Last turn ended on a `<synthetic>` error line (`isApiErrorMessage`) with nothing after it |
| waiting on me | pid file `status:"waiting"`, or a pending `AskUserQuestion` / `ExitPlanMode` tool_use |
| running | pid file `status:"busy"`; or (no pid file, older or remote sessions) mid-turn and the transcript grew in the last 2 min; or any subagent still running |
| idle | Process alive (pid file present, `kill(pid,0)` succeeds, `procStart` matches) and none of the above |
| done | `cost-state` seen after the last activity, or no live process and quiet for 2 min |

"Mid-turn" means the last event is a human prompt, a tool_result, or a `tool_use` without its
result, rather than an `end_turn` text followed by `stop_hook_summary` / `turn_duration`.

## 6. Durations for estimates

Exact durations come from the transcripts: `totalDurationMs` (foreground) and the
notification's `<duration_ms>` (background). Fallback: last subagent line timestamp minus
first. The first scan reads every transcript on disk for these (about 45 completed runs here,
across 11 agent types) and stores them in SQLite. After that, only new bytes are read.

## 7. Hooks (optional, lower latency)

The transcript path already gives sub-second updates. FSEvents with a 0.1 s latency, plus
the meta sidecar written when an agent starts, means a new subagent appears well within
1 s. Hooks would add little. They are documented in the README as an optional add-on. The
app never edits `~/.claude/settings.json`.

Relevant events (code.claude.com/docs/en/hooks): `SubagentStart` / `SubagentStop`
(matcher = agent type; payload has `agent_id`, `agent_type`, `agent_transcript_path`),
`PreToolUse` / `PostToolUse` with matcher `"Agent"` (payload has `tool_name`,
`tool_input`, `tool_response`), `Stop`, `SessionStart`, `SessionEnd`, `Notification`.
Every payload carries `session_id`, `transcript_path`, `cwd` and `hook_event_name`.
`type:"http"` hooks also exist, but a `command` hook that appends the payload to a file
keeps the app free of any listening socket.

If a hook is installed, it appends one JSON line per event to
`~/.claude/agentdeck/events.jsonl`. AgentDeck tails that file when it exists and treats it
as a hint to re-read the named transcript right away. The README has the snippet.

## 8. Things to watch for

- Huge lines (multi-MB tool results). Lines are skipped by type before being fully decoded.
- Partial trailing lines while a file is being written. Keep the remainder and finish it on the next read.
- Files that shrink or are replaced (inode change). Re-read from 0 for that session.
- Clock skew between line timestamps. Use max(), never assume order.
- `sessionId` on subagent lines is the parent's, so it doesn't identify the subagent.

## 9. Sidebar entries: workflow groups, folders, Others

Each task goes in exactly one sidebar entry (`TaskSnapshot.projectName`, with `projectKind`),
decided by `WorkflowClassifier` in this order: the first workflow group with a matching rule,
else the real project folder (named after the folder), else Others. The rules themselves are
in the README (Projects and workflow groups); this section is what they read and why the
defaults look the way they do.

### Signals

| Signal | Where it comes from | Kept |
|---|---|---|
| Working folder | First `cwd` of the main transcript, or the latest `relocatedCwd` (§1). Later `cwd`s from a Bash `cd` are ignored | — |
| Title | The task title (§2 Titles) | ≤ 120 chars |
| Agent types | `subagent_type` of every Agent call (meta `agentType` for runs without a call) | ≤ 128 names |
| Skills | The Skill tool's `input.skill`, and `<command-name>/name</command-name>` in a `user` line | ≤ 128 names, ≤ 300 chars each |
| Tools | `name` of every `tool_use` in any of the task's files; MCP tools by full name | ≤ 128 names, ≤ 300 chars each |

```json
{"type":"tool_use","name":"Skill","input":{"skill":"anthropic-skills:skill-creator","args":"…"}}
{"type":"user","message":{"content":"<command-message>localbiz-pipeline</command-message>\n<command-name>/localbiz-pipeline</command-name>\n<command-args>…</command-args>"},"origin":{"kind":"human"}, …}
{"type":"tool_use","name":"mcp__07c0f660-e970-4f41-bb4f-8b485e3c62ab__createScheduledPost","input":{…}}
```

Both skill sources are needed. A skill the model calls is a Skill `tool_use`. A skill you type
as a slash command never makes one — it shows up only as the command echo above, followed by
an `isMeta` user line starting "Base directory for this skill: …". A Skill call the skill
refuses (`disable-model-invocation`) still counts: the session asked for that skill.

Nothing new is JSON-decoded for these. The Skill input's `skill` was already decoded for the
inspector's tool summary, and a command echo was already recognized (and dropped as a prompt)
by its `<command-` prefix; the name is cut out of the first 2 KB of that text.

### No real project folder

A working folder isn't a project folder when it contains `/scratch-workspaces/` (desktop
sessions started without a folder:
`~/Library/Application Support/Claude/scratch-workspaces/<org>/<account>/scratch-YYYY-MM-DD-xxxxxx`),
is inside `/tmp`, `/private/tmp`, `/var/folders` or `/private/var/folders` (for example a Claude
Code scratchpad, `/private/tmp/claude-501/<encoded-cwd>/<sessionId>/scratchpad/…`), or is the
home folder itself, `/`, or unknown. Paths compare ignoring case, like the default macOS volume.

The September sessions that start in the home folder and later `cd ~/voice-assistant` land in
Others: their working folder is the first `cwd`. Following `cd` instead would let any session
that glances into another folder change entry.

### Scheduled runs aren't marked

Checked on every main transcript here: `entrypoint` is `cli` or `claude-desktop`;
`promptSource` is `typed`, `queued`, `sdk` or `system`; `turnOrigin` is `human`, `peer`,
`task_notification` or `sdk`. The scheduled "Daily Gmail report" run starts with
`promptSource:"sdk"`, `turnOrigin:"human"`, `origin.kind:"human"` — the same as a desktop
session someone typed into — and its first prompt is the desktop's scratch-workspace reminder.
Its `agent-name` line isn't a marker either: every desktop session has one, equal to its custom
title. No field tells a scheduled run apart, so GmailMonitor matches on the `gmail-monitor` agent type and the morning
skill instead, and a scheduled task that uses neither lands in Others.

### The defaults against real sessions

| Session | Working folder | Signals | Entry |
|---|---|---|---|
| Daily Gmail report | scratch workspace | agent `gmail-monitor` | GmailMonitor |
| Gmail monitor subagent | scratch workspace | agents `gmail-monitor` (failed: the type didn't exist yet), `general-purpose`; `mcp__scheduled-tasks__*` tools | GmailMonitor |
| Video quality enhancement | scratch workspace | skill `anthropic-skills:skill-creator`, `/agents`; Bash commands running `~/Projects/Pubg_Tools/bin/ffmpeg` | PubgMontages, by the title keyword `video` |
| second-session | `/private/tmp/claude-501/…/scratchpad/second-session` | agents `Explore` ×2 | Others |
| Task execution dashboard UI | scratch workspace | none | Others |
| AgentDeck sessions | `~/Projects/AgentDeck` | code agents, `my-writing-style` skill | AgentDeck |
| localbiz sessions | `~/localbiz` (one moved there from a scratch workspace with `relocated`) | `localbiz-*` agents, `/localbiz-pipeline` | localbiz |

"Video quality enhancement" is the weak case. None of the strict PubgMontages signals appear in
it: no `pubg-montage` or `video-enhance` Skill call (it ran skill-creator to *create*
`video-enhance`), no `video-editor` run (it wrote that agent's definition but never launched it),
no Metricool call, and its `cwd` never left the scratch workspace — it only moved to
`video-enhance/scripts` inside it. The `Pubg_Tools` path is in Bash command text, which isn't a
signal. Its title is all that ties it to the PUBG work, which is why `video` is a default title
keyword. Later sessions that run `video-enhance` or a `video-editor` agent match on those.

The Metricool tools (`createScheduledPost`, `createScheduledPostForReview`) appear in this Mac's
tool listings but haven't been called in any transcript yet; the rule matches the tool's own name
because the server part of an MCP tool name is an id that differs per install.

### Stored with history

History rows keep the signals as JSON in `history_task.signals` (migration v2), so a rule change
reclassifies every task, history included, without reading a transcript. `history_task.project_name`
(and `projectName` in the snapshot blob) records the entry when the row was written and is never
read back for display. Builds before workflow groups stored the raw folder name there — `Scratch`,
or `scratch-2026-10-02-cfe996` from a build before scratch folders were folded together — and
showed it as-is, so the same scratch folder appeared under two names. v2 fills `signals` for
those rows from what each row kept: the working folder, the title, the agent types, and the Skill
and tool names among each agent's last 20 tool calls. Their slash commands are lost — they were
never tool calls. A row an older build writes after v2 has `signals` NULL and gets the same
recovery when it's read.
