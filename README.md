# Project Atlas

Local-first project command center for personal work tracking.

Project Atlas is a Flutter desktop app for answering the daily operational questions: what am I carrying, what is blocked, what needs action today, and what should go to my phone? It stores data locally in SQLite through Drift. There is no cloud sync, no telemetry, and optional integrations stay user-reviewed.

## Current State

- Version: `1.4.0+1`
- Platform target: Flutter desktop, currently Windows-oriented
- Storage: local SQLite via Drift, schema version `20`
- Primary navigation: Today, Projects, Work, Operations, Library, Settings
- Legacy deep links still available: Dashboard, Review, Export, Governance, Backend Log
- Optional local AI: Ollama drafts, Today/Review summaries, and work-item analysis remain human-in-the-loop
- Project AI summaries: disabled by default, with an opt-in Settings wizard for manual review, Library evidence defaults, ranked evidence preview, and packet warnings
- Optional phone handoff: outbound Telegram task-list sending with outbox logging
- Contacts / workforce directory with JSON and CSV import/export
- Stage management: add, rename, delete, and reorder stages via API (`AppState.addStage`, `updateStageTitle`, `deleteStage`, `reorderStage`)
- Owner pickers on work items, project owners, and governance stages — all linked to the contact directory
- Project organization: category grouping, pinned categories/projects, category visibility selection, category and project sorting, tag assignment, project filters for context/status/phase/priority, status descriptors for Open/Review/Inactive/Closed lifecycle states, and project merge
- Project runtime profiles: opt-in per-project launch/stop/test commands, ports, URLs, and health checks with Launch/Test/Capsule actions, run history, settings-backed Dev Launchpad/capsule defaults, Dev Launchpad YAML import, and Project Ops Capsule integration — commands are operator-configured and never invented by the app
- Project change log: per-project event history with changed-field views, newest/oldest sort controls, JSON copy, and persisted AI change-summary drafts in Project Detail
- Project metadata: description, desired outcome, success criteria, scope, outcome summary, lessons learned
- Project governance: people roster, risk register, decision log
- Workboard planning layer: global board grouped by readiness with filters for project/readiness/actor/risk/size/blocked/review/stale/high-priority, deterministic snapshot counts, next-work scoring, and explicit bulk planning actions for work items and queue items
- Project media: app-owned image/file gallery with cover-image selection; media can be attached to work items and queued LLM tasks; local refresh imports discovered image, video, and audio files from linked project folders
- Document library: native file picker, app-owned copies, in-app preview, and AI analysis integration
- Local Operations Registry: manual shallow scans of operator-selected local project folders, selectable additional folders, append-only observations, queue filters, bulk candidate review, reviewed registry records, candidate accept/link/ignore/needs-review actions, create/update existing Project actions, first-import local refresh for docs/media/source/card/native project rows, Atlas-only enrichment runs with open findings, scan JSON copy/export, project bundle preview/export with bootstrap JSON/Markdown artifacts, and app-owned scan artifact storage
- Agent boundary: `AtlasAgentService` exposes read-heavy project status/brief/summary operations, Workboard workload snapshots/suggestions/context bundles, Project Ops Capsule identity/evidence/bootstrap context reads, queue-bound bootstrap packets, Atlas-only enrichment runs/findings, an operator-editable persisted LLM task queue with media attachment context, and proposal-first writes including closeout records stored as reviewable drafts (`kind='atlas_agent_proposal'`) for the Atlas MCP and local LLM harness

## Project Ops Capsule Audit

Project Ops Capsule v0.2 is installed as repo-local metadata under `.project/` with public-repo raw evidence and outboxes kept local-only by `.gitignore`. The capsule records launch, test, build, documentation, Atlas outbox, BOH outbox, and git closeout evidence; it is not the Atlas Operations scanner, a BOH promotion mechanism, a GitHub sync engine, or authority to bypass proposal review.

## Screenshots

These screenshots are current Windows desktop captures from the schema v20 app,
with local project paths and private library rows sanitized for the public repo.
They show daily focus, project runtime controls, local Operations review,
Library-backed AI draft review, and opt-in AI summary settings.

![Today dashboard with focus list, phone queue, and operator signals](docs/screenshots/today.png)

![Opened project detail with work board, metadata, export, launch, test, and capsule actions](docs/screenshots/projects.png)

![Operations workspace with scan review, registry counts, and project health findings](docs/screenshots/operations.png)

