#!/bin/bash
# Builds and tests the checked-out commit, then lints it; logs go to /home/hylo/wt/l4-*.
c=$(git rev-parse --short HEAD)
git submodule update --quiet hylo-new || { echo "=== RESULT submodule-failed $c"; exit 1; }
echo "=== $c $(git log -1 --format=%s) hylo-new $(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C hylo-new rev-parse --short HEAD)"
swift build -j 4 --build-tests > /home/hylo/wt/l4-verify-build-$c.log 2>&1 || { echo "=== RESULT build-failed $c"; exit 1; }
swift test -j 4 --skip-build > /home/hylo/wt/l4-verify-test-$c.log 2>&1; r=$?
grep -E "Executed [0-9]+ tests" /home/hylo/wt/l4-verify-test-$c.log | grep -v "Executed 0 tests" | sort -t' ' -k2 -n | tail -1
grep -E "Test run with [0-9]+ tests" /home/hylo/wt/l4-verify-test-$c.log | tail -1
./lint.sh > /home/hylo/wt/l4-verify-lint-$c.log 2>&1 || { echo "=== lint failed $c"; r=1; }
echo "=== RESULT $r $c"
exit $r
