# Project Atlas MCP Auth0 JWKS Connector Setup

This note is a self-hosted setup example for a ChatGPT custom connector smoke
using OpenAI Secure MCP Tunnel and Auth0-style JWT validation. The public repo
does not provide a shared Project Atlas endpoint, tunnel, Auth0 tenant, or
populated disclosure policy. Keep the remote tool allowlist frozen to:

- `list_projects`
- `get_project_status`
- `atlas.workload_snapshot`
- `atlas.project_planning_context`

Do not enable project briefs, queue reads, task context, proposal tools,
enrichment tools, GitHub refresh, or write tools.

The gateway also requires an ignored, local disclosure policy. OAuth access is
not disclosure approval by itself. Policy v2 separates inventory discovery from
detailed reads: every entry requires `inventory`, while `detail` is optional.
Remote callers address projects by approved alias rather than Atlas's local
project ID.

## Auth0 Values

Create or use an Auth0 API for Project Atlas.

- API Identifier: use this as `ATLAS_MCP_RESOURCE_URL`
- Permission/scope: `atlas.read`
- Issuer/domain: use `https://<tenant-domain>/` as
  `ATLAS_MCP_AUTHORIZATION_SERVERS`
- JWKS URL: use `https://<tenant-domain>/.well-known/jwks.json` as
  `ATLAS_MCP_JWKS_URL`

Create or use an Auth0 application that can complete authorization-code + PKCE
for ChatGPT.

- Add the ChatGPT connector OAuth redirect URL to Auth0 Allowed Callback URLs.
- Keep Auth0 client secrets out of the repo and chat.

## Disclosure Policy

Create the ignored local policy from the public shape example, then replace the
placeholder project ID with the real Atlas project ID and choose a non-sensitive
alias, label, and capability list. Review the full candidate label list in
Settings -> Integrations before replacing or restarting the live policy:

```powershell
Copy-Item `
  docs\examples\atlas_mcp_remote_disclosure.example.json `
  .local\atlas_mcp_remote_disclosure.json
```

Do not commit the populated policy. It contains the private mapping from remote
aliases to local Atlas IDs. A missing, unreadable, or invalid policy makes the
gateway refuse startup; an empty valid policy exposes no projects.

## Gateway Window

Run from this checkout:

```powershell
Set-Location <project-atlas-mcp-gateway-checkout>

$env:ATLAS_MCP_AUTH_MODE="oauth"
$env:ATLAS_MCP_RESOURCE_URL="<Auth0 API Identifier>"
$env:ATLAS_MCP_AUTHORIZATION_SERVERS="https://<tenant-domain>/"
$env:ATLAS_MCP_OAUTH_SCOPE="atlas.read"
$env:ATLAS_MCP_JWKS_URL="https://<tenant-domain>/.well-known/jwks.json"
$env:ATLAS_MCP_DISCLOSURE_POLICY=".local\atlas_mcp_remote_disclosure.json"

python tools\atlas_mcp_gateway.py `
  --host 127.0.0.1 `
  --port 4874 `
  --exe <path-to-project_atlas-release-exe>
```

## Tunnel Window

Run from this checkout:

```powershell
Set-Location <project-atlas-mcp-gateway-checkout>

$env:CONTROL_PLANE_API_KEY="<OpenAI tunnel runtime API key>"

.local\tunnel-client\v0.0.10-windows-amd64\tunnel-client.exe init `
  --sample sample_mcp_with_dcr `
  --profile project-atlas `
  --profile-dir .local\tunnel-client\profiles `
  --tunnel-id <OpenAI tunnel ID> `
  --mcp-server-url http://127.0.0.1:4874/mcp `
  --force

.local\tunnel-client\v0.0.10-windows-amd64\tunnel-client.exe doctor `
  --profile project-atlas `
  --profile-dir .local\tunnel-client\profiles `
  --explain

.local\tunnel-client\v0.0.10-windows-amd64\tunnel-client.exe run `
  --profile project-atlas `
  --profile-dir .local\tunnel-client\profiles
```

## ChatGPT Connector

- Connection: Tunnel
- Tunnel ID: the OpenAI tunnel ID
- Authentication: OAuth
- Scope: `atlas.read`

First success condition: ChatGPT lists exactly four Project Atlas tools and can
call all four through the strict remote projection. Results must contain only
approved aliases and bounded structured fields; local IDs, paths, free-text
notes, task bodies, commands, evidence excerpts, and upstream tool metadata must
not appear.

## Verification

Before live ChatGPT testing, run:

```powershell
python -m py_compile `
  tools\atlas_mcp_gateway.py `
  tools\atlas_mcp_remote_policy.py `
  tools\smoke_mcp_gateway.py `
  tools\test_atlas_mcp_remote_policy.py
python -m unittest discover -s tools -p "test_*.py" -v
python tools\smoke_mcp_gateway.py --exe <path-to-project_atlas-release-exe>
```
