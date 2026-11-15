#!/usr/bin/env python3
"""Update Docs/features.html: tools/set_status.py "feature text prefix" d|p|t ["note"]
or several at once from a file of lines: prefix | status | note."""
import re, sys, datetime, os
P = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Docs", "features.html")
s = open(P, encoding="utf-8").read()

def setone(prefix, st, note=None):
    global s
    pat = re.compile(r'\[("' + re.escape(prefix) + r'[^"]*"), "([dpt])", (\d+), "((?:[^"\\]|\\.)*)"\]')
    m = pat.search(s)
    if not m:
        print("NOT FOUND:", prefix); return
    n = m.group(4) if note is None else note.replace('"', '\\"')
    s = s[:m.start()] + '[%s, "%s", %s, "%s"]' % (m.group(1), st, m.group(3), n) + s[m.end():]

if len(sys.argv) == 2:
    for line in open(sys.argv[1], encoding="utf-8"):
        if not line.strip() or line.startswith("#"): continue
        parts = [x.strip() for x in line.split("|")]
        setone(parts[0], parts[1], parts[2] if len(parts) > 2 else None)
else:
    setone(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
s = re.sub(r'const UPDATED = "[^"]*";', 'const UPDATED = "%s";' % datetime.date.today().isoformat(), s)
open(P, "w", encoding="utf-8").write(s)
