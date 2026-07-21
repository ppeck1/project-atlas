# Variable Matrix

This matrix describes the configuration variables used by the current public
Project Atlas source. It intentionally contains names, defaults, and handling
rules only—never live values, credentials, or machine-specific paths.

Last reviewed: 2026-07-21. This is a reconciliation reference: it records
where each value is read, how precedence works, and whether it is portable
between installs. It never records a live value.

## Build, launcher, and test inputs

| Variable | Read by | Default / precedence | Purpose and reconciliation note |
|---|---|---|---|
| `ATLAS_DATABASE_PATH` | `lib/db/db_open.dart` | Unset; platform app-support database when absent | Compile-time Dart define for an isolated database, such as portfolio capture or disposable testing. Do not embed a personal path in a published build. |
| `PROJECT_ATLAS_FLUTTER` | `launch.ps1` | PATH-discovered Flutter when unset | Optional Flutter executable override used by the development launcher. Path-sensitive and local-only. |
| `PROJECT_ATLAS_DART` | `launch.ps1` | PATH Dart, then Dart bundled with resolved Flutter | Optional Dart executable override used by the development launcher. Path-sensitive and local-only. |
| `ATLAS_MCP_SMOKE_DB` | `tools/seed_mcp_smoke_fixture_test.dart` and CI workflow | Unset outside CI | Process environment value naming the CI-owned smoke database. Never point it at a personal Atlas database. |
| `ATLAS_SCHEMA21_SOURCE_DB` | `test/schema21_real_migration_test.dart` | Unset | Compile-time Dart define for an optional local schema-19 migration fixture. |
| `ATLAS_SCHEMA21_EVIDENCE_PATH` | `test/schema21_real_migration_test.dart` | Unset | Compile-time Dart define for the optional local migration evidence output. |

When unset, Atlas uses `project_atlas.sqlite` in the platform application
support directory. The override is compile-time, not a normal runtime setting.
The schema migration values are also Dart defines, not process environment
variables; `ATLAS_MCP_SMOKE_DB` is the process environment exception.

## System-derived process inputs (not Atlas configuration)

| Input | Used by | Handling | Reconciliation note |
|---|---|---|---|
| Windows process `Path` / `PATH` | `lib/services/mcp_connector_autostart_service.dart` | The hidden PowerShell launcher reads either spelling from the inherited process environment and restores the canonical `Path` spelling before it starts a child process. | This is not an Atlas setting and is never persisted. Record it here so a future launcher reconciliation does not mistake this compatibility normalization for user configuration. |

## MCP gateway environment

| Variable | Default | Required when | Sensitive |
|---|---|---|---|
| `PROJECT_ATLAS_EXE` | Repository release executable | The gateway should launch a different Atlas executable | Path may reveal local layout |
| `ATLAS_MCP_AUTH_MODE` | `static` | Selecting `static` or `oauth` authentication | No |
| `ATLAS_MCP_GATEWAY_TOKEN` | Unset | Static-token mode | **Yes** |
| `ATLAS_MCP_RESOURCE_URL` | Unset | OAuth mode | Public URL |
| `ATLAS_MCP_AUTHORIZATION_SERVERS` | Unset | OAuth mode; comma-separated issuer URLs | Usually no |
| `ATLAS_MCP_OAUTH_SCOPE` | `atlas.read` | Overriding the required OAuth scope | No |
| `ATLAS_MCP_RESOURCE_DOCUMENTATION` | Unset | Advertising operator documentation in protected-resource metadata | Public URL |
| `ATLAS_MCP_JWKS_URL` | Unset | OAuth JWT validation; mutually exclusive with introspection | Usually no |
| `ATLAS_MCP_INTROSPECTION_URL` | Unset | OAuth opaque-token validation; mutually exclusive with JWKS | Usually no |
| `ATLAS_MCP_INTROSPECTION_CLIENT_ID` | Unset | Authenticated token introspection | Identifier |
| `ATLAS_MCP_INTROSPECTION_CLIENT_SECRET` | Unset | Authenticated token introspection | **Yes** |
| `ATLAS_MCP_ALLOWED_ORIGINS` | Local origin only | Additional comma-separated browser origins | No, but security-sensitive |
| `ATLAS_MCP_DISCLOSURE_POLICY` | Unset | Every remote gateway start | Path may reveal local layout |
| `ATLAS_MCP_DISCLOSURE_AUDIT_LOG` | `.local/runs/atlas-mcp-disclosure-audit.jsonl` | Overriding the ignored audit destination | Path may reveal local layout |
| `ATLAS_MCP_PRIVATE_NAME_PATTERN` | Generic example-owner pattern | Extending outbound private-name redaction | May contain private names |

