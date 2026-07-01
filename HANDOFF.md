# Project Atlas — Handoff Document

> Current as of v1.3.0+1, schema v18. Updated alongside each release.

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

**App-owned file copies.** When files are added to a project's media gallery or the document library, they are copied into the app data directory. For project media the copy goes into the app data root; for Library documents it goes into `atlas_documents/` inside `getApplicationDocumentsDirectory()`. The `stored_path` column points to the copy. The original source path is not preserved. For Library documents, `AppDb.deleteDocument(id)` removes the DB row, cascades document_links, and deletes the disk file. For project media, deleting a record removes media_links rows but does not delete the copied file — manual cleanup via Admin → Open app data folder.

**Document library import pipeline.** `importDocumentFromPath(path)` in `AppDb`:
1. Copies the file into `<appDocDir>/atlas_documents/<id>.<ext>`.
2. Detects MIME type via `mimeTypeForExtension(ext)` and saves it to `mime_type`.
3. Files over 10 MB skip text extraction; both text columns stay null.
4. For text-extractable types, reads content immediately and stores it in the DB:
   - `.txt`, `.log`, `.csv`, `.xml`, `.yaml`, `.yml`, `.ini`, `.toml`, `.rst`, `.json` → `extracted_text`
   - `.md` → `rendered_markdown`
   - `.html`/`.htm` → raw HTML into `rendered_markdown`; `extractHtmlText()` result (tags stripped) into `extracted_text` (dual storage: renders rich, searches clean)
   - `.eml` → `stripEmlBody()` result into `extracted_text`
   - `.docx` → `extracted_text` (DOCX XML parsed by `extractDocxTextFromBytes` in `document_extractor.dart`)
5. Binary types (`.pdf`, `.doc`, `.rtf`, `.svg`, images) get no extraction; both text columns remain null.

`document_extractor.dart` exports a `textDocumentExtensions` const Set and `shouldLoadDocumentText(ext)` function as the single source of truth used by the picker allowlist, the importer, and `DocumentPreview`.

The extraction helpers live in `lib/db/document_extractor.dart` as standalone pure-Dart functions — no Flutter dependency — making them fully unit-testable.

**Library entry model bridges documents and media.** `_LibraryEntry.fromDocument` in `library_screen.dart` detects image extensions (`jpg`, `jpeg`, `png`, `gif`, `webp`, `bmp`) and sets `isMedia: true` + `mediaType: 'image'`. This lets Library-imported images appear in the Images filter and use the `InteractiveViewer` image path. The entry's `content` field uses `extractedText ?? renderedMarkdown` (stripped text first, so HTML search/copy doesn't expose raw markup). Documents with `content == null` and no image type fall through to `DocumentPreview`, which handles the full extension matrix: rendered Markdown, pretty-printed JSON, rendered HTML, EML body text, plain text, external-viewer prompt (PDF, RTF, SVG, .doc), and DOCX extracted text.

**Structured AI Summary (two-layer design).** The project summary system separates LLM output from UI rendering. Ollama is called with `format:"json"` (an Ollama API parameter that forces valid JSON output), and the Flutter app renders the parsed result deterministically. This means the UI layout is never at the mercy of LLM prose formatting. All typed input/output models for the summary pipeline live in `lib/services/project_summary_models.dart`. `ProjectSummaryResult.tryParse()` handles three common LLM failure modes: `<think>…</think>` reasoning blocks (Qwen models), markdown code fences, and JSON parsing errors — returning null on any failure so the UI can gracefully fall back to prose. The system prompt instructs the model to use only supplied data and never invent document IDs, paths, people, or work assignments.

**Summary Caching and Background Refresh.** After generating a structured summary, it is auto-saved as a Draft with `kind='project_summary'` (replacing any prior draft for that project). When Project Detail opens, it loads the cached draft instantly and shows an age badge ("2h ago", "just now") in the AI panel header. Ten seconds after app startup, and then every 6 hours, a background job (`_backgroundSummaryRefresh` in `AppState`) checks summary-eligible operational projects (`active`, `stale`, `needs_update`, `needs_review`, `local_only`, `public_mismatch`, `blocked`) and generates a fresh structured summary if none exists for today. The Projects toolbar can force this refresh across those statuses. The job is silently skipped if Ollama is unreachable, and a 3-second inter-project delay prevents hammering Ollama when many projects exist.