![Library view with documents, media, AI drafts, and agent proposal review](docs/screenshots/library.png)

![Settings AI Summaries setup with Library evidence and bulk refresh gates](docs/screenshots/settings.png)

The checked-in PNGs should be recaptured from the desktop app for release docs.
For fallback public-safe mockups only, run:

```powershell
python tools\generate_readme_screenshots.py
```

## Quick Start

```powershell
# First time, or after schema/source changes:
.\launch.ps1 -Full

# Normal daily launch:
.\launch.ps1
```

`launch.ps1` uses `flutter` and `dart` from `PATH`. Set `PROJECT_ATLAS_FLUTTER`
or `PROJECT_ATLAS_DART` to an explicit executable path if your Flutter install
is not on `PATH`.

Manual path:

```powershell
flutter pub get
dart run build_runner build
flutter run -d windows
```

After changing Drift tables or database code, rerun build runner before launching.

## Main Screens

| Screen | Current role |
| --- | --- |
| Today | Focus list for doing, overdue, due today, phone queue, blocked, and high-priority work |
| Projects | Category-grouped project list with pinned category/project ordering, category visibility, runtime quick actions (launch/test/capsule), active project switching, lifecycle metadata, tag/status/phase/priority filters, project merge, project bundle export wizard, detail entry point |
| Project Detail | Collapsible task header with project tasks and editable/movable LLM queue items with media attachments, identity, scope, lifecycle fields, runtime profile section with run history, project change log with sort controls and persisted AI change summaries, local repo refresh preview/apply for docs/media/native rows, read-only git visibility inspection, project bundle preview/export, people roster, risk register, decision log, media gallery, tag assignment |
| Work | Workboard planning surface grouped by readiness with workload metadata, filters, deterministic planning snapshot, next-work suggestions, and explicit bulk planning actions |
| Operations | Manual local project scans, reviewable observations, local registry records, create/update existing Project bridge, enrichment run dashboard/findings, Project Health tab with grouped finding actions (dismiss/suppress/mark reviewed), warnings, scan JSON copy/export, warnings JSON save, and app scan-folder access |
| Library | Documents, project media, and AI drafts with search, project/type filters, native file picker import, copy, preview, and file-open actions |
| Settings | Integrations, AI summary setup, activity log, export tools, workforce contacts, backup export, app-data access, and admin controls |
| Review | Blocked/overdue/in-progress review and optional Ollama briefing |
| Export | Markdown task list, Telegram send, AI summary, and outbox visibility |
| Governance | Stage ownership and bottleneck flags |
| Backend Log | Recent event log filtering and JSON/Markdown copy |

## Document Library

The Library screen unifies three content types: imported **documents**, project **media**, and AI **drafts**. All document types are imported via a native Windows file picker — no manual path entry.

### Supported file types and preview behavior

| Extension(s) | Preview | Content at import |
|---|---|---|
| `.txt`, `.log`, `.csv`, `.xml`, `.yaml`, `.yml`, `.ini`, `.toml`, `.rst` | Plain text (selectable, monospace) | Extracted to `extracted_text` column |
| `.md` | Rendered Markdown (`flutter_markdown`) | Stored in `rendered_markdown` column |
| `.json` | Pretty-printed, indented (monospace) | Extracted to `extracted_text` column |
| `.html`, `.htm` | Rendered HTML (`flutter_html`) | Raw HTML stored in `rendered_markdown`; tag-stripped text in `extracted_text` (searchable) |
| `.eml` | RFC-2822 headers stripped, body as plain text | Body extracted to `extracted_text` at import |
| `.docx` | Extracted paragraph text (plain) | Word XML parsed at import; stored in `extracted_text` |
| `.doc`, `.rtf`, `.pdf`, `.svg` | "Open in system viewer" button | No extraction |
| `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.bmp` | Inline `InteractiveViewer` with pan/zoom | None (binary) |

All imported files are **copied** into the app data directory (`atlas_documents/` subfolder). Moving or deleting the original has no effect on the stored copy. Deleting a document record via the Library UI also deletes the app-owned copy from disk.

MIME type is detected at import and saved to the `mime_type` column. Image documents are tagged `mediaType: 'image'` internally so they appear under the **Images** filter and use the image viewer.

### Library filters

| Filter | Shows |
|---|---|
| All types | Everything |
| Documents | Non-media, non-draft entries |
| Media | All `project_media` entries |
| Images | Media or documents with `mediaType = 'image'` |
| AI Drafts | Ollama-generated drafts |

