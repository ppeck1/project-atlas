# Project Atlas MCP Connector Path

Project Atlas has two MCP surfaces with different trust boundaries.

## Local stdio MCP

The desktop release executable exposes the core MCP server over stdio:

```powershell
build\windows\x64\runner\Release\project_atlas.exe --mcp-stdio
```

Use this only from local tools that can start a Windows process, such as Codex
or Claude Code. It talks to the local Project Atlas app state through the same
desktop-side service boundary as the app. It is not reachable by ChatGPT on its
own.

## Codex and Claude Local Use

Codex can point at the stdio server from a trusted project `.codex\config.toml`
or a user config. Claude Code can use an equivalent local stdio MCP entry.
These clients run on the same machine and inherit the local-machine trust
boundary.

For Project Atlas, keep local agent writes proposal-first. Do not let local
agents approve their own proposals, push Git, delete projects, or mutate source
repositories.

## ChatGPT Remote Connector Use

ChatGPT needs a reachable HTTPS MCP endpoint. Do not expose the desktop app,
SQLite database, Flutter VM service, or app-data directory directly.

This repository does not provide a hosted Project Atlas connector. The gateway
is a self-hosted sidecar: each operator supplies their own release executable,
`.local` disclosure policy, HTTPS tunnel, OAuth provider, and connector
registration.

The tracked gateway script provides a small sidecar endpoint. Static bearer
mode is for private localhost smoke only:

```powershell
$env:ATLAS_MCP_GATEWAY_TOKEN = "<long random token>"
python tools\atlas_mcp_gateway.py `
  --exe "<release-exe>" `
  --disclosure-policy ".local\atlas_mcp_remote_disclosure.json" `
  --host 127.0.0.1 `
  --port 4874
```

For ChatGPT connector work, use OAuth mode with protected-resource metadata and
exactly one token verifier. The public resource URL should be the operator's
HTTPS tunnel or hosted origin, not the `/mcp` path. A common Auth0-style path
uses JWKS:

```powershell
python tools\atlas_mcp_gateway.py `
  --auth-mode oauth `
  --resource-url "https://your-tunnel.example" `
  --authorization-server "https://your-auth.example" `
  --jwks-url "https://your-auth.example/.well-known/jwks.json" `
  --scope atlas.read `
  --exe "<release-exe>" `
  --disclosure-policy ".local\atlas_mcp_remote_disclosure.json" `
  --host 127.0.0.1 `
  --port 4874
```

For a provider that requires token introspection, replace `--jwks-url` with
`--introspection-url "https://your-auth.example/oauth/introspect"`. Supplying
both is rejected because JWKS and introspection have different revocation and
authority semantics.

OAuth mode exposes `GET /.well-known/oauth-protected-resource`, returns a
`WWW-Authenticate` challenge on unauthenticated `/mcp` requests, annotates the
four remote tools with `securitySchemes: [{ type: "oauth2", scopes:
["atlas.read"] }]`, and validates bearer tokens through the configured
JWKS or introspection verifier before forwarding calls to stdio.

For private development, expose the local OAuth-mode gateway with an HTTPS
tunnel such as Secure MCP Tunnel, Cloudflare Tunnel, or ngrok. The ChatGPT
connector URL should point at the tunneled `/mcp` endpoint.

For taskbar-first use, see `docs/MCP_CONNECTOR_AUTOSTART.md`. The desktop app
can opt in to starting the gateway and tunnel from a local ignored config file
when the normal UI launches.

## Current Remote Security Boundary

The first remote profile is a tiny, deny-by-default, read-only projection.

Allowed remotely by default:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`
- `atlas.project_planning_context`

Denied remotely by default:

- queue mutation: `enqueue_llm_task`, `claim_llm_task`, `complete_llm_task`, `fail_llm_task`
- proposal/write tools: `propose_*`, `record_*`
- enrichment/cache refresh tools
- bootstrap tools that can include local-machine context
- broader read tools that can carry private context, including project briefs,
  work item bundles, proposals, queue reads, and task context

