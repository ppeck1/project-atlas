# Project Atlas — Variable & Data Flow Map

> Maintained with each release. Every significant variable, column, and key is listed with its type, all write sites, all read sites, and any known quirks or constraints.

---

## 1. Database Tables

### `projects`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | — | Timestamp: `microsecondsSinceEpoch.toString()`. Never reassigned. |
| `title` | TEXT | — | Required. Shown in every project list and picker. |
| `owner` | TEXT? | null | Free text owner name. Linked to Contacts via `ContactOwnerField`. |
| `created_at` | INTEGER | now | Unix ms. Set once on create; never updated. |
| `description` | TEXT? | null | Added v5. Long-form project description. |
| `desired_outcome` | TEXT? | null | Added v5. Goal statement used in Ollama summarizer prompt. |
| `success_criteria` | TEXT? | null | Added v5. Used in Ollama summarizer prompt. |
| `status` | TEXT | `'active'` | Added v5. Shared UI values live in `project_metadata.dart`: `active\|stale\|needs_update\|needs_review\|local_only\|public_mismatch\|paused\|blocked\|completed\|archived`. Internal soft-delete rows use `deleted`. |
| `category` | TEXT? | null | Added v18. Free-text project grouping used by Projects and Project Detail; empty/null renders as `Uncategorized`. |
| `deleted_at` | DATETIME? | null | Added v5. Soft delete timestamp. |
| `delete_reason` | TEXT? | null | Added v5. Soft delete rationale. |
| `phase` | TEXT? | null | Added v6. Values: `idea\|design\|build\|test\|ship\|stabilize`. |
| `priority` | TEXT? | null | Added v6. Values: `low\|normal\|high\|urgent`. |
| `scope_included` | TEXT? | null | Added v6. In-scope narrative. |
| `scope_excluded` | TEXT? | null | Added v6. Out-of-scope narrative. |
| `outcome_summary` | TEXT? | null | Added v6. Post-project reflection field. |
| `lessons_learned` | TEXT? | null | Added v6. Post-project reflection field. |

**Written by:** `AppDb.createProject()`, `AppState.updateProjectMeta()`, `AppDb.mergeProjects()` (marks source projects deleted after merge), local refresh/import flows, and approved agent manifest/status proposals.
**Read by:** `watchProjects()`, `watchActiveProject()`, `ProjectsScreen`, `ProjectDetailScreen`, `DashboardScreen`, Ollama summarizer, Telegram formatter, `AtlasAgentService` status/brief DTOs
**Quirks:** `id` is set once; all updates use `UPDATE WHERE id = ?`. `deletedAt` column exists, but most current soft-delete/merge paths use `status = 'deleted'` plus `delete_reason`; archive is a visible lifecycle status, not the merge/delete marker. Status labels, colors, attention flags, and summary eligibility are centralized in `project_metadata.dart`.

---

### `app_meta`

Key-value store for all runtime settings and active-state flags.

| Key pattern | Value | Written by | Read by | Notes / Quirks |
|-------------|-------|-----------|---------|----------------|
| `active_project_id` | project ID string | `setActiveProjectId()` | `watchActiveProject()`, router gate | Cleared only if the project is deleted. |
| `active_stage_id::{projectId}` | stage ID | `setActiveStageIdForProject()` | `watchActiveStageForProject()` | One key per project. |
| `is_bottleneck::{stageId}` | `'1'` or `'0'` | `setIsBottleneck()` | `GovernanceScreen` | Stored in app_meta (not in stages table); distinct from `stages.is_bottleneck` column. |
| `projects_tab::category_sort` | sort option string | `ProjectsScreen` | `ProjectsScreen` | Category section order. Values include `name_az`, `name_za`, `recent_update`, `project_count_desc`, `newest_project`, and `oldest_project`. |
| `projects_tab::project_sort` | sort option string | `ProjectsScreen` | `ProjectsScreen` | Project row order within each category. Values include `name_az`, `name_za`, `recent_update`, `newest`, `oldest`, `priority`, `attention`, and `owner_az`. |
| `projects_tab::pinned_categories` | JSON string array | `ProjectsScreen` | `ProjectsScreen` | Category labels pinned above unpinned categories before the selected category sort is applied. |
| `projects_tab::pinned_projects` | JSON string array | `ProjectsScreen` | `ProjectsScreen` | Project IDs pinned above unpinned projects within each category before the selected project sort is applied. |
| `setting::telegram_bot_token` | bot token | `SettingsScreen → setSetting()` | `sendTodayToTelegram()` | Stored plaintext. Personal desktop use only. |
| `setting::telegram_chat_id` | chat ID | `SettingsScreen → setSetting()` | `sendTodayToTelegram()` | Can be personal or group chat. |
| `setting::telegram_enabled` | `'1'` or `'0'` | `SettingsScreen` | Informational (UI toggle), not enforced in send path | Toggle exists but `sendTodayToTelegram()` does not gate on this flag. |
| `setting::ollama_host` | URL string | `SettingsScreen → setSetting()` | `_buildOllama()` in `AppState` | Defaults to `http://localhost:11434` if null. |
| `setting::ollama_model` | model name | `SettingsScreen → setSetting()` | `_buildOllama()` in `AppState` | Defaults to `qwen3.5:9b` if null (Settings UI shows `mistral` as hint). |
| `setting::project_ai_summaries_enabled` | `'1'` or `'0'` | Settings -> AI Summaries | `ProjectDetailScreen`, `summarizeProjectFull()` | Default off. Gates manual project summary controls and generation. |
| `setting::project_ai_summary_include_library` | `'1'` or `'0'` | Settings -> AI Summaries | `ProjectDetailScreen`, `summarizeProjectFull()` | Default on. Controls whether linked Library docs are included by default. |
| `setting::project_ai_summary_allow_bulk_refresh` | `'1'` or `'0'` | Settings -> AI Summaries | `ProjectsScreen`, `refreshMissingProjectSummaries()` | Default off. Bulk refresh is a separate gate from manual summaries. |
| `setting::project_ai_summary_model` | model name? | Settings -> AI Summaries | `summarizeProjectFull()`, `refreshMissingProjectSummaries()` | Optional summary-specific Ollama model. Null/empty falls back to `setting::ollama_model`. |

**AppDb constants:** `kActiveProjectId`, `kTelegramBotToken`, `kTelegramChatId`, `kTelegramEnabled`, `kOllamaHost`, `kOllamaModel`, `kProjectAiSummariesEnabled`, `kProjectAiSummaryIncludeLibrary`, `kProjectAiSummaryAllowBulkRefresh`, `kProjectAiSummaryModel`
**Quirks:** All values stored as raw text strings. No type coercion — callers must parse booleans as `'1'/'0'` and handle null as "not set / use default".

---

### `stages`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | — | Pattern: `{projectId}_stage_{n}` for auto-created stages. |
| `project_id` | TEXT | — | FK → `projects.id`. No cascade; orphaned stages are handled in startup repair. |
| `title` | TEXT | — | Stage name displayed in Work and Governance screens. |
| `owner` | TEXT? | null | Stage responsibility owner. Free text; not linked to Contacts. |
| `position` | INTEGER | — | Display order (ascending). Not auto-updated on reorder; gaps are tolerated. |
| `created_at` | DATETIME | now | |
| `bottleneck_owner` | TEXT? | null | Added v5. Governance bottleneck assignee. Free text. |
| `is_bottleneck` | BOOLEAN | `false` | Added v5. Visual flag in GovernanceScreen. |

**Written by:** `_ensureDefaultStages()` (auto on project create), `setBottleneckOwner()`, `setIsBottleneck()`; `addStage(projectId, title)`, `updateStageTitle(stageId, title)`, `deleteStage(stageId)`, `reorderStage(stageId, position)` — stage lifecycle management (DB/AppState layer; no UI yet)  
**Read by:** `watchStagesForProject()`, `WorkScreen`, `GovernanceScreen`, `TodayScreen` (stage → project label lookup)  
**Quirks:** Default 6 stages are created with every new project. `stages.is_bottleneck` is a table column but bottleneck state is *also* tracked per-stage-id in `app_meta` under `is_bottleneck::{stageId}`. The `app_meta` path is what GovernanceScreen reads. The table column is a secondary/historical field.

---

### `work_items`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | — | `millisecondsSinceEpoch.toString()`. |
| `stage_id` | TEXT | — | FK → `stages.id`. |
| `title` | TEXT | — | Required. Used in all list views, Telegram messages, Ollama prompts. |
| `description` | TEXT? | null | Optional long-form context. Included in AI prompts. |
| `owner` | TEXT? | null | Free text owner. Linked to Contacts via `ContactOwnerField` in create/edit dialogs. |
| `status` | TEXT | `'next'` | Values: `inbox\|next\|doing\|waiting\|done\|archived`. `done` is canonical; `completed` bool is legacy. |
| `priority` | TEXT | `'normal'` | Values: `low\|normal\|high\|urgent`. |
| `due_at` | DATETIME? | null | Triggers Today inclusion when ≤ end-of-today. |
| `updated_at` | DATETIME | now | Updated on every write. |
| `created_at` | DATETIME | now | |
| `blocked_reason` | TEXT? | null | Non-null = item is blocked. Shown in TodayScreen blocked section. |
| `source` | TEXT? | null | Free-text origin note (e.g., "Slack", "email from Alice"). |
| `phone_queue` | BOOLEAN | `false` | Sends item to Today → Phone Queue section. |
| `completed` | BOOLEAN | `false` | Legacy bool; `status='done'` is canonical. Both are updated together for backwards compat. |

**Written by:** `addWorkItem()`, `updateWorkItem()`, `setWorkItemStatus()`, `toggleWorkDone()`  
**Read by:** `WorkScreen`, `TodayScreen`, `ReviewScreen`, `ExportScreen`, Ollama summarizers, Telegram formatter  
**Today query criteria (any one triggers inclusion):** `status='doing'` OR `phone_queue=1` OR `priority IN ('high','urgent')` OR `due_at <= end of today` — AND `status NOT IN ('done','archived')`  
**Quirks:** `completed` boolean is kept in sync with `status='done'` but is not the authoritative source. Do not use `completed` for business logic; use `status`.

---

### `work_item_notes`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | UUID-style timestamp. |
| `work_item_id` | TEXT | FK → `work_items.id`. No cascade. |
| `body` | TEXT | Markdown supported in display. |
| `created_at` | DATETIME | |
| `updated_at` | DATETIME | Updated on every edit. |

**Written by:** `addWorkItemNote()`, `updateWorkItemNote()`, `deleteWorkItemNote()`  
**Read by:** `watchNotesForWorkItem(id)` → `WorkItemDetailSheet`  
**Quirks:** Notes are persistent and append-only in intent (no UI to delete from the detail sheet, only via DB directly).

---

### `work_item_analyses`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `work_item_id` | TEXT | FK → `work_items.id`. |
| `prompt` | TEXT | System + user prompt sent to Ollama. |
| `output` | TEXT | Full Ollama response. |
| `model` | TEXT? | Model name at time of analysis; null if not recorded. |
| `created_at` | DATETIME | |

**Written by:** `analyzeWorkItemReadOnly()` — only after user accepts the advisory output  
**Read by:** `watchAnalysesForWorkItem(id)` → `WorkItemDetailSheet`  
**Quirks:** Read-only analyses do **not** mutate any task fields. Multiple analyses per work item are allowed. Stored output is advisory — the user is shown it first.

---

