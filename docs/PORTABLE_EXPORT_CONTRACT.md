# Portable Export Contract

This contract closes `SPA-20260721-R-13`. The Settings portable export is an
inspection and selective-transfer artifact. It is not a full backup and cannot
restore an Atlas instance.

## Execution and memory boundary

Database reads remain asynchronous. ZIP construction, manifest serialization,
file hashing, and file IO run in a dedicated Dart isolate.

The worker uses ZIP store mode deliberately. The archive package's deflate
path materializes a compressed entry before writing it, while store mode reads
the source through a bounded file stream and writes it directly to the output.
Atlas therefore retains neither all source files nor the completed ZIP in
memory. Metadata is emitted incrementally to a temporary manifest file rather
than encoded as one complete JSON byte array.

Each source is read in bounded passes:

1. preflight records its regular-file type, byte length, and modification time;
2. the worker hashes it;
3. the ZIP encoder performs its bounded CRC pass and streams the stored bytes;
4. the worker hashes and stats it again.

A size, modification-time, or SHA-256 change fails the export. No partial ZIP
is promoted.

## Default and hard limits

| Dimension | Default | Hard maximum |
|---|---:|---:|
| ZIP entries, including the manifest | 10,000 | 100,000 |
| One source file | 2 GiB | 8 GiB |
| Aggregate source bytes | 10 GiB | 64 GiB |
| Portable JSON manifest | 64 MiB | 256 MiB |
| Metadata records | 250,000 | 1,000,000 |
| Archive path length | 512 characters | 1,024 characters |

Runtime limits must be positive and cannot exceed the hard maximums. The
manifest and every source count toward their relevant limits before output can
be published.

## Paths and source errors

Archive paths must be bounded normalized relative POSIX paths. Absolute,
drive-qualified, backslash, traversal, empty-segment, and case-folded duplicate
paths fail before worker startup.

Every included source must be a no-follow regular file at preflight and again
in the worker. Missing, linked, non-file, oversized, changed, unreadable, or
otherwise failed sources produce a structured error with the archive path and
source path. Atlas does not silently publish an incomplete success. Database
rows whose recorded document or media file is already missing or unsafe are
retained in `portable_export.json` and reported as audit warnings, matching the
portable artifact's inspection role.

## Progress and cancellation

The worker reports manifest, per-file, promotion, completion, cancellation,
and failure phases with entry and source-byte progress. Settings exposes the
current phase and a cancel action.

Cancellation terminates the worker isolate, removes its typed manifest and ZIP
partials, and leaves any existing destination file unchanged. A completed
worker output is promoted only by the parent after it observes the ready
message. An existing destination is moved to a typed sibling during promotion
and restored if publication fails.

## Completion and audit

Only a closed worker ZIP is eligible for promotion. Success, cancellation, and
failure have distinct local audit events. The success audit records bounded
counts and byte totals plus missing/unsafe-source warnings; it does not copy
file contents into the audit log.

Compatibility remains `project_atlas_portable_export_v1`: the archive contains
`portable_export.json`, `documents/…`, and `media/…` entries as before.
