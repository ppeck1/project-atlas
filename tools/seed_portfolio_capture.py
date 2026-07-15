"""Seed an empty Atlas database with public-safe portfolio capture data."""

from __future__ import annotations

import argparse
import sqlite3
import time
from pathlib import Path


PROJECTS = (
    (
        "atlas-portfolio-demo",
        "Atlas Portfolio Demo",
        "Desktop application",
        "Local-first planning, project health, documents, and governed automation in one Windows workspace.",
        "Show a credible project command center with explicit review and privacy boundaries.",
        "Real UI captures, repeatable verification, and no private workspace data.",
        "Portfolio release",
        "high",
    ),
    (
        "atlas-release-demo",
        "Release Readiness Demo",
        "Quality engineering",
        "Build, test, privacy, and release evidence collected behind a review gate.",
        "Ship a verified Windows release with auditable checks.",
        "Analysis, tests, build, and artifact scan all pass.",
        "Verification",
        "normal",
    ),
    (
        "atlas-library-demo",
        "Research Library Demo",
        "Knowledge workflow",
        "Project-linked notes and technical evidence kept searchable and local.",
        "Make decisions traceable to concise source material.",
        "Key architecture and security notes are easy to retrieve.",
        "Curated",
        "normal",
    ),
)

WORK_ITEMS = (
    (
        "work-portfolio-narrative",
        "stage-atlas-portfolio-demo",
        "Finalize the portfolio narrative",
        "Lead with product outcomes and engineering decisions.",
        "doing",
        "urgent",
        0,
        "small",
        "review",
    ),
    (
        "work-real-screens",
        "stage-atlas-portfolio-demo",
        "Capture the real application surfaces",
        "Use the isolated demo database for every public image.",
        "doing",
        "high",
        0,
        "medium",
        "visual",
    ),
    (
        "work-release-build",
        "stage-atlas-release-demo",
        "Verify the Windows release build",
        "Run analysis, tests, compilation, and artifact scanning.",
        "next",
        "high",
        1,
        "medium",
        "tests",
    ),
    (
        "work-privacy-audit",
        "stage-atlas-release-demo",
        "Audit the public privacy boundary",
        "Check source, screenshots, and downloadable artifacts.",
        "next",
        "high",
        1,
        "small",
        "review",
    ),
    (
        "work-architecture-evidence",
        "stage-atlas-library-demo",
        "Curate architecture evidence",
        "Keep the design story concise and source-linked.",
        "next",
        "normal",
        3,
        "small",
        "review",
    ),
)

DOCUMENTS = (
    (
        "document-architecture",
        "Architecture Overview",
        "architecture-overview.md",
        "atlas-portfolio-demo",
        "# Architecture Overview\n\nFlutter desktop UI, Drift persistence, service boundaries, and explicit review gates.",
    ),
    (
        "document-release",
        "Release Verification",
        "release-verification.md",
        "atlas-release-demo",
        "# Release Verification\n\nStatic analysis, automated tests, Windows build, and privacy scans are required.",
    ),
    (
        "document-security",
        "MCP Security Boundary",
        "mcp-security-boundary.md",
        "atlas-library-demo",
        "# MCP Security Boundary\n\nThe remote projection is narrower than the trusted local interface and fails closed.",
    ),
    (
        "document-data-model",
        "Data Model Notes",
        "data-model-notes.md",
        "atlas-library-demo",
        "# Data Model Notes\n\nProjects, stages, work, documents, evidence, and review state remain local.",
    ),
)

PROJECT_SOURCES = (
    (
        "registry-portfolio-local",
        "atlas-portfolio-demo",
        "Atlas Portfolio Demo",
        r"C:\AtlasPortfolioCapture\AtlasPortfolioDemo",
        r"C:\AtlasPortfolioCapture\AtlasPortfolioDemo",
        "software",
        "linked",
        "primary_working",
        "local_path",
        "active",
        "evidence_only",
        10,
        r"c:\atlasportfoliocapture\atlasportfoliodemo",
    ),
    (
        "registry-portfolio-legacy-remote",
        "atlas-portfolio-demo",
        "Atlas Portfolio Demo",
        "https://github.com/example/atlas-portfolio-demo",
        None,
        "software",
        "linked",
        "unresolved_candidate",
        "remote_url_legacy",
        "legacy_remote",
        "blocked_unresolved",
        100,
        "https://github.com/example/atlas-portfolio-demo",
    ),
    (
        "registry-release-local",
        "atlas-release-demo",
        "Release Readiness Demo",
        r"C:\AtlasPortfolioCapture\ReleaseReadinessDemo",
        r"C:\AtlasPortfolioCapture\ReleaseReadinessDemo",
        "software",
        "linked",
        "primary_working",
        "local_path",
        "active",
        "evidence_only",
        10,
        r"c:\atlasportfoliocapture\releasereadinessdemo",
    ),
)


