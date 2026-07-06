# MCP Tunnel OAuth Live Smoke Preflight

Date: 2026-07-06
Branch: `mcp-tunnel-oauth-live-smoke`
Base: `origin/main` at `fff7600`
Status: blocked before live tunnel/OAuth execution

## Goal

Validate the merged Project Atlas MCP gateway through an HTTPS tunnel with real
OAuth validation while preserving the frozen three-tool remote surface.

## Frozen Remote Allowlist

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`

No project briefs, queue reads, task context, proposal tools, enrichment tools,
GitHub refresh, work-item context, or write/proposal tools were enabled.

## Completed Checks

- Verified `origin/main` contains the merged MCP gateway prototype at
  `fff7600`.
- Confirmed the gateway allowlist remains exactly the three tools listed above.
- Compiled the gateway scripts:

```text
python -m py_compile tools\atlas_mcp_gateway.py tools\smoke_mcp_gateway.py
```

- Ran the local gateway smoke against the Windows release executable using a
  redacted executable placeholder:

```text
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
  }
}
```

## Live Execution Blocker

The live tunnel/OAuth portion was not executed because the required local
prerequisites were not available:

- no Auth0 CLI or configured Auth0/OAuth provider environment was detected
- no OpenAI Secure MCP `tunnel-client` was detected
- no Cloudflare Tunnel client was detected
- no ngrok client was detected
- no relevant OpenAI/tunnel/Auth0/Okta/Cognito/Atlas MCP environment variable
  names were detected

Because there is no real issuer, introspection endpoint, public HTTPS tunnel
origin, or tunnel client, the gateway cannot yet be started in a real live
OAuth+tunnel configuration without fabricating the validation path.

## Not Executed

- Real `atlas.read` scope creation
- Real token introspection or trusted issuer validation
- Gateway startup using a public HTTPS tunnel origin
- HTTPS tunnel startup to local port `4874`
- Live public metadata/challenge checks
- Live valid/invalid token checks against a real provider
- Live `tools/list` and `list_projects` through the public tunnel
- Live direct hidden-tool rejection through the public tunnel

## Next Prerequisites

1. Provision an OAuth provider, preferably an Auth0 development tenant.
2. Configure a single `atlas.read` scope.
3. Configure token introspection or another trusted token validation path.
4. Install and authenticate OpenAI Secure MCP `tunnel-client`, or choose a
   fallback HTTPS tunnel client.
5. Start `tools\atlas_mcp_gateway.py` in OAuth mode with the real issuer,
   introspection endpoint, public HTTPS resource origin, and local release
   executable.
6. Run the live smoke checks from the work order without expanding the tool
   allowlist.

## Result

Merged gateway readiness is locally validated. Live ChatGPT or public connector
readiness is not claimed.