**Project status/category metadata.** Project statuses and category helpers are centralized in `lib/shared/models/project_metadata.dart`. The shared status list drives Projects filtering, Project Detail editing, attention detection in `AtlasAgentService`, and summary eligibility. `projects.category` is editable free text; Projects groups by category and uses `Uncategorized` for empty values. The Projects tab also stores operator ordering preferences in `app_meta`: category sort, project sort, pinned category labels, and pinned project IDs.

**Legacy Database Compatibility Repair.** `_ensureProjectCompatibilityColumns()` in `AppDb` runs in `beforeOpen` and issues `ALTER TABLE … ADD COLUMN` statements for columns added to the Drift schema after some databases were already created: `project_risks.severity TEXT NOT NULL DEFAULT 'medium'`, `project_risks.desc TEXT`, and `project_risks.ctx TEXT`. These ALTER TABLE calls are wrapped in try/catch so duplicate-column errors are silently ignored. Additionally, `addProjectRisk()` and `addProjectDecision()` catch `SqliteException` containing `'updated_at'` and fall back to a raw `customStatement` INSERT with an explicit timestamp — handling the case where legacy databases have `updated_at NOT NULL` but the newer Drift schema omits it from the generated INSERT.

**Agent boundary is proposal-first, with an explicit LLM queue.** `AtlasAgentService` in `lib/services/atlas_agent_service.dart` is the desktop-side adapter for the future Atlas MCP and the local LLM harness. It exposes read-heavy project operations (`listProjects`, `getProjectStatus`, `getProjectBrief`, cached summaries, stale/attention projects, local refresh preview, git visibility inspection, enrichment run history, summary refresh), persisted LLM queue lifecycle methods, operator-owned queue edit/cancel/requeue methods, and proposal-first write requests saved as drafts with `kind='atlas_agent_proposal'`. `lib/mcp/atlas_mcp_server.dart` maps MCP-style tool calls to that service for reads, Atlas-only enrichment runs, queue enqueue/list/get/claim/complete/fail, and proposal creation; approval/rejection and queue edit/cancel controls are intentionally not exposed to agents. LLM queue tasks can carry linked project media; MCP `get_llm_task` returns the task plus attached media metadata for harness context. Library has an Agent Proposals filter where pending proposals can be approved or rejected. Approval applies supported status, task, and manifest metadata/tag changes through `AppState`; validation approvals are logged; handoff approvals create `project_handoff` drafts. Queue completion can attach a `handoff_record` proposal draft via `proposalBody`, but it does not directly mutate project state. The service does not delete projects, overwrite manifests, push/fetch Git, or mutate discovered repositories; human review remains the approval boundary.

