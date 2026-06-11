# Project Atlas

Local-first project command center for personal work tracking.

Project Atlas is a Flutter desktop app for answering the daily operational questions: what am I carrying, what is blocked, what needs action today, and what should go to my phone? It stores data locally in SQLite through Drift. There is no cloud sync, no telemetry, and optional integrations stay user-reviewed.

## Current State

- Version: `1.2.0+1`
- Platform target: Flutter desktop, currently Windows-oriented
- Storage: local SQLite via Drift, schema version `8`
- Primary navigation: Today, Projects, Library, Settings
- Legacy deep links still available: Dashboard, Work, Review, Export, Governance, Backend Log
- Optional local AI: Ollama summaries and drafts, always human-in-the-loop
- Optional phone handoff: outbound Telegram task-list sending with outbox logging
- Current source tree includes contacts/workforce management, document library, activity logging, project detail metadata, risks, decisions, work-item notes, and read-only AI analyses

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

Manual path:

```powershell
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d windows
```

After changing Drift tables or database code, rerun build runner before launching.

## Main Screens

| Screen | Current role |
| --- | --- |
| Today | Focus list for doing, overdue, due today, phone queue, blocked, and high-priority work |
| Projects | Project list, active project switching, lifecycle metadata, detail entry point |
| Library | Documents and AI drafts with search, project/type filters, import, copy, and file-open actions |
| Settings | Integrations, activity log, export tools, workforce contacts, and admin controls |
| Work | Legacy stage/task list with editable work items |
| Review | Blocked/overdue/in-progress review and optional Ollama briefing |
| Export | Markdown task list, Telegram send, AI summary, and outbox visibility |
| Governance | Stage ownership and bottleneck flags |
| Backend Log | Recent event log filtering and JSON/Markdown copy |

## Local AI

Ollama is optional. AI output is advisory and is shown for review before it is saved as a draft or analysis.

```powershell
ollama pull mistral
```

Configure the host and model in Settings -> Integrations. The default host is `http://localhost:11434`. The UI currently shows `mistral` as the default model in Settings; older docs and some service paths may mention `qwen3.5:9b`.

## Telegram

Telegram is outbound only.

1. Create a bot with [@BotFather](https://t.me/botfather).
2. Get the destination chat ID.
3. Enter the bot token and chat ID in Settings -> Integrations.
4. Use Export to send the current task list.

All user text is HTML-escaped before sending. Send attempts are tracked in the local outbox.

## Database

- Engine: SQLite via Drift `NativeDatabase`
- Schema version: `8`
- Observed Windows support path: `%APPDATA%\com.example\project_atlas\project_atlas.sqlite`
- Encryption: not currently enabled in `lib/db/db_open.dart`
- Compatibility: startup repair/backfill handles partially migrated local databases and older project/work-item/stage columns

Do not commit local database files, secrets, app-data folders, `.dart_tool`, `build`, or generated Drift output.

## Architecture

```text
lib/
  app/           App widget, router, theme
  db/            Drift tables, AppDb, database open path
  services/      Ollama, Telegram, app logging
  features/      today, projects, library, settings, work, review, export, governance, log
  shared/
    models/      AppState and scope
    widgets/     shell, dialogs, pickers, previews
```

See `VARIABLE_MAP.md` for table columns, service fields, data flows, and migration notes.

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
- SQLCipher or another encrypted storage path before broader distribution
- Daily review persistence and review history browsing
