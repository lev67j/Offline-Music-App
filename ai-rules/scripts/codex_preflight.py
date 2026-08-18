#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class PreflightReport:
    repo_root: str
    branch: str
    upstream: str | None
    ahead: int | None
    behind: int | None
    staged: list[str]
    unstaged: list[str]
    untracked: list[str]
    conflicts: list[str]

    @property
    def dirty(self) -> bool:
        return bool(self.staged or self.unstaged or self.untracked or self.conflicts)


def run_git(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def require_git(args: list[str], cwd: Path) -> str:
    result = run_git(args, cwd)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(message or f"git {' '.join(args)} failed")
    return result.stdout.rstrip("\n")


def split_status(status: str) -> tuple[list[str], list[str], list[str], list[str]]:
    staged: list[str] = []
    unstaged: list[str] = []
    untracked: list[str] = []
    conflicts: list[str] = []

    for line in status.splitlines():
        if not line:
            continue
        code = line[:2]
        path = line[3:]
        if code == "??":
            untracked.append(path)
            continue
        if "U" in code or code in {"AA", "DD"}:
            conflicts.append(path)
            continue
        if code[0] != " ":
            staged.append(path)
        if code[1] != " ":
            unstaged.append(path)

    return staged, unstaged, untracked, conflicts


def build_report(cwd: Path) -> PreflightReport:
    repo_root = Path(require_git(["rev-parse", "--show-toplevel"], cwd))
    branch = require_git(["branch", "--show-current"], repo_root) or "DETACHED_HEAD"

    upstream_result = run_git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], repo_root)
    upstream = upstream_result.stdout.strip() if upstream_result.returncode == 0 else None
    ahead: int | None = None
    behind: int | None = None
    if upstream:
        counts = require_git(["rev-list", "--left-right", "--count", f"{upstream}...HEAD"], repo_root)
        behind_text, ahead_text = counts.split()
        behind = int(behind_text)
        ahead = int(ahead_text)

    staged, unstaged, untracked, conflicts = split_status(
        require_git(["status", "--porcelain"], repo_root)
    )

    return PreflightReport(
        repo_root=str(repo_root),
        branch=branch,
        upstream=upstream,
        ahead=ahead,
        behind=behind,
        staged=staged,
        unstaged=unstaged,
        untracked=untracked,
        conflicts=conflicts,
    )


def print_human(report: PreflightReport) -> None:
    print(f"repo: {report.repo_root}")
    print(f"branch: {report.branch}")
    if report.upstream:
        print(f"upstream: {report.upstream} (ahead {report.ahead}, behind {report.behind})")
    else:
        print("upstream: none")

    sections = (
        ("staged", report.staged),
        ("unstaged", report.unstaged),
        ("untracked", report.untracked),
        ("conflicts", report.conflicts),
    )
    for title, items in sections:
        print(f"{title}: {len(items)}")
        for item in items:
            print(f"  {item}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Non-mutating git preflight check for AI coding sessions.")
    parser.add_argument("--cwd", default=".", help="Repository path to inspect.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument("--fail-on-dirty", action="store_true", help="Exit non-zero when the worktree is dirty.")
    parser.add_argument("--fail-on-conflicts", action="store_true", help="Exit non-zero when merge conflicts exist.")
    parser.add_argument("--fail-on-no-upstream", action="store_true", help="Exit non-zero when the branch has no upstream.")
    args = parser.parse_args()

    try:
        report = build_report(Path(args.cwd).resolve())
    except Exception as exc:
        print(f"preflight failed: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(asdict(report), indent=2, sort_keys=True))
    else:
        print_human(report)

    failed = False
    if args.fail_on_dirty and report.dirty:
        print("failure: worktree is dirty", file=sys.stderr)
        failed = True
    if args.fail_on_conflicts and report.conflicts:
        print("failure: merge conflicts exist", file=sys.stderr)
        failed = True
    if args.fail_on_no_upstream and report.upstream is None:
        print("failure: branch has no upstream", file=sys.stderr)
        failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