**Local Operations Registry is observation-first.** Operations scans are manual only, default to the current working directory, and can include additional operator-selected folders. The scanner defaults to shallow root-first discovery (`maxDepth=2`) and stops descending once it sees a strong project root, which keeps nested folders from flooding the review queue. The scanner records append-only observations and scan-run metadata; reviewed registry rows are created only when the user accepts, links, ignores, or marks a candidate needs-review. Review Candidates defaults to a Needs action queue, hides handled rows, exposes Known/Ignored/All filters, and supports bulk accept, ignore, needs-review, and ignore-descendants actions. Repeat scans attach prior `project_registry` rows to new observations, so known paths stay known and linked paths become refresh work rather than re-triage. Accepted registry rows can create a new Atlas Project or update an existing Atlas Project from the Operations Registered Projects tab. The create-new path now reuses a single exact-title Atlas Project match instead of creating a duplicate; ambiguous matches require the operator to choose Update existing. First import links `project_registry.atlas_project_id`, imports safe root marker docs, and applies the local refresh profile into native Atlas documents, media, source files, card documents, decisions, risks, work items, and project metadata through the refresh ledger. Operations > Enrichment runs the Atlas-owned refresh/audit loop for linked projects, records completeness coverage, and writes open findings for missing or ambiguous details without mutating source repositories. Project Detail can preview/apply the same manual local refresh profile. Project Detail and the Projects list both preview/apply project bundle ZIP export, including Atlas record counts, optional copied file counts, registry/observation/refresh-ledger rows, and missing-file warnings. Scan artifacts can be saved under the app support directory at `operations_scans\` (`runs`, `warnings`, `logs`). The scanner, refresh profile, and enrichment loop do not call BOH, push/fetch Git, run tests, or mutate discovered repositories.

**Read-only Git Visibility.** Project Detail > Local Repo exposes a manual Inspect Git action for linked projects. `LocalGitVisibilityService` shells out to fixed read-only git commands and compares local tracked files to the available local remote-tracking ref (`@{u}`, `origin/<branch>`, `origin/main`, or `origin/master`). It also lists changed tracked files, untracked files, ignored files, `.gitignore` patterns, and suggested ignore entries. It does not fetch, push, call GitHub, or mutate the repository.

**Read-only GitHub Remote Metadata.** Project Detail > Local Repo can refresh cached GitHub metadata for a linked project when the latest local observation has a GitHub `origin` remote. `GithubRemoteMetadataService` parses HTTPS/SSH GitHub remotes, sanitizes credential-bearing URLs before storing, and calls `gh api` only for read-only repository metadata and default-branch HEAD. Results are saved in `project_git_remotes` with visibility, default branch, online HEAD SHA, timestamps, and any access/error message. This is a cache, not a publish/sync engine: Atlas does not push, create repos, clone, change visibility, or mutate GitHub.

**Project merge is source-to-target reassignment.** The Projects list exposes a merge action. `AppDb.mergeProjects()` moves source-linked stages, documents, people, risks, decisions, media, drafts, registry links, and unique tag assignments to the target project, preserves app-owned file paths, updates active project/stage metadata where needed, then marks the source project `status='deleted'` with a merge reason and logs `projects/merge_projects`.

---

## Project Structure

```text
lib/
  app/           app.dart (root widget), router.dart (go_router), theme.dart
  db/            tables.dart (all Drift tables), app_db.dart (AppDb + migrations), db_open.dart,
                 document_extractor.dart (DOCX/MIME/EML pure-Dart utilities)
  mcp/           atlas_mcp_server.dart (tool registry / JSON-safe dispatcher)
  services/      ollama_service.dart, telegram_service.dart, app_logger.dart,
                 project_summary_models.dart, local_operations_scanner.dart,
                 local_project_refresh_service.dart, local_git_visibility_service.dart,
                 github_remote_metadata_service.dart,
                 atlas_agent_service.dart
  features/
    today/       today_screen.dart, work_item_detail_sheet.dart
    projects/    projects_screen.dart, project_detail_screen.dart
    operations/  operations_screen.dart
    library/     library_screen.dart
    settings/    settings_screen.dart (tabs: Integrations, Activity Log, Export, Workforce, Admin)
    work/        work_screen.dart, status_priority_helpers.dart
    review/      review_screen.dart
    export/      export_screen.dart
    governance/  governance_screen.dart
    log/         log_screen.dart
    dashboard/   dashboard_screen.dart (legacy)
  shared/
    models/      app_state.dart, app_state_scope.dart, project_metadata.dart
    widgets/     atlas_shell.dart, contact_picker.dart, create_work_item_dialog.dart,
                 create_project_dialog.dart, document_preview.dart

windows/runner/resources/app_icon.ico   ← Windows app icon (multi-size ICO)
tools/generate_readme_screenshots.py    ← Python script to regenerate docs/screenshots/
docs/screenshots/                       ← PNG screenshots used in README
demo/                                   ← Sample files for Library import walkthrough (see DEMO.md)
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

## Schema Overview (v18)