### `drafts`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | |
| `project_id` | TEXT? | null | Optional link to a project. |
| `work_item_id` | TEXT? | null | Optional link to a work item. |
| `kind` | TEXT | | `project_summary\|today_summary\|email_draft\|task_extract\|atlas_agent_proposal\|custom` |
| `title` | TEXT | | Display label. |
| `body` | TEXT | | Full AI output. |
| `created_at` | DATETIME | | |
| `updated_at` | DATETIME | | |
| `input_json` | TEXT? | null | Serialized prompt input for traceability. |
| `accepted` | BOOLEAN | `false` | Reserved — user approval flag; not currently enforced in any workflow. |

**Written by:** `saveDraft()` — called after explicit "Save Draft" action by user, automatically for `kind='project_summary'` entries after background or on-demand structured summary generation, and by `AtlasAgentService` for validated agent proposals with `kind='atlas_agent_proposal'`
**Read by:** `watchDrafts()` — Library screen (AI Drafts filter)  
**Quirks:** `accepted` field exists in schema but is unused. The Drafts route is not yet a first-class navigation destination; drafts are accessed via Library → type filter.

**Agent proposal review:** `kind='atlas_agent_proposal'` drafts use `input_json.reviewStatus` (`pending`, `approved`, `rejected`) plus the existing `accepted` boolean. `updateDraftReview()` updates `accepted`, `input_json`, `body`, and `updated_at` after approve/reject without a schema migration.

---

### `daily_reviews`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `review_date` | DATETIME | Midnight of the review day (normalized). |
| `summary` | TEXT | Markdown text. |
| `created_at` | DATETIME | |

**Written by:** `saveDailyReview(summary)` — auto-triggered in ReviewScreen when a summary is generated; upserts by date  
**Read by:** `getDailyReviewForDate(date)` — returns the review for any given day; `watchRecentDailyReviews({limit})` — streams the most recent N reviews sorted by date desc  
**Quirks:** One record per calendar day. `review_date` is normalized to midnight. Upsert by date: a second call on the same day updates the existing record (DELETE then INSERT within the same calendar day). Enforced one-per-day by the v10 UNIQUE index on `review_date`.

---

### `outbox_messages`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | |
| `channel` | TEXT | | Always `'telegram'` currently. |
| `title` | TEXT | | Human-readable label (e.g., "Today Jun 23"). |
| `body` | TEXT | | Full HTML-escaped message sent. |
| `sent_at` | DATETIME? | null | Set on success; null = not yet sent or failed. |
| `created_at` | DATETIME | | |
| `status` | TEXT | `'pending'` | `pending\|sent\|failed` |
| `error` | TEXT? | null | Error string on failure. |

**Written by:** `addOutboxMessage()` (pending), `markOutboxSent()`, `markOutboxFailed()`  
**Read by:** `watchOutboxMessages()` → ExportScreen outbox log  
**Quirks:** Records accumulate indefinitely. No auto-pruning. Status transitions are one-way: pending → sent or pending → failed.

---

### `event_log`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `timestamp` | DATETIME | Set at log time. |
| `level` | TEXT | `debug\|info\|warn\|error` |
| `area` | TEXT | Subsystem tag (e.g., `contacts`, `ui`, `telegram`). |
| `action` | TEXT | Specific event name (e.g., `contact_created`, `send_failed`). |
| `entity_type` | TEXT? | Subject type (`project`, `work_item`, `contact`, etc.). |
| `entity_id` | TEXT? | Subject ID. |
| `input_json` | TEXT? | Serialized inputs at time of event. |
| `output_json` | TEXT? | Serialized outputs / results. |
| `error` | TEXT? | Error message if applicable. |
| `stack_trace` | TEXT? | Stack trace for error events. |
| `correlation_id` | TEXT? | Multi-step trace ID. Project summary start/result events share one ID. |

**Written by:** `AppDb.logEvent()`, `AppDb.logError()`  
**Read by:** `watchRecentEvents()` → Settings → Activity Log, `clearEventLog()`  
**Quirks:** No rotation or size limit. Use "Clear event log" in Settings → Admin to prune. Project summary provenance uses `entity_type='project_summary'` so summary runs do not appear as normal project-update attribution rows.

---

### `documents`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `microsecondsSinceEpoch.toString()`. |
| `title` | TEXT | | Display name — set to the original filename at import. |
| `original_filename` | TEXT | | Filename (basename only) at import time. |
| `stored_path` | TEXT? | null | App-owned copy path: `<appDocDir>/atlas_documents/<id>.<ext>`. Never the original source path. |
| `mime_type` | TEXT? | null | Detected at import via `mimeTypeForExtension(ext)` (mime package). Always set for known extensions; null for unknown. |
| `extension` | TEXT? | null | Lowercase file extension without dot (e.g., `pdf`, `md`). |
| `project_id` | TEXT? | null | Optional project link. |
| `source` | TEXT? | null | Import origin note. |
| `status` | TEXT | `'imported'` | `imported\|draft\|archived` |
| `created_at` | DATETIME | | |
| `updated_at` | DATETIME | | |
| `metadata_json` | TEXT? | null | Arbitrary metadata blob. |
| `extracted_text` | TEXT? | null | Populated at import for `.txt`, `.csv`, `.json`, `.docx`. Null for binary types. |
| `rendered_markdown` | TEXT? | null | Populated at import for `.md`. Null for all other types. |
| `parse_error` | TEXT? | null | Non-null if a content extraction step failed. |

**Written by:** `AppDb.importDocumentFromPath(path, {projectId})`  
**Read by:** `watchDocuments()` → `LibraryScreen`, `watchDocumentsForWorkItem()` → `WorkItemDetailSheet`, `getDocumentPathsForProject()` → Ollama structured summary  
**Import pipeline:**
1. Copies the source file to `atlas_documents/<id>.<ext>` via `File.copy()`.
2. Saves `mimeType` via `mimeTypeForExtension(ext)`.
3. Files over 10 MB: skips text extraction; both text columns remain null.
4. For `.txt`, `.csv`, `.json`, `.log`, `.xml`, `.yaml`, `.yml`, `.ini`, `.toml`, `.rst`: reads as UTF-8 (latin1 fallback) into `extractedText`.
5. For `.md`: reads into `renderedMarkdown`.
6. For `.html`/`.htm`: raw HTML stored in `renderedMarkdown`; `extractHtmlText()` result (tags stripped) stored in `extractedText`. This dual-storage allows rich rendering and full-text search from the same document.
7. For `.eml`: `stripEmlBody(raw)` result stored in `extractedText`; `renderedMarkdown` is null.
8. For `.docx`: calls `extractDocxText(destPath)` from `document_extractor.dart`; stores result in `extractedText`.
9. Binary types (`.pdf`, `.doc`, `.rtf`, `.svg`, images): no extraction; both text columns remain null.

**Library entry model behavior:** `_LibraryEntry.fromDocument` in `library_screen.dart` sets `content = extractedText ?? renderedMarkdown`. (Note: `extractedText` is preferred so HTML search/copy uses stripped text, not raw markup.) If `content` is null and the entry has a `document` reference, `_EntryViewer` delegates rendering to `DocumentPreview`. `DocumentPreview` uses `renderedMarkdown ?? extractedText` for display — which means HTML renders via `flutter_html` on the raw HTML stored in `renderedMarkdown`. Image extensions (`jpg`, `jpeg`, `png`, `gif`, `webp`, `bmp`) additionally receive `isMedia: true` + `mediaType: 'image'`, routing them to the `InteractiveViewer` image path.

**Quirks:** Moving or deleting the original source file does not affect the stored copy. `AppDb.deleteDocument(id)` deletes the `document_links` rows, the `documents` row, and the app-owned file from disk in one call. `AppState.deleteDocument(id)` wraps this and calls `notifyListeners()`.

---

### `document_links`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `document_id` | TEXT | FK → `documents.id`. |
| `entity_type` | TEXT | Always `'work_item'` currently. |
| `entity_id` | TEXT | FK → the entity (usually `work_items.id`). |
| `created_at` | DATETIME | |

**Written by:** `linkDocumentToWorkItem()`, `unlinkDocumentFromWorkItem()`  
**Read by:** `watchDocumentsForWorkItem(id)` → `WorkItemDetailSheet`  
**Quirks:** `entity_type` field allows future expansion (e.g., linking to projects) but only `'work_item'` is used today.

---

### `contacts`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | Timestamp-based. |
| `name` | TEXT | Required. Used as the display value in all owner pickers. |
| `title` | TEXT? | Job title or role. |
| `phone` | TEXT? | Primary phone. |
| `alternate_phone` | TEXT? | Secondary phone. |
| `email` | TEXT? | Used as secondary match key in import deduplication. |
| `website` | TEXT? | |
| `business_name` | TEXT? | |
| `notes` | TEXT? | Free-form notes. |
| `photo_path` | TEXT? | Path to local image file. Not copied to app data. |
| `created_at` | DATETIME | |
| `updated_at` | DATETIME | Updated on every edit. |

**Written by:** `saveContact()` (upsert), `deleteContact()`  
**Read by:** `watchContacts()` → `ContactOwnerField`, Settings → Workforce, responsibility lookups  
**Used in owner pickers:** `create_work_item_dialog.dart`, `work_item_detail_sheet.dart`, `project_detail_screen.dart` (project owner), `governance_screen.dart` (stage owner)  
**Import/Export:** JSON via `importContactsFromJson()` / `exportContactsToJson()`, CSV via `exportContactsToCsv()`  
**Import format:**
```json
{
  "schema": "project_atlas_contacts_v1",
  "exported_at": "...",
  "contacts": [
    {
      "id": "optional",
      "name": "Alice Smith",
      "title": "Engineer",
      "phone": "555-0100",
      "alternatePhone": null,
      "email": "alice@example.com",
      "website": null,
      "businessName": "Acme",
      "notes": null,
      "photoPath": null
    }
  ]
}
```
**Quirks:** Deduplication on import uses `id` first, then `email`, then `name`. Raw lists (array without wrapper) are also accepted.

---

### `project_people`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `project_id` | TEXT | FK → `projects.id`. |
| `name` | TEXT | Person name. Used for responsibility lookups by contact name. |
| `role` | TEXT? | Role in the project (e.g., "Lead", "Reviewer"). |
| `authority` | TEXT? | Decision authority note. |
| `created_at` | DATETIME | |

**Written by:** `addProjectPerson()`, `updateProjectPerson()`, `deleteProjectPerson()`  
**Read by:** `getProjectPeople()` → `ProjectDetailScreen` People section, `getContactResponsibilities()`  
**Quirks:** Not directly linked to `contacts.id`. The `name` field is matched against `contacts.name` (case-insensitive) in `getContactResponsibilities()`.

**`ContactResponsibilities` (view model, not persisted):** Assembled on-demand in `AppState.getContactResponsibilities(contactId)`. Aggregates: projects where the contact is `owner`, roles from `project_people`, and work items where the contact is `owner`. Used exclusively by `Settings → Workforce` contact detail view. Not stored in any table.

---

### `project_risks`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | |
| `project_id` | TEXT | | FK → `projects.id`. |
| `title` | TEXT | | Short risk statement. |
| `desc` | TEXT? | null | Optional detail. |
| `severity` | TEXT | `'medium'` | `low\|medium\|high\|critical` |
| `created_at` | DATETIME | | |

