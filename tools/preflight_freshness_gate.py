"""Project Atlas preflight freshness gate.

Checks the local checkout, public GitHub main, latest CI, portfolio docs, and
real application README screenshots before release work begins.
The gate is intentionally fail-closed: missing evidence is a blocked result,
not a model assertion.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REQUIRED_DOCS = (
    "README.md",
    "HANDOFF.md",
    "SECURITY.md",
    "docs/ARCHITECTURE.md",
    "docs/DATA_MODEL.md",
    "docs/MCP_SECURITY_MODEL.md",
    "docs/VARIABLE_MATRIX.md",
)

README_SCREENSHOTS = (
    "docs/screenshots/today.png",
    "docs/screenshots/projects.png",
    "docs/screenshots/workboard.png",
    "docs/screenshots/capsule.png",
    "docs/screenshots/operations-project-sources.png",
    "docs/screenshots/library.png",
)

@dataclass(frozen=True)
class CommandResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


def run(args: list[str], cwd: Path, timeout: int = 30) -> CommandResult:
    try:
        completed = subprocess.run(
            args,
            cwd=str(cwd),
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        return CommandResult(
            args=args,
            returncode=completed.returncode,
            stdout=completed.stdout.strip(),
            stderr=completed.stderr.strip(),
        )
    except FileNotFoundError as error:
        return CommandResult(args=args, returncode=127, stdout="", stderr=str(error))
    except subprocess.TimeoutExpired as error:
        return CommandResult(
            args=args,
            returncode=124,
            stdout=(error.stdout or "").strip(),
            stderr=f"Timed out after {timeout}s",
        )


def step(name: str, status: str, summary: str, **details: Any) -> dict[str, Any]:
    return {
        "name": name,
        "status": status,
        "summary": summary,
        "details": details,
    }


def command_step(
    name: str,
    result: CommandResult,
    ok_summary: str,
    fail_summary: str,
    blocked: bool = True,
) -> dict[str, Any]:
    status = "ok" if result.returncode == 0 else ("blocked" if blocked else "warn")
    return step(
        name,
        status,
        ok_summary if result.returncode == 0 else fail_summary,
        command=" ".join(result.args),
        exitCode=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )


def check_git(repo: Path, github_repo: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    status = run(["git", "status", "--short", "--branch"], repo)
    if status.returncode != 0:
        results.append(
            command_step(
                "git_status",
                status,
                "Local git status is readable.",
                "Local git status could not be read.",
            )
        )
        return results

    lines = [line for line in status.stdout.splitlines() if line.strip()]
    dirty_lines = lines[1:]
    branch_line = lines[0] if lines else ""
    branch_clean = not dirty_lines and "ahead" not in branch_line and "behind" not in branch_line
    results.append(
        step(
            "git_status",
            "ok" if branch_clean else "blocked",
            "Local checkout is clean and not ahead/behind origin."
            if branch_clean
            else "Local checkout is dirty or branch is ahead/behind origin.",
            branchLine=branch_line,
            dirtyCount=len(dirty_lines),
            dirtyPreview=dirty_lines[:25],
        )
    )

    head = run(["git", "rev-parse", "HEAD"], repo)
    remote = run(["git", "ls-remote", "origin", "refs/heads/main"], repo)
    if head.returncode == 0 and remote.returncode == 0 and remote.stdout:
        remote_sha = remote.stdout.split()[0]
        local_sha = head.stdout.strip()
        matches = local_sha == remote_sha
        results.append(
            step(
                "git_remote_main",
                "ok" if matches else "blocked",
                "Local HEAD matches origin/main."
                if matches
                else "Local HEAD does not match origin/main.",
                localHead=local_sha,
                originMain=remote_sha,
            )
        )
    else:
        results.append(
            step(
                "git_remote_main",
                "blocked",
                "Could not compare local HEAD to origin/main.",
                headExitCode=head.returncode,
                headStderr=head.stderr,
                remoteExitCode=remote.returncode,
                remoteStderr=remote.stderr,
            )
        )

    gh = run(
        [
            "gh",
            "run",
            "list",
            "--repo",
            github_repo,
            "--branch",
            "main",
            "--limit",
            "1",
            "--json",
            "databaseId,status,conclusion,headSha,workflowName,createdAt",
        ],
        repo,
        timeout=45,
    )
    if gh.returncode != 0:
        results.append(
            command_step(
                "github_actions_latest_main",
                gh,
                "Latest GitHub Actions main run was read.",
                "Latest GitHub Actions main run could not be read.",
            )
        )
    else:
        try:
            runs = json.loads(gh.stdout)
        except json.JSONDecodeError as error:
            results.append(
                step(
                    "github_actions_latest_main",
                    "blocked",
                    "GitHub Actions output was not valid JSON.",
                    error=str(error),
                    stdout=gh.stdout,
                )
            )
        else:
            latest = runs[0] if runs else None
            green = latest is not None and latest.get("conclusion") == "success"
            results.append(
                step(
                    "github_actions_latest_main",
                    "ok" if green else "blocked",
                    "Latest GitHub Actions main run is green."
                    if green
                    else "Latest GitHub Actions main run is not green.",
                    latestRun=latest,
                )
            )
    return results


def check_docs(repo: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for relative in REQUIRED_DOCS:
        path = repo / relative
        present = path.exists() and path.stat().st_size > 0
        results.append(
            step(
                f"doc_{relative.replace('/', '_')}",
                "ok" if present else "blocked",
                f"{relative} is present." if present else f"{relative} is missing or empty.",
                path=str(path),
                bytes=path.stat().st_size if path.exists() else 0,
            )
        )
    return results


def check_screenshots(repo: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for relative in README_SCREENSHOTS:
        path = repo / relative
        present = path.exists() and path.stat().st_size > 10_000
        results.append(
            step(
                f"screenshot_{Path(relative).stem}",
                "ok" if present else "blocked",
                f"{relative} is present and non-trivial."
                if present
                else f"{relative} is missing or suspiciously small.",
                path=str(path),
                bytes=path.stat().st_size if path.exists() else 0,
            )
        )
    return results


def build_report(repo: Path, github_repo: str) -> dict[str, Any]:
    repo = repo.resolve()
    checks = [
        *check_git(repo, github_repo),
        *check_docs(repo),
        *check_screenshots(repo),
    ]
    blocked = [item for item in checks if item["status"] == "blocked"]
    warnings = [item for item in checks if item["status"] == "warn"]
    return {
        "schema": "project_atlas_preflight_freshness_report_v1",
        "repo": str(repo),
        "githubRepo": github_repo,
        "status": "blocked" if blocked else "ok",
        "blockedCount": len(blocked),
        "warningCount": len(warnings),
        "checks": checks,
    }


def markdown_report(report: dict[str, Any]) -> str:
    lines = [
        "# Project Atlas Preflight Freshness Report",
        "",
        f"Status: `{report['status']}`",
        f"Repo: `{report['repo']}`",
        f"GitHub: `{report['githubRepo']}`",
        "",
        "| Check | Status | Summary |",
        "|---|---|---|",
    ]
    for item in report["checks"]:
        lines.append(f"| {item['name']} | {item['status']} | {item['summary']} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parents[1]),
        help="Project Atlas repo root.",
    )
    parser.add_argument(
        "--github-repo",
        default="ppeck1/project-atlas",
        help="GitHub owner/repo to check.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print JSON instead of Markdown.",
    )
    args = parser.parse_args()

    report = build_report(Path(args.repo), args.github_repo)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(markdown_report(report), end="")
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
