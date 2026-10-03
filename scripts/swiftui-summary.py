#!/usr/bin/env python3
"""Aggregate an exported `swiftui-updates` table: count and total time per view/description.
Usage: python3 scripts/swiftui-summary.py updates.xml [top-n] [module-filter]"""
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

path = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 30
module_filter = sys.argv[3] if len(sys.argv) > 3 else None
ids = {}
agg = defaultdict(lambda: [0, 0.0])
by_type = defaultdict(lambda: [0, 0.0])
cols = None

def val(el):
    if el is None:
        return None
    ref = el.get("ref")
    if ref is not None:
        el = ids.get(ref, el)
    return el

for ev, el in ET.iterparse(path, events=("end",)):
    if el.get("id") is not None:
        ids[el.get("id")] = el
    if el.tag != "row":
        continue
    children = list(el)
    # columns by position: start, duration, id, update-type, allocations, description, category, hierarchy, module, view-name, ...
    def fmt(i):
        if i >= len(children):
            return ""
        c = val(children[i])
        return (c.get("fmt") if c is not None and c.get("fmt") is not None else (c.text if c is not None else "")) or ""
    dur_el = val(children[1]) if len(children) > 1 else None
    dur = int(dur_el.text) / 1000.0 if dur_el is not None and dur_el.text and dur_el.text.isdigit() else 0.0  # µs
    utype, desc, module, view = fmt(3), fmt(5), fmt(8), fmt(9)
    if module_filter and module_filter not in module:
        el.clear(); continue
    key = f"{utype} | {view or desc} | {module}"
    agg[key][0] += 1; agg[key][1] += dur
    by_type[utype][0] += 1; by_type[utype][1] += dur
    el.clear()

print("== by update type ==")
for k, (n, d) in sorted(by_type.items(), key=lambda kv: -kv[1][1])[:15]:
    print(f"{n:8d}  {d/1000:8.1f} ms  {k}")
print(f"\n== top {top} by total time ==")
for k, (n, d) in sorted(agg.items(), key=lambda kv: -kv[1][1])[:top]:
    print(f"{n:8d}  {d/1000:8.1f} ms  {k[:160]}")
print(f"\n== top {top} by count ==")
for k, (n, d) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:top]:
    print(f"{n:8d}  {d/1000:8.1f} ms  {k[:160]}")
