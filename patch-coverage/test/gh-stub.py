#!/usr/bin/env python3
"""A stand-in for `gh api` over a directory ($GH_STUB_DIR) holding comments.json (the PR's
comments) and calls.log (one JSON argv per call). It accepts only the exact calls
patch_coverage.py is specified to make, and exits 3 on any other.

Failure knobs: GH_STUB_LIST_FAIL=<status> fails the list call, GH_STUB_WRITE_FAIL=<status>
fails POST and PATCH and writes $GH_TOKEN to stderr first, as a leaky gh would.
"""
import json
import os
import re
import sys

d = os.environ["GH_STUB_DIR"]
argv = sys.argv[1:]
with open(os.path.join(d, "calls.log"), "a") as fh:
    fh.write(json.dumps(argv) + "\n")
store = os.path.join(d, "comments.json")
comments = json.load(open(store)) if os.path.exists(store) else []
repo, pr = "o/r", 7
JQ = ".[] | {id, user: .user.login, body}"


def fail(status):
    sys.stderr.write(f"token={os.environ.get('GH_TOKEN', '')}\n")
    sys.stderr.write(f"gh: Resource not accessible by integration (HTTP {status})\n")
    sys.exit(1)


def unexpected():
    sys.stderr.write(f"gh-stub: unexpected call {argv}\n")
    sys.exit(3)


if argv[:1] != ["api"]:
    unexpected()
rest = argv[1:]
if rest == ["--paginate", f"repos/{repo}/issues/{pr}/comments", "--jq", JQ]:
    if os.environ.get("GH_STUB_LIST_FAIL"):
        fail(os.environ["GH_STUB_LIST_FAIL"])
    for c in comments:
        print(json.dumps(c))
    sys.exit(0)

m = re.fullmatch(r"--method (POST|PATCH) (\S+) --input (\S+)", " ".join(rest))
if not m:
    unexpected()
method, path, payload = m.groups()
if os.environ.get("GH_STUB_WRITE_FAIL"):
    fail(os.environ["GH_STUB_WRITE_FAIL"])
body = json.load(open(payload))["body"]
if method == "POST" and path == f"repos/{repo}/issues/{pr}/comments":
    comments.append({"id": 100 + len(comments), "user": "github-actions[bot]", "body": body})
elif method == "PATCH" and (n := re.fullmatch(rf"repos/{repo}/issues/comments/(\d+)", path)):
    hit = [c for c in comments if c["id"] == int(n.group(1))]
    if not hit:
        unexpected()
    hit[0]["body"] = body
else:
    unexpected()
json.dump(comments, open(store, "w"))
