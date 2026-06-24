# Contributing to Project Atlas

Project Atlas is a personal productivity tool for Windows. Pull requests are welcome, particularly for bug fixes and improvements to existing features. New feature requests may be declined if they fall outside the personal-tool scope — open an issue first to discuss before investing effort in a large change.

## Prerequisites

- Flutter SDK, stable channel, version 3.x or later
- Windows 10 or Windows 11
- PowerShell

## Building

**First build (generates Drift code and fetches dependencies):**

```powershell
.\launch.ps1 -Full
```

**Daily development:**

```powershell
.\launch.ps1
```

## Required Checks Before Submitting a PR

Both of the following must pass with zero issues:

```powershell
flutter analyze
flutter test
```

Fix all analyzer warnings and test failures before opening a pull request.

## Drift / Database Schema Changes

Any modification to `lib/db/tables.dart` or `lib/db/app_db.dart` requires regenerating the Drift-generated code:

```powershell
dart run build_runner build --delete-conflicting-outputs
```

Commit the regenerated `.g.dart` files along with your schema change.

## Commit Style

- Imperative, present tense: "Add CI workflow" not "Added CI workflow"
- Scope-prefix when helpful: "Fix document preview routing", "Add Telegram notification retry"
- Keep the subject line under 72 characters; use the body for context when needed

## Questions

Open a GitHub issue for questions about contributing or the codebase.
