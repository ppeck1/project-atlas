# ChatGPT, Codex, and Claude MCP Access

Project Atlas exposes an MCP-compatible JSON-RPC adapter for local agent work
and an optional authenticated remote projection for ChatGPT. The local stdio
surface is broad and machine-trusted; the remote surface is a separate
deny-by-default four-tool boundary.

## Local Stdio Access

Local clients such as Codex or Claude can launch the Atlas executable with:

```powershell
build\windows\x64\runner\Release\project_atlas.exe --mcp-stdio
```

The stdio adapter reads newline-delimited JSON-RPC from stdin and writes
responses to stdout. It opens the same local SQLite-backed Atlas state as the
desktop app, so clients should treat responses as local operator data that may
include local project paths, queue context, and review drafts.

Project-scoped Codex configuration only enables Codex in that workspace. It
does not make the local Windows stdio server available to ChatGPT, to other
OpenAI products, or to browsers.

## ChatGPT Remote Or Tunneled Access

ChatGPT access requires a separate authenticated remote or tunneled adapter.
Do not expose the raw stdio process directly to the public internet.

The tracked remote/tunneled adapter provides the following boundary:

- Authenticated users or service principals.
- A role allowlist that is enforced before forwarding any `tools/call`.
- No non-read tool classes.
- A required ignored project disclosure policy with approved aliases.
- Strict per-tool output projection plus defense-in-depth text scrubbing.
- Transport security appropriate for the tunnel or hosted endpoint.
- A metadata-only disclosure audit for allowed and denied remote reads. Queue,
  enrichment, and proposal activity remains on the broader local audit paths
  because those operations are not remotely exposed.

Without the authenticated gateway, HTTPS tunnel, and valid disclosure policy,
ChatGPT has no direct Atlas MCP access. The local stdio registration alone does
not enable ChatGPT access.

## Role Allowlists

The MCP tool registry advertises access metadata in each `tools/list` result:

- `annotations.readOnlyHint` - whether the tool should be treated as read-only.
- `annotations.openWorldHint` - whether the tool may reach outside local Atlas
  state, such as read-only GitHub metadata refresh.
- `_meta.atlas.accessClass` - Atlas-specific access class.
- `_meta.atlas.roleAllowlist` - client/gateway roles that may call the tool.
- `_meta.atlas.localOnly` - current transport boundary marker.
- `_meta.atlas.reviewBoundary` - whether the tool creates a human-reviewable
  proposal instead of directly applying a change.

These metadata fields are a client and gateway filtering contract. The local
stdio process is not an authentication boundary by itself.

| Access class | Role allowlist | Typical tools | Boundary |
| --- | --- | --- | --- |
| `reader` | `atlas.reader`, `atlas.local_operator` | Project status, bootstrap context, Workboard reads, queue reads, proposal reads | Read-only; may still expose local paths or private context. |
| `local-operator` | `atlas.local_operator` | `refresh_github_remote_status` | Local operator action; may use read-only network calls. |
| `enrichment-runner` | `atlas.enrichment_runner`, `atlas.local_operator` | `run_project_enrichment` | Updates Atlas-owned enrichment records, not source repos. |
| `queue-manager` | `atlas.queue_manager`, `atlas.local_operator` | `enqueue_llm_task` | Creates durable Atlas queue rows only. |
| `queue-worker` | `atlas.queue_worker`, `atlas.local_operator` | `claim_llm_task`, `complete_llm_task`, `fail_llm_task` | Mutates queue lifecycle state; completion output remains reviewable when it creates drafts. |
| `proposal-writer` | `atlas.proposal_writer`, `atlas.local_operator` | `propose_*`, `record_*` | Creates reviewable Atlas proposal drafts; approval stays in the desktop review flow. |

## Client Defaults

Default local Codex or Claude setups should start with `atlas.reader` unless
the operator is intentionally running a queue worker or proposal-writing task.

Default ChatGPT remote/tunneled setups should start with no tools enabled. The
first supported remote profile should be read-only, should enforce
`atlas.reader`, and should add redaction or disclosure review before exposing
local paths or private project packet content.

The tracked gateway prototype narrows that first profile to `list_projects`,
`get_project_status`, `atlas.workload_snapshot`, and
`atlas.project_planning_context` only. It requires a local ignored mapping of
approved project IDs to remote aliases. Tool results are parsed from their MCP
text blocks and rebuilt from exact output allowlists. Planning free text,
accepted-truth claims, commands, notes, evidence excerpts, and broader reads
remain blocked until their semantics and disclosure preview are hardened.

For ChatGPT connector work, the gateway should run in OAuth mode. OAuth mode
publishes protected-resource metadata, challenges unauthenticated MCP requests,
adds per-tool `oauth2` security schemes, and verifies bearer tokens through the
configured JWKS or introspection verifier before forwarding any call. Exactly
one verifier must be configured; this does not expand the tool allowlist.

No client role should be treated as permission to delete projects, push or
fetch Git repositories, overwrite manifests, bypass Library proposal review, or
mutate Capsule control-plane metadata.
