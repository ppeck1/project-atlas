"""Import Dev Launchpad runtime metadata into the live Project Atlas DB.

Dry-run by default. Use --apply to write profiles for exact title matches.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import time
from pathlib import Path
from typing import Any

import yaml


DEFAULT_YAML_PATH = Path(
    r"B:\dev\dev.launchpad\dev_launchpad_v0_3_public\dist\dev_launchpad.yaml"
)
DEFAULT_DB_PATH = Path(
    r"C:\Users\peckm\AppData\Roaming\Paul Peck\Project Atlas\project_atlas.sqlite"
)
DEFAULT_CAPSULE_PATH = Path(r"B:\Projects\LLM_Modules\Project_Ops_Capsule")


def _blank_to_none(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _list_of_strings(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if _blank_to_none(item)]
    text = _blank_to_none(value)
    return [] if text is None else [text]


def _list_of_ports(value: Any) -> list[int]:
    ports: list[int] = []
    for item in _list_of_strings(value):
        try:
            ports.append(int(item))
        except ValueError:
            continue
    return ports


def _list_of_urls(value: Any) -> list[dict[str, str]]:
    urls: list[dict[str, str]] = []
    if not isinstance(value, list):
        return urls
    for item in value:
        if not isinstance(item, dict):
            continue
        url = _blank_to_none(item.get("url"))
        if url is None:
            continue
        label = _blank_to_none(item.get("label")) or url
        urls.append({"label": label, "url": url})
    return urls


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def _load_apps(yaml_path: Path) -> list[dict[str, Any]]:
    with yaml_path.open("r", encoding="utf-8") as handle:
        decoded = yaml.safe_load(handle) or {}
    apps = decoded.get("apps", [])
    if not isinstance(apps, list):
        raise ValueError(f"Expected YAML apps list in {yaml_path}")
    return [app for app in apps if isinstance(app, dict)]


def _profile_from_app(app: dict[str, Any], yaml_path: Path, now_ms: int) -> dict[str, Any]:
    return {
        "enabled": 1,
        "working_directory": _blank_to_none(app.get("path")),
        "launch_command": _blank_to_none(app.get("start")),
        "stop_command": _blank_to_none(app.get("stop")),
        "test_commands_json": _json(_list_of_strings(app.get("tests"))),
        "ports_json": _json(_list_of_ports(app.get("ports"))),
        "urls_json": _json(_list_of_urls(app.get("urls"))),
        "health_urls_json": _json(_list_of_strings(app.get("health_urls"))),
        "notes": _blank_to_none(app.get("notes")),
        "autostart": 1 if app.get("autostart") is True else 0,
        "capsule_enabled": 1,
        "capsule_mode": "check",
        "capsule_source_path": str(DEFAULT_CAPSULE_PATH),
        "capsule_profile": "software_project",
        "import_source": str(yaml_path),
        "last_imported_at": now_ms,
    }


def _backup_db(db_path: Path) -> Path:
    backup_dir = Path.cwd() / ".project" / "db_backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    backup_path = backup_dir / f"project_atlas_before_runtime_import_{stamp}.sqlite"
    shutil.copy2(db_path, backup_path)
    return backup_path


def _verify_profiles(
    con: sqlite3.Connection,
    matched: list[tuple[dict[str, Any], sqlite3.Row, str]],
    yaml_path: Path,
) -> int:
    checks = [
        "enabled",
        "working_directory",
        "launch_command",
        "stop_command",
        "test_commands_json",
        "ports_json",
        "urls_json",
        "health_urls_json",
        "notes",
        "autostart",
        "capsule_enabled",
        "capsule_mode",
        "capsule_source_path",
        "capsule_profile",
        "import_source",
    ]
    failures = 0
    for app, project, _action in matched:
        expected = _profile_from_app(app, yaml_path, now_ms=0)
        row = con.execute(
            "SELECT * FROM project_runtime_profiles WHERE project_id = ?",
            (project["id"],),
        ).fetchone()
        if row is None:
            print(f"VERIFY_MISSING|{app['name']}|{project['id']}")
            failures += 1
            continue
        mismatches = []
        for key in checks:
            if row[key] != expected[key]:
                mismatches.append(key)
        if mismatches:
            print(
                f"VERIFY_MISMATCH|{app['name']}|{project['id']}|"
                + ",".join(mismatches)
            )
            failures += 1
        else:
            print(f"VERIFY_OK|{app['name']}|{project['id']}")
    print(f"VERIFY_SUMMARY|checked={len(matched)}|failures={failures}")
    return failures


def import_runtime(yaml_path: Path, db_path: Path, apply: bool, verify: bool) -> int:
    apps = _load_apps(yaml_path)
    now_ms = int(time.time() * 1000)
    con = sqlite3.connect(db_path, timeout=30)
    con.row_factory = sqlite3.Row
    try:
        projects = {
            row["title"].strip().casefold(): row
            for row in con.execute(
                "SELECT id, title FROM projects WHERE deleted_at IS NULL"
            )
        }
        existing = {
            row["project_id"]: row
            for row in con.execute(
                "SELECT id, project_id, created_at FROM project_runtime_profiles"
            )
        }
        matched: list[tuple[dict[str, Any], sqlite3.Row, str]] = []
        skipped: list[str] = []
        for app in apps:
            name = _blank_to_none(app.get("name"))
            if name is None:
                continue
            project = projects.get(name.casefold())
            if project is None:
                skipped.append(name)
                continue
            action = "update" if project["id"] in existing else "insert"
            matched.append((app, project, action))

        print(f"YAML apps: {len(apps)}")
        print(f"Matched Atlas projects: {len(matched)}")
        for app, project, action in matched:
            print(f"{action.upper()}|{app['name']}|{project['id']}|{project['title']}")
        print(f"Skipped YAML entries: {len(skipped)}")
        for name in skipped:
            print(f"SKIP|{name}")

        if verify:
            return 1 if _verify_profiles(con, matched, yaml_path) else 0

        if not apply:
            print("DRY_RUN|no database changes written")
            return 0

        backup_path = _backup_db(db_path)
        print(f"BACKUP|{backup_path}")

        with con:
            for app, project, _action in matched:
                profile = _profile_from_app(app, yaml_path, now_ms)
                current = existing.get(project["id"])
                profile_id = (
                    current["id"]
                    if current is not None
                    else f"runtime_{int(time.time() * 1000000)}"
                )
                created_at = current["created_at"] if current is not None else now_ms
                con.execute(
                    """
                    INSERT INTO project_runtime_profiles (
                        id, project_id, enabled, working_directory, launch_command,
                        stop_command, test_commands_json, ports_json, urls_json,
                        health_urls_json, notes, autostart, capsule_enabled,
                        capsule_mode, capsule_source_path, capsule_profile,
                        import_source, last_imported_at, created_at, updated_at
                    ) VALUES (
                        :id, :project_id, :enabled, :working_directory,
                        :launch_command, :stop_command, :test_commands_json,
                        :ports_json, :urls_json, :health_urls_json, :notes,
                        :autostart, :capsule_enabled, :capsule_mode,
                        :capsule_source_path, :capsule_profile, :import_source,
                        :last_imported_at, :created_at, :updated_at
                    )
                    ON CONFLICT(project_id) DO UPDATE SET
                        enabled=excluded.enabled,
                        working_directory=excluded.working_directory,
                        launch_command=excluded.launch_command,
                        stop_command=excluded.stop_command,
                        test_commands_json=excluded.test_commands_json,
                        ports_json=excluded.ports_json,
                        urls_json=excluded.urls_json,
                        health_urls_json=excluded.health_urls_json,
                        notes=excluded.notes,
                        autostart=excluded.autostart,
                        capsule_enabled=excluded.capsule_enabled,
                        capsule_mode=excluded.capsule_mode,
                        capsule_source_path=excluded.capsule_source_path,
                        capsule_profile=excluded.capsule_profile,
                        import_source=excluded.import_source,
                        last_imported_at=excluded.last_imported_at,
                        updated_at=excluded.updated_at
                    """,
                    {
                        **profile,
                        "id": profile_id,
                        "project_id": project["id"],
                        "created_at": created_at,
                        "updated_at": now_ms,
                    },
                )
                time.sleep(0.000001)
        print(f"APPLIED|profiles={len(matched)}")
    finally:
        con.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--yaml-path", type=Path, default=DEFAULT_YAML_PATH)
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB_PATH)
    args = parser.parse_args()
    return import_runtime(args.yaml_path, args.db_path, args.apply, args.verify)


if __name__ == "__main__":
    raise SystemExit(main())
