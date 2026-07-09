# MCP Connector Autostart

Project Atlas does not start remote MCP access just because the desktop UI
opens. The normal pinned app launch starts the Flutter desktop app only.

The app now supports an opt-in local autostart file. When this ignored file is
present and enabled, the desktop app starts:

1. the local OAuth HTTP MCP gateway on `127.0.0.1:4874`
2. the OpenAI tunnel client profile that forwards to that gateway

The local stdio MCP server is still not a background service. The gateway
launches `project_atlas.exe --mcp-stdio` per forwarded request.

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

Use JWKS validation for the current Auth0-style setup. If an OAuth provider
requires introspection instead, use `introspectionUrl` in place of `jwksUrl`;
do not place client secrets in tracked files.

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
- If the Atlas gateway is already healthy, the app does not start another one.
- If the tunnel health endpoint is already ready, the app does not start
  another tunnel process.
- If the gateway or tunnel need to start, the app starts hidden background
  processes and writes logs under `.local/runs/`.

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
Invoke-RestMethod http://127.0.0.1:4874/.well-known/project-atlas-mcp
Invoke-RestMethod http://127.0.0.1:4874/.well-known/oauth-protected-resource
Get-Content .local\runs\atlas-mcp-connector-autostart.log -Tail 5
```

Expected gateway name:

```text
Project Atlas MCP Gateway
```

Expected remote tools for connector v0.2:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`
- `atlas.project_planning_context`

If `127.0.0.1:4874` is down, the Atlas connector cannot work from ChatGPT even
when Auth0 login succeeds. If another local gateway is running on another port,
that does not satisfy the Project Atlas tunnel profile.

## Safety Boundary

Autostart does not broaden the remote tool surface. The gateway still filters
`tools/list`, rejects direct calls to hidden tools, requires OAuth bearer
validation, and redacts responses before they cross `/mcp`.
