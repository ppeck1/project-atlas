# MCP Tunnel OAuth Live Smoke

Date: 2026-07-07
Branch: `mcp-gateway-oauth-readiness`
Status: passed

## Goal

Validate that ChatGPT can reach the Project Atlas MCP gateway through the
OpenAI Secure MCP Tunnel with real OAuth validation while preserving the frozen
three-tool read-only remote surface.

## Frozen Remote Allowlist

The live connector surface remained frozen to:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`

No project briefs, queue reads, task context, work-item context, proposal
tools, enrichment tools, GitHub refresh, or write-capable tools were enabled.

## Code Fix Applied During Live Smoke

The live Auth0/JWKS path exposed an issuer formatting mismatch: the issuer in
the JWT used a trailing slash while the gateway configuration normalized the
authorization server without one. The gateway now compares OAuth issuer values
with trailing-slash normalization while still requiring:

- valid JWT signature from the configured JWKS endpoint
- expected OAuth audience/resource
- required `atlas.read` scope
- token expiry and issued-at claims

The gateway smoke test now covers the trailing-slash issuer case.

## Transport Compatibility Checks

The live smoke also retained the prior transport hardening and compatibility
behavior:

- `/.well-known/oauth-protected-resource/mcp` serves the same protected-resource
  metadata as `/.well-known/oauth-protected-resource`
- `/mcp` accepts only the configured origin set
- oversized MCP request bodies are rejected
- accepted notification responses include explicit zero-length close semantics
- JSON responses close the connection cleanly

## Local Verification

Commands run with private local paths redacted:

```text
python -m py_compile tools\atlas_mcp_gateway.py tools\smoke_mcp_gateway.py
python tools\smoke_mcp_gateway.py --exe <release-exe>
```

Smoke result:

```json
{
  "status": "ok",
  "tools": 3,
  "hiddenToolsRejected": 29,
  "deniedToolsExposed": [],
  "oauth": {
    "tools": 3,
    "challenge": true,
    "protectedResource": true,
    "negativePaths": 4,
    "originValidated": true
  },
  "oauthJwks": {
    "tools": 3,
    "challenge": true,
    "protectedResource": true,
    "negativePaths": 5,
    "hiddenToolRejected": true
  }
}
```

## Live ChatGPT Connector Result

ChatGPT successfully invoked the Project Atlas connector through the tunnel and
called only:

```text
Project_Atlas.list_projects
```

with `includeArchived: false`.

The call succeeded and returned a visible project count. Raw project rows were
not committed to the repository.

Gateway logs confirmed:

- authenticated `initialize` requests returned HTTP 200
- `tools/list` was served
- `tools/call list_projects` was proxied
- no write, queue, proposal, enrichment, GitHub refresh, task-context,
  work-item-context, or project-brief calls were observed

## Privacy Review

This report intentionally omits:

- OAuth tokens and runtime API keys
- provider client secrets
- tunnel IDs and full tunnel URLs
- tenant-specific authorization URLs
- local absolute paths
- raw connector responses
- raw project rows
- owner names, emails, draft text, queue context, and unresolved proposal bodies

Runtime logs and local tunnel configuration remain untracked under ignored local
runtime directories.

## Result

The first live ChatGPT-to-Project-Atlas connector smoke passed with real OAuth,
the OpenAI Secure MCP Tunnel, and the frozen three-tool remote allowlist.
