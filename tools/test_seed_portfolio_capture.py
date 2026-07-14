import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from seed_portfolio_capture import seed_database


SCHEMA = """
CREATE TABLE projects (
  id TEXT PRIMARY KEY NOT NULL,
  title TEXT NOT NULL,
  owner TEXT,
  created_at INTEGER NOT NULL,
  description TEXT,
  desired_outcome TEXT,
  success_criteria TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  category TEXT,
  phase TEXT,
  priority TEXT
);
CREATE TABLE stages (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL,
  title TEXT NOT NULL,
  position INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE work_items (
  id TEXT PRIMARY KEY NOT NULL,
  stage_id TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  owner TEXT,
  status TEXT NOT NULL DEFAULT 'next',
  priority TEXT NOT NULL DEFAULT 'normal',
  due_at INTEGER,
  updated_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  source TEXT,
  readiness TEXT NOT NULL DEFAULT 'ready',
  size TEXT NOT NULL DEFAULT 'medium',
  risk TEXT NOT NULL DEFAULT 'low_code',
  suggested_actor TEXT NOT NULL DEFAULT 'user',
  verification_needed TEXT NOT NULL DEFAULT 'none'
);
CREATE TABLE documents (
  id TEXT PRIMARY KEY NOT NULL,
  title TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  extension TEXT,
  mime_type TEXT,
  project_id TEXT,
  source TEXT,
  status TEXT NOT NULL DEFAULT 'imported',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  extracted_text TEXT,
  rendered_markdown TEXT
);
CREATE TABLE app_meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);
"""


class SeedPortfolioCaptureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="portfolio-capture-test-")
        self.addCleanup(self.temp.cleanup)
        self.database_path = Path(self.temp.name) / "project_atlas.sqlite"
        with closing(sqlite3.connect(self.database_path)) as connection:
            connection.executescript(SCHEMA)
            connection.commit()

    def test_seeds_expected_public_fixture(self) -> None:
        seed_database(self.database_path)

        with closing(sqlite3.connect(self.database_path)) as connection:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM projects").fetchone()[0],
                3,
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM work_items").fetchone()[0],
                5,
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0],
                4,
            )
            self.assertEqual(
                connection.execute(
                    "SELECT value FROM app_meta WHERE key = 'active_project_id'"
                ).fetchone()[0],
                "atlas-portfolio-demo",
            )

    def test_refuses_to_overwrite_seeded_database(self) -> None:
        seed_database(self.database_path)

        with self.assertRaisesRegex(RuntimeError, "not empty"):
            seed_database(self.database_path)


if __name__ == "__main__":
    unittest.main()