The gateway refuses to start without a disclosure policy. Static mode also
requires a token. OAuth mode requires a resource URL, at least one authorization
server, and exactly one token-validation mechanism: JWKS or introspection.

## Test and verification variables

| Variable | Used by | Purpose | Commit value? |
|---|---|---|---|
| `ATLAS_MCP_SMOKE_DB` | `tools/seed_mcp_smoke_fixture_test.dart` | Identifies the CI-owned database initialized by the release executable | No |
| `ATLAS_SCHEMA21_SOURCE_DB` | `test/schema21_real_migration_test.dart` | Optional schema 19 source database for a local migration-to-21 exercise | No |
| `ATLAS_SCHEMA21_EVIDENCE_PATH` | `test/schema21_real_migration_test.dart` | Optional destination for local migration evidence | No |

`tools/seed_portfolio_capture.py` takes an explicit `--db` argument instead of
an environment variable. It refuses paths that do not contain
`portfolio-capture`, requires an Atlas-initialized current schema (schema 25 at
this review), and refuses to seed a database that already contains projects,
work items, or documents. The fixture also seeds public-safe Project Sources
rows for Operations screenshots. Treat the schema number as a verification
target, not a configurable value: update this note whenever a capture is made
against a newer migration.

## In-application settings

These values are saved in Atlas's local `app_meta` table through the Settings
screen. They are not process environment variables.

| Setting key | UI purpose | Default | Sensitive |
|---|---|---|---|
| `ollama_host` | Local Ollama endpoint | `http://localhost:11434` | Usually no |
| `ollama_model` | Default local model | Unset; runtime falls back to `qwen3.5:9b` | No |
| `project_ai_summaries_enabled` | Shows the project AI summary surface | `false` | No |
| `project_ai_summary_include_library` | Includes linked Library documents in evidence packets | `true` | No |
| `project_ai_summary_allow_bulk_refresh` | Enables the Projects-toolbar batch refresh | `false`; effective only when summaries are enabled | No |
| `project_ai_summary_model` | Per-summary model override | Unset; falls back to `ollama_model`, then runtime fallback | No |
| `telegram_enabled` | Enables outbound task-list delivery | Disabled | No |
| `telegram_bot_token` | Telegram Bot API credential | Unset | **Yes — stored as Windows-DPAPI ciphertext in the app-support secret store, not in SQLite.** Legacy plaintext AppMeta values migrate and are deleted on first read. |
| `telegram_chat_id` | Telegram destination | Unset | Treat as private |
| `project_runtime_default_manifest_path` | Runtime manifest used for profile imports | Built-in neutral default path | Path may reveal local layout |
| `project_runtime_default_capsule_enabled` | Default capsule preflight toggle for imported/new runtime profiles | `true` | No |
| `project_runtime_default_capsule_mode` | Capsule preflight mode | `check`; valid values: `off`, `check`, `strict_check` | No |
| `project_runtime_default_capsule_source_path` | Default local capsule source | `.local\\project_protocol` | Path may reveal local layout |
| `project_runtime_default_capsule_profile` | Default capsule profile | `software_project` | No |

On startup or first read, Atlas copies the value from exactly one nonempty older
`project_runtime_default_%_yaml_path` setting into
`project_runtime_default_manifest_path`. It leaves the older setting intact for
downgrade compatibility. A current value always wins; multiple older
candidates fail closed.

The Settings form suggests `mistral` when its model field is blank, while the
runtime fallback is `qwen3.5:9b`. This is recorded intentionally for future
reconciliation: saving the Settings suggestion persists `mistral`; leaving the
stored value blank uses the runtime fallback. Do not treat the two as a single
default without a separate behavior-alignment change.

## Persisted UI and operational state

These `app_meta` keys are real variables, but they are local state rather than
portable configuration. Do not copy them between installations unless a
reconciliation procedure explicitly calls for it.

