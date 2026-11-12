# shared-github-actions
Central repository for storing shared github actions.

## patch-coverage
inputs:
```
  reports:
    required: true
    description: Coverage report paths, one per line, relative to working-directory. All of one format.
  format:
    required: true
    description: One of clover, lcov, cobertura
  base-ref:
    required: true
    description: The ref the PR is compared against, already fetched (for example origin/main)
  working-directory:
    required: false
    default: '.'
    description: Directory the reports and lcov SF paths are relative to
  threshold:
    required: false
    default: '85'
    description: Minimum patch coverage in percent, 0 to 100
  label:
    required: false
    default: patch-coverage
    description: Names the PR comment. Use one label per job
  extensions:
    required: false
    default: ''
    description: Extensions of the source files that should be in the report. Defaults per format (clover .php, lcov .ts,.tsx,.js, cobertura .py)
```
This action should be used in your **code repo**, after the tests have written a coverage report. It installs a pinned `diff-cover`, computes patch coverage (executable changed lines covered ÷ executable changed lines, against `base-ref`), and **fails the job when that is below `threshold`**. Total coverage is shown in the summary but never gates. It writes the job summary and edits one sticky PR comment per `label` (a run with no pull request, such as a `push`, writes the summary only).

```yaml
permissions:
  contents: read
  pull-requests: write   # for the sticky comment

steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0      # the base ref must be in the checkout
  # ... run the tests so they write coverage/clover.xml ...
  - uses: callpotential/shared-github-actions/patch-coverage@v1
    with:
      reports: coverage/clover.xml
      format: clover
      base-ref: origin/${{ github.base_ref }}
      label: php
```
**Note:** Call it once per format. `reports` may name several files of one format, but lcov and XML can't mix in one call.<br />
**Note:** Use one `label` per job; two parallel jobs sharing a label can both post a comment.<br />
**Note:** For lcov, `SF:` paths are relative to `working-directory` (an Nx workspace sets it to the workspace directory). Absolute paths under the checkout work too. A report written in a container (`/var/www/...`) needs its paths mapped to the checkout first.<br />
**Note:** The report must include the files no test loads (PHPUnit `<source>` with `includeUncoveredFiles`, Jest `collectCoverageFrom`). diff-cover only measures files the report lists, so a changed file missing from it is **listed under "Not in the coverage report" but not gated**.<br />
**Note:** The step fails (exit 2, not a pass) when `base-ref` isn't in the checkout, a report is missing, empty or unparseable, or none of the report's files resolves to a file tracked in the checkout.<br />
**Note:** The tests run with `bash patch-coverage/test/run.sh` (it installs `diff-cover` on first use) and in `.github/workflows/patch-coverage-test.yaml`.