| Table | Purpose |
|-------|---------|
| `projects` | Core project records with lifecycle metadata (v5/v6 fields) and category metadata (v18) |
| `app_meta` | Key-value store for settings and active-state flags |
| `stages` | Project stages (default 6 per project) |
| `work_items` | Tasks linked to stages |
| `work_item_tags` | Tag <-> work item assignments (v13) |
| `work_item_notes` | Persistent notes on a work item (v7) |
| `work_item_analyses` | Read-only Ollama analyses on work items (v7) |
| `drafts` | AI-generated drafts (human-approved before use) |
| `daily_reviews` | Daily review snapshots (one per day) |
| `outbox_messages` | Telegram send attempts with status |
| `event_log` | Application event and error log |
| `documents` | Imported document library — app-owned copies, MIME, extracted text |
| `document_links` | Work item ↔ document associations |
| `contacts` | Reusable people/company directory (v8) |
| `project_people` | People roster per project (v5) |
| `project_risks` | Risk register per project (v5) |
| `project_decisions` | Decision log per project (v5) |
| `tags` | Reusable project labels (v9) |
| `project_tags` | Tag ↔ project assignments (v9) |
| `project_media` | Project image/file gallery with app-owned copies (v9) |
| `media_links` | Project media attachments to work items and LLM task queue rows (v18) |
| `project_registry` | Human-reviewed local project identities from Operations review (v11) |
| `project_observations` | Append-only scanner facts tied to a scan run (v11) |
| `project_scan_runs` | Manual Operations scan metadata and status (v11) |
| `local_project_refresh_items` | Source-key ledger for idempotent local project refresh child imports (v12) |
| `project_git_remotes` | Cached read-only GitHub remote metadata for linked projects (v14, raw SQL compatibility table) |
| `project_enrichment_runs` | Atlas-owned enrichment run history and coverage counts (v15, raw SQL compatibility table) |
| `project_enrichment_findings` | Open exception/completeness findings from enrichment runs (v15, raw SQL compatibility table) |
| `project_enrichment_steps` | Worker-level enrichment step ledger (v16, raw SQL compatibility table) |
| `project_enrichment_proposals` | Worker-level enrichment proposal ledger (v16, raw SQL compatibility table) |
| `llm_task_queue` | Persisted MCP/local harness queue with claim/complete/fail plus operator edit/cancel/requeue lifecycle (v17, raw SQL compatibility table) |

**v10 addition:** `UNIQUE INDEX idx_daily_reviews_date` on `daily_reviews(review_date)` — enables safe date-keyed upsert via `saveDailyReview()`. Stage CRUD methods (`addStage`, `updateStageTitle`, `deleteStage`, `reorderStage`) added to `AppDb` and `AppState`; no UI hooked up yet.

**v11 addition:** Local Operations Registry tables and Operations screen. `project_scan_runs` stores manual scan metadata, `project_observations` stores append-only facts, and `project_registry` stores the human-reviewed local project identity/review state. Scan JSON can be copied, exported to an arbitrary path, or saved into the app-owned `operations_scans\runs`; warning-only JSON can be saved into `operations_scans\warnings`.

**v12 addition:** Local Project Refresh Profiles. `local_project_refresh_items` stores one ledger row per imported source anchor (`registry_id`, `source_kind`, `source_key`) so repeated refreshes update or skip existing Atlas documents, project media, decisions, risks, work items, and project metadata instead of duplicating them. The first profile is BOH-oriented for root-level operations docs such as `DECISIONS.md`, `ACTIVE_TASK.md`, `CURRENT_STATE.md`, `ROADMAP.md`, `ACCEPTANCE.md`, and `CHANGELOG_AGENT.md`, and it also imports discovered image, video, and audio files from linked local project folders.

**v13 addition:** Work item tags. `work_item_tags` adds many-to-many tags for tasks independently from project tags. The Today tab uses this for project-linked task lists with checkoffs, status/project/tag filters, and per-task tag editing.

**v14 addition:** Read-only GitHub remote metadata. `project_git_remotes` caches the latest GitHub owner/repo identity, visibility, default branch, online HEAD SHA, timestamps, and access/error state for linked projects. It is created through raw compatibility SQL rather than as a generated Drift table in this slice.

**v15 addition:** Project enrichment run ledger. `project_enrichment_runs` records Atlas-only refresh/audit runs with registry, refresh, summary, coverage, warning, and finding counts. `project_enrichment_findings` records open info/warning/error items for missing links, documents, media, source files, cards, people/roles, tasks, risks, decisions, summaries, and repository metadata gaps. Enrichment writes Atlas records only; it does not mutate source repositories.

**v16 addition:** Enrichment loop worker ledgers. `project_enrichment_steps` records per-worker step status/output, and `project_enrichment_proposals` records worker-level proposal payloads for agent-array enrichment runs.

