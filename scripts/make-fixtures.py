#!/usr/bin/env python3
"""Copy a few real Claude Code sessions into test fixtures, with private text removed.

Structure, ids, timestamps, models, tool names, statuses and token counts are kept.
Free text (prompts, tool inputs/outputs, titles, thinking) is replaced by a short,
deterministic token ("txt-1a2b3c4d") so that equal strings stay equal across files,
which keeps links such as "subagent's first prompt == Agent input.prompt" testable.

Usage: python3 scripts/make-fixtures.py <session-id> [<session-id> ...]
"""
import glob
import hashlib
import json
import os
import re
import sys

SRC = os.path.expanduser("~/.claude/projects")
DST = os.path.join(os.path.dirname(__file__), "..", "AgentDeckCore", "Tests", "AgentDeckCoreTests",
                   "Fixtures", "projects")
HOME = os.path.expanduser("~")

KEEP = {
    "type", "subtype", "uuid", "parentUuid", "logicalParentUuid", "sessionId", "session_id", "agentId",
    "timestamp", "model", "id", "tool_use_id", "stop_reason", "status", "version", "entrypoint",
    "userType", "requestId", "subagent_type", "operation", "agentType", "toolUseId", "requestShape",
    "resolvedModel", "error", "level", "commandMode", "kind", "promptSource", "turnOrigin", "messageId",
    "promptId", "sourceToolAssistantUUID", "sourceToolUseID", "leafUuid", "permissionMode", "mode",
    "effort", "perTurnEffort", "toolDenialKind", "from", "senderTaskId", "producer", "reason",
    "commandUuid", "deliveryId", "parentSessionId", "parentLastUuid", "service_tier", "speed",
    "role", "stop_sequence", "trigger", "source", "rateLimitType", "agentName",
}
PATH_KEYS = {"cwd", "relocatedCwd", "outputFile"}
DROP = {"wireToolInputs", "wireIngestContext", "serverClassifierContext", "serverClassifierRequest",
        "quotaLimits", "snapshot", "backup", "hookInfos", "compactMetadata", "toolStats",
        "handbackReport", "input_transformations", "diagnostics", "context_management", "iterations",
        "rendered", "addedLines", "trackedFileBackups", "imagePasteIds", "modelUsage", "usageLimitNote"}
TITLE_KEYS = {"customTitle", "aiTitle", "lastPrompt"}
INTERRUPTS = ("[Request interrupted by user for tool use]", "[Request interrupted by user]")


def tok(s, prefix="txt"):
    return f"{prefix}-{hashlib.sha1(s.encode()).hexdigest()[:8]}"


def path(p):
    if not isinstance(p, str):
        return p
    p = p.replace(HOME, "/Users/dev").replace(HOME.replace("/", "-"), "-Users-dev")
    return re.sub(r"/private/tmp/claude-\d+", "/private/tmp/claude-501", p)


def notification(s):
    """Keep a <task-notification>'s ids, status and usage; drop its free text."""
    def tag(name):
        m = re.search(rf"<{name}>(.*?)</{name}>", s, re.S)
        return m.group(1) if m else None
    status = tag("status") or "completed"
    parts = ["<task-notification>"]
    for name in ("task-id", "tool-use-id"):
        v = tag(name)
        if v is not None:
            parts.append(f"<{name}>{v}</{name}>")
    parts.append(f"<status>{status}</status>")
    summary = tag("summary") or ""
    kind = "Background command" if summary.startswith("Background command") else "Agent"
    verb = "failed: Agent terminated early due to an API error" if status == "failed" else "finished"
    parts.append(f'<summary>{kind} "{tok(summary)}" {verb}</summary>')
    parts.append("<result>…</result>")
    usage = tag("usage")
    if usage:
        parts.append(f"<usage>{usage}</usage>")
    parts.append("</task-notification>")
    return "\n".join(parts)