**Written by:** `addProjectRisk()`, `updateProjectRisk()`, `deleteProjectRisk()`  
**Read by:** `getProjectRisks()` → `ProjectDetailScreen` Risks section  
**Quirks:** `updated_at` column may be missing on legacy DBs; `addProjectRisk()` falls back to a raw SQL INSERT with an explicit timestamp when `SqliteException` mentions `updated_at`. `_ensureProjectCompatibilityColumns()` runs at startup and adds `severity TEXT NOT NULL DEFAULT 'medium'` if missing.

---

### `project_decisions`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `project_id` | TEXT | FK → `projects.id`. |
| `title` | TEXT | Short decision statement. |
| `ctx` | TEXT? | Context / rationale. |
| `decider` | TEXT? | Who made the decision. |
| `created_at` | DATETIME | |

**Written by:** `addProjectDecision()`, `updateProjectDecision()`, `deleteProjectDecision()`  
**Read by:** `getProjectDecisions()` → `ProjectDetailScreen` Decisions section  
**Quirks:** `updated_at` column may be missing on legacy DBs; `addProjectDecision()` falls back to a raw SQL INSERT with an explicit timestamp when `SqliteException` mentions `updated_at`.

---

### `tags`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | |
| `name` | TEXT UNIQUE | Tag label (e.g., "home", "work", "personal"). Unique constraint enforced at DB level. |
| `color` | TEXT? | Hex color string (`#RRGGBB`). Parsed and rendered in `ProjectDetailScreen`. |
| `created_at` | DATETIME | |
| `updated_at` | DATETIME | |

**Written by:** `createTag()`, `updateTag()`, `deleteTag()`  
**Read by:** `watchTags()` → `ProjectDetailScreen` tag assignment UI, `ProjectsScreen` tag filter  
**Quirks:** `name` must be unique (DB constraint). Color is parsed client-side; invalid hex strings fall back to `_kPrimary`.

---

### `project_tags`

Data class: `ProjectTagAssignment`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `project_id` | TEXT | FK → `projects.id`. |
| `tag_id` | TEXT | FK → `tags.id`. |
| `created_at` | DATETIME | |

**PK:** `(project_id, tag_id)` composite  
**Written by:** `assignTagToProject()`, `removeTagFromProject()`  
**Read by:** `watchTagsForProject()` → `ProjectDetailScreen`, `ProjectsScreen` filter logic

---

### `project_media`

Data class: `ProjectMediaItem`

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | |
| `project_id` | TEXT | | FK → `projects.id`. |
| `title` | TEXT | | Display name. |
| `original_filename` | TEXT | | Filename at import time. |
| `stored_path` | TEXT | | App-owned copy path. Copied into app data on import. |
| `media_type` | TEXT | `'file'` | Common values: `image\|video\|audio\|file\|folder` — used for thumbnail/icon rendering. |
| `mime_type` | TEXT? | null | |
| `extension` | TEXT? | null | Lowercase, no dot. |
| `byte_size` | INTEGER? | null | File size in bytes. |
| `file_modified_at` | DATETIME? | null | Source file modification time. |
| `caption` | TEXT? | null | Optional user caption. |
| `is_cover` | BOOLEAN | `false` | At most one cover image per project. Enforced in AppDb. |
| `source` | TEXT? | null | Import origin note. |
| `metadata_json` | TEXT? | null | Arbitrary metadata blob. |
| `created_at` | DATETIME | | |
| `updated_at` | DATETIME | | |

**Written by:** `addProjectMedia()`, `updateProjectMedia()`, `deleteProjectMedia()`, `setProjectCoverImage()`, `AppState.applyLocalProjectRefresh()` (via `importProjectMediaFromPath()` for media discovered in linked local project folders), `importWorkItemMediaFromPath()`, `importLlmTaskMediaFromPath()`, `AppDb.mergeProjects()` (reassigns source media rows to target project)
**Read by:** `watchProjectMedia()` → `ProjectDetailScreen` Media gallery; `watchAllProjectMedia()` → `LibraryScreen` Media filter; `watchProjectMediaForEntity()` / `getProjectMediaForEntity()` through work item and LLM task attachment surfaces
**Quirks:** App-owned copies are stored under the app data directory. Deleting a `project_media` record deletes its `media_links` rows but does **not** auto-delete the copied file — cleanup is manual via "Open app data folder" in Admin. Local refresh records media source keys as `local_refresh:<relativePath>` so repeated refreshes update/skip rather than duplicate. Project merge preserves existing stored paths; it does not copy files again.

---

### `media_links`

Data class: `MediaLink`

| Column | Type | Notes / Quirks |
|--------|------|----------------|
| `id` | TEXT PK | `media_link_<microseconds>`. |
| `media_id` | TEXT | FK -> `project_media.id`. |
| `entity_type` | TEXT | Currently `work_item` or `llm_task`. |
| `entity_id` | TEXT | Target entity ID. Not FK-constrained so future entity types can share the table. |
| `created_at` | DATETIME | Attachment timestamp. |

**Written by:** `linkProjectMediaToEntity()`, `unlinkProjectMediaFromEntity()`, `attachProjectMediaToWorkItem()`, `attachProjectMediaToLlmTask()`, `importWorkItemMediaFromPath()`, `importLlmTaskMediaFromPath()`, and `deleteProjectMedia()` cleanup.
**Read by:** `watchProjectMediaForEntity()` / `getProjectMediaForEntity()`, `WorkItemDetailSheet`, Project Detail LLM queue dialogs, `AtlasAgentService.getLlmTaskDetail()`, MCP `get_llm_task`.
**Quirks:** Links reuse existing project media records; they do not copy the file again. AppState validates same-project ownership before linking media to a work item or LLM task.

---

### `project_registry`

Human-reviewed local project registry for Operations.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `registry_<microseconds>` for rows created from review actions. |
| `atlas_project_id` | TEXT? | null | Optional FK to `projects.id`; set by the Link action. |
| `display_name` | TEXT | | Derived from scanner display name or path basename at review time. |
| `local_path` | TEXT UNIQUE | | Local candidate path. One registry row per path. |
| `git_root` | TEXT? | null | Read-only git root fact copied from the reviewed observation if available. |
| `classification` | TEXT | | One of `active_project`, `knowledge_store`, `data_root`, `sdk_vendor`, `archive_export`, `needs_review`. |
| `review_state` | TEXT | | `accepted\|linked\|ignored\|needs_review`. |
| `notes` | TEXT? | null | Reserved for reviewed operator notes. |
| `created_at` | DATETIME | | Preserved on upsert. |
| `updated_at` | DATETIME | | Updated on each review action. |
| `last_reviewed_at` | DATETIME? | null | Set when an observation is reviewed into the registry. |

**Written by:** `AppDb.reviewProjectObservation()` via `AppState.acceptProjectObservation()`, `linkProjectObservation()`, `ignoreProjectObservation()`, `markProjectObservationNeedsReview()`
**Read by:** `watchProjectRegistry()` -> `OperationsScreen` Registered Projects tab; `getProjectRegistryByPath()` when persisting new observations
**Quirks:** Registry rows are reviewed identity/state. They are not raw scan facts. Re-reviewing the same `local_path` updates the existing row instead of creating a duplicate.

---

### `project_observations`

Append-only facts emitted by manual local scans.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `obs_<scanRunId>_<index>` within a scan. |
| `registry_id` | TEXT? | null | Optional FK to `project_registry.id` if a matching registry row already existed before the observation was inserted. |
| `scan_run_id` | TEXT | | FK to `project_scan_runs.id`. |
| `observed_path` | TEXT | | Candidate path discovered by the scanner. |
| `classification_guess` | TEXT | | Scanner guess; displayed as an observation, not truth. |
| `confidence` | INTEGER | | Scanner confidence score. |
| `branch` | TEXT? | null | Read-only git branch fact when available. |
| `head_sha` | TEXT? | null | Read-only git HEAD SHA when available. |
| `dirty_count` | INTEGER? | null | Count of `git status --porcelain` rows; null if unavailable. |
| `remote_url` | TEXT? | null | Read-only `origin` URL when available. No GitHub API call is made. |
| `marker_files_json` | TEXT | | JSON array of marker filenames detected by existence check. |
| `warnings_json` | TEXT | | JSON array of scanner warnings for this observation. |
| `raw_json` | TEXT | | Full serialized scanner result for review/export. |
| `observed_at` | DATETIME | | Time the candidate was observed. |

**Written by:** `AppState.runLocalOperationsScan()` -> `AppDb.addProjectObservation()`
**Read by:** `watchRecentProjectObservations()` -> `OperationsScreen` Review Candidates and Warnings tabs; `getProjectObservationsForScanRun()` for JSON copy
**Quirks:** Observations are append-only. Review actions write to `project_registry`; they do not rewrite observation facts.

---

### `project_scan_runs`

Manual Operations scan metadata.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `scan_<microseconds>`. |
| `roots_json` | TEXT | | JSON array of roots scanned. v0.1 UI starts with the current working directory and allows operator-selected folders. |
| `started_at` | DATETIME | | Set before scanner execution. |
| `completed_at` | DATETIME? | null | Set on completion or failure. |
| `status` | TEXT | | `running\|completed\|failed`. |
| `total_seen` | INTEGER | 0 | Directory count inspected by the scanner. |
| `candidates` | INTEGER | 0 | Number of observations inserted. |
| `ignored` | INTEGER | 0 | Count of excluded directories skipped. |
| `warnings_json` | TEXT | | JSON array of run-level warnings. |

**Written by:** `startProjectScanRun()`, `finishProjectScanRun()` through `AppState.runLocalOperationsScan()`
**Read by:** `watchProjectScanRuns()` -> `OperationsScreen` Scan Runs and Warnings tabs; `buildProjectScanRunExportJson()`
**Quirks:** v0.1 has no watcher or scheduler. The UI starts with the current working directory, allows adding/removing operator-selected folders, blocks drive roots, and uses the scan run as the review boundary for copyable/exportable JSON. App-owned scan artifacts are saved under `<app support>\operations_scans\`.

---

### `local_project_refresh_items`

Source-key ledger for idempotent local project refresh imports.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `refresh_<microseconds>` for generated ledger rows. |
| `registry_id` | TEXT | | FK to `project_registry.id`. |
| `source_kind` | TEXT | | `document`, `media`, `source_file`, `atlas_card`, `decision`, `work_item`, `risk`, or `project_meta`. |
| `source_key` | TEXT | | Stable local source anchor, e.g. `DECISIONS.md#dec-0001`. |
| `target_type` | TEXT | | Atlas target entity type. |
| `target_id` | TEXT | | Atlas target row ID created or adopted by refresh. |
| `source_fingerprint` | TEXT | | Deterministic content/stat fingerprint used to detect unchanged vs changed source anchors. |
| `last_imported_at` | DATETIME | | Last successful apply time for this source anchor. |

**Written by:** `AppState.applyLocalProjectRefresh()` through `AppDb.upsertLocalProjectRefreshItem()`
**Read by:** `AppState.previewLocalProjectRefresh()` to mark entries as `new`, `changed`, or `unchanged`; `previewProjectBundleExport()` / `exportProjectBundleToZip()`
**Quirks:** Unique on `(registry_id, source_kind, source_key)`. The ledger tracks Atlas imports only; it is not a source-control or repo mutation log.

---

### `project_enrichment_runs`

