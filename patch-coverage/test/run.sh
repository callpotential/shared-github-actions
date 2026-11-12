#!/usr/bin/env bash
# Fixture tests for patch-coverage: bash patch-coverage/test/run.sh
# Needs diff-cover installed by ../install.sh (installed on demand when missing).
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PC="$HERE/../patch_coverage.py"
export PATCH_COVERAGE_PKGS="${PATCH_COVERAGE_PKGS:-${RUNNER_TEMP:-${XDG_CACHE_HOME:-$HOME/.cache}}/patch-coverage/pkgs}"
if ! PYTHONPATH="$PATCH_COVERAGE_PKGS" python3 -c 'import diff_cover' 2>/dev/null; then
  bash "$HERE/../install.sh" || exit 2
fi

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
FAILED=0
PASSED=0

new_repo() { # new_repo [UNCOVERED] -> REPO
  REPO=$(mktemp -d -p "$SCRATCH")
  bash "$HERE/make-fixture-repo.sh" "$REPO" "${1:-0}" >/dev/null 2>&1 || { echo "fixture build failed"; exit 2; }
}

# run_pc [VAR=value ...]: run the action's script in $REPO with a clean environment.
# Sets OUT (stdout+stderr) and CODE.
run_pc() {
  OUT=$(cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" PATCH_COVERAGE_PKGS="$PATCH_COVERAGE_PKGS" \
    INPUT_FORMAT=clover INPUT_REPORTS=reports/clover.xml INPUT_BASE_REF=main \
    "$@" python3 "$PC" run 2>&1)
  CODE=$?
}

ok() { PASSED=$((PASSED + 1)); }
bad() { FAILED=$((FAILED + 1)); echo "FAIL: $CASE: $*"; echo "$OUT" | sed 's/^/    | /' | head -30; }
expect_code() { [ "$CODE" -eq "$1" ] && ok || bad "exit $CODE, want $1"; }
expect_fail() { [ "$CODE" -ne 0 ] && ok || bad "exit 0, want non-zero"; }
expect_out() { case "$OUT" in *"$1"*) ok ;; *) bad "output lacks: $1" ;; esac; }
expect_not_out() { case "$OUT" in *"$1"*) bad "output has: $1" ;; *) ok ;; esac; }

# --- AC 1, 2, 3, 9: clover, lcov, cobertura -------------------------------------------
CASE="AC1 clover summary"; new_repo 3
run_pc; expect_code 0; expect_out "Patch coverage (patch-coverage)"; expect_out "97.0%"
expect_out "| \`src/calc.php\` | 6-8 |"; expect_out "Head total coverage: 97.1% (101/104 lines)"

CASE="AC1 lcov summary"; new_repo 3
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=reports/lcov.info
expect_code 0; expect_out "97.0%"; expect_out "| \`src/calc.php\` | 6-8 |"; expect_out "Head total coverage: 97.1% (101/104 lines)"

CASE="AC1 cobertura summary"; new_repo 3
run_pc INPUT_FORMAT=cobertura INPUT_REPORTS=reports/cobertura.xml INPUT_EXTENSIONS=.php
expect_code 0; expect_out "97.0%"; expect_out "| \`src/calc.php\` | 6-8 |"; expect_out "Head total coverage: 97.1% (101/104 lines)"

CASE="AC1 label in heading"; new_repo 3
run_pc INPUT_LABEL=php
expect_out "Patch coverage (php)"

CASE="AC2 at the threshold passes"; new_repo 15
run_pc; expect_code 0; expect_out "85.0%"
CASE="AC2 below the threshold fails"; new_repo 16
run_pc; expect_code 1; expect_out "84.0%"; expect_out "Result: FAIL"
CASE="AC2 threshold input moves the gate"; new_repo 16
run_pc INPUT_THRESHOLD=80; expect_code 0
CASE="AC2 no executable changed lines passes"; new_repo 16
run_pc INPUT_BASE_REF=HEAD; expect_code 0; expect_out "No executable changed lines"

