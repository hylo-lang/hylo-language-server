#!/usr/bin/env python3 -I
"""Applies each mutation to the hn-argtypes tree, runs ArgumentTypeTests, and restores the file."""
import subprocess, sys, re
W='/home/hylo/wt/hn-argtypes'
S=W+'/Sources/FrontEnd/Typer/'
M=[
 ('M1 no merge of fork solutions', S+'Solver.swift',
  'if let ss = fork.solutionsWithoutError { me.solutionsWithoutError!.append(contentsOf: ss) }', ''),
 ('M2 collect erroneous leaves', S+'Solver.swift',
  'if let t = s, !t.diagnostics.containsError {', 'if let t = s {'),
 ('M3 keep undetermined types', S+'Typer.swift',
  'if !u[.hasVariable] && !u[.hasError] &&', 'if !u[.hasError] &&'),
 ('M4 no hole', S+'Typer.swift',
  '        check(a.value)\n        t = fresh().erased',
  '        t = context.withSubcontext { (ctx) in inferredType(of: a.value, in: &ctx) }'),
 ('M5 best solution only', S+'Typer.swift',
  'for x in solver.solutionsWithoutError! where', 'for x in [s] where !s.diagnostics.containsError &&'),
 ('M6 no reset in fork', S+'Solver.swift',
  '    self.solutionsWithoutError = base.solutionsWithoutError.map({ (_) in [] })\n', ''),
 ('M7 keep error types', S+'Typer.swift',
  'if !u[.hasVariable] && !u[.hasError] &&', 'if !u[.hasVariable] &&'),
 ('M8 first leaf only', S+'Solver.swift',
  'if let t = s, !t.diagnostics.containsError { solutionsWithoutError?.append(t) }',
  'if let t = s, !t.diagnostics.containsError, solutionsWithoutError?.isEmpty ?? false { solutionsWithoutError?.append(t) }'),
 ('M9 argument not checked', S+'Typer.swift',
  '        check(a.value)\n        t = fresh().erased', '        t = fresh().erased'),
 ('M10 keep solutions failing inference at commit', S+'Typer.swift',
  '\n        where syntaxWithoutInferredType(in: o, by: x) == nil {', ' {'),
]
only=sys.argv[1:]
import os
FILTER=os.environ.get('FILTER','ArgumentTypeTests')
for name,f,a,b in M:
    if only and name.split()[0] not in only: continue
    src=open(f).read(); assert src.count(a)==1,(name,a)
    open(f,'w').write(src.replace(a,b))
    try:
        r=subprocess.run(['swift','build','-j','4','--build-tests'],cwd=W,capture_output=True,text=True)
        if r.returncode: print(name,': BUILD FAILED', [l for l in r.stdout.splitlines() if ' error:' in l][:3]); continue
        r=subprocess.run(['swift','test','-j','4','--skip-build','--filter',FILTER],cwd=W,capture_output=True,text=True)
        fails=sorted(set(re.findall(r'ArgumentTypeTests\.(\w+) : ', r.stdout)))
        print(name, ': killed by' if fails else ': SURVIVED', fails, flush=True)
    finally:
        open(f,'w').write(src)
