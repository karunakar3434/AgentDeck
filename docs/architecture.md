# AgentDeckCore architecture

Status: proposed, 2026-10-02. Implements [data-sources.md](data-sources.md); on any format question that
document wins. Scope: the `AgentDeckCore` package (sources, parsing, state, estimator, persistence, mock).
The public data model in `Model/` is fixed; changes below are additive only.

**Targets:** window interactive at once, first live task < 1 s; 20 tasks x 15 agents live; at most one
`DeckUpdate` per 16 ms and none while idle; < 150 MB; idle CPU < 1 %. Read-only, no network, never
writes under `dataRoot`.
**Assumptions:** data root ~100 MB / ~60 files / largest ~10 MB (data-sources §1); stress write rate
of a few hundred lines/s; one app instance.

## 1. Components and actor boundaries

```
                            App (MainActor)
  AppModel ── for await u in source.updates() ──► DeckStore.apply(u)      (-mock, -stress, Debug menu;
        │                                                                   stop() on switch)
        ▼
  AgentSource ────────────────────────────────────────────────────────────────────────────────┐
  │ ClaudeCodeSource (facade)                              MockAgentSource (facade)           │
  │   ▼                                                      ▼                                │
  │ actor TranscriptEngine ◄─[FSChange]── FSEventsWatcher  actor MockSimulator                │
  │   FileTracker → LineParser → SessionReducer              world model, seeded RNG,         │
  │   StatusRules · ModelResolver · AgentDefinitions         own Estimator + UpdateCoalescer  │
  │   SnapshotBuilder · Estimator · UpdateCoalescer          (no disk, no DB)                 │
  │   Sweeper / deadline timer · ProcessProbe                                                 │
  │   ▲ samples          │ enqueue (sync, non-blocking)                                       │
  │ actor EstimateScanner ──► HistoryStore (GRDB DatabasePool, one per DB file per process)   │
  └───────────────────────────────────────────────────────────────────────────────────────────┘
  reads: <dataRoot>/projects/**, sessions/*.json, agents/*.md, agentdeck/events.jsonl (optional),
         <project>/.claude/agents/*.md
```

| Unit | Kind | Owns |
|---|---|---|
| `TranscriptEngine` | actor | File table (offset/fileID per file), every `SessionState`, pid table, agent-definition cache, in-memory `Estimator`, `UpdateCoalescer`, sweep and deadline timers, the stream continuation. **The only mutator of session state.** |
| `FSEventsWatcher` | `final class @unchecked Sendable` with a private serial `DispatchQueue` | The `FSEventStreamRef`; yields `[FSChange]` into an `.unbounded` `AsyncStream` (the engine de-dups by path) |
| `EstimateScanner` | actor, `Task(priority: .background)` | Its own `LineParser`/`JSONDecoder` and scan progress. Writes through `HistoryStore`; hands samples to the engine |
| `HistoryStore` | `final class Sendable` | `DatabasePool`, `Mutex<[HistoryOp]>` write buffer, one drain task |
| `MockSimulator` | actor | Fake world (`MockWorld`), seeded RNG, event queue; its own pull-based batching (≤ 1 batch per 16 ms, only changed tasks) |

Parser, reducer, status rules, model resolver, estimator and snapshot builder are plain synchronous
structs and functions (pure, testable), called only from the engine. Reading, parsing and applying one
file is a single synchronous step with no `await` inside, so actor reentrancy can never interleave two
reads of the same file. The engine yields (`await Task.yield()`) only between files. Within one
FSEvents batch, files are processed in this order: pid files, main transcripts, meta sidecars,
subagent transcripts, titles/hooks. That ordering means links usually exist before subagent lines arrive.

## 2. File layout (`Sources/AgentDeckCore/`)

```
AgentDeckCore.swift, Formatting.swift      (exist)
Model/Snapshots.swift, ModelFamily.swift   (exist, unchanged)
Model/DeckUpdate.swift                     (exists; + optional `health`, §3)
Source/AgentSource.swift                   AgentSource protocol, SourceHealth
Source/UpdateCoalescer.swift               dirty set, 16 ms flush, backpressure retry (shared by both sources)
Support/DeckClock.swift                    DeckClock protocol + SystemClock
Support/ProcessProbe.swift                 ProcessProbe protocol + Darwin impl (kill, proc_pidinfo, exit source)
Support/Timestamp.swift                    fixed-layout ISO-8601 parser with FormatStyle fallback
ClaudeCode/ClaudeCodeSource.swift          public facade + Configuration; wires engine/watcher/scanner/store
ClaudeCode/TranscriptEngine.swift          actor: file table, sessions, change handling, timers
ClaudeCode/InitialLoader.swift             engine extension: tiered cold-load sequence (§10)
ClaudeCode/PathClassifier.swift            path → FileRole (main, subagent, meta, title, pid, agentDef, hook, ignored)
ClaudeCode/FileTracker.swift               FileState, incremental line reader, reset/rebind rules
ClaudeCode/FSEventsWatcher.swift           FSEventStream wrapper → AsyncStream<[FSChange]>
ClaudeCode/Sweeper.swift                   fallback stat sweep scheduling and scope
ClaudeCode/Parsing/LineScanner.swift       byte-level prefilter → LineKind
ClaudeCode/Parsing/LineModels.swift        minimal Decodable structs for lines and sidecars
ClaudeCode/Parsing/LineParser.swift        bytes → TranscriptEvent; tool-input summaries
ClaudeCode/Parsing/TaskNotification.swift  <task-notification> tag extraction
ClaudeCode/State/SessionState.swift        SessionState, RunState, link maps
ClaudeCode/State/SessionReducer.swift      apply(TranscriptEvent, role, &SessionState)
ClaudeCode/State/StatusRules.swift         pure task/run status derivation + next deadline
ClaudeCode/State/ModelResolver.swift       data-sources §4 resolution
ClaudeCode/State/AgentDefinitions.swift    frontmatter cache (dataRoot/agents, <project>/.claude/agents)
ClaudeCode/State/SnapshotBuilder.swift     SessionState → TaskSnapshot
Estimation/Estimator.swift                 buckets, median, confidence, built-in defaults
Estimation/EstimateScanner.swift           actor: background duration scan using scan_cache
Persistence/HistoryStore.swift             DatabasePool, buffered writes, reads, prune, shared(at:)
Persistence/Schema.swift                   DatabaseMigrator ("v1", …)
Persistence/Records.swift                  GRDB records for the four tables
Mock/MockAgentSource.swift                 public facade + Scenario; actor MockSimulator (real-time loop, 16 ms batches)
Mock/MockWorld.swift                       deterministic world model: tasks, agents, per-scenario MockTuning
Mock/MockEventQueue.swift                  min-heap of timed events (ties broken by insertion order)
Mock/MockScript.swift                      canned agent profiles (base durations, seeded sample counts), projects, tools, summaries
Mock/SeededRandom.swift                    SplitMix64
```

