# Project Atlas

Local-first project command center for personal work tracking.

Project Atlas is a Flutter desktop app for answering the daily operational questions: what am I carrying, what is blocked, what needs action today, and what should go to my phone? It stores data locally in SQLite through Drift. There is no cloud sync, no telemetry, and optional integrations stay user-reviewed.

## Current State

- Version: `1.3.0+1`
- Platform target: Flutter desktop, currently Windows-oriented
- Storage: local SQLite via Drift, schema version `10`
- Primary navigation: Today, Projects, Library, Settings
- Legacy deep links still available: Dashboard, Work, Review, Export, Governance, Backend Log
- Optional local AI: Ollama structured project summaries, prose summaries, drafts, and work-item analysis — always human-in-the-loop
- AI summary caching: structured summaries are stored as drafts and loaded instantly on Project Detail open; background job pre-generates summaries for all active projects 10 seconds after startup (once per day per project)
- Optional phone handoff: outbound Telegram task-list sending with outbox logging
- Contacts / workforce directory with JSON and CSV import/export
- Stage management: add, rename, delete, and reorder stages via API (`AppState.addStage`, `updateStageTitle`, `deleteStage`, `reorderStage`)
- Owner pickers on work items, project owners, and governance stages — all linked to the contact directory
- Project organization: tag assignment and project filters for context, status, phase, and priority
- Project metadata: description, desired outcome, success criteria, scope, outcome summary, lessons learned
- Project governance: people roster, risk register, decision log
- Project media: app-owned image/file gallery with cover-image selection
- Document library: import local files, link them to work items, and include them in AI analysis

## Screenshots

These screenshots use demo data and reflect the current UI structure.

![Today screen](docs/screenshots/today.png)

![Projects screen](docs/screenshots/projects.png)

![Library screen](docs/screenshots/library.png)

![Settings screen](docs/screenshots/settings.png)

Regenerate the README screenshots with:

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

`launch.ps1` uses `flutter` and `dart` from `PATH` when available. If they are
not on `PATH`, it falls back to `B:\dev\flutter\bin\flutter.bat` and that SDK's
bundled Dart. Set `PROJECT_ATLAS_FLUTTER` or `PROJECT_ATLAS_DART` to an explicit
executable path to override discovery.

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
| Projects | Project list, active project switching, lifecycle metadata, tag/status/phase/priority filters, detail entry point |
| Project Detail | Identity, scope, lifecycle fields, people roster, risk register, decision log, structured AI summary panel (7 sections, instant cached load, age badge), media gallery, tag assignment |
| Library | Documents, project media, and AI drafts with search, project/type filters, import, copy, preview, and file-open actions |
| Settings | Integrations, activity log, export tools, workforce contacts, backup export, app-data access, and admin controls |
| Work | Legacy stage/task list with editable work items |
| Review | Blocked/overdue/in-progress review and optional Ollama briefing |
| Export | Markdown task list, Telegram send, AI summary, and outbox visibility |
| Governance | Stage ownership and bottleneck flags |
| Backend Log | Recent event log filtering and JSON/Markdown copy |

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
- **Structured project summary** — produces a 7-section JSON-parsed summary for a project using `format:"json"` Ollama output mode (Project Detail); sections are Goal, Current State, Ownership/Active Work, Relevant Library Docs, Blockers/Risks, Next Practical Actions, and Confidence/Gaps. The summary is cached as a draft (`kind='project_summary'`) and loads instantly on next open. An age badge in the panel header shows when the cached summary was generated. Relevant Library Docs entries include "Open in Library" (navigates to the document) and "Show in Explorer" (opens Windows Explorer with the file selected) actions.
- **Project summary (prose)** — legacy prose summary; still available via `summarizeProject()` in OllamaService
- **Email draft** — drafts an email for a specific work item (Work Item Detail)
- **Task extract** — extracts tasks from free-form note text (Work Item Detail)
- **Work item analysis** — read-only advisory analysis including linked documents (Work Item Detail)

## Telegram

Telegram is outbound only.

1. Create a bot with [@BotFather](https://t.me/botfather).
2. Get the destination chat ID.
3. Enter the bot token and chat ID in Settings → Integrations.
4. Use Settings → Export → "Send to Telegram" to send the current task list.

All user text is HTML-escaped before sending. Send attempts are tracked in the local outbox.

## Database

- Engine: SQLite via Drift `NativeDatabase`
- Schema version: `10`
- Observed Windows support path: `%APPDATA%\com.example\project_atlas\project_atlas.sqlite`
- Encryption: `sqlcipher_flutter_libs` is included but not yet activated in `lib/db/db_open.dart`
- Compatibility: startup repair/backfill handles partially migrated local databases

Do not commit local database files, secrets, app-data folders, `.dart_tool`, `build`, or generated Drift output.

## Architecture

```text
lib/
  app/           App widget, router, theme
  db/            Drift tables, AppDb, database open path
  services/      Ollama (OllamaService, project_summary_models.dart), Telegram, app logging
  features/      today, projects, library, settings, work, review, export, governance, log
  shared/
    models/      AppState and scope
    widgets/     shell, dialogs, pickers, previews
```

See `VARIABLE_MAP.md` for complete table columns, service fields, data flows, and migration notes.
See `HANDOFF.md` for project context, design decisions, and known issues.

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

- Drafts screen as a first-class route
- Inbound Telegram commands such as `/done`, `/snooze`, and `/add`
- Project snapshots and decision-log export
- Restore/import flow for operational backup JSON
- SQLCipher encrypted storage path before broader distribution
- Review history browser — `watchRecentDailyReviews()` exists in the DB layer; no history screen yet