CASE="AC3 total coverage never gates"; new_repo 0
sed -i 's/coveredstatements="[0-9]*"/coveredstatements="10"/' "$REPO/reports/clover.xml"
run_pc; expect_code 0; expect_out "Head total coverage: 9.6% (10/104 lines)"

CASE="AC9 uncovered change fails (clover)"; new_repo 100
run_pc; expect_code 1
CASE="AC9 uncovered change fails (lcov)"; new_repo 100
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=reports/lcov.info; expect_code 1

# --- AC 5: several reports, mixed formats ----------------------------------------------
CASE="AC5 two lcov files count toward one result"; new_repo 10
sed 's#^SF:libs/x/f.ts#SF:cp-workspace/libs/x/f.ts#' "$REPO/reports/nx-lcov.info" > "$REPO/reports/f.info"
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=$'reports/lcov.info\nreports/f.info'
expect_code 0; expect_out "180/200 changed lines covered"; expect_out "| \`cp-workspace/libs/x/f.ts\` | 6-15 |"
CASE="AC5 lcov and XML in one call"; new_repo 0
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=$'reports/lcov.info\nreports/clover.xml'
expect_code 2; expect_out "once per format"
CASE="AC5 clover named without .xml"; new_repo 0
cp "$REPO/reports/clover.xml" "$REPO/reports/clover.out"
run_pc INPUT_REPORTS=reports/clover.out; expect_code 2; expect_out "once per format"

# --- AC 6: Nx lcov, workspace-relative SF paths -----------------------------------------
CASE="AC6 workspace-relative lcov is matched"; new_repo 3
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=../reports/nx-lcov.info INPUT_WORKING_DIRECTORY=cp-workspace
expect_code 0; expect_out "97.0%"; expect_out "| \`cp-workspace/libs/x/f.ts\` | 6-8 |"
CASE="lcov absolute SF under the root"; new_repo 3
sed -i "s#^SF:libs/#SF:$REPO/cp-workspace/libs/#" "$REPO/reports/nx-lcov.info"
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=../reports/nx-lcov.info INPUT_WORKING_DIRECTORY=cp-workspace
expect_code 0; expect_out "97.0%"

# --- AC 7: report paths vs the checkout -------------------------------------------------
write_container_clover() { # a clover whose paths are from a container: /var/www/...
  sed "s#name=\"[^\"]*calc.php\"#name=\"/var/www/html/lib/other.php\"#" "$REPO/reports/clover.xml" > "$REPO/reports/container.xml"
}
CASE="AC7 container clover matches no tracked file"; new_repo 0
write_container_clover
run_pc INPUT_REPORTS=reports/container.xml; expect_code 2; expect_out "don't match the checkout"; expect_out "/var/www/html/lib/other.php"
CASE="AC7 docs-only PR with a bad report still fails"; new_repo 0
(cd "$REPO" && git checkout -q -b docs main && echo hi > README.md && git add README.md && git commit -qm docs)
write_container_clover
run_pc INPUT_REPORTS=reports/container.xml; expect_code 2; expect_out "don't match the checkout"
CASE="AC7 test-only PR with a good report passes"; new_repo 0
(cd "$REPO" && git checkout -q -b tests main && mkdir tests && echo '<?php $t = 1;' > tests/CalcTest.php && git add tests && git commit -qm tests)
run_pc; expect_code 0; expect_out "No executable changed lines"; expect_out "- \`tests/CalcTest.php\`"
CASE="AC7 Nx lcov without the workspace rewrite would not match"; new_repo 0
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=reports/nx-lcov.info   # wd '.', SF relative to cp-workspace
expect_code 2; expect_out "don't match the checkout"

