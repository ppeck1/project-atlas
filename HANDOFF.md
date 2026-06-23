# Project Atlas — Handoff Document

> Current as of v1.2.0+1, schema v10. Updated alongside each release.

---

## What This Project Is

Project Atlas is a Flutter Windows desktop app for personal project and task management. It is local-first: all data stays in a SQLite file on the machine. There is no backend, no sync, and no telemetry.

The core problem it solves: on any given morning, what am I doing, what is blocked, what is due, and what needs to go to my phone?

---

## Key Design Decisions

**Local-only SQLite via Drift.** Drift provides type-safe queries and reactive streams (`watch*` methods) that update the UI automatically when data changes. No manual refresh calls needed in most places.

**`AppState` as the single mediator.** All screens get data through `AppStateScope.of(context)`, which exposes `AppState`. Direct `AppDb` access is reserved for places where `AppState` has a gap. Never reach into `db` from a widget for a write path — use `AppState`.

**Human-in-the-loop AI.** Every Ollama response is shown to the user in a review dialog before it is saved. Nothing is auto-applied. `OllamaResult.isSuccess == false` means the server was unavailable or returned empty; the UI shows a SnackBar and stops.

**Owner fields link to contacts.** Anywhere an owner/person is assigned, the UI uses `ContactOwnerField` (a dropdown-plus-create widget backed by the `contacts` table). The contact name is stored as a plain text string in the owner field — there is no FK. The link is maintained by matching name or email at lookup time (`getContactResponsibilities()`).

**Schema migrations are defensive.** `addColumn` calls are wrapped in typed `on SqliteException` catches that only swallow duplicate-column errors and rethrow anything else. New tables use `CREATE TABLE IF NOT EXISTS` in the startup repair path. This means a partially-applied migration from a crash won't re-crash on the next open.

**App-owned media copies.** When files are added to a project's media gallery or the document library, they are copied into the app data directory. The `stored_path` column points to the copy. The original source path is not tracked. Deleting a record does not delete the copy; manual cleanup via Admin → Open app data folder.

---

## Project Structure

```text
lib/
  app/           app.dart (root widget), router.dart (go_router), theme.dart
  db/            tables.dart (all Drift tables), app_db.dart (AppDb + migrations), db_open.dart
  services/      ollama_service.dart, telegram_service.dart, app_logger.dart
  features/
    today/       today_screen.dart, work_item_detail_sheet.dart
    projects/    projects_screen.dart, project_detail_screen.dart
    library/     library_screen.dart
    settings/    settings_screen.dart (tabs: Integrations, Activity Log, Export, Workforce, Admin)
    work/        work_screen.dart, status_priority_helpers.dart
    review/      review_screen.dart
    export/      export_screen.dart
    governance/  governance_screen.dart
    log/         log_screen.dart
    dashboard/   dashboard_screen.dart (legacy)
  shared/
    models/      app_state.dart, app_state_scope.dart
    widgets/     atlas_shell.dart, contact_picker.dart, create_work_item_dialog.dart,
                 create_project_dialog.dart, document_preview.dart

windows/runner/resources/app_icon.ico   ← Windows app icon (multi-size ICO)
tools/generate_readme_screenshots.py    ← Python script to regenerate docs/screenshots/
docs/screenshots/                       ← PNG screenshots used in README
```

---

## How to Build and Run

**Requirements:**
- Flutter SDK (see `.flutter-version` or `pubspec.yaml` for SDK constraint `^3.11.0`)
- Windows build tools (Visual Studio with C++ workload)
- Python 3 + Pillow (for screenshot generation only)
- Ollama (optional, for AI features)

**Launch:**
```powershell
.\launch.ps1 -Full    # first time: pub get + build_runner + run
.\launch.ps1          # daily: run directly
```

**After schema changes:**
```powershell
dart run build_runner build
```

This regenerates `lib/db/app_db.g.dart`. Never edit the `.g.dart` file.

**Checks:**
```powershell
flutter analyze
flutter test
```

---

## Schema Overview (v10)

