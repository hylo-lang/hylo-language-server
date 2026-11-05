#!/usr/bin/env bash
# Summarizes a `swift test` log: XCTest totals per bundle and swift-testing totals.
L=$1
echo "XCTest: $(grep -A1 "Test Suite 'All tests'" "$L" | grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures' | awk '{t+=$2; f+=$5} END {print t" tests, "f" failures"}')"
echo "swift-testing: $(grep -oE 'Test run with [0-9]+ tests' "$L" | awk '{t+=$4} END {print t" tests"}'), failed runs: $(grep -c 'Test run with .* failed' "$L")"
grep -c "error:" "$L" | sed 's/^/error lines: /'
