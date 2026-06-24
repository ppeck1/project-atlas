Project Atlas — Architecture Notes
===================================

Overview
--------

Project Atlas is a local-first Flutter desktop application for personal
project management. All data is stored in a SQLite database via Drift ORM.
There is no cloud sync, no telemetry, and no background services.

Core Screens
------------

**Today**
    Focus list showing items that are doing, overdue, due today,
    or in the phone queue. Tap any item to open the detail sheet.

**Projects**
    Project list with status, phase, and priority filters.
    Create or switch the active project here.

**Library**
    Unified view of imported documents, project media, and AI drafts.
    Supports 20+ file extensions with in-app preview or system viewer fallback.

**Settings**
    Integrations (Ollama, Telegram), workforce contacts,
    export tools, and admin controls.

Key Design Constraints
----------------------

- No network calls except optional Ollama and Telegram integrations.
- All AI output is advisory and requires human review before saving.
- File imports are app-owned copies; original files are never modified.
- Schema migrations are defensive: duplicate-column errors are silently ignored.
