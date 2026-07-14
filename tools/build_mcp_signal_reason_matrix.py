#!/usr/bin/env python3
"""Build a public-safe portfolio signal matrix from live local Atlas reads."""

from __future__ import annotations

import argparse
import json
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from atlas_mcp_remote_policy import (
        RemoteCallContext,
        load_disclosure_policy,
        project_remote_tool_response,
    )
except ModuleNotFoundError:
    from tools.atlas_mcp_remote_policy import (
        RemoteCallContext,
        load_disclosure_policy,
        project_remote_tool_response,
    )


def _rpc_payload() -> str:
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "list_projects",
                "arguments": {"includeArchived": False},
            },
        },
    ]
    return "\n".join(json.dumps(request) for request in requests) + "\n"


def read_local_projects(executable: Path) -> dict[str, Any]:
    process = subprocess.run(
        [str(executable), "--mcp-stdio"],
        input=_rpc_payload(),
        text=True,
        capture_output=True,
        timeout=90,
        check=False,
    )
    if process.returncode:
        raise RuntimeError(
            f"local Atlas MCP failed with {process.returncode}: "
            f"{process.stderr[:500]}"
        )
    responses = [
        json.loads(line) for line in process.stdout.splitlines() if line.strip()
    ]
    return next(response for response in responses if response.get("id") == 2)


def project_inventory(
    local_response: dict[str, Any], policy_path: Path
) -> dict[str, Any]:
    policy = load_disclosure_policy(policy_path)
    outcome = project_remote_tool_response(
        local_response,
        RemoteCallContext("list_projects", offset=0, limit=64),
        policy,
        max_response_bytes=65_536,
    )
    content = outcome.response["result"]["content"]
    return json.loads(content[0]["text"])


def render_reason_matrix(
    projected: dict[str, Any], *, captured_at: str, source_commit: str
) -> str:
    projects = projected.get("projects")
    page = projected.get("page")
    if not isinstance(projects, list) or not isinstance(page, dict):
        raise ValueError("projected inventory has an unexpected shape")
    if page.get("truncated") or page.get("returned") != page.get("total"):
        raise ValueError("reason matrix requires one complete inventory page")

    freshness_counts = Counter()
    planning_counts = Counter()
    refresh_counts = Counter()
    severity_counts = Counter()
    rows: list[str] = []
    for project in projects:
        freshness = project.get("freshness") or {}
        signals = project.get("signals") or {}
        freshness_status = str(freshness.get("status", "unknown"))
        planning = signals.get("planningActionRequired") is True
        refresh = signals.get("dataRefreshRequired") is True
        severity = str(signals.get("severity", "none"))
        classes = signals.get("reasonClasses") or []
        freshness_counts[freshness_status] += 1
        planning_counts[planning] += 1
        refresh_counts[refresh] += 1
        severity_counts[severity] += 1
        rows.append(
            "| {alias} | {title} | {status} | {freshness} | {planning} | "
            "{refresh} | {severity} | {classes} |".format(
                alias=project["projectId"],
                title=str(project["title"]).replace("|", "\\|"),
                status=project["status"],
                freshness=freshness_status,
                planning="yes" if planning else "no",
                refresh="yes" if refresh else "no",
                severity=severity,
                classes=", ".join(classes) if classes else "none",
            )
        )

    lines = [
        "# MCP Portfolio Signal Reason Matrix - 2026-07-14",
        "",
        "- Work order: `WO-PSC-1`",
        f"- Captured: `{captured_at}`",
        f"- Accepted runtime source: `{source_commit}`",
        f"- Projected schema: `{projected.get('schema')}`",
        "- Projection semantics: WO-PSC-1 candidate source applied to the accepted runtime read; this is pre-activation evidence",
        "- Scope: all operator-approved inventory aliases and labels; no local IDs, paths, notes, commands, or raw evidence",
        "- Data action: read-only baseline; no bulk freshness or lifecycle cleanup was performed",
        "",
        "## Summary",
        "",
        "| Measure | Count |",
        "|---|---:|",
        f"| Approved inventory | {len(projects)} |",
        f"| Planning action required | {planning_counts[True]} |",
        f"| Planning action not required | {planning_counts[False]} |",
        f"| Data refresh required | {refresh_counts[True]} |",
        f"| Data refresh not required | {refresh_counts[False]} |",
        f"| Freshness current | {freshness_counts['current']} |",
        f"| Freshness stale | {freshness_counts['stale']} |",
        f"| Freshness unknown | {freshness_counts['unknown']} |",
        f"| Severity high | {severity_counts['high']} |",
        f"| Severity medium | {severity_counts['medium']} |",
        f"| Severity low | {severity_counts['low']} |",
        f"| Severity none | {severity_counts['none']} |",
        "",
        "## Matrix",
        "",
        "`planningActionRequired` identifies project/workload decisions or blockers. `dataRefreshRequired` identifies evidence maintenance. `stale` and `unknown` remain distinct and are never bulk-cleared by this work order.",
        "",
        "| Alias | Approved label | Lifecycle | Freshness | Planning | Data refresh | Severity | Sanitized reason classes |",
        "|---|---|---|---|---|---|---|---|",
        *rows,
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--captured-at")
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--expected-count", type=int, default=49)
    args = parser.parse_args()

    projected = project_inventory(read_local_projects(args.exe), args.policy)
    projects = projected.get("projects")
    if not isinstance(projects, list) or len(projects) != args.expected_count:
        raise RuntimeError(
            f"expected {args.expected_count} approved projects, got "
            f"{len(projects) if isinstance(projects, list) else 'invalid'}"
        )
    args.output.write_text(
        render_reason_matrix(
            projected,
            captured_at=args.captured_at
            or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            source_commit=args.source_commit,
        ),
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "output": str(args.output),
                "projects": len(projects),
                "schema": projected.get("schema"),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
