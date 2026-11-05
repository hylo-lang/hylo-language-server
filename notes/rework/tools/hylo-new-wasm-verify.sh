#!/bin/bash
cd /home/hylo/wt/hn-wasm
for c in 8b1fc9c 4037aa8 3acb4e7 0378b9e 1a965e7; do
  git checkout -q --detach $c
  git submodule update -q
  swift build --build-tests -j 4 > /home/hylo/wt/hn-wasm-logs/build-$c.log 2>&1 || { echo "$c BUILD FAIL"; continue; }
  swift test -j 4 --skip-build > /home/hylo/wt/hn-wasm-logs/test-$c.log 2>&1; rc=$?
  echo "$c rc=$rc failures=$(grep -c ' error: ' /home/hylo/wt/hn-wasm-logs/test-$c.log) $(grep -E "^Test Suite '.*\.xctest' (passed|failed)" -A1 /home/hylo/wt/hn-wasm-logs/test-$c.log | grep -oE 'Executed [0-9]+' | awk '{s+=$2} END {print "tests=" s}')"
done
git checkout -q wasm-foundation-essentials
