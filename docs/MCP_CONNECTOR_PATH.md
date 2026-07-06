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

The tracked gateway script provides a small sidecar endpoint:

```powershell
$env:ATLAS_MCP_GATEWAY_TOKEN = "<long random token>"
python tools\atlas_mcp_gateway.py `
  --exe "B:\dev\Project_Atlas\project-atlas-main\build\windows\x64\runner\Release\project_atlas.exe" `
  --host 127.0.0.1 `
  --port 4874
```

For private development, expose that local gateway with an HTTPS tunnel such as
Secure MCP Tunnel, Cloudflare Tunnel, or ngrok. The connector URL should point
at the tunneled `/mcp` endpoint.

The current gateway token is a private smoke-test layer. Treat it as temporary
for local development tunnels only. ChatGPT connector readiness requires the
OAuth/protected-resource metadata flow described in the Apps SDK MCP auth
guidance; do not treat a hand-entered static bearer token as production auth.

## Current Remote Security Boundary

The first remote profile is a tiny, redacted, read-only prototype.

Allowed remotely by default:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`

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

Gateway responses are scrubbed before crossing `/mcp`. The scrubber masks
Windows paths, file URIs, email addresses, the known local owner name, draft
fields, private queue context, and unresolved proposal bodies. This is a
defense-in-depth layer, not permission to expose broader read tools yet.

The v0.1 gateway still launches `project_atlas.exe --mcp-stdio` per forwarded
request. Calls are serialized with a single-flight lock and protected by a
timeout, but the pre-ChatGPT-testing hardening path is a long-lived stdio child
or small process pool with restart/backoff behavior.

## Remote Smoke Test

Run the tracked smoke test after building the Windows release executable:

```powershell
python tools\smoke_mcp_gateway.py `
  --exe "B:\dev\Project_Atlas\project-atlas-main\build\windows\x64\runner\Release\project_atlas.exe"
```

The smoke verifies:

- metadata at `/.well-known/project-atlas-mcp`
- bearer-token failure behavior
- `GET /mcp` SSE readiness behavior
- `initialize`
- `tools/list`
- `list_projects`
- no non-allowlisted, queue, proposal, write, worker, bootstrap, enrichment, or
  sensitive-read tools exposed remotely
- direct calls to hidden tools are rejected
- `/mcp` responses and the gateway redaction self-test do not leak local paths,
  emails, owner names, draft text, private queue context, or unresolved proposal
  bodies

The older `.project\verification` folder is local evidence and intentionally
ignored. Public/reproducible gateway checks should live under `tools\` or
tracked tests.
