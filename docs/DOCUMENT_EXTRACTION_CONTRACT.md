# Bounded document extraction contract

This contract defines the resource and compatibility boundary for Project
Atlas DOCX and HTML/HTM extraction. Importing the app-owned copy and creating
its database row remain the primary operation; text extraction is a bounded,
non-fatal enrichment step.

## Execution boundary

Production DOCX and HTML extraction runs in a dedicated Dart isolate. The
worker receives only the source path, normalized format, and validated integer
limits. File, archive, inflater, XML, and text objects are created and released
inside the worker.

The source must be a no-follow regular file. The worker captures its byte
length and modified time before extraction and revalidates both before
returning success. A changed, missing, linked, or non-regular source produces a
structured warning and no extracted text.

## Limits

Every configured value must be positive and no greater than its hard maximum.
The central-directory and compressed-entry limits must also be no greater than
the configured source limit.

| Resource | Default | Hard maximum |
|---|---:|---:|
| Source bytes | 10 MiB | 64 MiB |
| ZIP entries | 2,048 | 16,384 |
| ZIP central-directory bytes | 4 MiB | 16 MiB |
| Compressed `word/document.xml` bytes | 10 MiB | 64 MiB |
| Actual expanded `word/document.xml` bytes | 32 MiB | 128 MiB |
| Extracted-text characters | 16 Mi | 32 Mi |

The source cap also bounds raw HTML returned for preview. The character cap
applies to the stripped text result.

## DOCX rules

DOCX extraction performs a bounded file-backed ZIP preflight before
decompression:

- the EOCD and central directory must be complete, single-disk, non-ZIP64, and
  within the entry and metadata limits;
- `word/document.xml` must occur exactly once with matching local and central
  headers;
- encrypted `word/document.xml` and target compression other than STORE or
  DEFLATE are rejected;
- local payload extents and ordinary or signed/unsigned data descriptors must
  agree with the central directory; and
- declared compressed and expanded sizes are checked before inflation.

Only `word/document.xml` is inflated. A bounded sink enforces actual expanded
bytes even when ZIP headers understate them, then verifies the declared size
and CRC. XML must be strict UTF-8, may not contain a `DOCTYPE`, and must parse
within the expanded-byte bound. The existing paragraph/text spacing behavior
is preserved, and the final trimmed text must fit the character limit.

## HTML rules

HTML/HTM is read once through a capped stream in the worker. Decoding remains
compatible with the previous behavior: strict UTF-8 first, then Latin-1
fallback. The decoded source is stored as `rendered_markdown`; the existing
tag-stripping and whitespace normalization produces `extracted_text`.

## Warning and import semantics

Expected hostile, malformed, missing, changed, or oversized input returns
`atlas.document_extraction_warning.v1` JSON with a stable code, format,
sanitized operator message, and applicable observed and limit values. It never
contains a source path, stack trace, archive content, or raw exception.

Stable warning codes include:

- `source_not_regular`, `source_size_limit`, and `source_changed`;
- `archive_entry_limit`, `archive_metadata_limit`, and `invalid_archive`;
- `expanded_size_limit` and `text_size_limit`;
- `document_xml_missing`, `malformed_document_xml`, and
  `unsafe_document_xml`; and
- `io_failure`, `worker_failure`, and `extraction_failed`.

Warnings do not fail document import. The owned copy and `status = imported`
row are retained, extraction fields remain null, and the warning JSON is
stored in `documents.parse_error`. The legacy `Future<String>` database and
`Future<void>` application import methods remain compatible; detailed methods
expose the document ID and optional warning to operator-facing callers.

Library and work-item import surfaces report successful imports with extraction
warnings. Document preview and project-summary evidence reads do not bypass a
stored warning, and their legacy raw-file fallback uses the same source-byte
cap.

## Exclusions

This contract does not add cancellation or byte-level progress for individual
document extraction, expand extraction to other document formats, or change
HTML parsing semantics. ZIP64, multi-disk, encrypted, and non-STORE/DEFLATE
DOCX document XML are unsupported and fail closed with a warning.