Atlas-owned refresh/audit run history for local project completeness.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `enrich_<microseconds>`. |
| `started_at` | INTEGER | | Milliseconds since epoch. |
| `completed_at` | INTEGER? | null | Set on completion/failure. |
| `status` | TEXT | | `running`, `completed`, `completed_with_findings`, `completed_with_errors`, or `failed`. |
| `scope_json` | TEXT | | JSON envelope with run flags and `writeBoundary='atlas_only'`. |
| `registry_entries` | INTEGER | 0 | Registry rows seen by the run. |
| `linked_projects` | INTEGER | 0 | Registry rows linked to Atlas projects. |
| `refreshed_projects` | INTEGER | 0 | Linked projects with created/updated refresh output. |
| `created_items` | INTEGER | 0 | Atlas rows created by local refresh. |
| `updated_items` | INTEGER | 0 | Atlas rows updated by local refresh. |
| `unchanged_items` | INTEGER | 0 | Ledger-matched unchanged refresh entries. |
| `skipped_items` | INTEGER | 0 | Refresh entries skipped by selection/status. |
| `failed_projects` | INTEGER | 0 | Linked project refresh failures. |
| `summary_considered` | INTEGER | 0 | Legacy counter retained while project AI summaries are disabled. |
| `summary_refreshed` | INTEGER | 0 | Legacy counter retained while project AI summaries are disabled. |
| `summary_skipped` | INTEGER | 0 | Legacy counter retained while project AI summaries are disabled. |
| `summary_failed` | INTEGER | 0 | Legacy counter retained while project AI summaries are disabled. |
| `findings` | INTEGER | 0 | Findings saved for this run. |
| `open_findings` | INTEGER | 0 | Findings with `status='open'`. |
| `warnings_json` | TEXT | `[]` | Run-level warnings. |
| `output_json` | TEXT | `{}` | Coverage object and phase summaries. |

**Written by:** `AppState.runProjectEnrichment()` through `AppDb.startProjectEnrichmentRun()` and `finishProjectEnrichmentRun()`
**Read by:** `OperationsScreen` Enrichment tab; `AtlasAgentService.listProjectEnrichmentRuns()`; MCP `list_project_enrichment_runs`
**Quirks:** Raw SQL compatibility table, not a generated Drift table in this slice. Enrichment writes Atlas DB records only and does not mutate source repositories.

---

### `project_enrichment_findings`

Open exception/completeness ledger emitted by enrichment runs.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `finding_<runId>_<index>`. |
| `run_id` | TEXT | | Parent `project_enrichment_runs.id`. |
| `project_id` | TEXT? | null | Atlas project anchor when known. |
| `registry_id` | TEXT? | null | Local registry anchor when known. |
| `severity` | TEXT | | `info`, `warning`, or `error`. |
| `category` | TEXT | | `registry`, `identity`, `library`, `media`, `people`, `workboard`, `governance`, or `repository`. |
| `title` | TEXT | | Human-readable finding. |
| `detail` | TEXT? | null | Optional next-action detail. |
| `evidence_json` | TEXT | `{}` | Project title, registry display name/path, remote URL, dirty count, or other evidence. |
| `status` | TEXT | `open` | Reserved for future resolve/suppress workflow. |
| `created_at` | INTEGER | | Milliseconds since epoch. |

**Written by:** `AppState.runProjectEnrichment()` after the refresh/audit pass.
**Read by:** `OperationsScreen` Enrichment tab; `getOpenProjectEnrichmentFindings()`; MCP `get_project_enrichment_run`
**Quirks:** Findings are intentionally non-destructive. They document what Atlas could not fill, what needs linking/review, and which future workaround or source parser may be needed.

---

### `llm_task_queue`

Persisted queue for MCP/local harness LLM jobs attached to Atlas projects and optional work items.

| Column | Type | Default | Notes / Quirks |
|--------|------|---------|----------------|
| `id` | TEXT PK | | `llm_task_<microseconds>`. |
| `project_id` | TEXT | | Atlas project anchor. Queueing validates that the project is visible to the agent service. |
| `work_item_id` | TEXT? | null | Optional work item anchor. Queueing validates that it belongs to the project. |
| `title` | TEXT | | Human-readable queue item label. |
| `objective` | TEXT | | Actual instruction for the harness/LLM loop. |
| `context_json` | TEXT | `{}` | Structured operator/agent context. |
| `priority` | TEXT | `normal` | `low`, `normal`, `high`, or `urgent`. Claim order prioritizes urgent/high first, then oldest. |
| `status` | TEXT | `pending` | `pending`, `leased`, `completed`, `failed`, or `cancelled`. |
| `created_by` | TEXT | | Actor that queued the task, usually `operator` or an MCP client name. |
| `created_at` / `updated_at` | INTEGER | | Milliseconds since epoch. |
| `leased_by` | TEXT? | null | Worker ID that claimed the task. |
| `leased_at` / `lease_expires_at` | INTEGER? | null | Lease window for future harness retry/reclaim logic. |
| `attempts` | INTEGER | 0 | Incremented on claim. |
| `result_json` | TEXT? | null | JSON-safe result returned by the worker. |
| `error` | TEXT? | null | Failure detail for failed tasks. |
| `review_draft_id` | TEXT? | null | Optional `atlas_agent_proposal` draft created from completion output. |
| `completed_at` | INTEGER? | null | Completion, failure, or cancellation timestamp. |

**Written by:** `enqueueLlmTask()`, `updateLlmTask()`, `cancelLlmTask()`, `requeueLlmTask()`, `claimLlmTask()`, `completeLlmTask()`, and `failLlmTask()` through `AppState`, `AtlasAgentService`, the Project Detail operator UI, and MCP queue lifecycle tools.
**Read by:** `ProjectDetailScreen` collapsible task header and queue manager, `AtlasAgentService.listLlmTasks()`, `AtlasAgentService.getLlmTaskDetail()`, MCP `list_llm_tasks` / `get_llm_task`.
**Quirks:** The queue is a handoff/lease boundary, not autonomous execution by itself. Project Detail can edit/move/cancel/requeue tasks and attach/unlink project media. Editing a leased task clears the lease and returns it to `pending`. Workers can only complete or fail leased tasks. `completeLlmTask()` can create a reviewable handoff proposal draft when `proposalBody` is supplied; it does not directly apply project mutations. MCP `get_llm_task` includes attached media metadata; `list_llm_tasks` stays queue-row focused.

---

## 2. AppState (ChangeNotifier)

Located at `lib/shared/models/app_state.dart`. Wraps `AppDb` and adds reactive streams plus business logic.

| Field | Type | Notes / Quirks |
|-------|------|----------------|
| `db` | `AppDb` | Direct DB access. Avoid using outside AppState except where a method gap exists. |
| `_activeProject` | `Project?` | Cached from `watchActiveProject()` subscription. |
| `activeProject` | `Project? getter` | Synchronous read from cache. May be stale for one frame after a project switch. |
| `hasActiveProject` | `ValueNotifier<bool>` | Router uses this for nav gating. Updated on every active-project stream event. |

**Background refresh:** Project AI summary refresh is no longer automatic on a timer. Manual project summaries are gated by `project_ai_summaries_enabled`; toolbar bulk refresh is separately gated by `project_ai_summary_allow_bulk_refresh`. The constructor still schedules the linked-local project refresh timer when background refreshes are enabled.

**AppState document methods:**

| Method | Returns | Notes |
|--------|---------|-------|
| `importDocumentFromPath(path, {projectId})` | `Future<String>` | Delegates to `db.importDocumentFromPath`, then `notifyListeners()`; returns the document ID. |
| `deleteDocument(id)` | `Future<void>` | Calls `db.deleteDocument(id)` (removes document_links, documents row, and disk file), then `notifyListeners()`. |
| `getLatestProjectSummaryDraft(projectId)` | `Future<Draft?>` | Delegate to `db.getLatestProjectSummaryDraft(projectId)`. |
| `getDocumentPathsForProject(projectId)` | `Future<Map<String, String?>>` | Delegate to `db.getDocumentPathsForProject(projectId)`. |
| `buildProjectSummaryEvidencePacket(projectId, {includeLibrary})` | `Future<ProjectSummaryEvidencePacket>` | Builds the same ranked/capped Library evidence packet used by Project Detail preview and generation. README/HANDOFF/CURRENT_STATE/ACTIVE_TASK-style docs rank highest; excerpts are capped per document and per packet. |
| `summarizeProjectFull(projectId, {includeLibrary, evidencePacket, trigger})` | `Future<ProjectSummaryOutcome>` | Opt-in structured project summary generator. Throws while `projectAiSummariesEnabled == false`; otherwise uses the summary-specific model setting when present, can include a prebuilt ranked Library evidence packet, validates output, saves a review draft, and logs correlated summary provenance. |
| `refreshMissingProjectSummaries({force, includeLibrary, betweenProjects})` | `Future<ProjectSummaryRefreshResult>` | Bulk project-summary refresh. Requires `projectAiSummaryAllowBulkRefresh == true`; otherwise returns a zero-count result with an explanatory error and does not call Ollama. |
| `mergeProjects({sourceProjectId, targetProjectId})` | `Future<Map<String, int>>` | Delegates to `AppDb.mergeProjects()`, moves source-linked rows to the target, notifies listeners, and returns moved row counts. |
| `exportOperationalBackupToJson(path)` | `Future<int>` | Exports a ZIP archive to `path` containing `backup.json` (all DB tables serialized) plus `documents/<id>.<ext>` and `media/<id>.<ext>` entries for all stored files. |
| `previewProjectBundleExport(projectId, {includeFiles})` | `Future<ProjectBundleExportPreview>` | Builds the review summary for project bundle export: Atlas record counts, optional copied file counts, registry/observation/refresh-ledger counts, and missing-file warnings. Read-only. |
| `exportProjectBundleToZip(projectId, path, {includeFiles})` | `Future<int>` | Applies the reviewed project bundle export by writing one ZIP containing `project_bundle.json` plus optional copied document/media files. Includes project metadata, stages, work items, notes, analyses, documents, media, people, risks, decisions, registry row, observations, and refresh ledger rows. |
| `getVisibleProjects()` | `Future<List<Project>>` | Non-deleted projects ordered alphabetically, excluding the hidden internal General Tasks project. Used by `AtlasAgentService` for MCP/harness-safe project lists. |
| `saveDraft({kind, title, body, ...})` | `Future<String>` | Saves a draft and returns the generated draft ID. Existing callers may ignore the ID; agent proposal callers keep it for review/audit links. |

**AppState LLM queue methods:**

| Method | Returns | Notes |
|--------|---------|-------|
| `enqueueLlmTask(...)` | `Future<LlmTaskQueueItem>` | Persists a project-scoped queue item with optional work item anchor, priority, context, and creator. |
| `getLlmTasks({projectId, status, limit})` / `getLlmTasksForProject(projectId, {limit})` | `Future<List<LlmTaskQueueItem>>` | Reads queue items for MCP/harness views and the Project Detail task header. |
| `getLlmTask(id)` | `Future<LlmTaskQueueItem?>` | Reads one queue item. |
| `updateLlmTask(...)` | `Future<LlmTaskQueueItem>` | Operator-owned edit/move path. Validates visible project and optional work item anchor; editing a leased task revokes the lease and returns it to `pending`. Completed tasks cannot be edited. |
| `cancelLlmTask(taskId, {reason})` | `Future<LlmTaskQueueItem>` | Marks a non-completed task `cancelled`, clears any lease, stores the reason in `error`, and removes it from claimable work. |
| `requeueLlmTask(taskId)` | `Future<LlmTaskQueueItem>` | Returns a failed or cancelled task to `pending`, clearing lease/result/error/review linkage. |
| `claimLlmTask(workerId, {taskId, leaseDuration})` | `Future<LlmTaskQueueItem?>` | Claims a pending task or a specific pending task, increments attempts, and sets lease fields. |
| `completeLlmTask(taskId, workerId, {result, reviewDraftId})` | `Future<LlmTaskQueueItem?>` | Marks a leased task complete after worker validation. Optional review draft ID links completion to a human-approved proposal. Throws if the task is no longer leased. |
| `failLlmTask(taskId, workerId, error, {result})` | `Future<LlmTaskQueueItem?>` | Marks a leased task failed and stores error/result payloads. Throws if the task is no longer leased. |