### Linking documents and media to work items

Documents can be linked to work items in the Work Item Detail sheet. Linked work-item documents are included in Ollama work-item analysis; project-linked Library documents are included in project structured summaries (up to 3 000 chars per document, 16 000 char total cap).

Project media can also be attached from the Work Item Detail sheet. These attachments keep visual/audio/file context beside the task without feeding binary content into Ollama prompts.

## Contacts / Workforce

The Settings → Workforce tab manages a contact directory. Contacts are linked everywhere an owner can be assigned:

- New task dialog (Owner field)
- Work item detail sheet (Owner field)
- Project detail (Project owner)
- Governance screen (Stage owner)

Owner fields use the `ContactOwnerField` widget, which shows a dropdown of existing contacts and a "Create contact..." option for inline creation.

**Import format** (Settings → Workforce → Import JSON):

```json
{
  "schema": "project_atlas_contacts_v1",
  "contacts": [
    {
      "name": "Alice Smith",
      "title": "Engineer",
      "phone": "555-0100",
      "email": "alice@example.com",
      "businessName": "Acme"
    }
  ]
}
```

Import deduplicates by `id`, then `email`, then `name`. Raw JSON arrays (without the wrapper object) are also accepted.

Export options: JSON (re-importable) and CSV (for spreadsheets).

## Local AI

Ollama is optional. AI output is advisory and is shown for review before it is saved as a draft or analysis.

```powershell
ollama pull mistral
```

Configure the host and model in **Settings → Integrations**. The default host is `http://localhost:11434`.

When Ollama is reachable, the model field becomes a **dropdown** populated with all locally installed models — click the refresh button to re-fetch the list. If Ollama is offline, the field falls back to a free-text input so you can type the model name manually. The default model in code is `qwen3.5:9b`; the Settings UI shows `mistral` as the hint text.

AI actions available:
- **Today summary** — summarizes doing/overdue/blocked items (Export tab or Review screen)
- **Project AI summaries** — opt-in via **Settings -> AI Summaries**; project summaries can use the global Ollama model or a summary-specific installed model, can default to Library evidence, preview the categorized ranked evidence packet with warnings, log summary run provenance, emit deterministic evaluation JSON for tests, and keep bulk refresh separately gated while invalid schema/claim output fails validation
- **Project change summaries** — Project Detail -> Change Log can summarize normalized project changes into a saved `project_change_summary` draft. Runs are tracked in app state so navigation does not cancel them, failed/timeout output is not treated as a saved summary, and project bundle exports can include the latest summary plus full evidence/input JSON.
- **Project summary (prose)** — legacy prose summary; still available via `summarizeProject()` in OllamaService
- **Email draft** — drafts an email for a specific work item (Work Item Detail)
- **Task extract** — extracts tasks from free-form note text (Work Item Detail)
- **Work item analysis** — read-only advisory analysis including linked documents (Work Item Detail)

## Agent / MCP Boundary

`lib/services/atlas_agent_service.dart` is the desktop-side contract intended for the future Atlas MCP and for a local LLM harness.

- Read operations assemble stable project DTOs: alphabetical project list, status, brief, capsule-aware project identity, capsule evidence availability, bootstrap context, stale/attention list, local refresh preview, git visibility inspection, enrichment run history/findings, and local-refresh triggers.
- Write-shaped operations are proposal-first. Status changes, task updates, manifest updates, validation runs, handoffs, and agent closeouts are validated and saved as Library drafts with `kind='atlas_agent_proposal'`.
- Library has an **Agent Proposals** filter with pending/approved/rejected status chips. Pending proposals can be approved or rejected from the detail pane; approved status/task/manifest proposals apply through `AppState`, validation proposals log the run, and handoff proposals create a `project_handoff` draft.
- The MCP tool registry lives in `lib/mcp/atlas_mcp_server.dart`, with a local stdio JSON-RPC wrapper available from the Windows executable via `--mcp-stdio` for release builds. It exposes reads, capsule-aware bootstrap tools, read-only Workboard tools (`atlas.workload_snapshot`, `atlas.project_workload`, `atlas.suggest_next_work`, `atlas.work_item_context_bundle`), Atlas-only enrichment triggers, existing LLM queue lifecycle tools, and proposal-creation tools; approval/rejection stays in the desktop review queue. Project Detail lets the operator edit, move, cancel, requeue, and attach media to LLM tasks. MCP `get_project_bootstrap_context` returns the project startup packet; `get_llm_task_bootstrap` returns a task plus its project startup packet; `get_llm_task` returns attached media metadata for harness context. Queue completion can attach a proposed handoff as a reviewable draft, and `propose_closeout` records validation/git/packet evidence for review instead of directly mutating project state.
- The service does not delete projects, overwrite manifests, push/fetch Git, or mutate discovered repositories. Human review remains the approval boundary.
- Workboard MCP tools are read-only planning views. They do not claim tasks, complete work, run harness jobs, or mutate queue state.

