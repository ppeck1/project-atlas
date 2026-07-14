# MCP Connector Autostart

Project Atlas does not start remote MCP access just because the desktop UI
opens. The normal pinned app launch starts the Flutter desktop app only.

The app now supports an opt-in local autostart file. When this ignored file is
present and enabled, the desktop app starts:

1. the local OAuth HTTP MCP gateway on `127.0.0.1:4874`
2. the operator's configured tunnel-client profile that forwards to that gateway

The local stdio MCP server is still not a background service. The gateway
launches `project_atlas.exe --mcp-stdio` per forwarded request.

Remote startup is fail-closed. The gateway also requires an ignored disclosure
policy that explicitly maps approved local project IDs to remote aliases. A
missing, unreadable, or invalid policy prevents the gateway from starting.
Project Atlas does not provide or host a shared tunnel, OAuth tenant, connector
registration, or populated disclosure policy for other users.

## Local Config File

Create this file locally:

```text
.local/atlas_mcp_connector_autostart.json
```

`.local/` is gitignored. Do not commit this file.

Template:

```json
{
  "enabled": true,
  "pythonPath": "C:\\Path\\To\\Python311\\python.exe",
  "gatewayScriptPath": "tools\\atlas_mcp_gateway.py",
  "projectAtlasExePath": "build\\windows\\x64\\runner\\Release\\project_atlas.exe",
  "disclosurePolicyPath": ".local\\atlas_mcp_remote_disclosure.json",
  "disclosureAuditLogPath": ".local\\runs\\atlas-mcp-disclosure-audit.jsonl",
  "host": "127.0.0.1",
  "port": 4874,
  "authMode": "oauth",
  "resourceUrl": "https://api.openai.com/v1/tunnel/<tunnel-id>",
  "authorizationServers": [
    "https://<auth-provider-domain>/"
  ],
  "scope": "atlas.read",
  "jwksUrl": "https://<auth-provider-domain>/.well-known/jwks.json",
  "allowedOrigins": [
    "https://chatgpt.com"
  ],
  "tunnelEnabled": true,
  "tunnelClientPath": ".local\\tunnel-client\\v0.0.10-windows-amd64\\tunnel-client.exe",
  "tunnelProfile": "project-atlas",
  "tunnelProfileDir": ".local\\tunnel-client\\profiles"
}
```

Use JWKS validation when your OAuth provider issues JWT access tokens. If an OAuth provider
requires introspection instead, use `introspectionUrl` in place of `jwksUrl`;
exactly one verifier is allowed. Do not place client secrets in tracked files.

## Remote Disclosure Policy

Create this second ignored file before enabling autostart:

```text
.local/atlas_mcp_remote_disclosure.json
```

Start from `docs/examples/atlas_mcp_remote_disclosure.example.json`. Each entry
contains the private local Atlas project ID plus the alias, label, and explicit
capabilities approved for remote disclosure:

```json
{
  "schema": "project_atlas.remote_disclosure_policy.v2",
  "projects": [
    {
      "projectId": "replace-with-local-atlas-project-id",
      "alias": "project-atlas",
      "label": "Project Atlas",
      "access": ["inventory", "detail"],
      "sourceTitleFingerprint": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
```

Every v2 row requires `inventory`; `detail` is optional and independently
authorizes status, workload, and planning-context reads. Inventory capacity is
256 and detail capacity is 64. `sourceTitleFingerprint` is an optional local-only
SHA-256 baseline of the source title; Settings flags a missing baseline or later
title drift without forcing an intentionally curated remote label to equal the
private local title. The all-zero value above is a public placeholder and must
be replaced with the actual lowercase SHA-256 before relying on drift checks.
Valid v1 rows remain compatible as both
capabilities. The policy is loaded once at gateway startup. Unknown fields or
capabilities, duplicate IDs or aliases, invalid aliases, and unsupported schemas
are rejected. An explicit empty `projects` array is the deny-all configuration.
Policy changes require a gateway restart.

`disclosureAuditLogPath` is passed explicitly to the gateway. Keep it in the
main Atlas state directory when `gatewayScriptPath` points at a separate
accepted deployment checkout; otherwise the gateway's script-relative default
and the Settings preview can silently read different audit files.

## Tunnel Profile

The tunnel profile must forward to the Atlas gateway:

```yaml
mcp:
  server_urls:
    - channel: main
      url: "http://127.0.0.1:4874/mcp"
```

The profile may reference the OpenAI tunnel runtime key by local file path. Keep
that key under `.local/secrets/` or another ignored location.

