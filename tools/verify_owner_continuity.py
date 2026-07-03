import argparse
import json
import sqlite3


VISIBLE_PROJECTS_WHERE = """
deleted_at IS NULL
AND COALESCE(status, '') != 'deleted'
AND id != 'atlas-general-tasks'
AND COALESCE(description, '') != '__atlas_hidden_general_tasks_project__'
"""


def verify(db_path: str):
    conn = sqlite3.connect(db_path)
    try:
        visible_projects = conn.execute(
            f"SELECT COUNT(*) FROM projects WHERE {VISIBLE_PROJECTS_WHERE}"
        ).fetchone()[0]
        non_paul_owner_projects = conn.execute(
            f"""
            SELECT COUNT(*)
            FROM projects
            WHERE {VISIBLE_PROJECTS_WHERE}
              AND COALESCE(trim(owner), '') != 'Paul Peck'
            """
        ).fetchone()[0]
        visible_without_paul_people = conn.execute(
            f"""
            SELECT COUNT(*)
            FROM projects p
            WHERE {VISIBLE_PROJECTS_WHERE}
              AND NOT EXISTS (
                SELECT 1
                FROM project_people pp
                WHERE pp.project_id = p.id
                  AND lower(pp.name) = lower('Paul Peck')
              )
            """
        ).fetchone()[0]
        continuity_contacts = [
            row[0]
            for row in conn.execute(
                """
                SELECT name
                FROM contacts
                WHERE name IN ('Paul Peck', 'Atlas', 'Atlas Agent', 'Codex')
                   OR name LIKE 'Model: %'
                ORDER BY name
                """
            ).fetchall()
        ]
        return {
            "visibleProjects": visible_projects,
            "nonPaulOwnerProjects": non_paul_owner_projects,
            "visibleWithoutPaulPeopleRows": visible_without_paul_people,
            "continuityContacts": continuity_contacts,
        }
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("db_path")
    args = parser.parse_args()
    print(json.dumps(verify(args.db_path), indent=2))


if __name__ == "__main__":
    main()
