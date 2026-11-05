#!/usr/bin/env bash
# Builds the corpus in /home/hylo/wt/difftest/corpus and the job list jobs.txt used by run.sh.
#
# Usage: jobs.sh <hylo-new tree for Tests/> <hc for the stdlib root> <dir of random programs>...
# CORPUS and JOBS override the corpus directory and the job list (default: corpus/, jobs.txt).
set -eu
SRC=$(realpath "$1"); HC=$(realpath "$2"); shift 2
D=/home/hylo/wt/difftest
C=${CORPUS:-$D/corpus}
rm -rf "$C"; mkdir -p "$C"
cd "$SRC" && find Tests \( -name '*.hylo' -o -name package.json \) -exec cp --parents {} "$C" \;
cp -r "$("$HC" --print-stdlib-root)" "$C/stdlib"
printf 'public fun main() {}\n' > "$C/warm.hylo"
# Extra single-file programs (e.g., tests added on branches) go under extra/.
mkdir -p "$C/extra"
cp "$D"/extra/*.hylo "$C/extra/" 2>/dev/null || true
mkdir -p "$C/random"
for r in "$@"; do cp -r "$D/$r"/* "$C/random/"; done

cd "$C"
{
  find Tests extra -name '*.hylo' -not -path '*.package/*' | sort | while read -r f; do
    if head -1 "$f" | grep -q '^//!.*no-std'; then echo "nostd $f"; else echo "std $f"; fi
  done
  find Tests -name '*.package' -type d | sort | while read -r p; do
    if grep -q 'no-std' "$p/package.json"; then echo "nostd $p"; else echo "std $p"; fi
  done
  echo "stdlib stdlib"
  find random -mindepth 1 -maxdepth 1 -type d | sort | while read -r r; do echo "random $r"; done
} > "${JOBS:-$D/jobs.txt}"
wc -l "${JOBS:-$D/jobs.txt}"
