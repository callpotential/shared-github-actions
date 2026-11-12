#!/usr/bin/env bash
# Installs the pinned diff-cover into PATCH_COVERAGE_PKGS (pip --target, so no venv and no
# PEP 668 error). patch_coverage.py runs it as `python3 -m diff_cover.diff_cover_tool` with
# PYTHONPATH set to the same directory. diff-cover 10.6.0 needs Python >= 3.10.
set -euo pipefail

DIFF_COVER_VERSION=10.6.0
PKGS="${PATCH_COVERAGE_PKGS:-${RUNNER_TEMP:-${XDG_CACHE_HOME:-$HOME/.cache}}/patch-coverage/pkgs}"

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "patch-coverage: diff-cover ${DIFF_COVER_VERSION} needs Python >= 3.10 (found $(python3 --version 2>&1))" >&2
  exit 2
fi

python3 -m pip install --quiet --disable-pip-version-check --target "$PKGS" "diff-cover==${DIFF_COVER_VERSION}"
echo "patch-coverage: installed $(PYTHONPATH="$PKGS" python3 -m diff_cover.diff_cover_tool --version) into $PKGS"