**AppState media attachment methods:**

| Method | Returns | Notes |
|--------|---------|-------|
| `watchMediaForWorkItem(id)` / `getMediaForWorkItem(id)` | `Stream<List<ProjectMediaItem>>` / `Future<List<ProjectMediaItem>>` | Reads project media attached through `media_links(entity_type='work_item')`. Used by Work Item Detail. |
| `attachProjectMediaToWorkItem(workItemId, mediaId)` | `Future<void>` | Validates that the work item and media belong to the same project, then links them. |
| `importWorkItemMediaFromPath(workItemId, path)` | `Future<String>` | Imports a file into the owning project's media gallery, links it to the work item, and returns the media ID. |
| `unlinkProjectMediaFromWorkItem(workItemId, mediaId)` | `Future<void>` | Removes the attachment row only; the project media file record remains. |
| `watchMediaForLlmTask(id)` / `getMediaForLlmTask(id)` | `Stream<List<ProjectMediaItem>>` / `Future<List<ProjectMediaItem>>` | Reads project media attached through `media_links(entity_type='llm_task')`. Used by the Project Detail LLM queue dialogs and agent task detail. |
| `attachProjectMediaToLlmTask(taskId, mediaId)` | `Future<void>` | Validates that the task and media belong to the same project, then links them. |
| `importLlmTaskMediaFromPath(taskId, path)` | `Future<String>` | Imports a file into the task project's media gallery, links it to the LLM task, and returns the media ID. |
| `unlinkProjectMediaFromLlmTask(taskId, mediaId)` | `Future<void>` | Removes the attachment row only; the project media file record remains. |

**AppState Operations methods:**

