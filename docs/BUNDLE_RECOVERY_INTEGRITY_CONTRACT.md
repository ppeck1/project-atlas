# Bundle recovery integrity contract

Status: R-07–R-10 implemented by PR #37 (`9d0e792`) and verified on exact
merged `main`; R-11 is implemented by PR #46 (`fce3769`) and verified on
exact merged `main`.
Date: 2026-07-23

This contract defines the merged R-07 through R-11 boundary, including the
incomplete-artifact lifecycle. Full backups are directory trees with a
completion marker; project bundles are ZIP archives. They retain separate
schemas and validators because their trust roots and materialization rules
differ.

## Exact full-backup inventory

Valid `project_atlas_full_backup_v1` manifests already contain four-field
descriptors: canonical relative `path`, enumerated `kind`, non-negative integer
`bytes`, and lowercase SHA-256. Validation now requires exactly one
`sqlite_snapshot` descriptor whose path equals `databaseSnapshot`; all other
payload descriptors are `app_owned_file`.

The actual regular-file tree must equal the declared descriptors plus
`manifest.json` and, for completed bundles, `backup_complete.json`. Missing,
duplicate, case-aliased, linked, malformed, and undeclared entries fail. This
tightens validation without changing the full-backup v1 producer contract.

## Project-bundle manifest v2

Current exports retain `project_atlas_project_bundle_v1` for the project
payload and use `project_atlas_project_bundle_manifest_v2` for integrity. The
manifest lists every non-manifest payload with its canonical path, enumerated
kind, exact byte length, and SHA-256. Actual ZIP inventory must equal those
descriptors plus the single manifest entry. Required payload, manifest, and
README pointers and document/media counts are checked against the final
descriptor inventory.

The manifest cannot contain its own byte hash. It is the structural root and
is rebound byte-for-byte between validation and extraction. Project manifest
v1 lacks the required proof and fails closed with guidance to re-export.

## Explicit recovery limits

The default project recovery limits are:

- source ZIP: 512 MiB;
- central directory: 16 MiB;
- entries: 2,048;
- compressed bytes per entry: 256 MiB;
- expanded bytes per entry: 512 MiB;
- aggregate expanded bytes, including metadata: 1 GiB;
- each metadata JSON document: 8 MiB; and
- archive path length: 512 characters.

Before the archive library runs, Atlas locates the bounded end record, rejects
ZIP64 and multi-disk archives, parses and counts every central-directory
record, and requires exact count and extent agreement. Content then streams
from the source file through actual-byte, SHA-256, and CRC counters. Advertised
sizes are preflight hints, never the enforcement boundary. Central and local
headers must agree, and each physical compressed extent must end exactly at the
next local record or the central-directory boundary.

## Windows path and staging rules

Archive paths use forward slashes and must be relative. Validation rejects
backslashes, rooted and drive paths, ADS colons, empty or dot components,
control characters, Win32-invalid characters, trailing dots/spaces, reserved
device basenames, case-insensitive aliases, and file/ancestor collisions.
Every materialized target is resolved beneath a newly created staging root and
must pass containment before it is opened.

Recovery is two-pass. The first pass verifies exact inventory, semantic
pointers, limits, CRCs, and hashes without creating the final staging tree.
The second pass repeats source/directory/path limits and rebinds every written
byte to the already verified descriptor. The source ZIP and live Atlas state
are never modified.

## Incomplete-artifact lifecycle

The R-11 implementation creates full backups, full-backup staging
restores, and project-bundle staging trees under typed
`.atlas-incomplete-<operationId>` sibling names. A successful operation
promotes that working tree to its absent final path while its ownership marker
is still present, then removes the marker. A crash or fault before promotion
therefore cannot leave an ordinary-looking final artifact.

Failure is a serialized terminal transition. When owned failure publication
succeeds, the owner exclusively creates a separate typed failed marker,
quarantines the tree under `.atlas-failed-<operationId>`, and attempts deletion
only within explicit entry and byte budgets. If ownership or failed-marker
publication cannot be proven, the operation remains terminal under its typed
incomplete path and never overwrites foreign evidence. Markers contain only
schema, enumerated kind/state, a 128-bit operation identifier, and canonical
UTC timestamps; they never contain paths, filenames, user content, or
exception text.

The lifecycle also exposes bounded persisted-artifact cleanup. It scans only a
limited number of direct children with the exact typed-name grammar, refuses
links and invalid or mismatched ownership markers, enforces candidate,
entry, byte, and minimum-age limits, and rechecks an artifact snapshot before
deletion. Changed or over-budget trees remain quarantined.

Directory-chain validation checks both lexical and resolved components. On
Windows it rejects native reparse-point attributes while accepting safe 8.3
spellings of the same directory. Lifecycle markers must be no-follow regular
files; linked markers are refused. An operation ID is registered as active
before its working path is published and is released on every begin failure,
so cleanup cannot race an operation into existence or retain a leaked active
registration.

Public full-backup validation rejects all lifecycle files. Only the creating
operation may temporarily admit its exact marker while validating its own
working tree. If ordinary completion evidence was written before a later
failure, the integration attempts to remove that evidence; the typed failed or
incomplete path remains authoritative if the host denies removal.

PR #46 hosted CI run 144, exact-main push run 145, and local exact-`main`
proof at `fce3769` passed. The canonical follow-up matrix records the closure
evidence.

## Threat boundary and exclusions

SHA-256 detects inconsistent or corrupted bundles; it is not authentication
against malicious same-user code that can rewrite both payload and manifest.
Nested Git ZIPs remain opaque hashed payloads and are not recursively expanded.

R-12 is specified separately by the
[`recovery artifact retention contract`](RECOVERY_ARTIFACT_RETENTION_CONTRACT.md).
R-12 through R-14 remain open pending their individual closure gates. The
R-11 lifecycle above does not by itself claim recovery-artifact retention,
streaming export, or bounded DOCX/HTML extraction. WP2 therefore remains open.