The gateway filters `tools/list` and rejects denied `tools/call` requests even
if a caller sends them directly. ChatGPT permission prompts are not treated as
authorization.

The gateway will not start without an ignored disclosure policy. The policy
maps explicitly approved local project IDs to remote aliases and labels. Remote
callers use the alias; local IDs and hidden-project existence are not returned.
Archived projects are unavailable through every remote tool, even if an alias
remains in the local policy or an older list caller sends
`includeArchived=true`. Global workload reads first resolve the current
non-archived approved-project set and recompute results against it.

Tool results arrive from stdio as JSON encoded inside an MCP text block. The
gateway parses that inner JSON and constructs a fresh per-tool DTO from exact
allowed fields. Unknown fields, owners, local IDs, URLs, paths, branches, SHAs,
raw JSON, commands, notes, and hidden-project aggregates are dropped. Workload
responses are capped and recompute counts only from approved projects. Regex
scrubbing remains defense in depth after structural projection. Set
`ATLAS_MCP_PRIVATE_NAME_PATTERN` locally if upstream text could contain an
operator name that should be scrubbed as `[redacted:person]`.

All remotely returned status, freshness, and workload classification strings
come from fixed semantic enums. Arbitrary token-shaped values are mapped to a
fixed `unknown` sentinel or omitted. Freshness action text is reduced to a
boolean signal. The `initialize` result and `tools/list` metadata are also
rebuilt from fixed contracts, so upstream metadata and malformed errors cannot
cross the gateway.

The current containment profile intentionally withholds work-item titles,
accepted-truth claims, commands, free-text notes, and evidence excerpts until
their semantics are hardened.

Settings -> Integrations includes a local-only disclosure preview for the
remote profile. It reads only local ignored config/policy/audit files and
loopback metadata from an already-running gateway. It shows approved aliases,
the exact four tools, disclosed field groups, synthetic redacted samples, OAuth
scope/verifier shape, issuer count, short policy fingerprint, recent
metadata-only audit events, and whether gateway metadata matches the current
policy. The preview does not start the gateway or tunnel, and active executable
identity remains `unverified` until the gateway can attest its process binary.

The v0.1 gateway still launches `project_atlas.exe --mcp-stdio` per forwarded
request. Calls are serialized with a single-flight lock and protected by a
timeout. Stdout and stderr are drained incrementally under separate hard byte
caps, and the child is terminated on overflow. A long-lived stdio child or
small process pool with restart/backoff remains a later performance and
supervision improvement.

## Remote Smoke Test

Run the tracked smoke test after building the Windows release executable:

```powershell
python tools\smoke_mcp_gateway.py `
  --exe "<release-exe>"
```

The smoke verifies:

- metadata at `/.well-known/project-atlas-mcp`
- bearer-token failure behavior
- OAuth protected-resource metadata at `/.well-known/oauth-protected-resource`
- OAuth `WWW-Authenticate` challenge behavior
- OAuth introspection, scope, audience/resource checks, and per-tool
  `securitySchemes`
- `GET /mcp` SSE readiness behavior
- `initialize`
- `tools/list`
- the four-tool remote allowlist, including `atlas.project_planning_context`
- live calls to all four projected tools through static bearer, OAuth
  introspection, and OAuth JWKS modes
- required disclosure-policy startup and approved-alias translation
- exact projected schemas, hidden-project filtering, and bounded output
- no non-allowlisted, queue, proposal, write, worker, bootstrap, enrichment, or
  sensitive-read tools exposed remotely
- direct calls to hidden tools are rejected
- `/mcp` responses and the gateway projection/redaction tests do not leak local
  IDs, paths, emails, owner names, URLs, SHAs, commands, notes, raw JSON, draft
  text, private queue context, or unresolved proposal bodies

The older `.project\verification` folder is local evidence and intentionally
ignored. Public/reproducible gateway checks should live under `tools\` or
tracked tests.
