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

CASE="AC2 at the threshold passes"; new_repo 20
run_pc; expect_code 0; expect_out "80.0%"
CASE="AC2 below the threshold fails"; new_repo 21
run_pc; expect_code 1; expect_out "79.0%"; expect_out "Result: FAIL"
CASE="AC2 threshold input moves the gate"; new_repo 21
run_pc INPUT_THRESHOLD=75; expect_code 0
CASE="AC2 threshold input raises the gate"; new_repo 15
run_pc INPUT_THRESHOLD=90; expect_code 1
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
# The AC 7 check must match by diff-cover's own rules: a path it suffix-matched but
# diff-cover didn't measured nothing and passed (code review).
CASE="AC7 lcov with container SF paths fails"; new_repo 100
sed -i 's#^SF:src/#SF:/app/src/#' "$REPO/reports/lcov.info"
run_pc INPUT_FORMAT=lcov INPUT_REPORTS=reports/lcov.info; expect_code 2; expect_out "don't match the checkout"
CASE="AC7 cobertura with container filenames fails"; new_repo 100
sed -i 's#filename="src/#filename="/app/src/#' "$REPO/reports/cobertura.xml"
run_pc INPUT_FORMAT=cobertura INPUT_REPORTS=reports/cobertura.xml; expect_code 2; expect_out "don't match the checkout"
CASE="AC7 clover relative to a subdirectory working-directory fails"; new_repo 100
sed -i "s#name=\"$REPO/src/calc.php\"#name=\"calc.php\"#" "$REPO/reports/clover.xml"
run_pc INPUT_REPORTS=../reports/clover.xml INPUT_WORKING_DIRECTORY=src; expect_code 2; expect_out "don't match the checkout"
CASE="AC7 clover with container paths under the repo root still matches"; new_repo 100
sed -i "s#name=\"$REPO/#name=\"/var/www/html/#" "$REPO/reports/clover.xml"
run_pc; expect_code 1; expect_out "0/100 changed lines covered"

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

CASE="a long not-in-report list is capped under GitHub's comment size limit"; new_repo 0
(cd "$REPO" && mkdir gen && for i in $(seq 1 1500); do echo '<?php $g = 1;' > "gen/generated_file_with_a_long_name_$i.php"; done && git add gen && git commit -qm gen)
run_pc; expect_code 0; expect_out "and 1450 more"
[ "$(printf '%s' "$OUT" | wc -c)" -lt 65536 ] && ok || bad "output is $(printf '%s' "$OUT" | wc -c) chars"

# --- Step 2: the sticky PR comment, against a stub gh -----------------------------------
GHBIN="$SCRATCH/ghbin"; mkdir -p "$GHBIN"
printf '#!/usr/bin/env bash\nexec python3 "%s/gh-stub.py" "$@"\n' "$HERE" > "$GHBIN/gh"; chmod +x "$GHBIN/gh"
new_pr() { # new_pr [UNCOVERED]: a repo plus a stub-gh state dir and a PR event file
  new_repo "${1:-0}"
  GHD=$(mktemp -d -p "$SCRATCH")
  printf '{"pull_request":{"number":7}}' > "$GHD/event.json"
}
# run_gh [VAR=value ...]: run_pc with the stub gh first on PATH and a PR event
run_gh() {
  run_pc PATH="$GHBIN:$PATH" GH_STUB_DIR="$GHD" GITHUB_EVENT_PATH="$GHD/event.json" \
    GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=pull_request GH_TOKEN=secret-token-123 "$@"
}
calls() { cat "$GHD/calls.log" 2>/dev/null; }
bodies() { python3 -c 'import json,sys; [print(c["id"], repr(c["body"][:60])) for c in json.load(open(sys.argv[1]))]' "$GHD/comments.json"; }
n_comments() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$GHD/comments.json"; }

