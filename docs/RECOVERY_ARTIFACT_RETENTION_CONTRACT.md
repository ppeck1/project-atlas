# Recovery Artifact Retention Contract

Status: R-12 implementation contract
Scope: local recovery artifacts only
Default policy: 30 days or 10 GiB of retained managed artifacts

## Purpose

Recovery must retain enough evidence to recover safely without allowing old
safety backups, rollback directories, staging restores, failed handoffs, and
completion metadata to grow without bound.

Retention is always an explicit two-phase operator action:

1. **Preview** discovers and validates local candidates without deleting.
2. **Apply** accepts only candidate IDs from that preview, repeats discovery
   under the recovery-artifact lock, and deletes only exact unchanged
   snapshots.

There is no scheduled or startup deletion.

## Managed roots and artifacts

Atlas scans its application-owned `recovery_handoffs` directory. The operator
may additionally select one safety-backup root. Valid plan and completion
metadata may discover further safety-backup roots.

Only strict Atlas artifact shapes are managed:

- validated completed full backups directly below a safety-backup root;
- typed failed full-backup siblings;
- rollback directories with Atlas live-recovery names;
- validated completed staging restores and typed failed staging siblings;
- failed or consumed recovery plans with a matching failure diagnostic;
- failed recovery diagnostics;
- orphaned acknowledgement files;
- bounded temporary handoff files; and
- current or historical live-recovery completion markers.

Unknown files, unverified backup directories, malformed metadata, links,
reparse-backed paths, unsupported filesystem entities, and artifacts outside
a direct trusted parent are retained.

## Required exclusions

Retention must never offer these artifacts for deletion:

- the newest valid completed safety backup in every inspected safety root;
- every pending plan without a failure diagnostic;
- the acknowledgement belonging to an active plan;
- any rollback or staging artifact while a plan may still be active;
- typed incomplete backup or staging artifacts that may still be active; or
- any artifact that cannot be completely inventoried within configured entry
  and byte limits.

The newest safety backup exclusion applies even when it exceeds both the age
and aggregate-size thresholds.

## Age and size selection

An otherwise eligible artifact becomes a preview candidate when either:

- its trusted observation timestamp is at least the configured maximum age; or
- retaining it would keep managed artifacts above the configured aggregate
  byte limit, in which case the oldest eligible artifacts are selected first.

The preview identifies whether age, size, or both selected each candidate.
Scan, candidate, per-artifact entry, per-artifact byte, and metadata-read
limits are hard bounded. Reaching a bound is reported and never expands the
deletion set.

## Preview and apply integrity

Every previewed file is a bounded regular-file snapshot containing its size,
modification time, and SHA-256 digest. Every previewed directory is an exact
no-follow inventory containing the type, size, modification time, and SHA-256
digest of every file.

Candidate IDs bind:

- artifact kind;
- normalized absolute path; and
- the opaque snapshot fingerprint.

Apply rejects candidate IDs not present in the supplied preview. It then
repeats the complete retention preview under the same policy and scope. A path
that is no longer a candidate, became protected, changed bytes, changed
inventory, exceeded a bound, or changed filesystem type is refused.

Directory deletion reuses the R-11 two-pass bounded deletion implementation.
It checks the complete snapshot again immediately before deleting descendants,
deletes deepest paths first, and revalidates containment and entity type for
every deletion.

## Coordination

Plan creation, live recovery application, retention preview, and retention
apply serialize through the application-owned recovery-artifact lock. The
live-recovery worker holds that lock across plan consumption, safety backup,
staging restore, replacement, rollback handling, completion publication, and
handoff cleanup.

The UI process registers each prepared plan as active until it launches or
explicitly discards that plan. Cancelling the typed replacement confirmation
deletes the unlaunched plan under the same lock. An old pending plan from a
previous process has no active registration and may become eligible under the
normal policy.

Retention also performs a fresh active-plan scan during apply. An active plan
that appears after preview removes rollback and staging artifacts from the
current candidate set. Because an applying worker holds the lock for its full
lifetime, a consumed-plan file visible while retention owns the lock is an
abandoned terminal artifact, not an active plan; it is still subject to the
normal age/size policy and snapshot checks.

## Operator surface and audit

Settings exposes **Preview recovery cleanup**. The operator chooses whether to
include a safety-backup root, reviews every candidate path, kind, trigger, and
size, and explicitly confirms deletion.

Apply writes a local recovery event containing candidate counts and per-path
terminal dispositions. It does not record file contents.

## Closure gate

R-12 closes only after focused hostile/race/preservation tests, the full
Flutter suite, static analysis, policy tests, a Windows release build, hosted
pull-request CI, and exact-main post-merge CI all pass. R-13 and R-14 remain
outside this contract.
