# Live recovery handoff threat model

Status: implemented by PR #30 (`1e18ebd`) and verified on merged `main`
Date: 2026-07-21

Project Atlas treats the live-recovery handoff as a one-time, same-account
coordination artifact. Plans are created only as direct children of Atlas's
application-support `recovery_handoffs` directory, written by temporary-file
rename, and claimed by rename before they are parsed. A claimed plan cannot be
replayed under its original name. Failed claims remain as `.consuming-*`
diagnostic artifacts.

The v2 schema contains no executable path. The worker always relaunches the
currently running Atlas executable. The plan parser rejects missing or unknown
fields, verifies a SHA-256 payload checksum, and requires absolute normalized,
non-overlapping source and safety-backup paths outside the handoff directory.
The source bundle is cryptographically and structurally revalidated after the
worker claims the plan and before it acknowledges the parent.

The checksum detects accidental corruption and unsophisticated mutation; it is
not an authentication boundary against malicious code already running as the
same OS user. Such code can read Atlas data, recompute a checksum, replace the
application binary, or otherwise act with the user's authority. Protecting a
fully compromised same-user session would require a separately protected key
or privileged broker and is outside the supported local threat model. Atlas
therefore relies on the OS account boundary and the user's application-support
directory permissions, while minimizing replay and arbitrary-execution risk
inside that boundary.