| Method | Returns | Notes |
|--------|---------|-------|
| `runLocalOperationsScan({scanner})` | `Future<String>` | Starts a `project_scan_runs` row, executes `LocalOperationsScanner`, appends observations, completes/fails the run, logs an operations event, and returns the scan run ID. Default scanner root is the current working directory. |
| `acceptProjectObservation(observationId)` | `Future<void>` | Reviews one observation into `project_registry` with `review_state='accepted'`. |
| `linkProjectObservation(observationId, atlasProjectId)` | `Future<void>` | Reviews one observation into `project_registry` with `review_state='linked'` and an Atlas project FK. |
| `ignoreProjectObservation(observationId)` | `Future<void>` | Reviews one observation into `project_registry` with `review_state='ignored'`. |
| `markProjectObservationNeedsReview(observationId)` | `Future<void>` | Reviews one observation into `project_registry` with `review_state='needs_review'`. |
| `importProjectRegistryEntryAsProject(registryId, {importDocs, refresh})` | `Future<String>` | Creates a normal Atlas Project from an accepted registry row, links `project_registry.atlas_project_id`, sets the new Project active, imports safe root marker docs into Library, and applies the local refresh profile by default. Idempotent when already linked. If exactly one active Atlas Project already has the same title, it links/imports/refreshes that project instead of creating a duplicate; ambiguous matches require operator selection. |
| `updateExistingProjectFromRegistryEntry(registryId, atlasProjectId, {importDocs, refresh})` | `Future<String>` | Links a registry row to a selected existing Atlas Project, imports safe root marker docs without duplicate filenames, optionally applies the local refresh profile, sets the project active, and logs the operation. Used by Operations Registered Projects > Update existing. |
| `previewLocalProjectRefresh(projectId)` | `Future<LocalProjectRefreshPreview>` | Reads the linked local registry path and builds a reviewable profile preview. BOH v0.1 parses root-level operations docs into candidate documents, decisions, work items, risks, project metadata, and media files. |
| `applyLocalProjectRefresh(projectId, {selectedActionIds})` | `Future<LocalProjectRefreshApplyResult>` | Applies selected preview entries and writes `local_project_refresh_items` ledger rows so repeated refreshes skip unchanged source anchors. Handles documents, media, decisions, risks, work items, and project metadata. |
| `applyLocalProjectRefreshForRegistryEntry(registryId, projectId, {selectedActionIds})` | `Future<LocalProjectRefreshApplyResult>` | Applies a local refresh for a specific registry row/project pair. Used by Operations registered-project refresh so duplicate linked paths refresh the intended registry source. |
| `inspectLocalGitVisibility(projectId)` | `Future<LocalGitVisibilityReport>` | Read-only local git inspection for a linked project. Reports local tracked vs local remote-tracking ref paths, changed tracked paths, untracked paths, ignored paths, `.gitignore` patterns, and suggested ignore entries. Does not fetch, push, mutate repos, or call GitHub. |
| `runProjectEnrichment({refreshLinkedProjects, includeSourceDocuments})` | `Future<ProjectEnrichmentRunResult>` | Runs the Atlas-only enrichment workflow: refreshes linked project artifacts, audits completeness, writes `project_enrichment_runs` and `project_enrichment_findings`, and logs the run. Does not mutate source repositories. |
| `getProjectEnrichmentRuns({limit})` | `Future<List<ProjectEnrichmentRun>>` | Recent enrichment run summaries. |
| `getProjectEnrichmentFindingsForRun(runId)` | `Future<List<ProjectEnrichmentFinding>>` | Findings for one enrichment run. |
| `getOpenProjectEnrichmentFindings({projectId, limit})` | `Future<List<ProjectEnrichmentFinding>>` | Open findings globally or for one project. |
| `buildProjectScanRunExportJson(scanRunId)` | `Future<String>` | Builds indented JSON containing one scan run, summary counts, flattened warnings, and observations for clipboard/file export. |
| `buildProjectScanRunWarningsExportJson(scanRunId)` | `Future<String>` | Builds warning-only JSON for one scan run, including run warnings and flattened observation warnings. |
| `ensureOperationsScansFolder()` | `Future<Directory>` | Creates `<app support>\operations_scans\` plus `runs`, `warnings`, and `logs` subfolders. |
| `saveProjectScanRunExportToAppFolder(scanRunId)` | `Future<String>` | Writes full scan JSON to `operations_scans\runs\<scanId>_operations_scan.json`. |
| `saveProjectScanRunWarningsToAppFolder(scanRunId)` | `Future<String>` | Writes warning-only JSON to `operations_scans\warnings\<scanId>_operations_warnings.json`. |
| `openOperationsScansFolder()` | `Future<void>` | Ensures the scan artifact folder exists, then opens it in Explorer. |

**Key exposed streams:**

| Stream | Returns | Notes |
|--------|---------|-------|
| `watchProjects()` | `Stream<List<Project>>` | Non-deleted projects ordered alphabetically by title, excluding the hidden internal General Tasks project. |
| `watchActiveProject()` | `Stream<Project?>` | Null if no active project set. |
| `watchStagesForProject(id)` | `Stream<List<Stage>>` | Ordered by `position` asc. |
| `watchActiveStageForProject(id)` | `Stream<Stage?>` | |
| `watchWorkItemsForStage(id)` | `Stream<List<WorkItem>>` | All statuses including done/archived. |
| `watchTodayItems()` | `Stream<List<WorkItem>>` | Filtered by Today criteria (see work_items quirks). |
| `watchDrafts()` | `Stream<List<Draft>>` | All drafts, most recent first. |
| `watchDocuments()` | `Stream<List<Document>>` | All documents. |
| `watchDocumentsForWorkItem(id)` | `Stream<List<Document>>` | Via `document_links`. |
| `watchNotesForWorkItem(id)` | `Stream<List<WorkItemNote>>` | Ordered by `created_at` asc. |
| `watchAnalysesForWorkItem(id)` | `Stream<List<WorkItemAnalysis>>` | Ordered by `created_at` desc. |
| `watchContacts()` | `Stream<List<Contact>>` | Ordered by `name` asc. |
| `watchTags()` | `Stream<List<Tag>>` | Ordered by `name` asc. |
| `watchTagsForProject(id)` | `Stream<List<Tag>>` | Tags assigned to a project. |
| `watchAllProjectMedia()` | `Stream<List<ProjectMediaItem>>` | Streams all media across all projects. Used by `LibraryScreen` for the unified media/image filter. |
| `watchProjectMedia(projectId)` | `Stream<List<ProjectMediaItem>>` | Per-project media stream. Used by `ProjectDetailScreen` media section. |
| `watchMediaForWorkItem(id)` | `Stream<List<ProjectMediaItem>>` | Project media linked to a work item through `media_links`. Used by `WorkItemDetailSheet`. |
| `watchMediaForLlmTask(id)` | `Stream<List<ProjectMediaItem>>` | Project media linked to an LLM queue task through `media_links`. Used by Project Detail queue dialogs. |
| `watchProjectsFull()` | `Stream<List<ProjectFull>>` | Streams all projects with full metadata. Proxy for `db.watchProjectsFull()`. Used by `DashboardScreen`. |
| `watchProjectScanRuns()` | `Stream<List<ProjectScanRun>>` | Recent manual Operations scans, most recent first. |
| `watchRecentProjectObservations()` | `Stream<List<ProjectObservation>>` | Recent append-only Operations observations, most recent first. |
| `watchProjectRegistry()` | `Stream<List<ProjectRegistryEntry>>` | Reviewed local project registry rows, ordered by display name. |
| `watchProjectEnrichmentRuns()` | `Stream<List<ProjectEnrichmentRun>>` | Recent enrichment run summaries. Raw SQL stream is mainly a read convenience; Operations reloads explicitly after a run. |
| `watchProjectEnrichmentFindingsForRun(runId)` | `Stream<List<ProjectEnrichmentFinding>>` | Findings for one enrichment run. |
| `watchSetting(key)` | `Stream<String?>` | Reactive app_meta read. |
| `watchWorkOwner(id)` | `Stream<String?>` | |
| `watchBottleneckOwner(id)` | `Stream<String?>` | |
| `watchIsBottleneck(id)` | `Stream<bool>` | From `app_meta` key `is_bottleneck::{id}`. |
| `watchRecentEvents()` | `Stream<List<EventLogData>>` | Last 500 events, most recent first. |

---

### ProjectDetailScreen state (`lib/features/projects/project_detail_screen.dart`)

| Variable | Type | Notes |
|----------|------|-------|
| `_summaryOutcome` | `ProjectSummaryOutcome?` | Current or cached project AI summary result when opt-in summaries are enabled. Validation failures are retained for operator review. |
| `_summaryGeneratedAt` | `DateTime?` | Timestamp for the current or cached project AI summary result. |
| `_taskHeaderExpanded` | `bool` | Controls the top collapsible Project Detail task header. Defaults expanded. |
| `_llmQueueItems` | `List<LlmTaskQueueItem>` | Most recent queue items for the current project, rendered in the LLM queue subsection and manager dialog. Queue rows open an operator edit/move/cancel/requeue dialog with media attachment controls. |

**`_loadAll()` behavior:** On startup, loads current project LLM queue items (via `getLlmTasksForProject`) and populates `_llmQueueItems`. Cached project AI summary loading is gated off while `projectAiSummariesEnabled == false`.

---

## 3. Document Extractor (`lib/db/document_extractor.dart`)

Standalone pure-Dart utility module. No Flutter dependency; fully unit-testable. Used by both `AppDb` (at import time) and `DocumentPreview` (at render time).

| Export | Type / Signature | Notes |
|--------|-----------------|-------|
| `textDocumentExtensions` | `const Set<String>` | Single source of truth for which extensions are decoded as text: `{txt, md, json, csv, log, xml, yaml, yml, ini, toml, rst, html, htm, eml}`. Referenced by the file picker allowlist, import pipeline, and preview widget. |
| `shouldLoadDocumentText(extension)` | `bool Function(String extension)` | Returns true when `extension` (any case, no dot) is in `textDocumentExtensions`. Called by `DocumentPreview._shouldLoadText` to decide whether to disk-read the file. |
| `extractHtmlText(path)` | `String? Function(String path)` | Reads a file at `path` as UTF-8 (latin1 fallback on `FormatException`), strips all `<[^>]+>` HTML tags, collapses consecutive spaces, and trims. Returns null on any I/O failure. Used by `AppDb.importDocumentFromPath` to populate `extractedText` for `.html`/`.htm` files. |
| `extractDocxText(path)` | `String? Function(String path)` | Reads `.docx` bytes from disk, delegates to `extractDocxTextFromBytes`. Returns null on any I/O or parse failure. |
| `extractDocxTextFromBytes(bytes)` | `String? Function(List<int> bytes)` | Unzips the DOCX (ZIP format) via the `archive` package, finds `word/document.xml`, UTF-8 decodes it, parses XML via the `xml` package, extracts all `<w:t>` inner text nodes with `<w:p>` paragraph separators. Returns null on failure. |
| `mimeTypeForExtension(ext)` | `String? Function(String? ext)` | Calls `lookupMimeType('file.$ext')` from the `mime` package. Returns null for null input or unknown extensions. Used by `AppDb.importDocumentFromPath` and `AppDb.addProjectMedia`. |
| `stripEmlBody(raw)` | `String Function(String raw)` | Splits the EML string on newlines, discards all lines up to and including the first blank line (RFC-2822 header/body separator), returns trimmed body. Used by `AppDb.importDocumentFromPath` (stored in `extractedText`) and by `DocumentPreview` (renders the stored value directly without re-stripping). |

**Tests:** `test/document_extractor_test.dart` — covers DOCX extraction (valid, invalid, empty, multi-paragraph, UTF-8), MIME lookup (common types, null, unknown), EML body stripping (headers, no body, body-only), and `extractHtmlText` (tags stripped, no double-spaces, latin1, missing file, empty file).  
**Tests:** `test/document_preview_allowlist_test.dart` — covers `shouldLoadDocumentText` (all text extensions return true, binary extensions return false, case-insensitive).

---

## 5. Services

### AtlasAgentService (`lib/services/atlas_agent_service.dart`)

Desktop-side adapter for the future Atlas MCP and local LLM harness. It wraps `AppState` and exposes stable DTOs rather than UI widgets or raw screen state.

| Method | Returns | Notes |
|--------|---------|-------|
| `listProjects({includeArchived})` | `Future<List<AtlasProjectStatus>>` | Alphabetical, non-deleted project list. Excludes the hidden General Tasks project. Includes category, active/blocked task counts, docs/media counts, risk/decision counts, registry presence, and attention flag. |
| `getProjectStatus(projectId)` | `Future<AtlasProjectStatus?>` | Single-project status DTO. Null if missing, deleted, or hidden. |
| `getProjectBrief(projectId)` | `Future<AtlasProjectBrief?>` | Aggregates lifecycle/category fields, tags, people, risks, decisions, open work items, local registry, and latest local observation. |
| `getStaleProjects()` | `Future<List<AtlasProjectStatus>>` | Returns projects whose status or blocked work indicates attention. |
| `refreshLinkedLocalProjects({includeSourceDocuments})` | `Future<LocalProjectBatchRefreshResult>` | Delegates to the existing linked-local refresh workflow. |
| `runProjectEnrichment({refreshLinkedProjects, includeSourceDocuments})` | `Future<ProjectEnrichmentRunResult>` | Delegates to the Atlas-only enrichment workflow. Refreshes Atlas records and records findings; source repositories are not mutated. |
| `listProjectEnrichmentRuns({limit})` | `Future<List<ProjectEnrichmentRun>>` | Recent enrichment run summaries for MCP/harness reads. |
| `getProjectEnrichmentRun(runId)` | `Future<Map<String,Object?>?>` | One enrichment run plus findings as JSON-safe data. |
| `enqueueLlmTask(...)` | `Future<LlmTaskQueueItem>` | Validates project/work item anchors, priority, and context, then stores a pending queue item. |
| `listLlmTasks({projectId, status, limit})` / `getLlmTask(taskId)` | `Future<List<LlmTaskQueueItem>>` / `Future<LlmTaskQueueItem?>` | Read queue state for MCP clients and UI surfaces. |
| `getLlmTaskDetail(taskId)` | `Future<Map<String,Object?>?>` | Returns one queue item as JSON plus attached project media metadata. Used by MCP `get_llm_task` for harness context. |
| `updateLlmTask(...)` | `Future<LlmTaskQueueItem>` | Operator-owned queue edit/move path. Validates project/work item anchors and revokes any active lease. Not exposed through MCP. |
| `claimLlmTask(workerId, {taskId, leaseDuration})` | `Future<LlmTaskQueueItem?>` | Claims the next pending task or a named pending task for a harness worker. |
| `completeLlmTask(taskId, workerId, {result, proposalBody})` | `Future<LlmTaskQueueItem>` | Completes a leased task. If `proposalBody` is supplied, records a reviewable `handoff_record` proposal draft and stores its ID. Rejects stale completion if the task was edited, cancelled, failed, completed, or requeued out from under the worker. |
| `failLlmTask(taskId, workerId, error, {result})` | `Future<LlmTaskQueueItem>` | Fails a leased task and stores error/result payloads. Rejects stale failure if the task is no longer leased. |
| `cancelLlmTask(taskId, {reason})` / `requeueLlmTask(taskId)` | `Future<LlmTaskQueueItem>` | Operator-owned cancellation and retry helpers. Not exposed through MCP. |
| `previewLocalRefresh(projectId)` | `Future<LocalProjectRefreshPreview>` | Read-only preview of import/update actions for a linked local project. |
| `inspectGitVisibility(projectId)` | `Future<LocalGitVisibilityReport>` | Read-only local git visibility report. |
| `listRecentAgentProposals({limit})` | `Future<List<Draft>>` | Recent drafts with `kind='atlas_agent_proposal'`. |
| `listRecentAgentProposalReviews({limit})` / `getAgentProposalReview(draftId)` | `Future<List<AtlasProposalDraft>>` / `Future<AtlasProposalDraft?>` | Parses proposal envelopes from draft `input_json`, including pending/approved/rejected review status. |
| `proposeStatusChange(...)`, `proposeTaskUpdate(...)`, `proposeManifestUpdate(...)`, `recordValidationRun(...)`, `recordHandoff(...)` | `Future<AtlasProposalResult>` | Validate inputs and save reviewable proposal drafts. Invalid requests return validation errors and are not saved. |
| `approveAgentProposal(draftId)` | `Future<AtlasProposalApplyResult>` | Applies supported proposals after human approval: project status, task create/update with tags, manifest metadata/tags, validation-run log entry, or `project_handoff` draft creation. Marks the proposal approved. |
| `rejectAgentProposal(draftId, {reason})` | `Future<AtlasProposalApplyResult>` | Marks a pending proposal rejected without applying it. |

**Safety boundary:** Agents still cannot directly mutate Atlas state through proposal creation. Queue edit/cancel/requeue controls are operator-owned and not exposed through MCP. Only a human approval path applies supported proposals, and the service does not delete projects, overwrite manifests, write discovered repos, fetch/push Git, deploy, or publish releases.

### AtlasMcpAdapter (`lib/mcp/atlas_mcp_server.dart`)

Transport-neutral MCP tool registry and JSON-safe dispatcher for `AtlasAgentService`.

| Method | Returns | Notes |
|--------|---------|-------|
| `listTools()` | `List<AtlasMcpTool>` | Exposes read and proposal-creation tools only. Destructive tools and approval/rejection tools are intentionally absent. |
| `callTool(name, arguments)` | `Future<AtlasMcpCallResult>` | Dispatches MCP-style tool calls to `AtlasAgentService` and returns JSON-safe text content. Unknown tools return an error result. |

**Tools exposed:** `list_projects`, `get_project_status`, `get_project_brief`, `get_stale_projects`, `list_agent_proposals`, `preview_local_refresh`, `inspect_git_visibility`, `get_github_remote_status`, `refresh_github_remote_status`, `list_project_enrichment_runs`, `get_project_enrichment_run`, `run_project_enrichment`, `enqueue_llm_task`, `list_llm_tasks`, `get_llm_task`, `claim_llm_task`, `complete_llm_task`, `fail_llm_task`, `propose_status_change`, `propose_task_update`, `propose_manifest_update`, `record_validation_run`, and `record_handoff`.

### OllamaService (`lib/services/ollama_service.dart`)

| Field | Source | Default | Quirks |
|-------|--------|---------|--------|
| `host` | `AppDb.kOllamaHost` from AppMeta | `http://localhost:11434` | Configurable in Settings → Integrations. |
| `model` | `AppDb.kOllamaModel` from AppMeta | `qwen3.5:9b` | Settings UI shows `mistral` as hint; actual default in code is `qwen3.5:9b`. |

| Method | Input | Output | Notes |
|--------|-------|--------|-------|
| `isAvailable()` | — | `bool` | GET to `/api/tags`. Timeout: 4 s. Checks server reachability only, not model presence. |
| `isModelAvailable()` | — | `bool` | Parses `/api/tags` model list; prefix-matches `model` (handles `:tag` suffixes). |
| `getAvailableModels()` | — | `List<String>` | Returns all installed model names sorted alphabetically. Returns `[]` if Ollama unreachable. Used by Settings -> Integrations and Settings -> AI Summaries model dropdowns. |
| `summarizeProject(...)` | project title, active/blocked/done work item titles | `OllamaResult` | Includes `desired_outcome` and `success_criteria` in system prompt if set. |
| `summarizeToday(...)` | doing/overdue/dueToday/blocked item titles | `OllamaResult` | |
| `draftEmail(...)` | task context + user instruction | `OllamaResult` | |
| `extractTasksFromNote(...)` | raw text, project title | `OllamaResult` | |
| `analyzeWorkItem(...)` | work item fields + linked document text | `OllamaResult` | Read-only; does not mutate any record. |
| `summarizeProjectStructured({required ProjectSummaryContext context})` | `ProjectSummaryContext` | `({OllamaResult result, ProjectSummaryResult? parsed, ProjectSummaryValidationReport validation})` | Structured JSON summary via `format:"json"`, low temperature. Validates parsed output and retries once with validation feedback before failing closed. |

**`OllamaResult`:** `{ input: String, output: String?, kind: String, title: String, isSuccess: bool }`  
`output == null` or `isSuccess == false` means unavailable or empty. Never auto-applied.

**Timeout:** Both `_chat` and `_chatStructured` use a 300 s timeout (previously 90 s).

---

### TelegramService (`lib/services/telegram_service.dart`)