## 3. Public API (adapter protocol)

The app is already written against these names. They are kept as-is; additions are marked.

```swift
public protocol AgentSource: AnyObject, Sendable {
    /// Starts the source on first call; later calls return the same stream (single consumer).
    func updates() async -> AsyncStream<DeckUpdate>
    /// Idempotent: stops FSEvents/timers/scanner, flushes pending DB writes, finishes the stream.
    func stop() async
}

public final class ClaudeCodeSource: AgentSource {          // let-only facade over the engine actor
    public struct Configuration: Sendable {
        public var dataRoot: URL                             // ~/.claude
        public var historyWindow: TimeInterval               // finished tasks older than this aren't emitted
        // Added, defaulted:
        public var databaseURL: URL                          // ~/Library/Application Support/AgentDeck/agentdeck.sqlite
        public var quietInterval: TimeInterval = 120         // "quiet for 2 min"
        public var recentWindow: TimeInterval = 600          // tier-1 load and sweep scope
        public init(dataRoot: URL, historyWindow: TimeInterval)
    }
    public init(configuration: Configuration)
    init(configuration: Configuration, environment: CoreEnvironment)   // internal: tests
}

public final class MockAgentSource: AgentSource {
    public enum Scenario: Sendable { case demo, stress }     // stress = 20 tasks x 15 agents
    public init(scenario: Scenario)
    init(scenario: Scenario, seed: UInt64, clock: any DeckClock) // internal: tests
}

// Internal seams
protocol DeckClock: Sendable { func now() -> Date; func sleep(for: Duration) async throws }
protocol ProcessProbe: Sendable {
    func isAlive(pid: Int32, procStart: String?, startedAtMs: Int64?) -> Bool
    func watchExit(pid: Int32, _ onExit: @escaping @Sendable () -> Void) -> ExitWatch   // cancellable
}
struct CoreEnvironment: Sendable {
    var clock: any DeckClock; var probe: any ProcessProbe; var history: HistoryStore; var watchFileSystem: Bool
}
```

- **Additive model change (optional):** add `DeckUpdate.health: SourceHealth?` (nil = unchanged;
  `.ok` / `.degraded(String)`, for example "Data folder not found"). This lets the app feed `DeckStore.setError`.
- **`ModelSource` gets no new case.** The UI switches over it exhaustively, so `resolvedModel` maps to `.transcript`.
- **Snapshot conventions:**
  - `source` is `"claude-code"` or `"mock"`.
  - Main run: id `main:<sessionId>`, `agentType` `"main"`, description = task title, prompt = latest human prompt.
  - Subagent run id = the Agent `tool_use.id`, or `agent:<agentId>` when there is no `toolUseId` (forks).
  - `runs` order: main first, then by (startedAt, file order).
- **Emission scope:** a task is emitted while its pid is live, or it is active or idle, or
  `(endedAt ?? lastActivityAt) >= now − historyWindow`. This includes DB-only tasks whose transcript is gone.
  When a task leaves the window it is sent in `removed`.

## 4. File watching and incremental reads

| Path under `dataRoot` | Role |
|---|---|
| `projects/<dir>/<sid>.jsonl` | main transcript (incremental) |
| `projects/<dir>/<sid>/subagents/agent-<aid>.jsonl` | subagent transcript (incremental). `aid` = filename minus `agent-`/`.jsonl` and may contain `-` |
| `…/agent-<aid>.meta.json`, `projects/<dir>/<sid>/custom-title.json` | sidecars (small, re-read whole) |
| `sessions/<pid>.json` | pid file (re-read whole). `.key` files are never opened |
| `agents/*.md` | definition cache invalidation |
| `agentdeck/events.jsonl` | hook hints (§12) |
| anything else (`tool-results/`, `memory/`, `*.desktop-released.json`) | ignored without I/O |

**FSEvents setup:**
- One stream over the existing directories among `projects`, `sessions`, `agents`, `agentdeck`.
- Flags `kFSEventStreamCreateFlagFileEvents | NoDefer | WatchRoot`, latency 0.1 s, `kFSEventStreamEventIdSinceNow`,
  scheduled with `FSEventStreamSetDispatchQueue`.
- The event flags `MustScanSubDirs`, `UserDropped`, `KernelDropped` and `RootChanged` trigger a full sweep.
- The stream is recreated when a watched directory appears later (the sweep notices).

**`FileState`:** `{path, role, sessionID, agentID?, fileID (st_dev, st_ino), offset, size, mtime, lastGrowthAt}`.

**`readNewBytes(file)`:**
1. `open` + `fstat`. If the file is missing, start a 2 s removal grace period (relocation, below).
2. If `fileID` changed or `size < offset` (replaced or truncated), **reset the session**: drop its `SessionState`
   and re-read all of its files from 0, in the order main, metas, subagents. A per-file undo isn't possible
   because every file folds into one session state. Resets are rare.
