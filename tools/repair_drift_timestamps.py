"""Audit or repair millisecond values in Drift DateTime columns.

Drift stores DateTime values as integer epoch seconds. This tool is dry-run by
default. ``--apply`` creates an online SQLite backup before making an
idempotent, explicit-allowlist repair. Custom tables that intentionally use
epoch milliseconds, including ``project_git_remotes.checked_at``, are excluded.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path


EPOCH_SECOND_THRESHOLD = 100_000_000_000
LEGACY_MILLISECOND_UPPER_BOUND = 100_000_000_000_000
MIN_REPAIR_SECONDS = 946_684_800  # 2000-01-01 UTC
MAX_REPAIR_SECONDS = 4_133_980_800  # 2101-01-01 UTC


@dataclass(frozen=True)
class TimestampField:
    table: str
    column: str

    @property
    def key(self) -> str:
        return f"{self.table}.{self.column}"


# Keep synchronized with lib/db/timestamp_contract.dart. This is deliberately
# explicit so a schema review can prove that custom millisecond tables are not
# in repair scope.
DRIFT_TIMESTAMP_FIELDS = (
    TimestampField("projects", "created_at"),
    TimestampField("projects", "deleted_at"),
    TimestampField("stages", "created_at"),
    TimestampField("work_items", "due_at"),
    TimestampField("work_items", "updated_at"),
    TimestampField("work_items", "created_at"),
    TimestampField("work_items", "last_reviewed_at"),
    TimestampField("work_item_notes", "created_at"),
    TimestampField("work_item_notes", "updated_at"),
    TimestampField("work_item_analyses", "created_at"),
    TimestampField("drafts", "created_at"),
    TimestampField("drafts", "updated_at"),
    TimestampField("daily_reviews", "review_date"),
    TimestampField("daily_reviews", "created_at"),
    TimestampField("outbox_messages", "sent_at"),
    TimestampField("outbox_messages", "created_at"),
    TimestampField("event_log", "timestamp"),
    TimestampField("documents", "created_at"),
    TimestampField("documents", "updated_at"),
    TimestampField("documents", "deleted_at"),
    TimestampField("document_links", "created_at"),
    TimestampField("contacts", "created_at"),
    TimestampField("contacts", "updated_at"),
    TimestampField("project_people", "created_at"),
    TimestampField("project_risks", "created_at"),
    TimestampField("project_decisions", "created_at"),
    TimestampField("project_capsule_revisions", "accepted_at"),
    TimestampField("tags", "created_at"),
    TimestampField("tags", "updated_at"),
    TimestampField("project_tags", "created_at"),
    TimestampField("project_media", "file_modified_at"),
    TimestampField("project_media", "created_at"),
    TimestampField("project_media", "updated_at"),
    TimestampField("media_links", "created_at"),
    TimestampField("project_registry", "created_at"),
    TimestampField("project_registry", "updated_at"),
    TimestampField("project_registry", "last_reviewed_at"),
    TimestampField("project_observations", "observed_at"),
    TimestampField("project_scan_runs", "started_at"),
    TimestampField("project_scan_runs", "completed_at"),
    TimestampField("local_project_refresh_items", "last_imported_at"),
    TimestampField("project_runtime_profiles", "last_imported_at"),
    TimestampField("project_runtime_profiles", "created_at"),
    TimestampField("project_runtime_profiles", "updated_at"),
    TimestampField("project_runtime_runs", "started_at"),
    TimestampField("project_runtime_runs", "completed_at"),
)


def _quoted(identifier: str) -> str:
    if not identifier.replace("_", "").isalnum():
        raise ValueError(f"Unsafe SQLite identifier: {identifier!r}")
    return f'"{identifier}"'


def _require_contract(conn: sqlite3.Connection) -> None:
    tables = {
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }
    missing = []
    for field in DRIFT_TIMESTAMP_FIELDS:
        if field.table not in tables:
            missing.append(field.key)
            continue
        columns = {
            row[1]
            for row in conn.execute(f"PRAGMA table_info({_quoted(field.table)})")
        }
        if field.column not in columns:
            missing.append(field.key)
    if missing:
        raise RuntimeError("Timestamp contract fields missing: " + ", ".join(missing))


def _candidate_where(field: TimestampField) -> str:
    column = _quoted(field.column)
    return f"""
        typeof({column}) = 'integer'
        AND ABS({column}) >= {EPOCH_SECOND_THRESHOLD}
        AND ABS({column}) < {LEGACY_MILLISECOND_UPPER_BOUND}
        AND CAST({column} / 1000 AS INTEGER) >= {MIN_REPAIR_SECONDS}
        AND CAST({column} / 1000 AS INTEGER) < {MAX_REPAIR_SECONDS}
    """


def _invalid_where(field: TimestampField) -> str:
    column = _quoted(field.column)
    return f"""
        {column} IS NOT NULL AND (
          typeof({column}) != 'integer'
          OR ABS({column}) >= {EPOCH_SECOND_THRESHOLD}
        )
    """


def _counts(
    conn: sqlite3.Connection, *, invalid: bool = False
) -> dict[str, int]:
    result = {}
    for field in DRIFT_TIMESTAMP_FIELDS:
        where = _invalid_where(field) if invalid else _candidate_where(field)
        count = conn.execute(
            f"SELECT COUNT(*) FROM {_quoted(field.table)} WHERE {where}"
        ).fetchone()[0]
        if count:
            result[field.key] = int(count)
    return result


def _integrity(conn: sqlite3.Connection) -> tuple[str, int]:
    quick_check = conn.execute("PRAGMA quick_check").fetchone()[0]
    foreign_key_violations = len(conn.execute("PRAGMA foreign_key_check").fetchall())
    return str(quick_check), foreign_key_violations


def _custom_millisecond_snapshot(conn: sqlite3.Connection) -> tuple | None:
    exists = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='project_git_remotes'"
    ).fetchone()
    if exists is None:
        return None
    return tuple(
        conn.execute(
            "SELECT id, checked_at, remote_updated_at, remote_pushed_at "
            "FROM project_git_remotes ORDER BY id"
        ).fetchall()
    )


def _online_backup(source: sqlite3.Connection, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    destination = sqlite3.connect(path)
    try:
        source.backup(destination)
    finally:
        destination.close()


def _default_backup_path(db_path: Path) -> Path:
    stamp = time.strftime("%Y%m%d_%H%M%S")
    return db_path.with_name(
        f"{db_path.stem}.before_drift_timestamp_repair_{stamp}{db_path.suffix}"
    )


def audit_or_repair(
    db_path: Path,
    *,
    apply: bool = False,
    backup_path: Path | None = None,
) -> dict[str, object]:
    conn = sqlite3.connect(db_path, timeout=30)
    conn.execute("PRAGMA busy_timeout = 30000")
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        _require_contract(conn)
        quick_before, fk_before = _integrity(conn)
        if quick_before != "ok" or fk_before:
            raise RuntimeError(
                f"Preflight failed: quick_check={quick_before!r}, "
                f"foreign_key_violations={fk_before}"
            )
        before = _counts(conn)
        invalid_before = _counts(conn, invalid=True)
        custom_before = _custom_millisecond_snapshot(conn)

        result: dict[str, object] = {
            "mode": "apply" if apply else "dry_run",
            "database": str(db_path),
            "contractFieldCount": len(DRIFT_TIMESTAMP_FIELDS),
            "candidateCounts": before,
            "candidateTotal": sum(before.values()),
            "invalidCounts": invalid_before,
            "invalidTotal": sum(invalid_before.values()),
            "quickCheck": quick_before,
            "foreignKeyViolations": fk_before,
        }
        if not apply:
            return result

        backup = backup_path or _default_backup_path(db_path)
        _online_backup(conn, backup)
        backup_conn = sqlite3.connect(backup)
        try:
            _require_contract(backup_conn)
            backup_quick, backup_fk = _integrity(backup_conn)
            backup_counts = _counts(backup_conn)
        finally:
            backup_conn.close()
        if backup_quick != "ok" or backup_fk or backup_counts != before:
            raise RuntimeError("Backup readback did not match the source preflight")

        conn.execute("BEGIN IMMEDIATE")
        updated: dict[str, int] = {}
        try:
            for field in DRIFT_TIMESTAMP_FIELDS:
                column = _quoted(field.column)
                cursor = conn.execute(
                    f"UPDATE {_quoted(field.table)} "
                    f"SET {column} = CAST({column} / 1000 AS INTEGER) "
                    f"WHERE {_candidate_where(field)}"
                )
                if cursor.rowcount:
                    updated[field.key] = cursor.rowcount
            if updated != before:
                raise RuntimeError(
                    f"Repair count mismatch: expected={before!r}, updated={updated!r}"
                )

            # Apply the same statements again inside the transaction. A correct
            # migration is a no-op on the second pass.
            second_pass = 0
            for field in DRIFT_TIMESTAMP_FIELDS:
                column = _quoted(field.column)
                second_pass += conn.execute(
                    f"UPDATE {_quoted(field.table)} "
                    f"SET {column} = CAST({column} / 1000 AS INTEGER) "
                    f"WHERE {_candidate_where(field)}"
                ).rowcount
            if second_pass:
                raise RuntimeError(f"Repair was not idempotent: {second_pass} rows")

            after = _counts(conn)
            invalid_after = _counts(conn, invalid=True)
            custom_after = _custom_millisecond_snapshot(conn)
            quick_after, fk_after = _integrity(conn)
            if after or invalid_after:
                raise RuntimeError(
                    f"Timestamp violations remain: candidates={after!r}, "
                    f"invalid={invalid_after!r}"
                )
            if custom_after != custom_before:
                raise RuntimeError("Custom millisecond fields changed unexpectedly")
            if quick_after != "ok" or fk_after:
                raise RuntimeError(
                    f"Postflight failed: quick_check={quick_after!r}, "
                    f"foreign_key_violations={fk_after}"
                )
            conn.commit()
        except Exception:
            conn.rollback()
            raise

        result.update(
            {
                "backup": str(backup),
                "backupQuickCheck": backup_quick,
                "backupForeignKeyViolations": backup_fk,
                "updatedCounts": updated,
                "updatedTotal": sum(updated.values()),
                "secondPassUpdatedTotal": 0,
                "remainingInvalidTotal": 0,
                "customMillisecondFieldsUnchanged": True,
                "quickCheck": quick_after,
                "foreignKeyViolations": fk_after,
            }
        )
        return result
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("db_path", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--backup-path", type=Path)
    args = parser.parse_args()
    result = audit_or_repair(
        args.db_path,
        apply=args.apply,
        backup_path=args.backup_path,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
