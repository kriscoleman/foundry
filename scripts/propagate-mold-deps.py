#!/usr/bin/env python3
"""Propagate a mold release up the dependency DAG.

When release-please cuts a release for a leaf mold, any super-mold (aggregate)
that declares a dependency on it needs its own release so its published version
reflects the updated dependency. This script performs that propagation: for each
just-released mold it finds the dependents by parsing every ``molds/*/mold.yaml``
``dependencies:`` block and bumps the matching dependency's constraint floor to
``^<new-version>`` — a real, honest diff that release-please then turns into the
aggregate's release PR.

The dependency graph is a DAG, so a single hop per invocation (leaf -> its direct
dependents) plus release-please re-running on each human merge produces a
terminating cascade (leaf -> con-voyage-personas -> con-voyage).

Released molds are supplied either as repeatable ``--released <path>=<version>``
args (used by the offline unit tests) or via the ``RP_OUTPUTS`` environment
variable (the JSON blob of release-please-action outputs, used by CI).

By default the script only edits files and prints a JSON summary. Pass
``--commit`` to create one conventional commit per changed aggregate and
``--push`` to push them to ``origin``.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = "github.com/kriscoleman/foundry"
# A dependency entry is a `- mold: <repo>//molds/<name>` line followed (before the
# next list item) by its `version:` constraint line.
DEP_MOLD = re.compile(
    r'^\s*-\s*mold:\s*' + re.escape(REPO) + r'//molds/([a-z0-9][a-z0-9-]*)\s*$'
)
VERSION_LINE = re.compile(r'^(?P<indent>\s*)version:\s*"?\^?(?P<ver>\d+\.\d+\.\d+)"?\s*$')
NEXT_ITEM = re.compile(r'^\s*-\s')


def semver(v: str) -> tuple:
    return tuple(int(x) for x in v.split("."))


def bump_kind(old: str, new: str) -> str:
    """'patch' if only the patch component grew, else 'minor' (covers minor+major)."""
    o, n = semver(old), semver(new)
    return "patch" if (n[0], n[1]) == (o[0], o[1]) else "minor"


def update_mold(mold_yaml: Path, released: dict) -> list:
    """Bump matching dependency floors in one mold.yaml. Returns list of changes.

    released: {mold_name: new_version}. Only bumps when new_version > current floor.
    """
    lines = mold_yaml.read_text().splitlines(keepends=True)
    changes = []
    i = 0
    while i < len(lines):
        m = DEP_MOLD.match(lines[i])
        if not m:
            i += 1
            continue
        dep_name = m.group(1)
        # find this dependency's version line before the next list item
        j = i + 1
        while j < len(lines) and not NEXT_ITEM.match(lines[j]):
            vm = VERSION_LINE.match(lines[j])
            if vm:
                break
            j += 1
        else:
            i += 1
            continue
        if j >= len(lines):
            i += 1
            continue
        vm = VERSION_LINE.match(lines[j])
        if vm and dep_name in released:
            old, new = vm.group("ver"), released[dep_name]
            if semver(new) > semver(old):
                lines[j] = f'{vm.group("indent")}version: "^{new}"\n'
                changes.append({"name": dep_name, "from": old, "to": new})
        i = j + 1
    if changes:
        mold_yaml.write_text("".join(lines))
    return changes


def parse_released_args(pairs: list) -> dict:
    """['molds/security-reviewer=0.1.1'] -> {'security-reviewer': '0.1.1'}."""
    out = {}
    for p in pairs:
        path, _, ver = p.partition("=")
        out[Path(path).name] = ver
    return out


def parse_rp_outputs(blob: str) -> dict:
    """release-please-action outputs JSON -> {mold_name: version} for released paths."""
    out = {}
    data = json.loads(blob)
    paths = data.get("paths_released")
    paths = json.loads(paths) if isinstance(paths, str) else (paths or [])
    for path in paths:
        ver = data.get(f"{path}--version")
        if ver:
            out[Path(path).name] = ver
    return out


def git(*args) -> None:
    subprocess.run(["git", *args], check=True)


def commit_aggregate(name: str, changes: list) -> None:
    kind = "feat" if any(bump_kind(c["from"], c["to"]) == "minor" for c in changes) else "fix"
    summary = ", ".join(f'{c["name"]} to {c["to"]}' for c in changes)
    git("-c", "user.name=release-please[bot]",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "add", f"molds/{name}/mold.yaml")
    git("-c", "user.name=release-please[bot]",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "commit", "-m", f"{kind}({name}): bump {summary}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Propagate mold releases to dependents.")
    ap.add_argument("--released", action="append", default=[],
                    help="repeatable <path>=<version> of a just-released mold")
    ap.add_argument("--commit", action="store_true", help="commit each changed aggregate")
    ap.add_argument("--push", action="store_true", help="push commits to origin (implies --commit)")
    args = ap.parse_args()

    released = parse_released_args(args.released)
    if not released and os.environ.get("RP_OUTPUTS"):
        released = parse_rp_outputs(os.environ["RP_OUTPUTS"])

    if not released:
        print("propagate: no released molds provided; nothing to do.")
        return 0

    summary = []
    for mold_yaml in sorted(Path("molds").glob("*/mold.yaml")):
        name = mold_yaml.parent.name
        if name in released:
            continue  # a mold never depends on itself
        changes = update_mold(mold_yaml, released)
        if changes:
            kind = "feat" if any(bump_kind(c["from"], c["to"]) == "minor" for c in changes) else "fix"
            summary.append({"aggregate": name, "bump": kind, "deps": changes})

    print(json.dumps({"released": released, "propagated": summary}, indent=2))

    if not summary:
        print("propagate: no dependents needed a bump.")
        return 0

    if args.commit or args.push:
        for entry in summary:
            commit_aggregate(entry["aggregate"], entry["deps"])
        if args.push:
            git("push", "origin", "HEAD:main")

    return 0


if __name__ == "__main__":
    sys.exit(main())