| Field | Source | Notes |
|-------|--------|-------|
| `botToken` | `AppDb.kTelegramBotToken` from AppMeta | Required for sending. |
| `chatId` | `AppDb.kTelegramChatId` from AppMeta | Personal or group chat ID. |

| Method | Notes |
|--------|-------|
| `sendMessage(text)` | POST to `api.telegram.org/bot{token}/sendMessage`. Outbound only. |
| `testConnection()` | Sends a test message with timestamp. Returns `(bool ok, String? error)`. |
| `formatTodayList(...)` | Static — builds HTML-escaped Telegram message from work item list. |

**HTML escaping:** All user content is escaped with `_esc()` before insertion. Escapes `&`, `<`, `>`. Entire message uses Telegram `parse_mode=HTML`.

---

### ProjectSummaryModels (`lib/services/project_summary_models.dart`)

Input models (all `const`-constructable):

| Class | Fields | Notes |
|-------|--------|-------|
| `ProjectSummaryContextWorkItem` | `id, title, status, priority, owner?, blockedReason?` | Represents a single work item for the summary prompt. |
| `ProjectSummaryContextPerson` | `name, role?` | Person entry for the summary prompt. |
| `ProjectSummaryContextRisk` | `title, severity` | Risk entry for the summary prompt. |
| `ProjectSummaryContextDecision` | `title, decider?` | Decision entry for the summary prompt. |
| `ProjectSummaryContextDoc` | `id, title, extension?, excerpt?, storedPath?, canOpenInExplorer, rank?, score?, selectionReason?` | Document reference with optional text excerpt and ranked evidence-preview metadata. |
| `ProjectSummaryContext` | `id, title, description?, desiredOutcome?, successCriteria?, status, phase?, priority?, owner?, workItems, people, risks, decisions, documents` | Top-level input aggregate. Has `toPromptText()` method that serializes all fields to a human-readable prompt string. |
| `ProjectSummaryEvidencePacket` | `context, includeLibrary, suppliedDocumentCount, maxExcerptCharsPerDoc, maxTotalExcerptChars, warnings` | Shared Project Detail preview/generation packet. Exposes document counts, excerpt totals, document paths, and compact log JSON without storing full excerpts in `event_log`. |

Output models:

| Class | Fields | Notes |
|-------|--------|-------|
| `ProjectSummaryOwnershipItem` | `person, work: List<String>, basis?` | Ownership breakdown entry within a structured result. |
| `ProjectSummaryDocumentRef` | `documentId, title, reason` | Document reference with relevance rationale. |
| `ProjectSummaryResult` | `goal: List<String>, currentState, ownership, relevantDocuments, blockersAndRisks, nextActions, confidence` | Parsed structured output. Has `fromJson(Map)` factory and `tryParse(String?)` static method. `tryParse` strips `<think>…</think>` blocks (Qwen reasoning models), removes markdown fences, extracts the outermost JSON object, and returns null on failure. |

Return type:

| Class | Fields / Getters | Notes |
|-------|-----------------|-------|
| `ProjectSummaryOutcome` | `rawOutput?, inputText?, structured?, validationIssues, documentPaths`; `hasStructured`, `hasValidationIssues`, `isSuccess` getters | `inputText` is the exact model prompt/evidence input saved with project summary drafts. `isSuccess` fails closed when validation issues are present. |

---

### LocalOperationsScanner (`lib/services/local_operations_scanner.dart`)

Manual, read-only local project scanner used only by Operations.

| Item | Value / Behavior |
|------|------------------|
| Default root | Current working directory; the Operations UI can add more folders manually |
| Max depth | `2` by default |
| Marker files | `.git`, `README.md`, `ACTIVE_TASK.md`, `CURRENT_STATE.md`, `AGENTS.md`, `CLAUDE.md`, `pyproject.toml`, `package.json`, `pubspec.yaml` |
| Classifications | `active_project`, `knowledge_store`, `data_root`, `sdk_vendor`, `archive_export`, `needs_review` |
| Excluded directory names | `.git`, `node_modules`, `.dart_tool`, `build`, `.venv`, `venv`, `__pycache__`, `dist`, `coverage`, `target`, `.pytest_cache`, `.mypy_cache`, `.gradle`, `.idea`, `.vs` |
| Git commands | Fixed read-only calls: `rev-parse --show-toplevel`, `branch --show-current`, `log -1 --format=%H`, `status --porcelain`, `remote get-url origin` |

**Queue behavior:** Strong project roots stop descent by default, so nested package/example folders are not emitted as separate candidates once the parent root is classified. Operations Review Candidates defaults to `Needs action`, hiding accepted/linked/ignored rows unless the operator switches to `Known`, `Ignored`, or `All`. Bulk review actions can accept, ignore, mark needs-review, or ignore descendants of selected roots.

**Safety boundary:** The scanner checks marker existence and directory listings, but does not read source file contents, `.env`, keys, PEMs, databases, archives, or logs as content. It blocks drive roots like `B:\`, does not run tests, install dependencies, call BOH, call GitHub, execute agents, or mutate discovered repositories.

---

### Project Summary DB Methods (`lib/db/app_db.dart`)

| Method | Returns | Notes |
|--------|---------|-------|
| `getLatestProjectSummaryDraft(projectId)` | `Future<Draft?>` | Finds the most recent draft with `kind='project_summary'` for the given project. |
| `hasTodayProjectSummaryDraft(projectId)` | `Future<bool>` | True if a `project_summary` draft exists with today's date. |
| `getDocumentPathsForProject(projectId)` | `Future<Map<String, String?>>` | Returns a map of `documentId → storedPath` for all docs linked to the project. |
| `deleteProjectSummaryDrafts(projectId)` | `Future<void>` | Deletes all `kind='project_summary'` drafts for the project. Called before saving a fresh summary to avoid accumulation. |

---

## 6. Navigation

Router: `lib/app/router.dart` using `go_router`  
Shell: `lib/shared/widgets/atlas_shell.dart`

| Route | Screen | Requires active project? | Notes |
|-------|--------|-------------------------|-------|
| `/today` | `TodayScreen` | Yes | |
| `/projects` | `ProjectsScreen` | No | |
| `/projects/:id` | `ProjectDetailScreen` | No | |
| `/operations` | `OperationsScreen` | No | Manual local scans, filtered/bulk review candidates, filtered registry rows, enrichment run dashboard/findings, warnings, scan JSON copy/export, app-folder save actions, and app scan-folder access. |
| `/library` | `LibraryScreen` | No | Accepts query params `?entryType=document&entryId=<id>`. `LibraryScreen` constructor accepts `initialEntryId` and `initialEntryType` optional params; `initState` pre-selects the entry when params are provided. |
| `/settings` | `SettingsScreen` | No | |
| `/` | `DashboardScreen` (legacy) | Yes | |
| `/work` | `WorkScreen` (legacy) | Yes | |
| `/review` | `ReviewScreen` (legacy) | Yes | |
| `/export` | `ExportScreen` (legacy) | Yes | |
| `/governance` | `GovernanceScreen` (legacy) | Yes | |
| `/log` | `LogScreen` (legacy) | Yes | |

**Gate logic:** `AtlasShell` checks `hasActiveProject`. If false and current route is not `/projects`, it redirects to `/projects` via `addPostFrameCallback`.  
**Quirk:** Initial location is `/today`. If no active project exists, the app immediately redirects to `/projects`.

---

## 7. Data Flows

### Project Creation
```
ProjectsScreen → showCreateProjectDialog()
  → AppState.createProject(title)
    → AppDb.createProject(id, title, now)
      → INSERT INTO projects
      → _ensureDefaultStages(id)   ← creates 6 default stages
      → setActiveProjectId(id)     ← writes app_meta
    → notifyListeners()
  → watchActiveProject() fires → hasActiveProject = true → nav unlocks
```

### Task Creation (Work screen)
```
WorkScreen → showCreateWorkItemDialog()
  → ContactOwnerField selects owner from contacts or creates new contact
  → returns Map { title, description, owner, status, priority, dueAt(ISO string) }
  → AppState.addWorkItem(stageId, title, ..., dueAt)
    → AppDb.addWorkItem(...)
      → INSERT INTO work_items
    → notifyListeners()
  → watchWorkItemsForStage() fires → list updates
```

### Today Screen Population
```
AtlasShell renders TodayScreen
  → watchTodayItems() stream
    → SELECT work_items WHERE status NOT IN ('done','archived')
      AND (status='doing' OR phone_queue=1
           OR priority IN ('high','urgent')
           OR due_at <= tonight)
  → Dart partitions results into: doing / overdue / dueToday / phoneQueue / highPrio
  → Renders in sections with tap → WorkItemDetailSheet
```

### Telegram Send
```
Settings → Export tab → "Send to Telegram"
  → AppState.sendTodayToTelegram()
    → _buildTelegram() → reads bot_token, chat_id from AppMeta
    → getTodayItems()
    → for each item: look up Stage → Project for label (real DB query)
    → TelegramService.formatTodayList(...) → HTML-escaped string
    → AppDb.addOutboxMessage(...) → status='pending'
    → TelegramService.sendMessage(text)
    → AppDb.markOutboxSent(id) OR markOutboxFailed(id, err)
  → returns (bool ok, String? error)
```

### Ollama (human-in-the-loop)
```
[ReviewScreen / ExportScreen / WorkItemDetailSheet / ProjectDetailScreen]
  → user triggers AI action
  → AppState.summarize* / draftEmail* / analyzeWorkItem*
    → reads ollama_host, ollama_model from AppMeta
    → OllamaService._chat(system, user) → HTTP POST to /api/chat
    → returns OllamaResult { output: String?, isSuccess: bool }
  → if !isSuccess → SnackBar "Ollama not available"
  → else → show OllamaReviewDialog
    → "Discard" → nothing saved
    → "Save Draft" → AppDb.saveDraft(...) → INSERT INTO drafts
```

### Contact Responsibility Lookup
```
Settings → Workforce → select contact → _ContactDetail
  → AppState.getContactResponsibilities(contact)
    → getProjects() → filter where project.owner matches contact.name or email
    → getProjectPeople() → filter where person.name matches contact.name or email
    → getTodayItems() + getAllActiveWorkItems() → filter where item.owner matches
  → renders ownedProjects / contributingProjects / workItems sections