# --- AC 10: base ref --------------------------------------------------------------------
CASE="AC10 base ref missing (shallow clone)"; new_repo 0
CLONE="$SCRATCH/shallow"; git clone -q --depth 1 "file://$REPO" "$CLONE" 2>/dev/null
cp -r "$REPO/reports" "$CLONE/reports"
sed -i "s#$REPO#$CLONE#" "$CLONE/reports/clover.xml"
REPO=$CLONE run_pc INPUT_BASE_REF=origin/main; expect_code 2; expect_out "base-ref 'origin/main' is not in the checkout"; expect_out "git fetch"
CASE="AC10 base fetched shallow, no merge base"; 
(cd "$CLONE" && git fetch -q --depth 1 origin main:refs/remotes/origin/main 2>/dev/null)
REPO=$CLONE run_pc INPUT_BASE_REF=origin/main; expect_code 2; expect_out "no merge base between 'origin/main' and HEAD"; expect_out "Fetch more history"

# --- AC 11: bad reports -----------------------------------------------------------------
CASE="AC11 missing report"; new_repo 0
run_pc INPUT_REPORTS=reports/nope.xml; expect_code 2; expect_out "report not found"
CASE="AC11 empty report"; new_repo 0
: > "$REPO/reports/empty.xml"
run_pc INPUT_REPORTS=reports/empty.xml; expect_code 2; expect_out "empty"
CASE="AC11 truncated XML"; new_repo 0
head -c 300 "$REPO/reports/clover.xml" > "$REPO/reports/trunc.xml"
run_pc INPUT_REPORTS=reports/trunc.xml; expect_code 2; expect_out "cannot parse"
CASE="AC11 empty lcov"; new_repo 0
printf 'TN:\n' > "$REPO/reports/empty.info"
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=reports/empty.info; expect_code 2; expect_out "no SF: records"
CASE="AC11 cobertura given as clover"; new_repo 0
run_pc INPUT_REPORTS=reports/cobertura.xml; expect_code 2; expect_out "not a clover report"

# --- AC 14: working directory with a space, a .. report path ----------------------------
CASE="AC14 working-directory with a space and a .. report"; 
REPO=$(mktemp -d -p "$SCRATCH"); WS_DIR="cp ws" bash "$HERE/make-fixture-repo.sh" "$REPO" 3 >/dev/null 2>&1
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=../reports/nx-lcov.info "INPUT_WORKING_DIRECTORY=cp ws"
expect_code 0; expect_out "97.0%"; expect_out "| \`cp ws/libs/x/f.ts\` | 6-8 |"

# --- AC 15: bad inputs fail before diff-cover is called ---------------------------------
STUB="$SCRATCH/stub-diff-cover.sh"
printf '#!/usr/bin/env bash\necho called >> "$STUB_LOG"\nexit 0\n' > "$STUB"; chmod +x "$STUB"
bad_input() { # bad_input <var=value> <expected message part>
  new_repo 0; rm -f "$SCRATCH/stub.log"
  run_pc "$1" DIFF_COVER_CMD="$STUB" STUB_LOG="$SCRATCH/stub.log"
  expect_code 2; expect_out "$2"
  [ ! -e "$SCRATCH/stub.log" ] && ok || bad "diff-cover was called"
}
CASE="AC15 threshold abc"; bad_input INPUT_THRESHOLD=abc threshold
CASE="AC15 threshold 101"; bad_input INPUT_THRESHOLD=101 threshold
CASE="AC15 threshold nan"; bad_input INPUT_THRESHOLD=nan threshold
CASE="AC15 format jacoco"; bad_input INPUT_FORMAT=jacoco format
CASE="AC15 label with -->"; bad_input "INPUT_LABEL=a-->b" label

# --- plan-review cases ------------------------------------------------------------------
CASE="unstaged edits don't change the result"; new_repo 15
sed -i '3s/.*/$changed = 1;/' "$REPO/src/calc.php"
run_pc; expect_code 0; expect_out "85/100 changed lines covered"

CASE="deleted file isn't listed as not in the report"; new_repo 0
(cd "$REPO" && git rm -q src/old.php && git commit -qm rm)
run_pc; expect_code 0; expect_not_out "src/old.php"

CASE="new file absent from the report is listed, ungated"; new_repo 0
(cd "$REPO" && echo '<?php $n = 1;' > src/new.php && git add src/new.php && git commit -qm new)
run_pc; expect_code 0; expect_out "### Not in the coverage report"; expect_out "- \`src/new.php\`"

echo
echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
