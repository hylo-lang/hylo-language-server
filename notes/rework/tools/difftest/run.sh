#!/usr/bin/env bash
# Runs the compiler driver `$1` (an `hc` built with dump.patch applied) on every program of the
# corpus in /home/hylo/wt/difftest/corpus, writing the typed program dump, the diagnostics, and the
# exit status of each run to `$2`.
#
# Usage: run.sh <path-to-hc> <output-dir>
# CORPUS and JOBS override the corpus directory and the job list (default: corpus/, jobs.txt).
#
# Jobs (one per line of the job list, built by `jobs.sh`):
#   std  <path>              : compile <path> (file or directory) with the standard library
#   nostd <path>             : compile <path> with --no-std
#   stdlib                   : type check the standard library itself as module Hylo
#   random <dir>             : <dir>/lib.hylo is compiled to an archive, then <dir>/main*.hylo
#                              importing it; also <dir> merged into one module (merged.d)
# For each job, typed-ast (with the HYLO_DIFF_DUMP dump of all types and name referents) is emitted;
# for jobs whose typing succeeds, raw IR is emitted too.
set -u
HC=$(realpath "$1")
OUT=$(realpath -m "$2")
CORPUS=${CORPUS:-/home/hylo/wt/difftest/corpus}
mkdir -p "$OUT/mc" "$OUT/res"
export HC OUT CORPUS HYLO_DIFF_DUMP=1

# Normalizes output: strips ANSI colors and absolute paths of the corpus / output dir.
norm() { sed -e 's|/home/hylo/wt/[^/]*/.build/out/Products/[^/]*/Hylo_StandardLibrary.bundle/|STDLIB/|g' -e 's|/home/hylo/wt/hn-diff-[a-z]*/|TREE/|g' -e 's/\x1b\[[0-9;]*m//g' -e "s|$CORPUS/||g" -e "s|$OUT/||g"; }
export -f norm

one() {
  local kind=$1 path=$2
  local key
  key=$(echo "$kind-$path" | tr '/' '_')
  local r="$OUT/res/$key"
  local args=()
  case $kind in
    std) args=(--module-cache "$OUT/mc") ;;
    nostd|stdlib) args=(--no-std) ;;
  esac
  local mod=()
  [ "$kind" = stdlib ] && mod=(--module-name Hylo)
  cd "$CORPUS" || exit 1
  if [ "$kind" = random ]; then
    local w="$OUT/work/$key"; mkdir -p "$w"
    # Library archive, then the module importing it.
    "$HC" --no-std --module-name Lib --emit typed-ast -o "$r.lib.ast" --emit-module-to "$w/Lib.hylomodule" \
      "$path/lib.hylo" > "$r.lib.err" 2>&1; echo $? > "$r.lib.exit"
    norm < "$r.lib.err" > "$r.lib.errn"; rm "$r.lib.err"
    "$HC" --no-std --module-name Main --module-search-path "$w" --import Lib --emit typed-ast \
      -o "$r.ast" "$path/main0.hylo" "$path/main1.hylo" > "$r.err" 2>&1; echo $? > "$r.exit"
    # The same sources merged into one module.
    "$HC" --no-std --module-name Main --emit typed-ast -o "$r.merged.ast" "$path/merged.d" \
      > "$r.merged.err" 2>&1; echo $? > "$r.merged.exit"
    if [ "$(cat "$r.merged.exit")" = 0 ]; then
      "$HC" --no-std --module-name Main --emit raw-ir -o "$r.merged.ir" "$path/merged.d" \
        > /dev/null 2>&1; echo $? > "$r.merged.ir.exit"
    fi
    for f in "$r.err" "$r.merged.err"; do norm < "$f" > "$f"n; rm "$f"; done
    rm -rf "$w"
  else
    "$HC" "${args[@]}" "${mod[@]}" --emit typed-ast -o "$r.ast" "$path" > "$r.err" 2>&1
    echo $? > "$r.exit"
    if [ "$(cat "$r.exit")" = 0 ] && [ "$kind" != stdlib ]; then
      "$HC" "${args[@]}" "${mod[@]}" --emit raw-ir -o "$r.ir" "$path" > /dev/null 2>&1
      echo $? > "$r.ir.exit"
    fi
    norm < "$r.err" > "$r.errn"; rm "$r.err"
  fi
  for f in "$r".*ast "$r".*ir; do [ -f "$f" ] && { norm < "$f" > "$f.n"; mv "$f.n" "$f"; }; done
  return 0
}
export -f one

# Warm the module cache (the standard library) once, sequentially, before parallel runs.
cd "$CORPUS" && "$HC" --module-cache "$OUT/mc" --emit typed-ast -o "$OUT/warm.ast" warm.hylo \
  > "$OUT/warm.log" 2>&1

xargs -P 4 -L 1 bash -c 'one "$0" "$1"' < ${JOBS:-/home/hylo/wt/difftest/jobs.txt}
echo "done: $(ls "$OUT/res" | wc -l) result files"
