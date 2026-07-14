# MCP security model

Project Atlas separates its trusted local MCP surface from its optional remote
projection.

## Trusted local surface

The stdio server runs under the local Windows user and can access private Atlas
state. It must not be exposed directly to a network or tunnel.

## Remote projection

The Python gateway provides four read-only tools through a fresh allowlisted
projection. It does not forward broad internal DTOs. A local disclosure policy
maps approved project IDs to public aliases and labels, with separate
`inventory` and `detail` grants.

Safety properties:

- Missing, malformed, or empty policy state denies access.
- Local IDs, paths, commands, remotes, branches, SHAs, notes, and raw JSON are
  omitted from remote responses.
- OAuth is required outside loopback development mode.
- Tool names, schemas, result sizes, duration, aliases, and outcome may be
  audited; arguments, response content, tokens, and OAuth claims are not.
- A disclosure preview shows synthetic projected samples without starting the
  gateway or tunnel.

Start from
`docs/examples/atlas_mcp_remote_disclosure.example.json`, copy it into ignored
local configuration, and replace the sample IDs and fingerprints locally.

## Operator responsibilities

- Keep gateway, OAuth, tunnel, and policy files under ignored local storage.
- Approve the smallest useful inventory and detail sets.
- Treat absence from a remote response as non-disclosure, not proof that a
  project does not exist.
- Revoke the OAuth client or tunnel credential and stop the gateway if access
  may be compromised.

The repository does not include credentials, a hosted connector, or a default
public project inventory.