3. If `size == offset`, do nothing.
4. Read `[offset, size)` in chunks of at most 1 MB and split on `\n`. Each complete line goes to the parser, and
   `offset` moves past the last `\n`. **A partial trailing line is not buffered**: it is re-read from `offset`
   next time. A line longer than one chunk keeps reading until its newline. Lines over 64 MB are skipped and logged.
5. Set `lastGrowthAt = clock.now()` and mark the session dirty if any event applied.

**Relocation (keyed by sessionId):** a main `.jsonl` appears at a new path with a known sessionId.
- If the old path is gone and `fileID` matches, rebind (keep offset). Rebind its subagent and meta files by
  agentId under the new `<sid>/`.
- If `fileID` differs (a copy), reset the session from the new path.
- If both paths exist, the newest mtime wins.

The `relocated` line updates the project. Deleting a transcript never removes a finished task; history
keeps it until the window expires. New subagent or sidecar files are registered from their path
(sessionId and agentId), and linking (§6) tolerates any arrival order.

**Fallback sweep:** runs every 10 s while any task is active, otherwise every 60 s. Each sweep:
- `stat`s the files of sessions with activity within `recentWindow` (usually fewer than 50),
- lists `sessions/`,
- `stat`s the `projects/*` directories (their mtime changes when a session file is created).

Any change in (fileID, size) triggers `readNewBytes`. Idle cost is about 100 syscalls per minute.

**Liveness:** `kill(pid, 0)` returns 0 or EPERM, **and** `proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec` is
within ±1 s of `procStart` (parsed as local ctime; fallback: `startedAt` ±30 s). A
`DispatchSource.makeProcessSource(.exit)` per live pid catches crashes that leave the pid file behind,
with no polling.

## 5. Parsing

**Stage 1: `LineScanner.classify(bytes) -> LineKind`** (no allocation, at most the first 4 KB).
A tiny state machine walks the top-level object, tracking string, escape and depth, and skipping whitespace.
It stops at the first decisive depth-1 key:
- `type`: read its value. Metadata lines have it first; user, system and queue-operation lines have it at key
  index 2–4, after short `parentUuid`/`isSidechain`/`promptId`/`agentId`.
- `attachment`: this comes **before** `type` on attachment lines, so read the attachment's own first key
  (`type`). Only `queued_command` continues; everything else is `.skip`.
- `message`: assistant lines put `message` **before** `type` (verified on the fixtures), so this means `.assistant`.
- Undecided after 4 KB: `.decode` (full envelope decode; for unknown shapes).

**Never JSON-decoded:**
- line types `file-history-*`, `mode`, `permission-mode`, `atis-latch`, `last-prompt`, `agent-name`, `bridge-session`, and unknown types;
- every attachment except `queued_command`;
- `queue-operation` lines unless `operation` is `enqueue` and a `memmem` finds `<task-notification>`.

**Stage 2: `JSONDecoder` into minimal `Decodable` structs.** I chose this over `JSONSerialization`.
swift-foundation's decoder scans the buffer once into an offset map and unescapes or allocates a string
only when a `Decodable` asks for that key. `JSONSerialization` builds an `NSDictionary`/`NSString` for every
value, so a 5 MB tool output would be copied to the heap just to be dropped. With minimal structs,
tool_result `content`, `stdout`, thinking signatures and Write/Edit bodies never become Swift values.
Each actor owns one decoder.

| Struct | Fields decoded |
|---|---|
| `AssistantLine` | `timestamp, cwd, gitBranch, isApiErrorMessage, isAbortedMidStream, message{id, model, stop_reason, usage{4 ints}, content[0]{type, id, name, text (text blocks only, first 300 chars kept), input: ToolInput}}` |
| `ToolInput` | optional `command, description, file_path, path, pattern, url, query, prompt, subagent_type, model, run_in_background` (Agent calls + one-line summaries) |
| `UserLine` | `timestamp, cwd, isMeta, isCompactSummary, origin{kind, from}`, `message.content` = string or `[{type, text, tool_use_id, is_error}]` (custom init; `content` of tool_result not declared), `toolUseResult` decoded with `try?` as `AgentToolResult{status, agentId, agentType, resolvedModel, totalDurationMs, totalTokens, usage, content[{text}]}` (it is a string on errors and tool-specific otherwise) |
| `SystemLine` / `QueueOperation` / `QueuedCommand` | `subtype, timestamp` / `operation, content, timestamp` / `attachment{commandMode, prompt}, timestamp` |
| metadata | `customTitle`, `aiTitle`, `relocatedCwd`, `cost-state` (presence only), `fork-context-ref` |
| sidecars | `AgentMeta{agentType, description, toolUseId?, model?, isFork?, name?}`, `PidFile{pid, sessionId, cwd, startedAt, procStart, status, waitingFor?}`, `CustomTitleFile`, `HookEvent{session_id, transcript_path, agent_transcript_path?, hook_event_name}` |

- **`TaskNotification`:** a tag scan for `task-id, tool-use-id, status, summary`, the first line of `result`
  (at most 200 chars), `duration_ms` and `subagent_tokens`. It is ignored without `tool-use-id`
  (Bash/Monitor `b…` tasks), and `<usage>` may be absent on failures.
- **Tool summaries** (120 chars max): Bash `description ?? command`, file tools the last 2 path components,
  Grep/Glob `pattern`, WebFetch the host and path, WebSearch `query`, Agent `description`.
- **Output** is `TranscriptEvent`, a small Sendable enum.

## 6. Session state and reducer

