#!/usr/bin/env bash
# Compares two run.sh output directories and prints summary counts.
# Usage: compare.sh <out-a> <out-b>
A=$1; B=$2
echo "result files: $(ls $A/res | wc -l) vs $(ls $B/res | wc -l)"
echo "differing files: $(diff -rq $A/res $B/res | wc -l)"
diff -rq $A/res $B/res | head -50
echo "jobs: $(wc -l < ${JOBS:-jobs.txt}) ($(awk '{print $1}' ${JOBS:-jobs.txt} | sort | uniq -c | tr '\n' ' '))"
echo "compilations whose typing succeeded (exit 0): $(grep -lx 0 $A/res/*.exit | grep -v '\.ir\.exit' | wc -l) / $(ls $A/res/*.exit | grep -v '\.ir\.exit' | wc -l)"
echo "raw-ir runs: $(ls $A/res/*.ir.exit 2>/dev/null | wc -l), of which succeeded: $(grep -lx 0 $A/res/*.ir.exit | wc -l)"
echo "dumped typed nodes: $(cat $A/res/*.ast | grep -c ': ')"
echo "dumped name references: $(cat $A/res/*.ast | grep -c ' -> ')"
echo "diagnostic lines: $(cat $A/res/*.errn | grep -c 'error:\|warning:')"
