from __future__ import annotations

import re
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path

from tools import apply_owner_continuity
from tools import import_runtime_manifest
from tools import repair_drift_timestamps


LEGACY_MS = 1_783_971_458_113
EXPECTED_SECONDS = 1_783_971_458


class TimestampIntegrityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="atlas_timestamp_tools_")
        self.root = Path(self.temp.name)
        self.db_path = self.root / "atlas.sqlite"
        self._create_contract_database()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _create_contract_database(self) -> None:
        columns_by_table: dict[str, list[str]] = {}
        for field in repair_drift_timestamps.DRIFT_TIMESTAMP_FIELDS:
            columns_by_table.setdefault(field.table, []).append(field.column)
        con = sqlite3.connect(self.db_path)
        try:
            for table, columns in columns_by_table.items():
                declarations = ", ".join(f'"{column}" INTEGER' for column in columns)
                con.execute(
                    f'CREATE TABLE "{table}" (id TEXT PRIMARY KEY, {declarations})'
                )
                names = ", ".join(["id", *(f'"{column}"' for column in columns)])
                placeholders = ", ".join("?" for _ in range(len(columns) + 1))
                con.execute(
                    f'INSERT INTO "{table}" ({names}) VALUES ({placeholders})',
                    [f"row-{table}", *([LEGACY_MS] * len(columns))],
                )
            con.execute(
                """
                CREATE TABLE project_git_remotes (
                  id TEXT PRIMARY KEY,
                  checked_at INTEGER NOT NULL,
                  remote_updated_at INTEGER,
                  remote_pushed_at INTEGER
                )
                """
            )
            con.execute(
                "INSERT INTO project_git_remotes VALUES (?, ?, ?, ?)",
                ("remote", LEGACY_MS, LEGACY_MS - 1, None),
            )
            con.commit()
        finally:
            con.close()

    def test_python_and_dart_contracts_are_identical(self) -> None:
        dart_path = (
            Path(__file__).resolve().parents[1] / "lib" / "db" / "timestamp_contract.dart"
        )
        dart_fields = set(
            re.findall(
                r"DriftTimestampField\('([^']+)', '([^']+)'\)",
                dart_path.read_text(encoding="utf-8"),
            )
        )
        python_fields = {
            (field.table, field.column)
            for field in repair_drift_timestamps.DRIFT_TIMESTAMP_FIELDS
        }
        self.assertEqual(dart_fields, python_fields)
        self.assertEqual(len(python_fields), 45)
        self.assertNotIn(("project_git_remotes", "checked_at"), python_fields)

    def test_repair_is_dry_run_by_default_and_apply_is_verified(self) -> None:
        dry_run = repair_drift_timestamps.audit_or_repair(self.db_path)
        self.assertEqual(dry_run["mode"], "dry_run")
        self.assertEqual(dry_run["candidateTotal"], 45)
        self.assertEqual(dry_run["invalidTotal"], 45)

        con = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(
                con.execute("SELECT created_at FROM projects").fetchone()[0],
                LEGACY_MS,
            )
        finally:
            con.close()

        backup_path = self.root / "before.sqlite"
        applied = repair_drift_timestamps.audit_or_repair(
            self.db_path,
            apply=True,
            backup_path=backup_path,
        )
        self.assertEqual(applied["updatedTotal"], 45)
        self.assertEqual(applied["secondPassUpdatedTotal"], 0)
        self.assertEqual(applied["remainingInvalidTotal"], 0)
        self.assertTrue(applied["customMillisecondFieldsUnchanged"])
        self.assertTrue(backup_path.exists())

        source = sqlite3.connect(self.db_path)
        backup = sqlite3.connect(backup_path)
        try:
            self.assertEqual(
                source.execute("SELECT created_at FROM projects").fetchone()[0],
                EXPECTED_SECONDS,
            )
            self.assertEqual(
                source.execute(
                    "SELECT checked_at FROM project_git_remotes"
                ).fetchone()[0],
                LEGACY_MS,
            )
            self.assertEqual(
                backup.execute("SELECT created_at FROM projects").fetchone()[0],
                LEGACY_MS,
            )
        finally:
            source.close()
            backup.close()

        second = repair_drift_timestamps.audit_or_repair(self.db_path)
        self.assertEqual(second["candidateTotal"], 0)
        self.assertEqual(second["invalidTotal"], 0)

    def test_maintenance_writers_generate_epoch_seconds(self) -> None:
        owner_timestamp = apply_owner_continuity.epoch_seconds()
        self.assertLess(abs(owner_timestamp - int(time.time())), 3)
        self.assertLess(owner_timestamp, repair_drift_timestamps.EPOCH_SECOND_THRESHOLD)

        profile = import_runtime_manifest._profile_from_app(
            {"name": "Atlas"}, Path("runtime_manifest.yaml"), owner_timestamp
        )
        self.assertEqual(profile["last_imported_at"], owner_timestamp)
        self.assertLess(
            profile["last_imported_at"],
            repair_drift_timestamps.EPOCH_SECOND_THRESHOLD,
        )

    def test_runtime_import_backup_uses_sqlite_online_backup(self) -> None:
        source_path = self.root / "source.sqlite"
        source = sqlite3.connect(source_path)
        try:
            source.execute("CREATE TABLE evidence (value TEXT)")
            source.execute("INSERT INTO evidence VALUES ('online-backup')")
            source.commit()
            original_cwd = Path.cwd()
            try:
                # Keep the tool's repo-relative backup directory inside temp.
                import os

                os.chdir(self.root)
                backup_path = import_runtime_manifest._backup_db(
                    source, source_path
                )
            finally:
                os.chdir(original_cwd)
        finally:
            source.close()
        backup = sqlite3.connect(backup_path)
        try:
            self.assertEqual(
                backup.execute("SELECT value FROM evidence").fetchone()[0],
                "online-backup",
            )
            self.assertEqual(backup.execute("PRAGMA quick_check").fetchone()[0], "ok")
        finally:
            backup.close()


if __name__ == "__main__":
    unittest.main()
