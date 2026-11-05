#!/usr/bin/env python3 -I
"""Classifies the differences between two run.sh outputs by the source text at their sites.

Usage: analyze-ext.py <out-a> <out-b>. For each differing line of each differing result file,
finds the source line its first site refers to and reports whether that line contains an
introducer-qualified name (`@let`, `@inout`, `@set`, `@sink`)."""
import os, re, sys, difflib, collections
A, B = sys.argv[1], sys.argv[2]
C = '/home/hylo/wt/difftest/corpus'
site = re.compile(r'^((?:random|Tests|extra|stdlib)/[^:]+\.hylo):(\d+)\.')
files = sorted(set(os.listdir(A + '/res')) | set(os.listdir(B + '/res')))
programs, kinds, stats = set(), collections.Counter(), collections.Counter()
offending = []
for f in files:
    pa, pb = f'{A}/res/{f}', f'{B}/res/{f}'
    la = open(pa).read().splitlines() if os.path.exists(pa) else []
    lb = open(pb).read().splitlines() if os.path.exists(pb) else []
    if la == lb: continue
    programs.add(re.sub(r'\.(lib|merged)?\.?(ast|errn|exit|ir\.exit|ir)$', '', f).rstrip('.'))
    for l in difflib.unified_diff(la, lb, lineterm='', n=0):
        if l.startswith(('---', '+++', '@@')): continue
        m = site.match(l[1:])
        if not m:
            stats['no-site'] += 1; continue
        src = open(os.path.join(C, m.group(1))).read().splitlines()[int(m.group(2)) - 1]
        if re.search(r'@(let|inout|set|sink)\b', src): stats['introducer'] += 1
        else:
            stats['other'] += 1; offending.append((f, l, src))
print('programs with differences:', len(programs))
for p in sorted(programs): print('  ', p)
print('differing lines by source:', dict(stats))
for o in offending[:40]: print('NOT INTRODUCER:', o)
