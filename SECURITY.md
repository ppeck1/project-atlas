# Security Policy

## Architecture Overview

Project Atlas is a **local-first** Windows desktop application. All data remains on your machine.

- No cloud sync, no telemetry, no analytics.
- No data is transmitted to external servers except for two explicit, user-configured features:
  - **Telegram notifications** — messages are sent to a bot/chat you configure. Transmission only occurs when you trigger a notification.
  - **Ollama AI summaries** — requests go to `localhost:11434` by default. Ollama is self-hosted; no data leaves your machine unless you have pointed Ollama at a remote host.

## Data Storage Warning

**The SQLite database is stored in plaintext.**

Location: `%APPDATA%\<company>\project_atlas\project_atlas.sqlite` — use **Settings → Admin → Open app data folder** to find the exact path on your machine.

Any process running under your Windows user account can read this file. Do not store passwords, API keys, or other sensitive credentials in project notes, decisions, or risk descriptions.

**Telegram credentials (bot token and chat ID) are stored in plaintext** inside the SQLite database. Use a dedicated bot created solely for Project Atlas — do not reuse a shared group bot token that other people or services rely on.

## Reporting a Vulnerability

If you discover a security issue, please open a GitHub issue or email **peckx257@gmail.com** for security-sensitive reports. There is no formal SLA for a personal project, but reports will be addressed promptly.

## Roadmap

**Encryption at rest** is planned for a future release. Until then, treat the database file as you would any other unencrypted local file — protect it with OS-level access controls (user account separation, disk encryption via BitLocker) if needed.