```
SessionState  id, projectPath (first cwd | latest relocatedCwd), gitBranch (latest)
              title {custom?, ai?, firstPrompt? (one line, ≤120 chars)}, startedAt (min ts), lastActivityAt (max ts)
              lastGrowthAt (local clock), closed (cost-state seen, no activity line after it; file order)
              main: RunState, runs: [runID: RunState], order: [runID]
              agentToRun: [agentId: runID]  pendingLinks: [agentId: toolUseId]  orphans: [agentId: RunState]
RunState      id, parentRunID, depth, agentID?, agentType, description, prompt (≤32 KB), isBackground, isFork
              transcriptModel?, resolvedModel?, callModel?, metaModel?
              status, startedAt, endedAt?, lastActivityAt, exactDurationMs?, decidedBy (.exact | .fallback)
              phase (.midTurn | .ended(.normal | .interrupted | .error)), lastWasSyntheticError
              openTools [toolUseID → index], interactivePending Set<toolUseID> (AskUserQuestion, ExitPlanMode)
              recentTools (ring, 20), toolCallCount, currentActivity, usageByMessage [msgID: TokenUsage] + total,
              exactUsage?, resultSummary?, frozenEstimate?
```

**R** is the run that owns the file: the main file maps to the main run, and `agent-<aid>.jsonl` maps to the
run linked to `aid` (else to `orphans[aid]`). Lines are folded in file order and timestamps with `max()`.

| Line | Condition | State change |
|---|---|---|
| user / assistant / system | always | `lastActivityAt` = max(ts) on R and session; `startedAt` = min; first cwd → projectPath; gitBranch; `closed = false`; a `.queued` R becomes running |
| assistant | `model` ≠ `<synthetic>` | `R.transcriptModel = model` |
| assistant | `usage` and `message.id` | `R.usageByMessage[id] = usage` (last line per id wins; total adjusted) |
| assistant | `tool_use` (any) | `toolCallCount += 1`; append `ToolEvent(id, name, summary, ts)`; `openTools`; `currentActivity`; `phase = .midTurn` |
| assistant | `tool_use` `Agent`/`Task` | new run `id = tool_use.id`, parent R, `depth = R.depth + 1`, `type = subagent_type ?? "general-purpose"`, description, prompt, `callModel = input.model`, `isBackground = run_in_background ?? false`, `.queued`, startedAt = ts; apply `pendingLinks`/`orphans` |
| assistant | `AskUserQuestion` / `ExitPlanMode` | `interactivePending.insert(id)` |
| assistant | main file, `stop_reason == "end_turn"` | `phase = .ended(.normal)` (provisional; later lines reopen). Subagent `stop_reason` is unreliable and not used here |
| assistant | `isApiErrorMessage` or model `<synthetic>` | `lastWasSyntheticError = true`; `phase = .ended(.error)`; subagent run fails (fallback) |
| user | human prompt (string/text, `!isMeta`, origin human or absent, not an interrupt, `!isCompactSummary`) | main: `firstPrompt ??= trim`, `prompt = text`, `phase = .midTurn`, clear `lastWasSyntheticError`. Subagent file: `R.prompt` if empty |
| user | `tool_result` blocks | close `openTools[id]` (endedAt, isError); remove from `interactivePending`; `phase = .midTurn`; Agent ids continue below |
| user | Agent result `async_launched` | link `agentId`; `resolvedModel`; `isBackground = true`; running |
| user | Agent result `completed` | link; `resolvedModel`; `exactDurationMs = totalDurationMs`; `exactUsage = usage`; `resultSummary` = first line of content; done; `endedAt = startedAt + duration` |
| user | Agent result `is_error` | failed; `endedAt = ts`; `resultSummary` = first line of the error string |
| user | `[Request interrupted by user…]` | `R.phase = .ended(.interrupted)`; close `openTools`; R's foreground children without a result become cancelled |
| user / queued_command / queue-operation enqueue | `<task-notification>` with `tool-use-id` of a known Agent run (any file, so nesting works) | link task-id with tool-use-id; completed → done, failed → failed; `exactDurationMs = duration_ms`; `endedAt = startedAt + duration` (else ts); `resultSummary`. **Idempotent**: the same notice arrives up to 3 times |
| user | origin `peer` handback or `task-notification` | main `phase = .midTurn` (main agent will respond) |
| user | `isMeta`, `isCompactSummary`, origin `coordinator` | activity only |
| system | `turn_duration`, `stop_hook_summary` | `R.phase = .ended(.normal)`; clear `openTools` |
| system | `api_error` (retry), `compact_boundary`, other | activity only |
| `custom-title` line, `custom-title.json` / `ai-title` / `relocated` / `cost-state` | | `title.custom` / `title.ai` / `projectPath = relocatedCwd` / `closed = true` |
| `fork-context-ref` | | `R.isFork = true` |
| meta.json | | `toolUseId` → `link(aid, toolUseId)`; `metaModel` unless `"inherit"`; fill agentType/description; no `toolUseId` → child of main, id `agent:<aid>` |
| subagent file | `SubagentHandback` result with `toolEndsTurn`, or end_turn text | fallback done (`endedAt = ts`), unless already decided by an exact signal |
| subagent file | any line while R is finished | resumed: running, `endedAt = nil` |

- **Linking:** `link(agentId, toolUseId)` is called from meta, tool results and notifications. Once both the
  link and the run exist, any orphan is merged in. An orphan with no link 5 s after its first line is shown as
  an `agent:<aid>` child of main. If a link arrives later, that row is removed and its state merged into the
  Agent run.
- **Exact signals win:** exact signals override fallback ones. Fallback duration = the run's last own line ts
  minus its first.
- **When a run finishes:** freeze its estimate, add an estimator sample (done runs only), and enqueue a
  `run_duration` upsert. A `run_duration` row is also enqueued when the Agent call is first seen
  (`outcome NULL`), so a scan can resume mid-file.
- **When a task reaches done/failed:** enqueue a history upsert.

## 7. Status derivation (`StatusRules`, pure)