## Startup Behavior

On normal desktop startup, Project Atlas checks the local config file.

- If the file is missing, startup continues normally.
- If `"enabled": false`, startup continues normally.
- If a gateway reports the hardened remote projection metadata, the app does
  not start another one. Health requires the exact four tools, the configured
  auth mode, scope, OAuth resource/issuer endpoints, and proof that the running
  gateway loaded the current policy file. Older or mismatched gateway metadata
  is not accepted.
- If the tunnel health endpoint is already ready, the app does not start
  another tunnel process.
- If the gateway or tunnel need to start, the app starts hidden background
  processes and writes logs under `.local/runs/`.
- After launching the gateway, the app polls the full hardened metadata check
  for up to 12 seconds. It does not launch the tunnel if the child exits early
  or reports mismatched tools, auth, or policy identity.

## Operator Disclosure Preview

Settings -> Integrations includes a local-only remote disclosure preview. The
preview reads the ignored autostart config, ignored disclosure policy, and
ignored disclosure audit metadata. If the configured gateway is already running
on loopback, it also reads the gateway metadata and OAuth protected-resource
metadata. It never starts, stops, restarts, or writes gateway or tunnel state.

The preview shows the exact four remote tools, inventory and detail aliases,
eligible unenrolled projects with local-only candidate labels and proposed
aliases, unsafe-label and title-drift warnings, page count, exact compact
first-page byte estimate, synthetic redacted samples, OAuth mode/scope and
verifier kind, issuer count, a short policy SHA-256 fingerprint, recent
metadata-only audit events, and the current policy/gateway metadata match. It
does not serialize local IDs or unenrolled labels. It reports active executable
identity as `unverified` because current gateway metadata does not attest the
process binary.

## Logs

Autostart summary:

```text
.local/runs/atlas-mcp-connector-autostart.log
```

Gateway logs:

```text
.local/runs/atlas-mcp-gateway-autostart.out.log
.local/runs/atlas-mcp-gateway-autostart.err.log
```

Disclosure audit metadata:

```text
.local/runs/atlas-mcp-disclosure-audit.jsonl
```

The disclosure audit contains generated correlation IDs, approved aliases,
tool names, projection schema and local policy digest, counts, duration, and
outcome. It does not contain tokens, OAuth claims, local project IDs, arguments,
payloads, paths, or response content.

Tunnel logs:

```text
.local/runs/tunnel-client-autostart.log
.local/runs/tunnel-client-autostart.out.log
.local/runs/tunnel-client-autostart.err.log
.local/runs/tunnel-client-health.url
.local/runs/tunnel-client.pid
```

## Verification

After launching the pinned app:

```powershell
$policyDigest = (Get-FileHash `
  .local\atlas_mcp_remote_disclosure.json `
  -Algorithm SHA256).Hash.ToLowerInvariant()
Invoke-RestMethod `
  http://127.0.0.1:4874/.well-known/project-atlas-mcp `
  -Headers @{ 'X-Project-Atlas-Policy-Digest' = $policyDigest }
Invoke-RestMethod http://127.0.0.1:4874/.well-known/oauth-protected-resource
Get-Content .local\runs\atlas-mcp-connector-autostart.log -Tail 5
```

Expected gateway name:

```text
Project Atlas MCP Gateway
```

Also verify `projectionSchema` is `project_atlas.remote_projection.v1`,
`denyByDefault` is `true`, and `disclosurePolicyLoaded` is `true`. The desktop
health check sends the current policy SHA-256 in a local request header and
requires `disclosurePolicyMatches: true`; the digest itself is not returned in
metadata. It also requires the configured OAuth/static auth metadata and the
exact four-tool set; OAuth mode additionally checks the protected resource,
authorization-server set, scope, and configured JWKS/introspection endpoint.

Expected remote tools for connector v0.2:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`
- `atlas.project_planning_context`

If `127.0.0.1:4874` is down, the Atlas connector cannot work from ChatGPT even
when OAuth login succeeds. If another local gateway is running on another port,
that does not satisfy the Project Atlas tunnel profile.

## Safety Boundary

Autostart does not broaden the remote tool surface. The gateway filters
`tools/list`, rejects direct calls to hidden tools, requires OAuth bearer
validation, translates only approved aliases, parses the JSON carried inside
MCP text blocks, and builds fresh per-tool allowlisted output objects. String
scrubbing remains defense in depth; it is not the primary disclosure boundary.