**v17 addition:** LLM task queue. `llm_task_queue` stores project-scoped pending/leased/completed/failed/cancelled jobs for MCP and the future local harness. The Project Detail screen opens with a collapsible Tasks panel containing normal project tasks and an editable LLM queue subsection; operators can open, move, edit, cancel, and requeue tasks. Editing a leased task clears the lease and returns it to pending so stale worker output cannot complete the corrected task. Queue completion may link to a reviewable agent proposal draft; it does not bypass human approval.

**v18 addition:** Project categories and media links. `projects.category` stores free-text grouping metadata used by Projects and Project Detail. `media_links` attaches existing project media to work items or LLM queue tasks without duplicating the file record. Work Item Detail can attach/unlink media for task context, Project Detail can attach/unlink media on queued LLM tasks, and MCP `get_llm_task` includes attached media metadata for local harness workers.

**Runtime compatibility columns (not a schema version bump):** `project_risks` and `project_decisions` have additional columns added at startup via `_ensureProjectCompatibilityColumns()` rather than through a migration version increment. This handles databases created before those columns existed without forcing a full migration. See the Legacy Database Compatibility Repair design decision above.

Full column-level documentation with write/read sites and quirks: `VARIABLE_MAP.md`.

---

## Active Integrations

**Ollama (local AI)**
- Host: `http://localhost:11434` (configurable in Settings → Integrations)
- Model: `qwen3.5:9b` default in code; `mistral` shown as hint in Settings UI
- Human-in-the-loop: every response requires user review before saving
- Actions: today summary, email draft, task extract, work item analysis, **structured project summary** (7-section JSON output with ownership, blockers, relevant docs, next actions; results cached as Drafts with startup plus 6-hour background refresh)
- Timeout: 300 seconds (5-minute) for all generation calls

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
| Encryption not active | Database is plaintext SQLite. No encryption library is currently included. Encryption is planned for a future release. |
| `telegram_enabled` not enforced | The toggle is UI-only; the send path ignores it. |
| `stages.is_bottleneck` vs `app_meta` | Duplicate bottleneck state. GovernanceScreen reads `app_meta`. Table column is legacy. |
| Drafts no first-class route | Drafts exist in Library under type filter. No dedicated `/drafts` route yet. |
| Media file cleanup | Deleting `project_media` removes DB/link rows but leaves the copied file in app data. Document deletion removes the copied document file. |
| `completed` boolean on work items | Legacy. `status='done'` is canonical. Both are kept in sync but only `status` should be used in logic. |
| `accepted` on drafts | Schema column exists but is never set or checked. |
| `project_risks`/`project_decisions` legacy `updated_at` | Resolved: startup repair adds missing columns; INSERT methods fall back to `customStatement` with explicit timestamp when `updated_at NOT NULL` constraint is present on older databases. |
| PDF in-app rendering | PDF files open in the system viewer. No in-app PDF rendering; `pdfx`/PDFium integration is a future milestone. |
| DOC (legacy Word) | `.doc` files show the external viewer button; no text extraction. Only `.docx` (OOXML ZIP format) supports text extraction. |

---

## Next Steps / Roadmap

1. **In-app PDF rendering** — integrate `pdfx` (PDFium) for Windows
2. **Drafts screen** — first-class `/drafts` route in primary nav
3. **Inbound Telegram** — `/done`, `/snooze`, `/add` commands via webhook
4. **Project bundle restore** — import from project bundle ZIP
5. **Backup restore** — import from the operational backup (ZIP)
6. **Encryption** — integrate an encryption library before broader distribution
7. **Review history UI** — `watchRecentDailyReviews()` exists in the DB layer; no browsing screen yet
8. **Tag management UI** — create/edit/delete tags from Settings

---

## Data Location

Windows: `%APPDATA%\<company>\project_atlas\project_atlas.sqlite`

The exact company segment depends on the `CompanyName` field in `windows/runner/Runner.rc` at build time. This was changed from `com.example` to `Paul Peck` in v1.3.0. **If you have an existing database at the `com.example` path, copy it to the new path before launching a rebuilt binary to avoid starting fresh.**

Access directly: Settings → Admin → Open app data folder.

Do not commit the database file, secrets, `.dart_tool/`, `build/`, or any app-data folders.