def text(s):
    if s in INTERRUPTS:
        return s
    if "<task-notification>" in s:
        return notification(s)
    if s.startswith("Error: Agent type"):
        m = re.match(r"Error: Agent type '([^']+)' not found", s)
        return f"Error: Agent type '{m.group(1) if m else 'x'}' not found. Available agents: general-purpose"
    if s.startswith("You've hit your"):
        return "You've hit your session limit · resets 9:20pm"
    if s.startswith("Another Claude session sent a message"):
        m = re.search(r'from="([^"]+)"', s)
        return f'Another Claude session sent a message:\n<agent-message from="{m.group(1) if m else ""}">…</agent-message>'
    if s.startswith("Async agent launched successfully"):
        m = re.search(r"agentId: (\S+)", s)
        return f"Async agent launched successfully.\nagentId: {m.group(1) if m else ''}"
    if not s:
        return s
    return tok(s)


def clean(v, key=None, parent=None):
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if k in DROP:
                continue
            if k == "thinking" or k == "signature":
                out[k] = ""
                continue
            if k == "input" and isinstance(x, dict):
                out[k] = tool_input(x, v.get("name"))
                continue
            out[k] = clean(x, k, v)
        return out
    if isinstance(v, list):
        return [clean(x, key, parent) for x in v]
    if isinstance(v, str):
        if key in KEEP:
            return path(v)
        if key == "name" and isinstance(parent, dict) and parent.get("type") == "tool_use":
            return v
        if key in PATH_KEYS:
            return path(v)
        if key == "gitBranch":
            return "main" if v not in ("HEAD", "") else v
        if key in TITLE_KEYS:
            return f"Title {tok(v, 't')}"
        if key in ("prompt", "content", "text", "body", "description", "message"):
            return text(v)
        return text(v)
    return v


def tool_input(inp, name):
    out = {}
    for k, x in inp.items():
        if name in ("Agent", "Task") and k in ("subagent_type", "model", "run_in_background", "isolation"):
            out[k] = x
        elif isinstance(x, (bool, int, float)) or x is None:
            out[k] = x
        elif isinstance(x, str):
            out[k] = text(x)
        else:
            out[k] = clean(x, k, inp)
    return out


def copy_jsonl(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    n = 0
    with open(src, errors="ignore") as f, open(dst, "w") as o:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") in ("file-history-snapshot", "file-history-delta", "bridge-session"):
                continue
            o.write(json.dumps(clean(d), ensure_ascii=False, separators=(",", ":")) + "\n")
            n += 1
    return n


def main(ids):
    for sid in ids:
        matches = glob.glob(os.path.join(SRC, "*", f"{sid}.jsonl"))
        if not matches:
            print(f"no session {sid}", file=sys.stderr)
            continue
        main_file = matches[0]
        proj = os.path.basename(os.path.dirname(main_file)).replace(
            HOME.replace("/", "-"), "-Users-dev")
        out_dir = os.path.join(DST, proj)
        n = copy_jsonl(main_file, os.path.join(out_dir, f"{sid}.jsonl"))
        print(f"{proj}/{sid}.jsonl: {n} lines")
        side = main_file[:-6]
        title = os.path.join(side, "custom-title.json")
        if os.path.exists(title):
            os.makedirs(os.path.join(out_dir, sid), exist_ok=True)
            t = json.load(open(title))
            json.dump({"customTitle": f"Title {tok(t.get('customTitle', ''), 't')}"},
                      open(os.path.join(out_dir, sid, "custom-title.json"), "w"))
        for sub in sorted(glob.glob(os.path.join(side, "subagents", "agent-*.jsonl"))):
            base = os.path.basename(sub)
            n = copy_jsonl(sub, os.path.join(out_dir, sid, "subagents", base))
            meta = sub[:-6] + ".meta.json"
            if os.path.exists(meta):
                m = json.load(open(meta))
                for k in ("description", "name"):
                    if k in m:
                        m[k] = text(m[k])
                json.dump(m, open(os.path.join(out_dir, sid, "subagents", os.path.basename(meta)), "w"))
            print(f"  subagents/{base}: {n} lines")


if __name__ == "__main__":
    main(sys.argv[1:])