CASE="AC4 first run posts, second run with the same label edits"; new_pr 3
run_gh INPUT_LABEL=php; expect_code 0
run_gh INPUT_LABEL=php; expect_code 0
[ "$(n_comments)" = 1 ] && ok || bad "want 1 comment, have $(n_comments)"
[ "$(calls | grep -c PATCH)" = 1 ] && ok || bad "want 1 PATCH"
[ "$(calls | grep -c POST)" = 1 ] && ok || bad "want 1 POST"
case "$(bodies)" in *"<!-- patch-coverage:php -->"*) ok ;; *) bad "marker missing: $(bodies)" ;; esac
CASE="AC4 a second label gets its own comment"
run_gh INPUT_LABEL=ts; expect_code 0
[ "$(n_comments)" = 2 ] && ok || bad "want 2 comments, have $(n_comments)"
CASE="AC4 a label that prefixes another doesn't match it"
run_gh INPUT_LABEL=ph; [ "$(n_comments)" = 3 ] && ok || bad "want 3 comments, have $(n_comments)"
CASE="list uses --paginate and the repos/ path"
case "$(calls | head -1)" in '["api", "--paginate", "repos/o/r/issues/7/comments", "--jq", ".[] | {id, user: .user.login, body}"]') ok ;; *) bad "list call: $(calls | head -1)" ;; esac

CASE="AC4 failing gate still updates the comment, exit 1"; new_pr 21
run_gh INPUT_LABEL=php; expect_code 1
run_gh INPUT_LABEL=php; expect_code 1
[ "$(n_comments)" = 1 ] && [ "$(calls | grep -c PATCH)" = 1 ] && ok || bad "want 1 comment edited once"

CASE="label with a quote and a backslash round-trips"; new_pr 0
run_gh 'INPUT_LABEL=a"b\c'; expect_code 0
run_gh 'INPUT_LABEL=a"b\c'; expect_code 0
[ "$(n_comments)" = 1 ] && [ "$(calls | grep -c PATCH)" = 1 ] && ok || bad "want 1 comment edited once"

CASE="a comment by another user quoting the marker is ignored"; new_pr 0
printf '[{"id":5,"user":"mallory","body":"<!-- patch-coverage:php --> hi"}]' > "$GHD/comments.json"
run_gh INPUT_LABEL=php; expect_code 0
[ "$(n_comments)" = 2 ] && [ "$(calls | grep -c PATCH)" = 0 ] && ok || bad "want a POST, no PATCH"

CASE="several matching comments: the lowest id is edited"; new_pr 0
printf '[{"id":9,"user":"github-actions[bot]","body":"<!-- patch-coverage:php --> x"},{"id":4,"user":"github-actions[bot]","body":"<!-- patch-coverage:php --> y"}]' > "$GHD/comments.json"
run_gh INPUT_LABEL=php; expect_code 0
case "$(calls | grep PATCH)" in *"repos/o/r/issues/comments/4"*) ok ;; *) bad "PATCH: $(calls | grep PATCH)" ;; esac

CASE="a failing list call never falls through to POST"; new_pr 0
run_gh GH_STUB_LIST_FAIL=500 INPUT_LABEL=php; expect_code 2; expect_out "gh api failed (HTTP 500)"
[ "$(calls | grep -c POST)" = 0 ] && ok || bad "POSTed after a failed list"

CASE="AC12 a push run writes the summary and never calls gh"; new_pr 3
printf '{"ref":"refs/heads/main"}' > "$GHD/event.json"
run_gh GITHUB_EVENT_NAME=push GITHUB_STEP_SUMMARY="$GHD/summary.md"; expect_code 0
[ ! -e "$GHD/calls.log" ] && ok || bad "gh was called"
grep -q "Patch coverage" "$GHD/summary.md" && ok || bad "summary not written"
expect_out "no pull request"

CASE="AC13 a 403 fails with the status and the permission, and leaks no token"; new_pr 0
run_gh GH_STUB_WRITE_FAIL=403; expect_code 2; expect_out "gh api failed (HTTP 403)"; expect_out "pull-requests: write"
expect_not_out "secret-token-123"
CASE="AC13 a failing gate plus a failing comment keeps exit 1"; new_pr 21
run_gh GH_STUB_WRITE_FAIL=403; expect_code 1; expect_out "gh api failed (HTTP 403)"

echo
echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
