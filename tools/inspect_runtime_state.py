"""Print recent Project Atlas runtime rows for launch troubleshooting.

Pass --db-path with the SQLite file for the local profile you want to inspect.
The default points at an ignored repo-local placeholder so this script remains
safe in the public repository.
"""

from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path


DEFAULT_DB_PATH = Path(".local/project_atlas.sqlite")


def _short(value: object, limit: int = 1200) -> str:
    if value is None:
        return ""
    text = str(value)
    return text if len(text) <= limit else text[:limit] + "...[truncated]"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--project", action="append")
    parser.add_argument("--limit", type=int, default=12)
    args = parser.parse_args()

    if not args.db_path.exists():
        parser.error(
            f"database not found: {args.db_path}. "
            "Pass --db-path pointing at your local Project Atlas SQLite file."
        )

    con = sqlite3.connect(args.db_path)
    con.row_factory = sqlite3.Row
    try:
        project_filter = args.project or []
        if project_filter:
            placeholders = ",".join("?" for _ in project_filter)
            profile_where = f"WHERE p.title IN ({placeholders})"
            params: list[object] = list(project_filter)
        else:
            profile_where = ""
            params = []

        print("PROFILES")
        for row in con.execute(
            f"""
            SELECT p.title, r.enabled, r.working_directory, r.launch_command,
                   r.stop_command, r.test_commands_json, r.ports_json,
                   r.urls_json, r.health_urls_json, r.capsule_enabled,
                   r.capsule_mode, r.capsule_source_path, r.capsule_profile
              FROM project_runtime_profiles r
              JOIN projects p ON p.id = r.project_id
              {profile_where}
             ORDER BY lower(p.title)
            """,
            params,
        ):
            print("---")
            for key in row.keys():
                print(f"{key}: {_short(row[key])}")

        run_params: list[object] = []
        run_where = ""
        if project_filter:
            placeholders = ",".join("?" for _ in project_filter)
            run_where = f"WHERE p.title IN ({placeholders})"
            run_params.extend(project_filter)
        run_params.append(args.limit)

        print("RUNS")
        for row in con.execute(
            f"""
            SELECT rr.started_at, rr.completed_at, p.title, rr.action,
                   rr.command, rr.status, rr.exit_code, rr.error_text,
                   rr.output_text, rr.capsule_status, rr.capsule_output_text
              FROM project_runtime_runs rr
              JOIN projects p ON p.id = rr.project_id
              {run_where}
             ORDER BY rr.started_at DESC
             LIMIT ?
            """,
            run_params,
        ):
            print("---")
            for key in row.keys():
                print(f"{key}: {_short(row[key])}")
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
