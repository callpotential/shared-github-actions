#!/usr/bin/env bash
# make-fixture-repo.sh DIR [UNCOVERED] — build a fixture git repo with a known PR diff and
# the reports for it (in DIR/reports, untracked).
#
# `main` holds src/calc.php, src/old.php and <WS_DIR>/libs/x/f.ts (WS_DIR defaults to
# cp-workspace), five lines each. Branch `pr` adds 100 executable lines to src/calc.php and to
# f.ts. The first UNCOVERED of each file's 100 new lines are uncovered in the reports.
set -euo pipefail

dir=$1
unc=${2:-0}
ws=${WS_DIR:-cp-workspace}

mkdir -p "$dir"
cd "$dir"
dir=$(pwd -P)
git init -q -b main .
git config user.email test@example.com
git config user.name test
git config commit.gpgsign false
git config core.hooksPath /dev/null

mkdir -p src "$ws/libs/x"
{ echo '<?php'; for i in 2 3 4 5; do echo "\$a$i = $i;"; done; } > src/calc.php
{ echo '<?php'; for i in 2 3 4 5; do echo "\$o$i = $i;"; done; } > src/old.php
for i in 1 2 3 4 5; do echo "export const a$i = $i;"; done > "$ws/libs/x/f.ts"
git add .
git commit -qm base
git checkout -q -b pr

for i in $(seq 6 105); do echo "\$b$i = $i;" >> src/calc.php; done
for i in $(seq 6 105); do echo "export const b$i = $i;" >> "$ws/libs/x/f.ts"; done
git add .
git commit -qm change

mkdir reports
# lines <first> <last>: DA/line entries; the first $unc changed lines (6..) are uncovered
hits() { if [ "$1" -ge 6 ] && [ "$1" -lt $((6 + unc)) ]; then echo 0; else echo 1; fi; }

{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<coverage generated="1700000000">'
  echo '  <project timestamp="1700000000">'
  echo "    <file name=\"$dir/src/calc.php\">"
  for n in $(seq 2 105); do echo "      <line num=\"$n\" type=\"stmt\" count=\"$(hits "$n")\"/>"; done
  echo '    </file>'
  echo "    <metrics files=\"1\" loc=\"105\" ncloc=\"105\" statements=\"104\" coveredstatements=\"$((104 - unc))\"/>"
  echo '  </project>'
  echo '</coverage>'
} > reports/clover.xml

{
  echo '<?xml version="1.0" ?>'
  echo "<coverage line-rate=\"0.9\" branch-rate=\"0\" lines-covered=\"$((104 - unc))\" lines-valid=\"104\" version=\"1\" timestamp=\"1\">"
  echo '  <packages><package name="src"><classes>'
  echo '    <class name="calc" filename="src/calc.php" line-rate="0.9"><lines>'
  for n in $(seq 2 105); do echo "      <line number=\"$n\" hits=\"$(hits "$n")\"/>"; done
  echo '    </lines></class>'
  echo '  </classes></package></packages>'
  echo '</coverage>'
} > reports/cobertura.xml

lcov() { # lcov <SF> <last-line> <first-line>
  echo "TN:"
  echo "SF:$1"
  for n in $(seq "$3" "$2"); do echo "DA:$n,$(hits "$n")"; done
  echo "LF:$(($2 - $3 + 1))"
  echo "LH:$(($2 - $3 + 1 - unc))"
  echo "end_of_record"
}
lcov src/calc.php 105 2 > reports/lcov.info
lcov libs/x/f.ts 105 1 > reports/nx-lcov.info