## Project Runtime Profiles

Each project can opt into a **software runtime profile**: working directory, launch command, stop command, test commands, ports, URLs, and health-check URLs. Configure it in the project metadata dialog (Software runtime section) or import it from a local Dev Launchpad YAML.

- **Launch** opens the configured command in a visible PowerShell window and polls the health URLs.
- **Test** runs the configured test commands headless and records output and exit codes.
- **Capsule** runs the Project Ops Capsule tooling for the project when enabled.

Every action is recorded in a per-project run history (status, exit code, output). All commands are operator-entered; Atlas never generates or auto-runs commands, and the stored `autostart` flag is not acted on. Default Dev Launchpad YAML and Project Ops Capsule settings are machine-specific and can be set in Settings -> Integrations -> Project runtime defaults.

## Telegram

Telegram is outbound only.

1. Create a bot with [@BotFather](https://t.me/botfather).
2. Get the destination chat ID.
3. Enter the bot token and chat ID in Settings → Integrations.
4. Use Settings → Export → "Send to Telegram" to send the current task list.

All user text is HTML-escaped before sending. Send attempts are tracked in the local outbox.

## Database

- Engine: SQLite via Drift `NativeDatabase`
- Schema version: `20`
- Windows data path: `%APPDATA%\<company>\project_atlas\project_atlas.sqlite` — exact path depends on build; use **Settings → Admin → Open app data folder** to locate it
- Operations scan artifacts: `<app support>\operations_scans\` with `runs`, `warnings`, and `logs` subfolders
- Encryption: plaintext SQLite (no encryption library included; SQLCipher integration is planned for a future release)
- Compatibility: startup repair/backfill handles partially migrated local databases

Do not commit local database files, secrets, app-data folders, `.dart_tool`, `build`, or generated Drift output.

## Architecture

```text
lib/
  app/           App widget, router, theme
  db/            Drift tables, AppDb, database open path, document_extractor
  mcp/           Atlas MCP tool registry and JSON-safe dispatcher
  services/      Ollama (OllamaService, project_summary_models.dart), Telegram, app logging, local project scan/refresh services, project runtime service, workload planning service, AtlasAgentService
  features/      today, projects, operations, library, settings, work, review, export, governance, log
  shared/
    models/      AppState and scope
    widgets/     shell, dialogs, pickers, document_preview
```

`lib/db/document_extractor.dart` — standalone pure-Dart utilities: `textDocumentExtensions` (const Set), `shouldLoadDocumentText()`, `extractDocxTextFromBytes()`, `extractHtmlText()`, `mimeTypeForExtension()`, `stripEmlBody()`. Used by both `AppDb` and `DocumentPreview`; fully unit-tested without Flutter dependencies.

See `VARIABLE_MAP.md` for complete table columns, service fields, data flows, and migration notes.
See `HANDOFF.md` for project context, design decisions, and known issues.
See `DEMO.md` for a step-by-step walkthrough covering all Library file types.

## Development Notes

```powershell
.\launch.ps1          # smart launch
.\launch.ps1 -Full    # pub get + build_runner + run
.\launch.ps1 -Build   # codegen only
.\launch.ps1 -Clean   # flutter clean + full rebuild + run
```

Recommended checks:

```powershell
flutter analyze
flutter test
```

Generated files and build products are intentionally ignored:

- `lib/db/app_db.g.dart`
- `.dart_tool/`
- `build/`
- local app-data and secret files

## Roadmap

- In-app PDF rendering (currently opens in system viewer)
- Drafts screen as a first-class route
- Inbound Telegram commands such as `/done`, `/snooze`, and `/add`
- Atlas MCP wrapper over `AtlasAgentService`
- Restore/import flow for project bundles and operational backups
- Restore/import flow for operational backup (ZIP)
- SQLCipher encrypted storage path before broader distribution
- Review history browser — `watchRecentDailyReviews()` exists in the DB layer; no history screen yet