`taskStatus(session, pid, now) -> (TaskStatus, nextDeadline: Date?)`. Two inputs:
- `alive` = a pid file is present **and** `probe.isAlive`.
- `quiet = now − max(lastActivityAt, lastGrowthAt)`. Taking the max with local time guards against clock skew.

First, run overrides: an unfinished run becomes **cancelled** if `closed`, or if `!alive && quiet ≥ 120 s`.
Then the first matching rule wins:

| Status | Rule |
|---|---|
| failed | `main.lastWasSyntheticError` (nothing after it) |
| waiting | `alive && pid.status == "waiting"`; or `main.interactivePending` non-empty `&& !closed && (alive \|\| quiet < 120 s)` |
| running | `alive && pid.status == "busy"`; or `!alive && main.phase == .midTurn && quiet < 120 s`; or any subagent running |
| idle | `alive` |
| done | `closed`, or `!alive && quiet ≥ 120 s` |
| idle (transient) | otherwise (no process, turn ended, quiet < 120 s); it becomes done at the deadline |

- **Main run status:** running/waiting → `.running`, idle/done → `.done`, failed → `.failed`.
- **Task `endedAt`:** set to `lastActivityAt` on entering done/failed, and cleared on leaving.
- **Time-based transitions:** each derivation returns its next deadline: `lastActivity + 120 s` for the quiet
  rules, and `endedAt + historyWindow` for window expiry (which emits `removed`). The engine keeps **one**
  timer sleeping on `clock` until the earliest deadline. When it fires, only the expired sessions are
  re-derived. No deadlines means no timer. Pid-file changes and process-exit sources re-derive at once.

## 8. Model resolution (`ModelResolver`, data-sources §4)

