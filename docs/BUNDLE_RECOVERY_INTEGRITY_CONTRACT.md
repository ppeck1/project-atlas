# Bundle recovery integrity contract

Status: implementation proof in progress on `fix/bundle-validation-integrity`.
Date: 2026-07-22

This contract defines the R-07 through R-10 boundary. Full backups are
directory trees with a completion marker; project bundles are ZIP archives.
They retain separate schemas and validators because their trust roots and
materialization rules differ.

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

## Threat boundary and exclusions

SHA-256 detects inconsistent or corrupted bundles; it is not authentication
against malicious same-user code that can rewrite both payload and manifest.
Nested Git ZIPs remain opaque hashed payloads and are not recursively expanded.

R-11 through R-14 remain open. In particular, a later extraction I/O failure
can leave a partial staging directory; this package does not claim an
`.incomplete` lifecycle, retention, streaming export, or bounded DOCX/HTML
extraction. WP2 therefore remains open after R-07 through R-10.
