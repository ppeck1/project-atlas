# Architecture

Project Atlas is a Flutter Windows desktop application organized around a
local data store and explicit service boundaries.

## Layers

1. `lib/features` contains screen-specific presentation and interaction logic.
2. `AppState` coordinates UI state, long-running operations, and service calls.
3. `lib/services` contains domain workflows such as discovery, refresh,
   runtime execution, AI summaries, metadata lookup, and export preparation.
4. `AppDb` and Drift tables own persistence, migrations, and query boundaries.
5. `lib/mcp` adapts a limited set of application operations to a trusted local
   stdio MCP server.

The desktop process is the authority for local writes. AI and MCP callers use
proposal or queue workflows where review matters; they do not bypass the data
layer or silently mutate unrelated repositories.

## Data flow

- UI actions call `AppState` methods.
- `AppState` validates user intent and delegates to a service or `AppDb`.
- Services return typed results, previews, findings, or drafts.
- Durable changes are recorded in SQLite, including relevant run history and
  review state.
- Screens subscribe to state changes and render the persisted result.

## External boundaries

Atlas is usable without any network integration. GitHub reads, Telegram sends,
Ollama requests, runtime commands, and the remote MCP gateway are opt-in and
operator-configured. Each boundary has a deliberately narrower data contract
than the internal model.

## Failure model

Parsing and remote projection fail closed when required configuration or schema
information is missing. Long-running work records status and error details, and
reviewable proposals remain separate from applied state.