First hit wins:
1. `transcriptModel` (latest non-`<synthetic>` `message.model` in R's own file) → `.transcript`
2. `resolvedModel` → `.transcript`
3. `callModel`, else `metaModel` unless `"inherit"` → `.callParameter`
4. frontmatter `model:` other than `inherit`, from `<projectPath>/.claude/agents` then `<dataRoot>/agents` (project wins, per the Claude Code docs) → `.definition`
5. `ModelInfo(id: nil, source: .inherited)`

The main run uses step 1, else 5. `AgentDefinitions` caches `[name: model?]` per directory, parsed from the
`---` frontmatter block (`name:` else the filename stem; `model:` unquoted).
- `<dataRoot>/agents` is invalidated by FSEvents.
- Project directories are revalidated on lookup when the cache entry is older than 30 s (list the directory and compare mtimes).
- A change re-dirties the sessions that used step 4.

Resolution runs in `SnapshotBuilder`.

## 9. Estimator

**Samples** are `(agentType, family, seconds, endedAt)` from runs that finished **done**.
- Duration: `exactDurationMs` (`totalDurationMs` / `<duration_ms>`), else the fallback timestamps.
- Family: from the resolved model, or the main model's family when inherited.
- In memory: the newest 50 per type and per (type, family), loaded from `run_duration` at start, appended live
  as runs finish, and in batches from the scanner.

```
estimate(type, family):
  b = bucket(type, family) if family != .other and bucket(type, family).count >= 5, else bucket(type)
  n = b.count;  confidence = EstimateConfidence(sampleCount: n)       // high ≥ 10, medium 3–9, low < 3
  d = default[type]                     // Explore 60, Plan 120, general-purpose 180, others 150
  seconds = n >= 3 ? median(b)          // even count: mean of the two middle values
          : n == 0 ? d
          : (sum(b) + d) / (n + 1)      // 1–2 samples: the default counts as one extra sample
  return DurationEstimate(seconds, confidence, sampleCount: n)          // low renders with "~"
```

- With 1–2 samples the blend keeps one unusual run from taking over the estimate, while real data still moves
  it away from the generic default (one 120 s Explore run gives (120 + 60) / 2 = 90 s). Confidence stays low.

- Estimates are memoized per key. A new sample invalidates the key and re-dirties sessions with running runs
  of that type.
- Main runs have no estimate. Finished runs keep `frozenEstimate`.
- Task ETA is the existing `TaskSnapshot.eta` (latest `expectedEnd` of running subagents).

## 10. Update flow and initial load

```
FSChange ─► engine.handle ─► readNewBytes ─► LineParser ─► SessionReducer ─► coalescer.markDirty(sid)
                                                    (first mark schedules flush in 16 ms on `clock`)
flush:  for sid in dirty: s = SnapshotBuilder.build(sid); if s != lastEmitted[sid] { changed.append(s) }
        switch continuation.yield(DeckUpdate(changed, removed, initialLoadComplete: loaded))
          .enqueued   → lastEmitted ← changed; clear dirty + removed
          .dropped    → keep dirty + removed; reschedule in 16 ms        // UI hasn't taken the last batch
          .terminated → stop()
```

- **Stream policy:** `AsyncStream(bufferingPolicy: .bufferingOldest(1))`.
- **Backpressure:** at most one batch waits. While the main actor is busy, the next yield is rejected. The
  rejected batch is not lost, because the **dirty set (bounded by the task count) is the source of truth, not
  the batch**. The UI then gets one merged batch with the latest snapshot of every changed task, and memory
  stays at two batches or fewer.
- **Termination:** `onTermination` (consumer cancelled) calls `stop()`.
- **Cost:** only dirty tasks are rebuilt; a rebuild is O(runs + 20 tools/run) with copy-on-write strings.
  Even 20 x 15 dirty in one frame is about 300 struct copies plus equality checks, under 1 ms.
- **Idle:** nothing is emitted for time passing. The UI computes elapsed time and progress, so idle means no batches.

**Cold launch.** The window is up immediately and `DeckStore` fills progressively.

| # | Step | Expected time |
|---|---|---|
| 1 | `updates()` returns the stream at once; the engine starts in a task | 0 |
| 2 | `HistoryStore.shared(at:)` opens and migrates; read estimator samples and window history rows | 10–20 ms |
| 3 | Start FSEvents (since now) so nothing is missed during load; events queue in the engine | 1 ms |
| 4 | Read `sessions/*.json` → pid table, liveness, exit sources | 1 ms |
| 5 | List `projects/*/` one level: size, mtime, fileID per `.jsonl` | ~5 ms |
| 6 | **Tier 1:** live-pid sessions first, then mtime within `recentWindow`, newest first. Per session: main → metas → subagents → custom-title, then `Task.yield()`; each is emitted as it completes | first card 50–200 ms |
| 7 | **Tier 2:** other sessions with mtime within historyWindow. If `history_task` matches the main file's (fileID, size, mtime), emit the stored snapshot (no parse, no reducer state); else parse. Also emit DB-only finished tasks in the window. Then `initialLoadComplete = true` | 0.1–0.5 s |
| 8 | **Tier 3:** `EstimateScanner` (background QoS) | first launch 1–2 s CPU; later only changed files |

**Tier 3 detail.** The scanner visits every main transcript whose `scan_cache` row doesn't match.
- It reads from `offset` when the fileID is unchanged and `size ≥ offset`, else from 0.
- It reuses `LineParser` with a ~10-line duration reducer: Agent calls, Agent results and notifications. It
  never reads subagent files, because `resolvedModel` is on the parent's result. Context from earlier bytes
  comes from `run_duration` rows.
- It upserts `run_duration` in batches of 200, updates `scan_cache`, and hands the samples to the engine.

**Later launches.** The engine also upserts `scan_cache` for the main files it has read, so the next scan
skips them. A stored snapshot whose transcript later grows (a resumed session) is re-parsed from 0. That is
rare, and it is the only full re-read outside resets.

## 11. History store (GRDB)

`~/Library/Application Support/AgentDeck/agentdeck.sqlite`, opened as a `DatabasePool` (WAL).
`HistoryStore.shared(at:)` keeps one store per file per process, so the old and new sources don't contend
during a switch. The mock never opens it. Migration `v1`:

```sql
CREATE TABLE run_duration (                      -- estimator samples; one row per Agent call
  tool_use_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, agent_type TEXT NOT NULL,
  model_family TEXT NOT NULL DEFAULT 'other', started_at DOUBLE NOT NULL, ended_at DOUBLE,
  duration_ms INTEGER, is_exact BOOLEAN NOT NULL DEFAULT 0,
  outcome TEXT);                                 -- completed | failed | cancelled | NULL (unfinished)
CREATE INDEX run_duration_estimator ON run_duration(agent_type, ended_at DESC) WHERE outcome = 'completed';

CREATE TABLE history_task (                      -- finished tasks (done/failed)
  id TEXT PRIMARY KEY, status TEXT NOT NULL, project_name TEXT NOT NULL,
  started_at DOUBLE NOT NULL, ended_at DOUBLE NOT NULL, transcript_path TEXT NOT NULL,
  file_id INTEGER NOT NULL, file_size INTEGER NOT NULL, file_mtime DOUBLE NOT NULL,
  snapshot BLOB NOT NULL);                       -- JSON TaskSnapshot with runs = []
CREATE INDEX history_task_ended ON history_task(ended_at DESC);

CREATE TABLE history_run (
  task_id TEXT NOT NULL REFERENCES history_task(id) ON DELETE CASCADE,
  id TEXT NOT NULL, ord INTEGER NOT NULL, agent_type TEXT NOT NULL, status TEXT NOT NULL,
  snapshot BLOB NOT NULL,                        -- JSON AgentRunSnapshot (recentTools ≤ 20)
  PRIMARY KEY (task_id, id));

CREATE TABLE scan_cache (                        -- estimate-scan progress per main transcript
  path TEXT PRIMARY KEY, session_id TEXT NOT NULL, file_id INTEGER NOT NULL,
  size INTEGER NOT NULL, mtime DOUBLE NOT NULL, offset INTEGER NOT NULL);
```

- **Columns vs blobs:** columns hold only what we query, sort or prune by. The rest is the existing Codable
  snapshot, so additive snapshot fields need no migration (new fields must be optional). A row that fails to
  decode is ignored and rebuilt from the transcript if it still exists.
- **Migrations:** `DatabaseMigrator` with append-only named migrations (`v1`, `v2`, …). Shipped migrations
  are never edited. `eraseDatabaseOnSchemaChange` is DEBUG only.
- **Corruption** (`SQLITE_CORRUPT` / `SQLITE_NOTADB` on open): rename the file and its `-wal`/`-shm` to
  `agentdeck.sqlite.broken-<yyyyMMdd-HHmmss>` and recreate it. Other open failures leave the file untouched
  and use an in-memory `DatabaseQueue` with `health = .degraded`; the next launch tries the file again. That
  covers busy, permissions, can't open, and a failed migration. A failed recreate falls back the same way.
- **Writes:** `enqueue(op)` is synchronous and just appends under a `Mutex`. A single drain task writes the
  whole buffer in one `dbPool.write` transaction every 1 s when non-empty, and on `stop()`. Upserts use
  `ON CONFLICT DO UPDATE` with `COALESCE`, so a call row and its later result merge.
  - Snapshot JSON is encoded before the transaction opens; an op that can't be encoded is dropped.
  - The batch runs in one `BEGIN IMMEDIATE` transaction with a savepoint per op, so a flush waits at most
    one busy timeout (2 s).
  - An op-specific error (constraint, too big, type mismatch) rolls back and drops only that op.
  - A database-wide error (busy, full, I/O) puts the batch back at the front of the buffer for the next
    tick. The buffer is capped at 5,000 ops, and the oldest are dropped first.
- **Prune:** at launch and hourly.
  - `history_task` with `ended_at < now − max(historyWindow, 7 d)` (cascades to runs; the floor stops a brief window shrink from deleting data).
  - `run_duration` older than 180 d.
  - `scan_cache` rows for missing files.

## 11a. Internal API contract: estimator and history store

Built in parallel with the engine, so this interface is fixed (internal to the package unless noted):

```swift
// Estimation/Estimator.swift
struct DurationSample: Sendable, Hashable { var agentType: String; var family: ModelFamily; var seconds: Double; var endedAt: Date }
struct Estimator: Sendable {
    static let builtInDefaults: [String: Double]          // Explore 60, Plan 120, general-purpose 180
    static let fallbackDefault: Double                    // 150
    init(samples: [DurationSample] = [])
    mutating func add(_ sample: DurationSample)           // keeps the newest 50 per type and per (type, family)
    mutating func add(contentsOf samples: [DurationSample])
    func estimate(agentType: String, family: ModelFamily) -> DurationEstimate   // §9 rules
    private(set) var version: Int                         // bumps on every add (cheap change detection)
}

// Persistence/HistoryStore.swift
final class HistoryStore: Sendable {
    static func shared(at url: URL) -> HistoryStore       // one per file per process; falls back to in-memory + health
    static func inMemory() -> HistoryStore
    var health: SourceHealth { get }                      // .ok, or .degraded("…") after an open failure
    func loadSamples(perTypeLimit: Int) async -> [DurationSample]      // outcome == completed, newest first: the newest N
                                                                       // per type and per (type, family ≠ other)
    func loadHistory(endedAfter: Date) async -> [StoredTask]           // tasks with runs, newest first
    func loadScanCache() async -> [String: ScanCacheEntry]             // keyed by path
    func enqueue(_ op: HistoryOp)                                      // synchronous, never blocks on I/O
    func flush() async                                                 // write the buffer now (also every 1 s)
    func prune(historyWindow: TimeInterval, now: Date) async           // §11 rules
    func close() async                                                 // flush and stop the drain task
}
enum HistoryOp: Sendable {
    case runDuration(RunDurationRow)       // upsert, COALESCE-merging a call row with its later result
    case finishedTask(StoredTask)          // upsert task row and replace its run rows
    case removeTask(id: String)
    case scanCache(ScanCacheEntry)
}
struct RunDurationRow: Sendable, Hashable {
    var toolUseID: String; var sessionID: String; var agentType: String; var modelFamily: ModelFamily
    var startedAt: Date; var endedAt: Date?; var durationMs: Int?; var isExact: Bool
    var outcome: String?                    // "completed" | "failed" | "cancelled" | nil while unfinished
}
struct StoredTask: Sendable, Hashable {
    var snapshot: TaskSnapshot              // with runs (recentTools trimmed to 20)
    var transcriptPath: String; var fileID: UInt64; var fileSize: Int64; var fileMtime: Date
}
struct ScanCacheEntry: Sendable, Hashable {
    var path: String; var sessionID: String; var fileID: UInt64; var size: Int64; var mtime: Date; var offset: Int64
}
// Support/FileID.swift (owned by the engine side): fileID = UInt64(st_ino) ^ (UInt64(st_dev) << 48)
// SourceHealth lives in Source/AgentSource.swift: public enum SourceHealth: Sendable, Hashable { case ok, degraded(String) }
```

The estimator expects de-duplicated samples. The engine adds at most one sample per Agent `tool_use` id,
because live runs and scanner batches can report the same run.

## 12. Optional hooks

If `<dataRoot>/agentdeck/events.jsonl` exists, the engine tails it like a transcript, starting at its end on
first sight. It is checked at start, by FSEvents on `agentdeck/`, and by the sweep.
- Each line is decoded as a `HookEvent`.
- Its `transcript_path` and `agent_transcript_path` are standardized and symlinks resolved. If they resolve
  inside `<dataRoot>/projects/`, `readNewBytes` runs at once (registering the file if new). Any other path is ignored.
- AgentDeck never writes under `dataRoot`.

## 13. Mock simulator

`MockSimulator` (actor, in `Mock/MockAgentSource.swift`; the world itself is `Mock/MockWorld.swift`):
- **Determinism:** seeded SplitMix64 (`Mock/SeededRandom.swift`); tests step `MockWorld.advance(to:)` directly and
  can run faster than real time (`speed`).
- **Loop (as built):** one task sleeps until the next scheduled event in `MockEventQueue` (tool call, launch,
  finish…), handles everything due within 10 ms, and sleeps again; nothing runs between events.
- **Batching (as built):** pull-based `AsyncStream(unfolding:)` rather than the shared `UpdateCoalescer`: when the
  consumer asks, it waits until something changed and ≥ 16 ms passed since the last batch, then snapshots only the
  dirty tasks. A slow consumer gets one merged batch, never a backlog.
- **Isolation:** source `"mock"`, no disk, no DB; simulated tasks never post notifications (app side).
- **Estimates:** synthetic per-type estimates with every confidence level represented (high, medium, and low with "~").
- **Time scale:** durations are scaled down (demo 0.2×, stress 0.5×) so a demo task finishes in 1–4 minutes.

**Each task:**
- 4 project names. The main agent emits tool events every 1–4 s (Read/Grep/Bash/Edit/WebFetch with canned summaries).
- **Fan-out:** after 5–20 s it starts 5–15 Agent calls staggered 0.2–1.5 s apart.
  - 70 % run in the background.
  - Types: Explore 35 %, general-purpose 25 %, Plan 10 %, custom 30 %.
  - Models are mostly inherited, plus some `sonnet`/`haiku` call parameters.
- **Durations and outcomes:**
  - Each run's target duration is lognormal around its type's estimate (σ ≈ 0.5, so about 30 % overrun).
  - Tool events every 1–5 s.
  - 8 % fail midway ("Agent terminated early due to an API error") and 3 % are cancelled.
  - 15 % spawn 1–3 nested runs (depth 2, rarely 3).
- 20 % of tasks pass through `waiting` for 10–30 s.
- When all runs finish, main summarizes for 3–10 s, goes idle, and is done 60 s later.

**Scenarios:**
- **demo:** starts with 2 running, 1 waiting, 1 idle and ~8 finished tasks in the last 24 h. A new task
  arrives every 20–60 s, with at most 8 concurrent.
- **stress:** 20 concurrent tasks x 15 subagents (300 runs) from t=0, with tool events every 0.5–2 s per run
  (~300 events/s). Finished tasks are replaced to hold the load.

## 14. Performance budget

| Budget | How |
|---|---|
| Memory < 150 MB | No raw lines kept (chunk buffers ≤ 1 MB). Tool inputs become ≤ 120-char summaries at parse time; tool outputs are never decoded. Agent prompts (needed by the inspector) and the latest human prompt are capped at 32 KB; the first prompt is kept only as a 120-char title. `recentTools` is a ring of 20. Usage map ≈ 100 B per message. Estimate: 300 runs x ~30 KB ≈ 9 MB, plus window history and `lastEmitted` (shared storage), for 30–50 MB total |
| Idle CPU < 1 % | FSEvents wakes only on writes; one 60 s stat sweep; a single deadline timer; process exits via dispatch sources; no batches |
| Live CPU | Only new bytes are read; about 40 % of lines (attachments and metadata) are dropped before decoding; at most 60 batches/s, each covering dirty tasks only |

## 15. Testing seams

- **Parser:** feed fixture lines (`Data`) to `LineScanner`/`LineParser`. Cover attachment-before-type and
  message-before-type key orders, whitespace, unknown types, and notifications without `<usage>`.
- **Pure core:** `SessionReducer`, `StatusRules`, `ModelResolver`, `Estimator` and `SnapshotBuilder` are pure.
  Golden tests on the fixtures:
  - `f275c38e…`: 11 meta-linked subagents; `a28854a40750f97c0` failed via notification; `localbiz-*` definitions.
  - `bd324a5f…`: fork without `toolUseId` → `agent:` child.
  - `08cb7b8e…`: foreground `totalDurationMs`.
  - `sessions/3156.json`: `waiting`.
- **Engine without FSEvents:** build
  `CoreEnvironment(clock: TestClock(), probe: FakeProbe(alive: [3156]), history: .inMemory(), watchFileSystem: false)`
  with `dataRoot` = a temp copy of `Fixtures/`. Drive it with `loadInitial()` / `handle([FSChange])` and assert
  on `snapshot(id)` or the collected stream.
- **Incremental reads:**
  - Append a fixture to a temp file in random chunks (splitting lines and UTF-8 sequences), handling after each
    chunk. The final snapshot must equal the one-shot parse.
  - Truncate the file, replace it (new inode), and move it to another project directory; expect a reset or a rebind as specified.
- **Time:** `TestClock` (`advance(by:)` resumes sleepers).
  - No pid file and mid-turn: running → +121 s → done.
  - The coalescer emits at most 1 batch per 16 ms of test time and none when idle.
  - The window expiry emits `removed`.
- **Store:** `HistoryStore` on an in-memory `DatabaseQueue`: migrations, upsert merge, prune, snapshot round-trip.
- **Estimator:** edge tables for 4 vs 5 family samples, the 2/3/9/10 confidence boundaries, and the defaults.
- **Mock stress:** 60 s of `TestClock` time with 300 runs; at most 60 batches/s; snapshot build p99 < 2 ms;
  deterministic for a fixed seed.

## 16. Risks and edge cases

1. **Agent-definition precedence.** Decided: project agents override user agents, as the Claude Code docs
   specify (data-sources §4 updated). No project has `.claude/agents` today.
2. **Format drift.** Unknown types are skipped. The only key-order assumption is "a decisive key within
   4 KB", and the fallback is a full decode. The `version` field is logged on the first decode failure per file.
3. **Repeated notifications.** A notice can arrive 3 times, and again after a `SendMessage` resume. Applying
   is idempotent. A resumed run keeps its original `startedAt`, so its elapsed time includes the gap, and the
   new duration overwrites its sample.
4. **Token undercount.** Background subagent `output_tokens` are undercounted in 2.1.284+. Only foreground
   runs have exact usage.
5. **Liveness.** Pid reuse is handled by the `procStart` check. Sessions with no pid file depend on the
   2-minute quiet rule, so their done status can lag by up to 2 min.
6. **Relocation races** and duplicate session files: handled by the 2 s removal grace and newest-mtime-wins.
   A meta file read mid-write fails to decode and is retried on the next event or sweep.
7. **Unparsed lines.** Lines over 64 MB are skipped. A line that never gets its newline (a crash) is never parsed.
8. **Scale.** If roots grow far beyond 1 GB, tier 2 can be parallelized with a `TaskGroup` of nonisolated
   parse calls. That isn't needed at today's ~100 MB.

## 17. Implementation order

| # | Task | Size |
|---|---|---|
| 1 | Clock, probe, timestamp; `LineScanner`/`LineModels`/`LineParser`/`TaskNotification`, plus tests | M |
| 2 | `SessionState`, `SessionReducer`, `StatusRules`, `ModelResolver`, `AgentDefinitions`, `SnapshotBuilder`, plus fixture golden tests | L |
| 3 | `PathClassifier`, `FileTracker`, engine with `handle`/`loadInitial` (no FSEvents), plus incremental/reset tests | M |
| 4 | `UpdateCoalescer`, `ClaudeCodeSource` facade, stream/stop | S |
| 5 | `FSEventsWatcher`, `Sweeper`, exit sources | M |
| 6 | `Estimator`, `HistoryStore`/`Schema`/`Records`, `EstimateScanner`, tiered `InitialLoader` | L |
| 7 | `MockSimulator` (demo + stress), plus budget tests | M |
| 8 | Hook tail | S |
