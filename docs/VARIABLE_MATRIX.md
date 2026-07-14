# Variable Matrix

This matrix describes the configuration variables used by the current public
Project Atlas source. It intentionally contains names, defaults, and handling
rules only—never live values, credentials, or machine-specific paths.

Last reviewed: 2026-07-14.

## Build-time Dart definitions

| Variable | Default | Purpose | Handling |
|---|---|---|---|
| `ATLAS_DATABASE_PATH` | Unset | Overrides the SQLite file for an isolated build, such as portfolio capture or disposable testing | Passed with `--dart-define`; do not embed a personal path in a published build |

When unset, Atlas uses `project_atlas.sqlite` in the platform application
support directory. The override is compile-time, not a normal runtime setting.

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
`portfolio-capture`, requires an Atlas-initialized schema, and refuses to seed a
database that already contains projects, work items, or documents.

## In-application settings

These values are saved in Atlas's local `app_meta` table through the Settings
screen. They are not process environment variables.

| Setting key | UI purpose | Default | Sensitive |
|---|---|---|---|
| `ollama_host` | Local Ollama endpoint | `http://localhost:11434` | Usually no |
| `ollama_model` | Default local model | `mistral` when no model is selected | No |
| `telegram_enabled` | Enables outbound task-list delivery | Disabled | No |
| `telegram_bot_token` | Telegram Bot API credential | Unset | **Yes** |
| `telegram_chat_id` | Telegram destination | Unset | Treat as private |
| `project_runtime_default_manifest_path` | Runtime manifest used for profile imports | Built-in neutral default path | Path may reveal local layout |

On startup or first read, Atlas copies the value from exactly one nonempty older
`project_runtime_default_%_yaml_path` setting into
`project_runtime_default_manifest_path`. It leaves the older setting intact for
downgrade compatibility. A current value always wins; multiple older
candidates fail closed.

## Linked-project compatibility contracts

- `.project/runtime_manifest.json` is the preferred project metadata file.
  When it is absent, Atlas accepts exactly one `.project/*.json` object with a
  nonempty `name` plus map-valued `commands` and `docs` fields.
- `secondary_sync` and `secondary_outbox` are preferred. When absent, Atlas can
  read exactly one non-Atlas `*_sync` map and exactly one non-Atlas
  `*_outbox` directory, while continuing to emit only generic secondary labels.
- Atlas never renames or writes these linked-project compatibility sources.
- Ambiguous fallback candidates are skipped instead of guessed.

## Handling rules

- Keep credentials and disclosure policies under ignored local storage.
- Never commit real values, `.env` files, app databases, audit logs, or capture
  build paths.
- Use HTTPS for non-loopback OAuth endpoints and browser origins.
- Treat a database path, executable path, chat identifier, and redaction pattern
  as potentially identifying even when they are not authentication secrets.
- Re-run the source, screenshot, and built-artifact privacy scans before a
  public release.
