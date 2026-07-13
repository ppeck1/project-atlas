import argparse
import json
import re
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_OWNER_NAME = "Project Owner"


OWNER_CONTACTS = [
    (
        "contact_operator_project_owner",
        DEFAULT_OWNER_NAME,
        "Owner / Operator",
        "Primary Project Atlas owner. Seeded for project ownership continuity.",
    ),
    (
        "contact_system_atlas",
        "Atlas",
        "Project Atlas system actor",
        "System actor used for app-originated project updates and logs.",
    ),
    (
        "contact_system_atlas_agent",
        "Atlas Agent",
        "AI-assisted project actor",
        "System actor used when approved Atlas agent proposals update project state.",
    ),
    (
        "contact_system_codex",
        "Codex",
        "AI coding agent",
        "System actor used for Codex-assisted code and project updates.",
    ),
]

_last_micros = 0


def epoch_seconds() -> int:
    """Return the storage unit required by Drift DateTime columns."""
    return int(datetime.now(timezone.utc).timestamp())


def micros_id(prefix: str) -> str:
    global _last_micros
    current = int(datetime.now(timezone.utc).timestamp() * 1000000)
    if current <= _last_micros:
        current = _last_micros + 1
    _last_micros = current
    return f"{prefix}_{current}"


def clean(value):
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def safe_id_segment(value: str) -> str:
    segment = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip()).strip("_").lower()
    return segment or "model"


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def upsert_contact(conn: sqlite3.Connection, contact_id: str, name: str, title: str, notes: str):
    existing = conn.execute(
        "SELECT id, title, notes, created_at FROM contacts WHERE id = ? OR lower(name) = lower(?) LIMIT 1",
        (contact_id, name),
    ).fetchone()
    current_seconds = epoch_seconds()
    if existing:
        existing_id, existing_title, existing_notes, created_at = existing
        merged_notes = clean(existing_notes)
        if notes not in (merged_notes or ""):
            merged_notes = f"{merged_notes}\n\n{notes}" if merged_notes else notes
        conn.execute(
            """
            UPDATE contacts
            SET name = ?, title = ?, notes = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                name,
                clean(existing_title) or title,
                merged_notes,
                current_seconds,
                existing_id,
            ),
        )
        return existing_id
    conn.execute(
        """
        INSERT INTO contacts (
          id, name, title, phone, alternate_phone, email, website,
          business_name, notes, photo_path, created_at, updated_at
        )
        VALUES (?, ?, ?, NULL, NULL, NULL, NULL, NULL, ?, NULL, ?, ?)
        """,
        (contact_id, name, title, notes, current_seconds, current_seconds),
    )
    return contact_id


def dedupe_contact_name(conn: sqlite3.Connection, name: str, preferred_id: str) -> int:
    rows = conn.execute(
        """
        SELECT id, title, notes
        FROM contacts
        WHERE lower(name) = lower(?)
        ORDER BY CASE WHEN id = ? THEN 0 ELSE 1 END, updated_at DESC
        """,
        (name, preferred_id),
    ).fetchall()
    if len(rows) <= 1:
        return 0
    keep_id, keep_title, keep_notes = rows[0]
    merged_notes = clean(keep_notes)
    for _contact_id, _title, notes in rows[1:]:
        extra = clean(notes)
        if extra and extra not in (merged_notes or ""):
            merged_notes = f"{merged_notes}\n\n{extra}" if merged_notes else extra
    conn.execute(
        "UPDATE contacts SET title = COALESCE(title, ?), notes = ?, updated_at = ? WHERE id = ?",
        (clean(keep_title), merged_notes, epoch_seconds(), keep_id),
    )
    for duplicate_id, _title, _notes in rows[1:]:
        conn.execute("DELETE FROM contacts WHERE id = ?", (duplicate_id,))
    return len(rows) - 1


def visible_projects(conn: sqlite3.Connection):
    return conn.execute(
        """
        SELECT id, title, owner
        FROM projects
        WHERE deleted_at IS NULL
          AND COALESCE(status, '') != 'deleted'
          AND id != 'atlas-general-tasks'
          AND COALESCE(description, '') != '__atlas_hidden_general_tasks_project__'
        ORDER BY title
        """
    ).fetchall()


def log_event(conn: sqlite3.Connection, area: str, action: str, entity_type=None, entity_id=None, output=None):
    columns = table_columns(conn, "event_log")
    event_id = micros_id("event")
    timestamp = epoch_seconds()
    base = {
        "id": event_id,
        "timestamp": timestamp,
        "level": "info",
        "area": area,
        "action": action,
        "entity_type": entity_type,
        "entity_id": entity_id,
        "input_json": None,
        "output_json": json.dumps(output) if output is not None else None,
        "error": None,
        "stack_trace": None,
        "correlation_id": None,
    }
    used = {key: value for key, value in base.items() if key in columns}
    names = ", ".join(used)
    placeholders = ", ".join("?" for _ in used)
    conn.execute(
        f"INSERT INTO event_log ({names}) VALUES ({placeholders})",
        tuple(used.values()),
    )


def _online_backup(conn: sqlite3.Connection, db_path: Path) -> Path:
    stamp = time.strftime("%Y%m%d_%H%M%S")
    backup_path = db_path.with_name(
        f"{db_path.stem}.before_owner_continuity_{stamp}{db_path.suffix}"
    )
    backup = sqlite3.connect(backup_path)
    try:
        conn.backup(backup)
    finally:
        backup.close()
    return backup_path


def apply(db_path: str, *, write: bool = True):
    path = Path(db_path)
    source = sqlite3.connect(path)
    backup_path = None
    if write:
        conn = source
        backup_path = _online_backup(conn, path)
    else:
        conn = sqlite3.connect(":memory:")
        source.backup(conn)
        source.close()
    try:
        conn.execute("PRAGMA busy_timeout = 30000")
        conn.execute("PRAGMA foreign_keys = ON")
        with conn:
            contacts = list(OWNER_CONTACTS)
            model = conn.execute(
                """
                SELECT value
                FROM app_meta
                WHERE key IN ('project_ai_summary_model', 'ollama_model')
                  AND value IS NOT NULL
                  AND trim(value) != ''
                ORDER BY CASE key
                  WHEN 'project_ai_summary_model' THEN 0
                  ELSE 1
                END
                LIMIT 1
                """
            ).fetchone()
            if model:
                model_name = model[0].strip()
                contacts.append(
                    (
                        f"contact_model_{safe_id_segment(model_name)}",
                        f"Model: {model_name}",
                        "AI model actor",
                        "Model contact seeded for AI summary/change continuity. "
                        f"Current configured model: {model_name}.",
                    )
                )

            seeded = []
            duplicate_contacts_removed = 0
            for contact_id, name, title, notes in contacts:
                kept_id = upsert_contact(conn, contact_id, name, title, notes)
                seeded.append(kept_id)
                duplicate_contacts_removed += dedupe_contact_name(
                    conn,
                    name,
                    kept_id,
                )

            projects = visible_projects(conn)
            owners_updated = 0
            people_added = 0
            people_updated = 0
            for project_id, _title, owner in projects:
                if clean(owner) != DEFAULT_OWNER_NAME:
                    conn.execute(
                        "UPDATE projects SET owner = ? WHERE id = ?",
                        (DEFAULT_OWNER_NAME, project_id),
                    )
                    owners_updated += 1
                    log_event(
                        conn,
                        "projects",
                        "project_metadata_updated",
                        "project",
                        project_id,
                        {
                            "agent": "Operator",
                            "actor": {"type": "operator", "displayName": "Operator"},
                            "changedFieldCount": 1,
                            "changedFields": {"owner": {"from": owner, "to": DEFAULT_OWNER_NAME}},
                        },
                    )

                person = conn.execute(
                    """
                    SELECT id, role, authority
                    FROM project_people
                    WHERE project_id = ? AND lower(name) = lower(?)
                    LIMIT 1
                    """,
                    (project_id, DEFAULT_OWNER_NAME),
                ).fetchone()
                if person is None:
                    conn.execute(
                        """
                        INSERT INTO project_people (id, project_id, name, role, authority, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (
                            micros_id("person"),
                            project_id,
                            DEFAULT_OWNER_NAME,
                            "Owner",
                            "Accountable",
                            epoch_seconds(),
                        ),
                    )
                    people_added += 1
                    log_event(
                        conn,
                        "projects",
                        "project_owner_person_added",
                        "project",
                        project_id,
                        {
                            "actor": {"type": "operator", "displayName": DEFAULT_OWNER_NAME},
                            "person": DEFAULT_OWNER_NAME,
                            "role": "Owner",
                            "authority": "Accountable",
                        },
                    )
                else:
                    person_id, role, authority = person
                    next_role = clean(role) or "Owner"
                    next_authority = clean(authority) or "Accountable"
                    if next_role != role or next_authority != authority:
                        conn.execute(
                            "UPDATE project_people SET role = ?, authority = ? WHERE id = ?",
                            (next_role, next_authority, person_id),
                        )
                        people_updated += 1

            result = {
                "dryRun": not write,
                "backup": str(backup_path) if backup_path else None,
                "contactsSeeded": len(seeded),
                "projectsConsidered": len(projects),
                "projectOwnersUpdated": owners_updated,
                "projectPeopleAdded": people_added,
                "projectPeopleUpdated": people_updated,
                "duplicateContactsRemoved": duplicate_contacts_removed,
            }
            log_event(
                conn,
                "contacts",
                "contact_continuity_seeded",
                "contact",
                seeded[0],
                result,
            )
        return result
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("db_path")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write after creating an online SQLite backup (default: dry run).",
    )
    args = parser.parse_args()
    print(json.dumps(apply(args.db_path, write=args.apply), indent=2))


if __name__ == "__main__":
    main()
