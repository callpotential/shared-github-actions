#!/usr/bin/env python3
"""Which tracked files diff-cover itself finds in the coverage reports.

Usage (cwd = the working directory diff-cover runs from, diff-cover on PYTHONPATH):
  report_match.py REPORT...   < root-relative paths, one per line
Prints the paths diff-cover has measured lines for, one per line.

patch_coverage.py's AC 7 check asks this instead of copying diff-cover's path rules,
which differ per format (clover suffix-matches absolute paths; lcov and Cobertura don't).
"""

import sys
import xml.etree.ElementTree as etree  # the parser diff_cover_tool uses

from diff_cover.git_path import GitPathTool
from diff_cover.violationsreporters.violations_reporter import (
    LcovCoverageReporter,
    XmlCoverageReporter,
)

SRC_ROOTS = ["src/main/java", "src/test/java"]  # diff_cover_tool's default


def reporter(reports):
    # Built as diff_cover_tool.generate_coverage_report builds it.
    if all(r.endswith(".xml") for r in reports):
        return XmlCoverageReporter([etree.parse(r) for r in reports], SRC_ROOTS)
    return LcovCoverageReporter([LcovCoverageReporter.parse(r) for r in reports], SRC_ROOTS)


def main(argv):
    GitPathTool.set_cwd(None)  # the cwd, as diff_cover_tool.main does
    cov = reporter(argv[1:])
    for path in sys.stdin.read().splitlines():
        if path and cov.measured_lines(path):
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