```

### Document Library Import
```
LibraryScreen → _importByPath()
  → FilePicker.platform.pickFiles(allowedExtensions:
      [txt,md,json,csv,log,xml,yaml,yml,ini,toml,rst,rtf,
       pdf,docx,doc,html,htm,eml,jpg,jpeg,png,gif,webp,bmp,svg])
  → AppState.importDocumentFromPath(path)
    → AppDb.importDocumentFromPath(path, {projectId})
      → File(path).existsSync()  ← throws FileSystemException if missing
      → File.copy(destPath)      ← destPath = atlas_documents/<id>.<ext>
      → mimeTypeForExtension(ext) ← document_extractor.dart
      → if file > 10 MB: skip extraction (both columns stay null)
      → if shouldLoadDocumentText(ext) && ext not in {html,htm,eml,md}:
          File(destPath).readAsString(utf8, fallback latin1) → extractedText
      → if md: readAsString() → renderedMarkdown
      → if html/htm:
          raw → renderedMarkdown
          extractHtmlText(destPath) → extractedText  ← dual storage
      → if eml:
          stripEmlBody(readAsString()) → extractedText
      → if docx: extractDocxText(destPath) → extractedText
          → ZipDecoder().decodeBytes(bytes)
          → archive.findFile('word/document.xml')
          → XmlDocument.parse(utf8.decode(content))
          → collect <w:t> nodes, separate <w:p> with newlines
      → INSERT INTO documents (storedPath=destPath, mimeType, extractedText, renderedMarkdown, ...)
  → watchDocuments() stream fires → LibraryScreen rebuilds
  → _LibraryEntry.fromDocument(d)
      → if ext in {jpg,jpeg,png,gif,webp,bmp}: isMedia=true, mediaType='image'
      → content = d.extractedText ?? d.renderedMarkdown  ← stripped text preferred
  → _EntryViewer renders:
      → mediaType='image' → InteractiveViewer(Image.file)
      → content != null  → SelectableText(content)  [for most text types]
      → document != null → DocumentPreview(document)
          → _shouldLoadText (shouldLoadDocumentText) decides if disk-read needed
          → display uses: renderedMarkdown ?? extractedText
          → ext='md'               → Markdown widget (flutter_markdown)
          → ext='json'             → _CodeBlock (JsonEncoder.withIndent)
          → ext='html'/'htm'       → Html widget (flutter_html) on renderedMarkdown
          → ext='eml'              → _CodeBlock(body) — body already stripped at import
          → ext in text extensions → _CodeBlock(body)
          → ext='pdf'/'rtf'/'svg'  → _ExternalViewerPrompt (url_launcher)
          → ext='docx'/'doc'       → _CodeBlock(body) if content, else _ExternalViewerPrompt
```

---

### Local Operations Manual Scan
```
OperationsScreen -> select scan roots -> "Scan selected"
  -> AppState.runLocalOperationsScan()
    -> AppDb.startProjectScanRun(rootsJson=[...], status='running')
    -> LocalOperationsScanner.scan()
      -> list directories under the selected root up to maxDepth
      -> stop descending at strong project roots by default
      -> skip excluded folders and .git internals
      -> detect marker filenames by existence check
      -> for git roots only, run fixed read-only git metadata commands
      -> return observation DTOs; no file content is read and no repo is mutated
    -> AppDb.addProjectObservation(...) for each candidate, with registry_id when local_path was already reviewed
    -> AppDb.finishProjectScanRun(status='completed' or 'failed')
  -> Operations tabs refresh from watchProjectScanRuns/watchRecentProjectObservations
```

### Local Operations Artifact Save
```
OperationsScreen scan-run menu
  -> Save full JSON to app folder
     -> AppState.saveProjectScanRunExportToAppFolder(scanRunId)
        -> <app support>\operations_scans\runs\<scanId>_operations_scan.json
  -> Save warnings JSON to app folder
     -> AppState.saveProjectScanRunWarningsToAppFolder(scanRunId)
        -> <app support>\operations_scans\warnings\<scanId>_operations_warnings.json
  -> Open scan folder
     -> AppState.openOperationsScansFolder()
```

### Local Operations Review Action
```
OperationsScreen candidate action
  -> AppState.accept/link/ignore/markProjectObservationNeedsReview(observationId)
    -> AppDb.reviewProjectObservation(...)
      -> load immutable observation
      -> upsert project_registry by observed_path/local_path
      -> set review_state and optional atlas_project_id
  -> observation row remains unchanged
Bulk actions call AppState.acceptProjectObservations(), ignoreProjectObservations(), or markProjectObservationsNeedsReview()
and reuse the same reviewProjectObservation path for each selected observation.
```

### Local Operations Import To Project
```
OperationsScreen Registered Projects -> Create new
  -> AppState.importProjectRegistryEntryAsProject(registryId)
    -> AppDb.createProject(projectId, displayName, now)
       -> creates normal Project and default Tasks stage
    -> AppDb.updateProjectMeta(...)
       -> records local path / classification in Project fields
    -> AppDb.linkProjectRegistryEntryToAtlasProject(...)
       -> sets review_state='linked' and atlas_project_id
    -> importDocumentFromPath(path, projectId)
       -> imports safe root marker docs:
          README.md, ACTIVE_TASK.md, CURRENT_STATE.md, AGENTS.md, CLAUDE.md,
          package.json, pubspec.yaml, pyproject.toml
    -> AppState.applyLocalProjectRefreshForRegistryEntry(...)
       -> imports/updates refresh-profile documents, media, source files, cards,
          decisions, risks, work items, and project metadata through the ledger
```

### Local Operations Update Existing Project
```
OperationsScreen Registered Projects -> Update existing
  -> AppState.updateExistingProjectFromRegistryEntry(registryId, atlasProjectId)
    -> AppDb.linkProjectRegistryEntryToAtlasProject(...)
       -> sets review_state='linked' and atlas_project_id
    -> importDocumentFromPath(path, projectId)
       -> imports safe root marker docs without duplicate filenames
    -> AppState.applyLocalProjectRefresh(projectId)
       -> updates native Atlas documents, media, decisions, risks, work items, and project metadata through local_project_refresh_items
```

### Local Operations Enrichment Run
```
OperationsScreen Enrichment -> Run enrichment
  -> AppState.runProjectEnrichment()
    -> AppDb.startProjectEnrichmentRun(scope_json, status='running')
    -> AppState.refreshLinkedLocalProjects()
       -> applies local refresh for linked registry rows
       -> imports/updates documents, media, source files, cards, work items, risks, decisions, and project metadata
    -> AppState.refreshMissingProjectSummaries()
       -> refreshes cached summaries when Ollama is available
    -> audit registry/project completeness
       -> checks registry links, local paths, docs/media/source/card coverage, tags, people, tasks, risks, decisions, summaries, git/GitHub cache
    -> AppDb.addProjectEnrichmentFinding(...) for each info/warning/error
    -> AppDb.finishProjectEnrichmentRun(status, counts, warnings_json, output_json)
Source repositories are read-only in this flow; enrichment writes Atlas records and findings only.
```

### Project Merge
```
ProjectsScreen project tile -> merge action
  -> AppState.mergeProjects(sourceProjectId, targetProjectId)
    -> AppDb.mergeProjects(...)
       -> reassigns stages, documents, people, risks, decisions, media, drafts, registry rows, and non-duplicate tags to target project
       -> moves active_project_id / active_stage metadata if the source was active
       -> marks source project status='deleted' with delete_reason='Merged into <target>.'
       -> logs projects/merge_projects with moved row counts
```

---

## 8. Schema Migration History

| Version | Change | Notes |
|---------|--------|-------|
| 1 | `projects`, `app_meta` | Initial schema. |
| 2 | `stages` added | |
| 3 | `work_items` added (basic) | id, stage_id, title, owner, completed, created_at |
| 4 | `work_items` extended; `drafts`, `daily_reviews`, `outbox_messages` created | Defensive: addColumn calls wrapped in try/catch for partial-migration safety. |
| 5 | `projects` extended (description, desired_outcome, success_criteria, status, deleted_at, delete_reason); `stages` extended (bottleneck_owner, is_bottleneck); `event_log`, `documents`, `document_links`, `project_people`, `project_risks`, `project_decisions` added | |
| 6 | `projects` extended (phase, priority, scope_included, scope_excluded, outcome_summary, lessons_learned) | |
| 7 | `work_item_notes`, `work_item_analyses` added | Startup repair also runs `CREATE TABLE IF NOT EXISTS` for both. |
| 8 | `contacts` added | Contact CRUD, JSON/CSV import/export, responsibility lookups. |
| 9 | `tags`, `project_tags`, `project_media` added | Normalized project labels and app-owned media gallery. |
| 10 | UNIQUE index on `daily_reviews(review_date)`; Stage CRUD methods added (`addStage`, `updateStageTitle`, `deleteStage`, `reorderStage`) | Enables date-keyed upsert; v4 addColumn catches now typed `on SqliteException` (swallows only duplicate-column errors). |
| 11 | `project_registry`, `project_observations`, `project_scan_runs` added | Local Operations Registry v0.1: manual scan runs, append-only observations, and reviewed registry records. |
| 12 | `local_project_refresh_items` added | Local Project Refresh Profiles v0.1: idempotent manual preview/apply imports from reviewed local project docs/media into Atlas-native rows. |
| 13 | `work_item_tags` added | Many-to-many task tag assignments for the Today task list and project-linked task filtering. |
| 14 | `project_git_remotes` added | Read-only cached GitHub remote metadata for linked projects; raw SQL compatibility table, not generated Drift table in this slice. |
| 15 | `project_enrichment_runs`, `project_enrichment_findings` added | Atlas-only enrichment run history and open exception/completeness findings for linked local projects; raw SQL compatibility tables in this slice. |
| 16 | `project_enrichment_steps`, `project_enrichment_proposals` added | Worker-level enrichment step/proposal ledger for agent-array and loop workflow runs; raw SQL compatibility tables. |
| 17 | `llm_task_queue` added | Persisted MCP/local harness queue with claim/complete/fail lifecycle, operator edit/cancel/requeue controls, and optional review-draft handoff linkage. |
| 18 | `projects.category`, `media_links` added | Free-text project grouping plus reusable project media attachments for work items and queued LLM tasks. |

**Migration strategy:** `onCreate` calls `createAll()`. `onUpgrade` applies changes sequentially by version. `addColumn` calls are wrapped in typed `on SqliteException` catches (v4+) that only swallow duplicate-column errors and rethrow anything else. New tables use `CREATE TABLE IF NOT EXISTS` in the startup repair path.

---

## 9. Known Limitations / Future Work

| Area | Current state | Detail |
|------|---------------|--------|
| Database encryption | Plaintext SQLite | No encryption library included. SQLCipher was removed (package was EOL). Encryption planned for a future release. |
| `accepted` field on drafts | Schema exists, unused | Reserved for an approval workflow. |
| Drafts first-class route | Table + Library filter exist; no dedicated route | Planned as next phase. |
| Inbound Telegram | Not implemented | `/done`, `/snooze`, `/add` commands planned. |
| Project bundle restore | Not implemented | Project bundle ZIP export exists; restore/import is deferred. |
| Operations automation | Manual plus explicit enrichment plus queued LLM handoff | Local Operations Registry has no background watcher, scheduled scan, autonomous harness execution, or BOH integration. `llm_task_queue` stores explicit queue/lease handoffs for future MCP harness workers, with operator edit/move/cancel/requeue controls in Project Detail. Workers still complete through reviewable output/proposal paths. Enrichment runs are operator-triggered or MCP-triggered Atlas-only DB updates. GitHub metadata refresh is explicit/read-only and cache-based. Registry rows stay separate from Atlas Projects unless linked. |
| `event_log` audit durability | Clearable operator log | Correlation IDs are persisted for multi-step traces, but Settings can still clear event rows; this is provenance, not immutable audit. |
| `stages.is_bottleneck` vs `app_meta` | Dual storage | GovernanceScreen reads `app_meta`; table column is historical. |
| Document/media file cleanup | Stored media files not deleted on media record delete | Manual via Open app data folder. `deleteDocument()` removes the copied document file; `deleteProjectMedia()` removes DB/link rows but leaves the copied media file. |
| `telegram_enabled` flag | Set but not enforced | `sendTodayToTelegram()` does not check this flag before sending. |
| PDF in-app rendering | External viewer only | `DocumentPreview` shows an "Open in system viewer" button for `.pdf`. `pdfx`/PDFium integration is a planned future milestone. |
| `.doc` (legacy Word) | External viewer only | No text extraction for binary `.doc` format. Only `.docx` (OOXML) supports paragraph text extraction. |