| Table | Purpose |
|-------|---------|
| `projects` | Core project records with lifecycle metadata (v5/v6 fields) |
| `app_meta` | Key-value store for settings and active-state flags |
| `stages` | Project stages (default 6 per project) |
| `work_items` | Tasks linked to stages |
| `work_item_notes` | Persistent notes on a work item (v7) |
| `work_item_analyses` | Read-only Ollama analyses on work items (v7) |
| `drafts` | AI-generated drafts (human-approved before use) |
| `daily_reviews` | Daily review snapshots (one per day) |
| `outbox_messages` | Telegram send attempts with status |
| `event_log` | Application event and error log |
| `documents` | Imported document library |
| `document_links` | Work item ↔ document associations |
| `contacts` | Reusable people/company directory (v8) |
| `project_people` | People roster per project (v5) |
| `project_risks` | Risk register per project (v5) |
| `project_decisions` | Decision log per project (v5) |
| `tags` | Reusable project labels (v9) |
| `project_tags` | Tag ↔ project assignments (v9) |
| `project_media` | Project image/file gallery with app-owned copies (v9) |

**v10 addition:** `UNIQUE INDEX idx_daily_reviews_date` on `daily_reviews(review_date)` — enables safe date-keyed upsert via `saveDailyReview()`. Stage CRUD methods (`addStage`, `updateStageTitle`, `deleteStage`, `reorderStage`) added to `AppDb` and `AppState`; no UI hooked up yet.

Full column-level documentation with write/read sites and quirks: `VARIABLE_MAP.md`.

---

## Active Integrations

**Ollama (local AI)**
- Host: `http://localhost:11434` (configurable in Settings → Integrations)
- Model: `qwen3.5:9b` default in code; `mistral` shown as hint in Settings UI
- Human-in-the-loop: every response requires user review before saving
- Actions: today summary, project summary, email draft, task extract, work item analysis

**Telegram (outbound)**
- Bot token + chat ID stored in `app_meta` as plaintext (personal desktop use)
- `sendTodayToTelegram()` fetches today's items, formats as HTML, posts to Bot API
- Outbox records every attempt with status (`pending` → `sent` / `failed`)
- Note: the `telegram_enabled` toggle in Settings is informational — the send path does not check it

---

## Contacts System

Contacts are stored in the `contacts` table. Every owner field across the app uses `ContactOwnerField` — a dropdown that shows existing contacts and a "Create contact..." option.

The contact name is stored as a plain string in the owner column (no FK). `getContactResponsibilities()` matches on `name` or `email` (case-insensitive) across `projects.owner`, `project_people.name`, and `work_items.owner`.

**Import:** Settings → Workforce → Import JSON. Accepts the `project_atlas_contacts_v1` schema or a bare array. Deduplicates by id → email → name.  
**Export:** JSON (re-importable) or CSV.

---

## Known Issues and Limitations

| Issue | Detail |
|-------|--------|
| Encryption not active | `sqlcipher_flutter_libs` is in pubspec but `db_open.dart` opens without a passphrase. Planned before distribution. |
| `telegram_enabled` not enforced | The toggle is UI-only; the send path ignores it. |
| `stages.is_bottleneck` vs `app_meta` | Duplicate bottleneck state. GovernanceScreen reads `app_meta`. Table column is legacy. |
| Drafts no first-class route | Drafts exist in Library under type filter. No dedicated `/drafts` route yet. |
| Media file cleanup | Deleting a `project_media` record does not delete the copied file in app data. |
| `completed` boolean on work items | Legacy. `status='done'` is canonical. Both are kept in sync but only `status` should be used in logic. |
| `accepted` on drafts | Schema column exists but is never set or checked. |

---

## Next Steps / Roadmap

1. **Drafts screen** — first-class `/drafts` route in primary nav
2. **Inbound Telegram** — `/done`, `/snooze`, `/add` commands via webhook
3. **Project snapshots** — exportable decision-log and project state bundles
4. **Backup restore** — import from the operational backup JSON
5. **SQLCipher** — activate encryption before any broader distribution
6. **Review history UI** — `watchRecentDailyReviews()` exists in the DB layer; no browsing screen yet
7. **Tag management UI** — create/edit/delete tags from Settings

---

## Data Location

Windows: `%APPDATA%\com.example\project_atlas\project_atlas.sqlite`

Access directly: Settings → Admin → Open app data folder.

Do not commit the database file, secrets, `.dart_tool/`, `build/`, or any app-data folders.
