# Security Policy

## Architecture Overview

Project Atlas is a **local-first** Windows desktop application. The SQLite
database remains local, but explicitly enabled integrations can transmit
selected data outside the machine.

- No cloud sync, no telemetry, no analytics.
- **Telegram notifications** - messages are sent to a bot/chat you configure. Transmission occurs only when you trigger a notification.
- **Ollama AI summaries** - requests go to `localhost:11434` by default. Data leaves the machine if Ollama is configured to use a remote host.
- **GitHub metadata refresh** - explicitly requested refreshes read repository metadata from GitHub for linked projects.
- **ChatGPT MCP connector** - when an operator enables their own ignored local gateway, HTTPS tunnel, OAuth configuration, and disclosure policy, the four approved read tools transmit structurally projected project data to the authenticated remote client. This repository does not host a shared connector service.

## Remote MCP Boundary

The local stdio MCP surface is machine-trusted and can contain private paths,
queue data, and project context. Do not expose it directly to a network.

The remote gateway requires OAuth or a localhost-only development bearer token,
an exact four-tool allowlist, and an ignored disclosure policy that maps
operator-approved local project IDs to remote aliases. Missing or invalid policy
state prevents startup. An explicit empty project list is deny-all.

Remote responses are not broad local DTOs passed through a regex. The gateway
parses the JSON inside the MCP text result and constructs a fresh allowlisted
object for each tool. Local IDs, owners, paths, URLs, branches, SHAs, raw JSON,
commands, notes, hidden-project counts, accepted-truth claims, and unrestricted
planning text are withheld. String scrubbing is retained only as a secondary
control.

Local connector configuration, disclosure policy, tunnel credentials, process
logs, and disclosure audit metadata live under `.local/`, which is ignored by
Git. The disclosure audit records generated correlation IDs, approved aliases,
tool/schema names, sizes, duration, and outcome; it does not record tokens,
OAuth claims, arguments, local IDs, or response content. Revoke the OAuth
client/tunnel credential and stop the local gateway if remote access may be
compromised.

Settings -> Integrations includes a local-only remote disclosure preview. It
reads the ignored connector config and disclosure policy, probes only the
configured loopback metadata endpoints, and shows approved aliases, disclosed
field groups, OAuth scope/verifier shape, policy fingerprint, recent audit
metadata, and synthetic redacted samples for the exact four tools. It does not
start or restart the gateway or tunnel. Active executable identity is reported
as unverified because current gateway metadata does not attest the process
binary.

## Data Storage Warning

**The SQLite database is stored in plaintext.**

Location: `%APPDATA%\<company>\project_atlas\project_atlas.sqlite` - use
**Settings -> Admin -> Open app data folder** to find the exact path on your
machine.

Any process running under your Windows user account can read this file. Do not
store passwords, API keys, or other sensitive credentials in project notes,
decisions, or risk descriptions.

**Telegram bot tokens are protected with Windows DPAPI** and stored separately
from SQLite. They are decryptable only by the Windows user that saved them on
that machine. On the next Settings read, a legacy plaintext database token is
migrated into the protected store and removed from SQLite. Telegram chat IDs
remain SQLite metadata and should be treated as private, not as credentials.

This does not encrypt project content or other SQLite metadata. Do not store
passwords, API keys, or other sensitive credentials in project fields.

## Reporting a Vulnerability

If you discover a security issue, please use this repository's private
**Security Advisories -> Report a vulnerability** flow. For non-sensitive
security improvements, open a GitHub issue. Please do not post exploit details
or user data in a public issue.

## Roadmap

**Encryption at rest** is planned for a future release. Until then, treat the
database file as you would any other unencrypted local file and protect it with
OS-level access controls such as account separation and BitLocker where needed.
