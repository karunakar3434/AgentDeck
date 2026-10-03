#!/usr/bin/env python3
"""Summarize an xctrace Time Profiler export.

Usage:
  xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > X.xml
  python3 scripts/tp-summary.py X.xml [process-name] [top-n]

Prints CPU time per thread, the hottest leaf functions (self time), the hottest
inclusive functions, and the app's own frames (AgentDeck / AgentDeckCore) by inclusive time.
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

path = sys.argv[1]
proc = sys.argv[2] if len(sys.argv) > 2 else "AgentDeck"
top = int(sys.argv[3]) if len(sys.argv) > 3 else 25
# Optional time windows in seconds: "21.6-24.4,31.0-34.7"
windows = []
if len(sys.argv) > 4:
    for w in sys.argv[4].split(","):
        a, b = w.split("-")
        windows.append((float(a) * 1e9, float(b) * 1e9))

ids = {}           # id -> element (for ref resolution)
frame_name = {}    # frame id -> (name, binary)
binary_name = {}

def resolve(el):
    ref = el.get("ref")
    return ids[ref] if ref is not None else el

thread_w = Counter()
self_w = Counter()
incl_w = Counter()
app_incl = Counter()
total = 0

for event, el in ET.iterparse(path, events=("end",)):
    if el.get("id") is not None:
        ids[el.get("id")] = el
    if el.tag != "row":
        continue
    if windows:
        t_el = resolve(el.find("sample-time"))
        t = int(t_el.text or 0)
        if not any(a <= t <= b for a, b in windows):
            el.clear(); continue
    thread = resolve(el.find("thread"))
    tname = thread.get("fmt", "?")
    if proc not in tname:
        el.clear(); continue
    w_el = resolve(el.find("weight"))
    w = int(w_el.text or 0) / 1e6  # ms
    bt = el.find("tagged-backtrace")
    if bt is None:
        bt = el.find("backtrace")
    frames = []
    if bt is not None:
        bt = resolve(bt)
        for f in bt.findall("frame"):
            f = resolve(f)
            name = f.get("name") or f.get("addr") or "?"
            b = f.find("binary")
            bname = resolve(b).get("name") if b is not None else ""
            frames.append((name, bname))
    total += w
    short = tname.split(" (")[0]
    thread_w[short] += w
    if frames:
        self_w[f"{frames[0][0]}  [{frames[0][1]}]"] += w
        seen = set()
        for name, bname in frames:
            key = f"{name}  [{bname}]"
            if key in seen:
                continue
            seen.add(key)
            incl_w[key] += w
            if bname in ("AgentDeck", "AgentDeckCore", "AgentDeck.debug.dylib"):
                app_incl[name] += w
    el.clear()

print(f"total sampled CPU: {total:.0f} ms")
print("\n== threads ==")
for k, v in thread_w.most_common(12):
    print(f"{v:9.0f} ms  {v/total*100:5.1f}%  {k}")
print(f"\n== self (leaf) top {top} ==")
for k, v in self_w.most_common(top):
    print(f"{v:9.0f} ms  {v/total*100:5.1f}%  {k[:150]}")
print(f"\n== inclusive top {top} ==")
for k, v in incl_w.most_common(top):
    print(f"{v:9.0f} ms  {v/total*100:5.1f}%  {k[:150]}")
print(f"\n== app frames (inclusive) top {top} ==")
for k, v in app_incl.most_common(top):
    print(f"{v:9.0f} ms  {v/total*100:5.1f}%  {k[:150]}")
