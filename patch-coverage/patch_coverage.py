#!/usr/bin/env python3
"""Patch-coverage gate: run diff-cover on coverage reports and gate on patch coverage.

Usage: patch_coverage.py run

Inputs come only from INPUT_* environment variables (see action.yml). Every git and
diff-cover call is an argv list; nothing is interpolated into a shell.

Exit codes: 0 pass, 1 patch coverage below the threshold, 2 input, report or base error.
"""

import json
import math
import os
import posixpath
import re
import shlex
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

FORMATS = ("clover", "lcov", "cobertura")
DEFAULT_EXTENSIONS = {"clover": ".php", "lcov": ".ts,.tsx,.js", "cobertura": ".py"}
EXIT_PASS, EXIT_GATE, EXIT_ERROR = 0, 1, 2


class InputError(Exception):
    """An input, report or base problem: exit 2, never a pass."""


def default_pkgs_dir(env):
    base = env.get("RUNNER_TEMP") or env.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return os.path.join(base, "patch-coverage", "pkgs")


def load_config(env):
    fmt = env.get("INPUT_FORMAT", "").strip()
    if fmt not in FORMATS:
        raise InputError(
            f"format must be one of {', '.join(FORMATS)}, got {fmt!r}"
        )
    raw_threshold = env.get("INPUT_THRESHOLD", "85").strip() or "85"
    try:
        threshold = float(raw_threshold)
    except ValueError:
        raise InputError(f"threshold must be a number from 0 to 100, got {raw_threshold!r}")
    if not math.isfinite(threshold) or not 0 <= threshold <= 100:
        raise InputError(f"threshold must be a number from 0 to 100, got {raw_threshold!r}")
    label = env.get("INPUT_LABEL", "patch-coverage").strip()
    if not label:
        raise InputError("label must not be empty")
    if "-->" in label:
        raise InputError("label must not contain '-->'")
    base_ref = env.get("INPUT_BASE_REF", "").strip()
    if not base_ref:
        raise InputError("base-ref is required")
    reports = [r.strip() for r in env.get("INPUT_REPORTS", "").splitlines() if r.strip()]
    if not reports:
        raise InputError("reports is required: one report path per line")
    extensions = env.get("INPUT_EXTENSIONS", "").strip() or DEFAULT_EXTENSIONS[fmt]
    extensions = tuple(e.strip() for e in extensions.split(",") if e.strip())
    return {
        "format": fmt,
        "threshold": threshold,
        "label": label,
        "base_ref": base_ref,
        "reports": reports,
        "extensions": extensions,
        "working_directory": env.get("INPUT_WORKING_DIRECTORY", "").strip() or ".",
    }


def child_env(env):
    """The environment for git and diff-cover: no token, diff-cover on PYTHONPATH."""
    out = {k: v for k, v in env.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    pkgs = env.get("PATCH_COVERAGE_PKGS") or default_pkgs_dir(env)
    out["PYTHONPATH"] = pkgs + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    return out


def run_git(args, cwd, env):
    proc = subprocess.run(
        ["git", *args], cwd=cwd, env=env, capture_output=True, check=False
    )
    return (
        proc.returncode,
        proc.stdout.decode("utf-8", "surrogateescape"),
        proc.stderr.decode("utf-8", "surrogateescape"),
    )


# ---- reports ---------------------------------------------------------------


def parse_clover(path):
    root = parse_xml(path)
    project = root.find("project") if root.tag == "coverage" else (
        root if root.tag == "project" else None
    )
    if project is None:
        raise InputError(f"{path} is not a clover report (no <project> element)")
    files = []
    for f in root.iter("file"):
        name = f.get("path") or f.get("name")
        if name:
            files.append(name)
    metrics = project.find("metrics")
    total = None
    if metrics is not None:
        total = (metrics.get("coveredstatements"), metrics.get("statements"))
    return files, total


def parse_cobertura(path):
    root = parse_xml(path)
    if root.tag != "coverage" or root.get("line-rate") is None:
        raise InputError(f"{path} is not a Cobertura report (no line-rate on <coverage>)")
    sources = [s.text.strip() for s in root.findall("sources/source") if s.text and s.text.strip()]
    files = []
    for c in root.iter("class"):
        name = c.get("filename")
        if not name:
            continue
        files.append(name)
        files.extend(posixpath.join(s, name) for s in sources)
    return files, (root.get("lines-covered"), root.get("lines-valid"))


def parse_xml(path):
    try:
        return ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        raise InputError(f"cannot parse {path}: {e}")


def parse_lcov_records(text):
    """Return [(sf, lf, lh)] per record; lf/lh None when absent."""
    records, current = [], None
    for line in text.splitlines():
        if line.startswith("SF:"):
            current = {"sf": line[3:], "lf": None, "lh": None}
            records.append(current)
        elif current is not None and line.startswith("LF:"):
            current["lf"] = line[3:]
        elif current is not None and line.startswith("LH:"):
            current["lh"] = line[3:]
        elif line.startswith("end_of_record"):
            current = None
    return records


def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def sum_field(records, key):
    """Sum an lcov LF/LH field over records; None when any record lacks it."""
    values = [to_int(r[key]) for r in records]
    return None if any(v is None for v in values) else sum(values)


def sum_totals(pairs):
    """pairs: [(covered, total)] as strings; None when any is missing."""
    covered = total = 0
    for c, t in pairs:
        c, t = to_int(c), to_int(t)
        if c is None or t is None:
            return None
        covered += c
        total += t
    return covered, total


# ---- path resolution -------------------------------------------------------


REPORT_MATCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "report_match.py")