def seed_database(database_path: Path) -> None:
    resolved = database_path.resolve()
    if "portfolio-capture" not in str(resolved).lower():
        raise ValueError("capture database path must contain 'portfolio-capture'")
    if not resolved.is_file():
        raise FileNotFoundError(
            "launch the capture build once so Atlas initializes the database schema"
        )

    connection = sqlite3.connect(resolved)
    try:
        required_tables = {"projects", "stages", "work_items", "documents", "app_meta"}
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        missing = sorted(required_tables - tables)
        if missing:
            raise RuntimeError(f"capture database is missing Atlas tables: {missing}")

        existing = {
            table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("projects", "work_items", "documents")
        }
        if any(existing.values()):
            raise RuntimeError(f"capture database is not empty: {existing}")

        now = int(time.time())
        owner = "Demo Maintainer"
        with connection:
            for (
                project_id,
                title,
                category,
                description,
                desired_outcome,
                success_criteria,
                phase,
                priority,
            ) in PROJECTS:
                connection.execute(
                    """
                    INSERT INTO projects (
                        id, title, owner, created_at, description,
                        desired_outcome, success_criteria, status,
                        category, phase, priority
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)
                    """,
                    (
                        project_id,
                        title,
                        owner,
                        now,
                        description,
                        desired_outcome,
                        success_criteria,
                        category,
                        phase,
                        priority,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO stages (id, project_id, title, position, created_at)
                    VALUES (?, ?, 'Tasks', 0, ?)
                    """,
                    (f"stage-{project_id}", project_id, now),
                )

            for (
                work_id,
                stage_id,
                title,
                description,
                status,
                priority,
                due_days,
                size,
                verification,
            ) in WORK_ITEMS:
                connection.execute(
                    """
                    INSERT INTO work_items (
                        id, stage_id, title, description, owner, status,
                        priority, due_at, updated_at, created_at, source,
                        readiness, size, risk, suggested_actor,
                        verification_needed
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ready', ?,
                              'low_code', 'user', ?)
                    """,
                    (
                        work_id,
                        stage_id,
                        title,
                        description,
                        owner,
                        status,
                        priority,
                        now + due_days * 86_400,
                        now,
                        now,
                        "portfolio_capture_fixture",
                        size,
                        verification,
                    ),
                )

            for document_id, title, filename, project_id, body in DOCUMENTS:
                connection.execute(
                    """
                    INSERT INTO documents (
                        id, title, original_filename, extension, mime_type,
                        project_id, source, status, created_at, updated_at,
                        extracted_text, rendered_markdown
                    ) VALUES (?, ?, ?, 'md', 'text/markdown', ?, ?, 'imported',
                              ?, ?, ?, ?)
                    """,
                    (
                        document_id,
                        title,
                        filename,
                        project_id,
                        "portfolio_capture_fixture",
                        now,
                        now,
                        body,
                        body,
                    ),
                )

            for (
                registry_id,
                project_id,
                display_name,
                local_path,
                git_root,
                classification,
                review_state,
                source_role,
                source_type,
                lifecycle_state,
                authority_level,
                precedence,
                normalized_identity,
            ) in PROJECT_SOURCES:
                connection.execute(
                    """
                    INSERT INTO project_registry (
                        id, atlas_project_id, display_name, local_path,
                        git_root, classification, review_state, source_role,
                        source_type, lifecycle_state, authority_level,
                        precedence, normalized_identity, notes, created_at,
                        updated_at, last_reviewed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL,
                              ?, ?, ?)
                    """,
                    (
                        registry_id,
                        project_id,
                        display_name,
                        local_path,
                        git_root,
                        classification,
                        review_state,
                        source_role,
                        source_type,
                        lifecycle_state,
                        authority_level,
                        precedence,
                        normalized_identity,
                        now,
                        now,
                        now,
                    ),
                )

            connection.execute(
                "INSERT OR REPLACE INTO app_meta (key, value) VALUES (?, ?)",
                ("active_project_id", "atlas-portfolio-demo"),
            )
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    args = parser.parse_args()
    seed_database(args.db)
    print("SEEDED|projects=3|work_items=5|documents=4")


if __name__ == "__main__":
    main()
