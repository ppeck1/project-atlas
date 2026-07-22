# Queue schema integrity contract

Status: closed after PR #39 merged as `9d753cb` and exact-main proof passed.
Date: 2026-07-22

This contract defines the A-11 storage boundary for `llm_task_queue`. Service
validation remains useful diagnostics, but SQLite is the final authority for
references, scalar types, enumerations, JSON shape, lease state, and temporal
ordering.

## Schema v26 boundary

Schema v26 rebuilds the hand-managed queue table in one transaction. Queue
projects must exist. Optional work-item links use `ON DELETE SET NULL` and
must resolve through a stage to the same project as the queue row. Database
triggers reject cross-project queue writes and work-item or stage reparenting
that would invalidate an existing link.

Every String-mapped value is stored as SQLite TEXT (or NULL where optional).
Context and result payloads are JSON objects, not arrays, scalars, `null`, or
BLOBs. Attempts and timestamps use INTEGER storage. Enumerated priority,
status, readiness, size, risk, actor, and verification fields accept only the
values used by Atlas workload planning.

Pending, leased, completed, failed, and cancelled rows each have an explicit
lease/terminal shape. Lease and completion times cannot precede creation or
their preceding transition, and `updated_at` cannot precede the state it
records. Queue claims require a nonblank worker and a positive lease duration.

## Migration behavior

The v25-to-v26 migration preflights the same ownership, type, JSON, enum,
state, and chronology rules before copying any row. Invalid legacy data fails
closed without advancing `user_version` or replacing the v25 table. Valid rows
are copied with an explicit column list, row counts must match, and indexes,
ownership triggers, and `foreign_key_check` are verified after the swap.

Queue-related triggers are removed and recreated inside the rebuild
transaction so partial/current-shaped databases cannot retain a trigger that
references the temporarily absent old table. Any later failure rolls the old
table and trigger inventory back together.

## Proof boundary

Focused proof covers raw foreign-key and trigger violations, every enum
family, wrong SQLite storage classes, non-object JSON, malformed state and
chronology, runtime claim/terminal/requeue behavior, retained-trigger recovery,
and valid v25 rows for every historical queue state. A-11 closed after merge
and exact-main post-merge proof. A-12 through A-15 remain separate
workload-semantics findings.
