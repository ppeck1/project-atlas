# Full backup point-in-time contract

Status: implemented on `fix/backup-point-in-time-contract`, pending review  
Date: 2026-07-21

## Guaranteed snapshot boundary

A completed Project Atlas full backup represents one application-coordinated
point in time:

1. Already-running Atlas-owned file mutations finish.
2. A backup-exclusive maintenance gate blocks new managed-file mutations.
3. Atlas inventories every regular file under `atlas_documents` and
   `project_media` without following links.
4. SQLite's online-backup API captures the database.
5. Atlas copies the fixed owned-file inventory, rechecking each source file's
   length and SHA-256 after reading it and rechecking the complete source path
   inventory after all copies.
6. Atlas validates the staged bundle and writes its completion marker before
   releasing the maintenance gate.

Document imports hold the mutation side of the gate across the owned-file copy
and database insert. Project-media imports and deletions, and expired-document
purges, likewise hold it across both their database and filesystem changes.
Database-only edits that do not change managed bytes do not require the gate;
the SQLite online snapshot already gives them a valid transaction boundary.

The bundle intentionally includes the complete managed-root inventory, not
only paths currently referenced by database rows. This preserves recoverable
soft-deleted and locally retained Atlas-owned data and makes the ownership rule
explicit and testable.

## External mutation boundary

The maintenance gate coordinates mutations performed through the running Atlas
process. It cannot lock out another same-user process editing these directories
directly. Atlas therefore rechecks source length, source SHA-256, copied bytes,
and root inventory and fails closed when an out-of-band change is observed
during capture. A malicious or continuously mutating same-user process remains
outside the supported local threat model documented for recovery handoffs.