| Key / pattern | Writer / reader | Unset behavior | Reconciliation note |
|---|---|---|---|
| `active_project_id` | project selection and creation | No active project until one is selected or created | References a local project ID. |
| `active_stage_<projectId>` | project workboard stage selection | First stage is used | Per-project local ID reference. |
| `project_detail::<projectId>::visible_sections` | Project Detail section controls | Default sections remain visible | JSON preference tied to a local project ID. |
| `projects_tab::category_sort`, `projects_tab::project_sort` | Projects screen sort controls | `name_az` | Enum UI preference, not project data. |
| `projects_tab::pinned_categories`, `projects_tab::pinned_projects`, `projects_tab::collapsed_sections`, `projects_tab::visible_categories` | Projects screen | Empty JSON arrays / no saved preference | JSON UI state; local project/category references may not transfer. |
| Projects search query and `/` focus registration | `ProjectsScreen` and `AtlasSearchFocusRegistry` | Empty query; `/` focuses the visible Projects query field | Transient widget state only. It is intentionally not written to `app_meta`, exported, or reconciled between installations. |
| `project_health_finding_suppressions_v1` | Project-health review workflow | Empty suppression list | JSON review-state preference; retain only with evidence. |

## Recovery paths and one-shot handoffs

Full-backup and project-recovery locations are selected through native file or
folder pickers, then passed directly to the recovery service for that one
operation. They are deliberately not persisted as `app_meta` settings: a path
can be private, stale, removable, or point at a different Atlas instance.

| Value / artifact | Writer / reader | Lifetime and handling | Reconciliation note |
|---|---|---|---|
| Full-backup destination, selected `manifest.json`, staging root, and live-recovery safety-backup root | Settings recovery UI -> `AtlasFullBackupService` / `AtlasLiveRecoveryService` | Native-picker result; operation-local only | Treat every selected path as private. A full restore validates and stages first; live replacement is restart-only, uses typed confirmation, and creates a new safety backup. |
| Project-recovery ZIP and staging root | Project Detail and Settings -> `ProjectBundleRecoveryService` | Native-picker result; operation-local only | Project recovery expands only into a separate staging folder; it does not overwrite the live project. |
| `recovery_handoffs/live-recovery-<id>.json` | `AtlasLiveRecoveryService` | App-support one-shot restart handoff, created only after confirmation | Contains selected local paths and must remain app-private. It is not portable configuration and should not be copied during reconciliation. |

## Linked-project compatibility contracts

- `.project/runtime_manifest.json` is the preferred project metadata file.
  When it is absent, Atlas accepts exactly one `.project/*.json` object with a
  nonempty `name` plus map-valued `commands` and `docs` fields.
- `secondary_sync` and `secondary_outbox` are preferred. When absent, Atlas can
  read exactly one non-Atlas `*_sync` map and exactly one non-Atlas
  `*_outbox` directory, while continuing to emit only generic secondary labels.
- Atlas never renames or writes these linked-project compatibility sources.
- Ambiguous fallback candidates are skipped instead of guessed.

## Gateway CLI and external manual contracts

`tools/atlas_mcp_gateway.py` accepts CLI flags for its host, port, executable,
authentication, disclosure policy, and timeout. CLI values take precedence over
the gateway environment values above, which in turn take precedence over code
defaults. The network defaults are loopback host `127.0.0.1`, port `4874`, a
45-second timeout, and no unsafe bind-all behavior. Treat non-loopback binding
and additional origins as security-sensitive operational choices.

The runtime manifest is an input file, not an environment variable. Its normal
local default is `.local\\runtime_manifest.yaml`; profile entries may include
`apps`, `name`, `enabled`, `path`, `start`, `stop`, `tests`, `ports`,
`urls[{label,url}]`, `health_urls`, `notes`, and `autostart`. Atlas reads these
operator-authored fields but does not invent runtime commands.

The following names appear in `docs/SHOPIFY_SEO_REVIEW.md` as a manual external
integration contract. No current production source reads them automatically;
they are documented here to prevent a future reconciler from mistaking them for
active Atlas configuration.

| Manual external variable | Intended meaning | Handling |
|---|---|---|
| `SHOPIFY_SHOP` | Shopify shop identifier | Treat as private business context. |
| `SHOPIFY_CLIENT_ID` | Shopify app identifier | Do not publish a live value. |
| `SHOPIFY_CLIENT_SECRET` | Shopify app secret | **Secret**; keep only in ignored operator storage. |
| `SHOPIFY_API_VERSION` | Requested Shopify API version | Explicit operator choice. |
| `SHOPIFY_SYNC_MODE` | Manual sync guardrail | Must remain `read_only`. |

## Handling rules

- Keep credentials and disclosure policies under ignored local storage.
- Never commit real values, `.env` files, app databases, audit logs, or capture
  build paths.
- Use HTTPS for non-loopback OAuth endpoints and browser origins.
- Treat a database path, executable path, chat identifier, and redaction pattern
  as potentially identifying even when they are not authentication secrets.
- Re-run the source, screenshot, and built-artifact privacy scans before a
  public release.