def measured_tracked(diff_inputs, tracked, wd, genv):
    """Tracked files diff-cover itself measures in the reports (report_match.py).

    Asking diff-cover, rather than copying its path rules, keeps AC 7 from passing a
    report whose paths diff-cover then matches to nothing.
    """
    proc = subprocess.run(
        [sys.executable, REPORT_MATCH, *diff_inputs],
        cwd=wd, env=genv, input="\n".join(sorted(tracked)) + "\n",
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise InputError(f"cannot match the report paths (exit {proc.returncode}); see above")
    return {line for line in proc.stdout.splitlines() if line}


def rewrite_lcov(text, root, wd_rel):
    """Make every SF: path root-relative, the way diff-cover resolves lcov paths."""
    out = []
    for line in text.splitlines(keepends=True):
        if line.startswith("SF:"):
            sf = line[3:].rstrip("\r\n")
            if sf.startswith("/"):
                if sf.startswith(root + "/"):
                    sf = posixpath.relpath(sf, root)
            else:
                sf = posixpath.normpath(posixpath.join(wd_rel, sf))
            line = "SF:" + sf + "\n"
        out.append(line)
    return "".join(out)


# ---- the run ---------------------------------------------------------------


def format_lines(lines):
    lines = sorted(set(lines))
    ranges, start, prev = [], None, None
    for n in lines:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            ranges.append((start, prev))
            start = prev = n
    if start is not None:
        ranges.append((start, prev))
    return ", ".join(str(a) if a == b else f"{a}-{b}" for a, b in ranges)


# Each file list in the summary is capped, so the PR comment stays under GitHub's
# 65,536-character body limit (a longer one is rejected with HTTP 422).
MAX_LISTED = 50


def more_line(count):
    if count <= MAX_LISTED:
        return []
    return [f"…and {count - MAX_LISTED} more.", ""]


def compose_summary(cfg, measured, uncovered, pct, passed, src_stats, total, not_in_report):
    lines = [f"## Patch coverage ({cfg['label']})", ""]
    if measured == 0:
        lines.append(
            f"No executable changed lines. Threshold {cfg['threshold']:g}%. Result: pass."
        )
    else:
        result = "pass" if passed else "FAIL"
        lines.append(
            f"**{pct:.1f}%** ({measured - uncovered}/{measured} changed lines covered). "
            f"Threshold {cfg['threshold']:g}%. Result: {result}."
        )
    lines.append("")
    rows = [(f, s.get("violation_lines") or []) for f, s in sorted(src_stats.items())]
    rows = [(f, v) for f, v in rows if v]
    if rows:
        lines += ["| File | Uncovered changed lines |", "|---|---|"]
        lines += [f"| `{f}` | {format_lines(v)} |" for f, v in rows[:MAX_LISTED]]
        lines.append("")
        lines += more_line(len(rows))
    if total is None:
        lines.append("Head total coverage: unavailable.")
    else:
        covered, count = total
        share = f"{100 * covered / count:.1f}%" if count else "n/a"
        lines.append(f"Head total coverage: {share} ({covered}/{count} lines).")
    if not_in_report:
        lines += [
            "",
            "### Not in the coverage report",
            "",
            "Changed files the report doesn't list, so their lines aren't measured:",
            "",
        ]
        lines += [f"- `{f}`" for f in not_in_report[:MAX_LISTED]]
        if len(not_in_report) > MAX_LISTED:
            lines += ["", *more_line(len(not_in_report))]
    return "\n".join(lines) + "\n"


def run(env, cwd, tmp):
    cfg = load_config(env)
    genv = child_env(env)
    xml = cfg["format"] != "lcov"

    wd = os.path.abspath(os.path.join(cwd, cfg["working_directory"]))
    if not os.path.isdir(wd):
        raise InputError(f"working-directory {cfg['working_directory']!r} is not a directory")
    code, out, err = run_git(["rev-parse", "--show-toplevel"], wd, genv)
    if code != 0:
        raise InputError(f"working-directory is not inside a git checkout: {err.strip()}")
    root = os.path.realpath(out.strip())
    wd_rel = posixpath.normpath(os.path.relpath(os.path.realpath(wd), root).replace(os.sep, "/"))
    if wd_rel.startswith(".."):
        raise InputError("working-directory resolves outside the git checkout")

    # Reports: exist, non-empty, one format.
    report_paths = []
    for entry in cfg["reports"]:
        path = os.path.abspath(os.path.join(wd, entry))
        if not os.path.isfile(path):
            raise InputError(f"report not found: {entry} (resolved to {path})")
        if os.path.getsize(path) == 0:
            raise InputError(f"report is empty: {entry}")
        is_xml_name = path.lower().endswith(".xml")
        if xml and not is_xml_name:
            raise InputError(
                f"{entry}: format {cfg['format']} needs an .xml report; call the action "
                "once per format (lcov and XML reports can't mix in one call)"
            )
        if not xml and is_xml_name:
            raise InputError(
                f"{entry} is XML but format is lcov: call the action once per format"
            )
        report_paths.append(path)

    # Parse every report (truncated or wrong-shaped ones fail here, not as a pass).
    names, totals = [], []
    diff_inputs = []
    for i, path in enumerate(report_paths):
        if cfg["format"] == "clover":
            files, total = parse_clover(path)
            names += files
            totals.append(total or (None, None))
            diff_inputs.append(path)
        elif cfg["format"] == "cobertura":
            files, total = parse_cobertura(path)
            names += files
            totals.append(total)
            diff_inputs.append(path)
        else:
            with open(path, encoding="utf-8", errors="surrogateescape") as fh:
                text = fh.read()
            records = parse_lcov_records(text)
            if not records:
                raise InputError(f"{path} has no SF: records: not an lcov report, or empty")
            rewritten = rewrite_lcov(text, root, wd_rel)
            copy = os.path.join(tmp, f"lcov-{i}.info")
            with open(copy, "w", encoding="utf-8", errors="surrogateescape") as fh:
                fh.write(rewritten)
            diff_inputs.append(copy)
            names += [r["sf"] for r in parse_lcov_records(rewritten)]
            totals.append(
                (
                    sum_field(records, "lh"),
                    sum_field(records, "lf"),
                )
            )
    total = sum_totals(totals)

    # Base ref.
    base = cfg["base_ref"]
    code, _, err = run_git(["rev-parse", "--verify", "--quiet", f"{base}^{{commit}}"], root, genv)
    if code != 0:
        raise InputError(
            f"base-ref {base!r} is not in the checkout. Fetch it before this step, e.g. "
            f"`git fetch origin {base.removeprefix('origin/')}` or actions/checkout with "
            "fetch-depth: 0."
        )
    code, _, err = run_git(["merge-base", base, "HEAD"], root, genv)
    if code != 0:
        raise InputError(
            f"no merge base between {base!r} and HEAD (a shallow clone?). Fetch more history, "
            "e.g. `git fetch --unshallow` or actions/checkout with fetch-depth: 0."
        )

    # Mismatch: the report's paths must resolve to a tracked file (AC 7).
    code, out, err = run_git(["ls-files", "-z"], root, genv)
    if code != 0:
        raise InputError(f"git ls-files failed: {err.strip()}")
    tracked = {t for t in out.split("\0") if t}
    in_report = measured_tracked(diff_inputs, tracked, wd, genv)
    if not in_report:
        sample = ", ".join(sorted(set(names))[:3]) or "(none)"
        raise InputError(
            "the report paths don't match the checkout: none of the files in the report "
            f"resolves to a tracked file (report paths: {sample}). Check the report's path "
            "prefix and the working-directory."
        )

    # Changed files, for the not-in-report list only.
    code, out, err = run_git(
        ["diff", "-z", "--name-only", "--diff-filter=d", f"{base}...HEAD", "--", wd_rel],
        root,
        genv,
    )
    if code != 0:
        raise InputError(f"git diff failed: {err.strip()}")
    changed = [c for c in out.split("\0") if c and c.endswith(cfg["extensions"])]
    not_in_report = sorted(c for c in changed if c not in in_report)

    # diff-cover.
    json_path = os.path.join(tmp, "diff-cover.json")
    cmd = shlex.split(env["DIFF_COVER_CMD"]) if env.get("DIFF_COVER_CMD") else [
        sys.executable, "-m", "diff_cover.diff_cover_tool"
    ]
    argv = [
        *cmd, *diff_inputs, "--compare-branch", base,
        "--ignore-staged", "--ignore-unstaged", "--format", f"json:{json_path}",
    ]
    print("+ " + shlex.join(argv), flush=True)
    proc = subprocess.run(argv, cwd=wd, env=genv, capture_output=True, text=True, check=False)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    if proc.returncode != 0 or not os.path.isfile(json_path):
        raise InputError(f"diff-cover failed (exit {proc.returncode}); see its output above")
    try:
        with open(json_path, encoding="utf-8") as fh:
            result = json.load(fh)
        measured = int(result["total_num_lines"])
        uncovered = int(result["total_num_violations"])
        src_stats = result.get("src_stats") or {}
    except (ValueError, KeyError, TypeError) as e:
        raise InputError(f"cannot read diff-cover's JSON report: {e}")

    pct = 100.0 if measured == 0 else 100.0 * (measured - uncovered) / measured
    passed = measured == 0 or pct >= cfg["threshold"]
    summary = compose_summary(cfg, measured, uncovered, pct, passed, src_stats, total, not_in_report)
    print(summary)
    summary_file = env.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as fh:
            fh.write(summary)
    return (EXIT_PASS if passed else EXIT_GATE), summary, cfg


# ---- sticky PR comment -----------------------------------------------------

COMMENT_AUTHOR = "github-actions[bot]"  # the github.token user
LIST_JQ = ".[] | {id, user: .user.login, body}"
PERMISSION_HINT = "add `permissions: pull-requests: write` to the calling job"


class CommentError(Exception):
    """The comment couldn't be listed, edited or posted."""


def pull_request_number(env):
    path = env.get("GITHUB_EVENT_PATH")
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            number = (json.load(fh).get("pull_request") or {}).get("number")
    except (ValueError, OSError, AttributeError):
        return None
    return number if isinstance(number, int) else None


def parse_json_stream(text):
    decoder, i, out = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        obj, i = decoder.raw_decode(text, i)
        out.append(obj)


def gh_api(env, args):
    """Run `gh api`; on failure raise CommentError with the redacted stderr and HTTP status."""
    token = env.get("GH_TOKEN", "")
    try:
        proc = subprocess.run(["gh", "api", *args], env=env, capture_output=True, text=True, check=False)
    except OSError as e:
        raise CommentError(f"cannot run gh: {e}")
    if proc.returncode != 0:
        stderr = proc.stderr.replace(token, "***") if token else proc.stderr
        status = re.search(r"HTTP (\d{3})", stderr)
        raise CommentError(
            f"gh api failed (HTTP {status.group(1) if status else 'unknown'}): {stderr.strip()}. "
            f"If this is a permission error, {PERMISSION_HINT}."
        )
    return proc.stdout


def sticky_comment(env, cfg, summary, tmp):
    """Edit this label's comment on the PR, or post it. No PR: log and skip (AC 12)."""
    number = pull_request_number(env)
    if number is None:
        print("patch-coverage: no pull request in this event; job summary only, no comment")
        return
    repo = env.get("GITHUB_REPOSITORY", "")
    if not repo:
        raise CommentError("GITHUB_REPOSITORY is not set")
    base = f"repos/{repo}"
    marker = f"<!-- patch-coverage:{cfg['label']} -->"

    listing = gh_api(env, ["--paginate", f"{base}/issues/{number}/comments", "--jq", LIST_JQ])
    try:
        comments = parse_json_stream(listing)
    except ValueError as e:
        raise CommentError(f"cannot parse the comment list from gh: {e}")
    ids = sorted(
        c["id"]
        for c in comments
        if isinstance(c, dict)
        and c.get("user") == COMMENT_AUTHOR
        and marker in (c.get("body") or "")
        and isinstance(c.get("id"), int)
    )

    payload = os.path.join(tmp, "comment.json")
    with open(payload, "w", encoding="utf-8") as fh:
        json.dump({"body": marker + "\n" + summary}, fh)
    if ids:
        gh_api(env, ["--method", "PATCH", f"{base}/issues/comments/{ids[0]}", "--input", payload])
        print(f"patch-coverage: updated comment {ids[0]} for label {cfg['label']!r}")
    else:
        gh_api(env, ["--method", "POST", f"{base}/issues/{number}/comments", "--input", payload])
        print(f"patch-coverage: posted a comment for label {cfg['label']!r}")


def main(argv, env=None, cwd=None):
    env = dict(os.environ if env is None else env)
    cwd = cwd or os.getcwd()
    if argv[1:] != ["run"]:
        print("usage: patch_coverage.py run", file=sys.stderr)
        return EXIT_ERROR
    with tempfile.TemporaryDirectory(prefix="patch-coverage-") as tmp:
        try:
            code, summary, cfg = run(env, cwd, tmp)
        except InputError as e:
            print(f"patch-coverage: error: {e}", file=sys.stderr)
            return EXIT_ERROR
        try:
            sticky_comment(env, cfg, summary, tmp)
        except CommentError as e:
            print(f"patch-coverage: error: {e}", file=sys.stderr)
            if code == EXIT_PASS:  # the gate's own failure code wins when both fail
                code = EXIT_ERROR
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
