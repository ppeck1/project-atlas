# Secure MCP Tunnel And OAuth Work Order

Status: prepared only. Do not execute this work order until the read-only
gateway PR has been reviewed and merged.

## Goal

Prove that ChatGPT can reach the Project Atlas `/mcp` gateway through an HTTPS
tunnel, complete OAuth bearer-token validation through a real provider, list
exactly the frozen three-tool remote surface, and call one harmless read tool
without leaking private local context.

## Non-Goals

- Do not expand the remote MCP allowlist.
- Do not expose queue, proposal, enrichment, GitHub refresh, project brief,
  work-item context, or packet-dump tools.
- Do not expose the desktop app port, SQLite database, app-data directory,
  Flutter VM service, or raw stdio process.
- Do not claim public ChatGPT connector readiness until a real authorization
  server and token validation path are configured and tested.

## Current Allowed Remote Tools

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`

## Preferred Tunnel Path

1. OpenAI Secure MCP Tunnel
2. Cloudflare Tunnel
3. ngrok

Use HTTPS only. The tunnel client should initiate outbound connectivity from
the local machine or trusted network. The public connector URL should point to
the tunneled `/mcp` endpoint, while the OAuth protected-resource metadata should
advertise the tunneled origin as the resource URL.

## Preferred Auth Provider Path

1. Auth0 development tenant
2. Okta developer tenant
3. AWS Cognito
4. Custom OAuth server only if the hosted providers are unsuitable

The gateway must run in OAuth mode, not static bearer mode, for this work order.
Static bearer mode remains a private localhost smoke layer only.

## Preconditions

- The read-only MCP gateway PR is merged or explicitly selected as the test
  branch.
- The Windows release executable is built and can run
  `project_atlas.exe --mcp-stdio`.
- `python tools\smoke_mcp_gateway.py --exe <release-exe>` passes locally.
- The OAuth provider has an issuer URL, introspection endpoint, client ID,
  client secret, and an access token with the `atlas.read` scope.
- The public resource URL is known before launching the gateway in OAuth mode.

## Execution Sequence

1. Start the OAuth provider configuration with a single `atlas.read` scope.
2. Configure token introspection for the gateway client.
3. Start the Project Atlas gateway locally in OAuth mode with:
   - `--auth-mode oauth`
   - `--resource-url <https tunnel origin>`
   - `--authorization-server <issuer URL>`
   - `--introspection-url <introspection URL>`
   - `--scope atlas.read`
   - `--exe <release exe>`
   - `--host 127.0.0.1`
4. Start the HTTPS tunnel to the local gateway port.
5. Verify public metadata and challenge behavior before opening ChatGPT.
6. Configure the ChatGPT connector against the tunneled `/mcp` endpoint.
7. Run the first live connector test with only `tools/list` and one harmless
   allowed read call.

## Validation Commands

```powershell
python -m py_compile tools\atlas_mcp_gateway.py tools\smoke_mcp_gateway.py
python tools\smoke_mcp_gateway.py --exe <release-exe>
```

After the tunnel is running, verify manually or with a small script:

- `GET /.well-known/oauth-protected-resource` returns metadata for the tunneled
  resource origin.
- Unauthenticated `/mcp` returns `401` with `WWW-Authenticate`.
- Missing token fails.
- Invalid token fails.
- Token missing `atlas.read` fails.
- Token with the wrong audience or resource fails.
- Valid token succeeds.
- `tools/list` returns exactly:
  - `list_projects`
  - `get_project_status`
  - `atlas.workload_snapshot`
- Calls to hidden tools are rejected.
- Raw `/mcp` responses do not include local Windows paths, repo-local paths,
  personal names, emails, queue context, proposal bodies, or draft text.

## First Live ChatGPT Exit Criteria

- ChatGPT reaches `/mcp` over HTTPS.
- OAuth challenge and protected-resource metadata are visible.
- ChatGPT sees exactly three tools.
- One harmless allowed read succeeds.
- Hidden tools remain unavailable.
- Redaction remains clean in captured raw responses.

## Rollback

- Stop the tunnel client.
- Stop the local gateway process.
- Revoke or rotate test OAuth client credentials and access tokens.
- Remove the connector configuration from ChatGPT if it was added for the test.
- Leave the remote MCP allowlist unchanged.
