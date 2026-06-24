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
| `status` | TEXT | `'active'` | Added v5. Values: `active\|paused\|blocked\|completed\|archived`. |
| `deleted_at` | DATETIME? | null | Added v5. Soft delete timestamp. |
| `delete_reason` | TEXT? | null | Added v5. Soft delete rationale. |
| `phase` | TEXT? | null | Added v6. Values: `idea\|design\|build\|test\|ship\|stabilize`. |
| `priority` | TEXT? | null | Added v6. Values: `low\|normal\|high\|urgent`. |
| `scope_included` | TEXT? | null | Added v6. In-scope narrative. |
| `scope_excluded` | TEXT? | null | Added v6. Out-of-scope narrative. |
| `outcome_summary` | TEXT? | null | Added v6. Post-project reflection field. |
| `lessons_learned` | TEXT? | null | Added v6. Post-project reflection field. |

**Written by:** `AppDb.createProject()`, `AppState.updateProject()`  
**Read by:** `watchProjects()`, `watchActiveProject()`, `ProjectsScreen`, `ProjectDetailScreen`, `DashboardScreen`, Ollama summarizer, Telegram formatter  
**Quirks:** `id` is set once; all updates use `UPDATE WHERE id = ?`. `deletedAt` column exists but the app currently uses `status = 'archived'` for soft-archival rather than the deleted_at path.

---

### `app_meta`

Key-value store for all runtime settings and active-state flags.

| Key pattern | Value | Written by | Read by | Notes / Quirks |
|-------------|-------|-----------|---------|----------------|
| `active_project_id` | project ID string | `setActiveProjectId()` | `watchActiveProject()`, router gate | Cleared only if the project is deleted. |
| `active_stage_id::{projectId}` | stage ID | `setActiveStageIdForProject()` | `watchActiveStageForProject()` | One key per project. |
| `is_bottleneck::{stageId}` | `'1'` or `'0'` | `setIsBottleneck()` | `GovernanceScreen` | Stored in app_meta (not in stages table); distinct from `stages.is_bottleneck` column. |
| `setting::telegram_bot_token` | bot token | `SettingsScreen → setSetting()` | `sendTodayToTelegram()` | Stored plaintext. Personal desktop use only. |
| `setting::telegram_chat_id` | chat ID | `SettingsScreen → setSetting()` | `sendTodayToTelegram()` | Can be personal or group chat. |
| `setting::telegram_enabled` | `'1'` or `'0'` | `SettingsScreen` | Informational (UI toggle), not enforced in send path | Toggle exists but `sendTodayToTelegram()` does not gate on this flag. |
| `setting::ollama_host` | URL string | `SettingsScreen → setSetting()` | `_buildOllama()` in `AppState` | Defaults to `http://localhost:11434` if null. |
| `setting::ollama_model` | model name | `SettingsScreen → setSetting()` | `_buildOllama()` in `AppState` | Defaults to `qwen3.5:9b` if null (Settings UI shows `mistral` as hint). |

**AppDb constants:** `kActiveProjectId`, `kTelegramBotToken`, `kTelegramChatId`, `kTelegramEnabled`, `kOllamaHost`, `kOllamaModel`  
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
| `kind` | TEXT | | `project_summary\|today_summary\|email_draft\|task_extract\|custom` |
| `title` | TEXT | | Display label. |
| `body` | TEXT | | Full AI output. |
| `created_at` | DATETIME | | |
| `updated_at` | DATETIME | | |
| `input_json` | TEXT? | null | Serialized prompt input for traceability. |
| `accepted` | BOOLEAN | `false` | Reserved — user approval flag; not currently enforced in any workflow. |

**Written by:** `saveDraft()` — called after explicit "Save Draft" action by user, and also called automatically for `kind='project_summary'` entries after background or on-demand structured summary generation  
**Read by:** `watchDrafts()` — Library screen (AI Drafts filter)  
**Quirks:** `accepted` field exists in schema but is unused. The Drafts route is not yet a first-class navigation destination; drafts are accessed via Library → type filter.

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
| `correlation_id` | TEXT? | Reserved for future multi-step tracing. |

**Written by:** `AppDb.logEvent()`, `AppDb.logError()`  
**Read by:** `watchRecentEvents()` → Settings → Activity Log, `clearEventLog()`  
**Quirks:** No rotation or size limit. Use "Clear event log" in Settings → Admin to prune. `correlation_id` is defined but never set in current code.

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
3. For `.txt`/`.csv`/`.json`: reads the file as a string into `extractedText`.
4. For `.md`: reads into `renderedMarkdown`.
5. For `.docx`: calls `extractDocxText(destPath)` from `document_extractor.dart`; stores result in `extractedText`.
6. Binary types (`.pdf`, `.doc`, `.jpg`, etc.): no extraction; both text columns remain null.

**Library entry model behavior:** `_LibraryEntry.fromDocument` in `library_screen.dart` sets `content = renderedMarkdown ?? extractedText`. If `content` is null and the entry has a `document` reference, `_EntryViewer` delegates rendering to `DocumentPreview`. Image extensions (`jpg`, `jpeg`, `png`, `gif`, `webp`, `bmp`) additionally receive `isMedia: true` + `mediaType: 'image'`, routing them to the `InteractiveViewer` image path.

**Quirks:** Moving or deleting the original source file does not affect the stored copy. Deleting a `documents` record does not delete the app-owned copy — clean up manually via Admin → Open app data folder.

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
| `media_type` | TEXT | `'file'` | `image\|video\|file` — used for thumbnail rendering. |
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

**Written by:** `addProjectMedia()`, `updateProjectMedia()`, `deleteProjectMedia()`, `setProjectCoverImage()`  
**Read by:** `watchProjectMedia()` → `ProjectDetailScreen` Media gallery  
**Quirks:** App-owned copies are stored under the app data directory. Deleting a media record does **not** auto-delete the copied file — cleanup is manual via "Open app data folder" in Admin.

---

## 2. AppState (ChangeNotifier)

Located at `lib/shared/models/app_state.dart`. Wraps `AppDb` and adds reactive streams plus business logic.

| Field | Type | Notes / Quirks |
|-------|------|----------------|
| `db` | `AppDb` | Direct DB access. Avoid using outside AppState except where a method gap exists. |
| `_activeProject` | `Project?` | Cached from `watchActiveProject()` subscription. |
| `activeProject` | `Project? getter` | Synchronous read from cache. May be stale for one frame after a project switch. |
| `hasActiveProject` | `ValueNotifier<bool>` | Router uses this for nav gating. Updated on every active-project stream event. |

**Background refresh:** The constructor schedules `Future.delayed(10s, _backgroundSummaryRefresh)`. On startup this quietly pre-generates structured summaries for all active projects (once per day per project, skips if Ollama is unavailable).

**`_backgroundSummaryRefresh()`** — private async method; checks Ollama availability, iterates active projects, skips if today's draft already exists, calls `summarizeProjectFull()`, applies a 3 s delay between projects.

**New AppState methods:**

| Method | Returns | Notes |
|--------|---------|-------|
| `getLatestProjectSummaryDraft(projectId)` | `Future<Draft?>` | Delegate to `db.getLatestProjectSummaryDraft(projectId)`. |
| `getDocumentPathsForProject(projectId)` | `Future<Map<String, String?>>` | Delegate to `db.getDocumentPathsForProject(projectId)`. |
| `summarizeProjectFull(projectId)` | `Future<ProjectSummaryOutcome>` | Return type changed from `OllamaResult`. Now also fetches people, risks, decisions, and document excerpts (3000 chars/doc, 16000 total cap); auto-saves to Drafts on success. |

**Key exposed streams:**

| Stream | Returns | Notes |
|--------|---------|-------|
| `watchProjects()` | `Stream<List<Project>>` | All projects, ordered by created_at desc. |
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
| `watchProjectsFull()` | `Stream<List<ProjectFull>>` | Streams all projects with full metadata. Proxy for `db.watchProjectsFull()`. Used by `DashboardScreen`. |
| `watchSetting(key)` | `Stream<String?>` | Reactive app_meta read. |
| `watchWorkOwner(id)` | `Stream<String?>` | |
| `watchBottleneckOwner(id)` | `Stream<String?>` | |
| `watchIsBottleneck(id)` | `Stream<bool>` | From `app_meta` key `is_bottleneck::{id}`. |
| `watchRecentEvents()` | `Stream<List<EventLogData>>` | Last 500 events, most recent first. |

---

### ProjectDetailScreen state (`lib/features/projects/project_detail_screen.dart`)

| Variable | Type | Notes |
|----------|------|-------|
| `_summaryOutcome` | `ProjectSummaryOutcome?` | Holds the current structured summary for the active project. |
| `_summaryGeneratedAt` | `DateTime?` | When the summary was generated; used to render the age badge in the AI panel. |

**`_loadAll()` behavior:** On startup, loads the cached summary from Drafts (via `getLatestProjectSummaryDraft`), populates `_summaryOutcome` and `_summaryGeneratedAt`, and auto-expands the AI summary panel if a cached summary is found.

---

## 3. Document Extractor (`lib/db/document_extractor.dart`)

Standalone pure-Dart utility module. No Flutter dependency; fully unit-testable. Used by both `AppDb` (at import time) and `DocumentPreview` (at render time).

| Function | Signature | Notes |
|----------|-----------|-------|
| `extractDocxText(path)` | `String? Function(String path)` | Reads `.docx` bytes from disk, delegates to `extractDocxTextFromBytes`. Returns null on any I/O or parse failure. |
| `extractDocxTextFromBytes(bytes)` | `String? Function(List<int> bytes)` | Unzips the DOCX (ZIP format) via the `archive` package, finds `word/document.xml`, UTF-8 decodes it, parses XML via the `xml` package, extracts all `<w:t>` inner text nodes with `<w:p>` paragraph separators. Returns null on failure. |
| `mimeTypeForExtension(ext)` | `String? Function(String? ext)` | Calls `lookupMimeType('file.$ext')` from the `mime` package. Returns null for null input or unknown extensions. Used by `AppDb.importDocumentFromPath` and `AppDb.addProjectMedia`. |
| `stripEmlBody(raw)` | `String Function(String raw)` | Splits the EML string on newlines, discards all lines up to and including the first blank line (RFC-2822 header/body separator), returns trimmed body. Used by `DocumentPreview` for `.eml` files. |

**Tests:** `test/document_extractor_test.dart` — covers DOCX extraction (valid, invalid, empty, multi-paragraph, UTF-8), MIME lookup (common types, null, unknown), and EML body stripping (headers present, no body, body-only input).

---

## 5. Services

### OllamaService (`lib/services/ollama_service.dart`)

| Field | Source | Default | Quirks |
|-------|--------|---------|--------|
| `host` | `AppDb.kOllamaHost` from AppMeta | `http://localhost:11434` | Configurable in Settings → Integrations. |
| `model` | `AppDb.kOllamaModel` from AppMeta | `qwen3.5:9b` | Settings UI shows `mistral` as hint; actual default in code is `qwen3.5:9b`. |

| Method | Input | Output | Notes |
|--------|-------|--------|-------|
| `isAvailable()` | — | `bool` | GET to `/api/tags`. Timeout: 4 s. Checks server reachability only, not model presence. |
| `isModelAvailable()` | — | `bool` | Parses `/api/tags` model list; prefix-matches `model` (handles `:tag` suffixes). |
| `getAvailableModels()` | — | `List<String>` | Returns all installed model names sorted alphabetically. Returns `[]` if Ollama unreachable. Used by Settings → Integrations model dropdown. |
| `summarizeProject(...)` | project title, active/blocked/done work item titles | `OllamaResult` | Includes `desired_outcome` and `success_criteria` in system prompt if set. |
| `summarizeToday(...)` | doing/overdue/dueToday/blocked item titles | `OllamaResult` | |
| `draftEmail(...)` | task context + user instruction | `OllamaResult` | |
| `extractTasksFromNote(...)` | raw text, project title | `OllamaResult` | |
| `analyzeWorkItem(...)` | work item fields + linked document text | `OllamaResult` | Read-only; does not mutate any record. |
| `summarizeProjectStructured({required ProjectSummaryContext context})` | `ProjectSummaryContext` | `({OllamaResult result, ProjectSummaryResult? parsed})` | Structured JSON summary via `format:"json"`, low temperature. Uses `_chatStructured`. |

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
| `ProjectSummaryContextDoc` | `id, title, extension?, excerpt?` | Document reference with optional text excerpt. |
| `ProjectSummaryContext` | `id, title, description?, desiredOutcome?, successCriteria?, status, phase?, priority?, owner?, workItems, people, risks, decisions, documents` | Top-level input aggregate. Has `toPromptText()` method that serializes all fields to a human-readable prompt string. |

Output models:

| Class | Fields | Notes |
|-------|--------|-------|
| `ProjectSummaryOwnershipItem` | `person, work: List<String>, basis?` | Ownership breakdown entry within a structured result. |
| `ProjectSummaryDocumentRef` | `documentId, title, reason` | Document reference with relevance rationale. |
| `ProjectSummaryResult` | `goal: List<String>, currentState, ownership, relevantDocuments, blockersAndRisks, nextActions, confidence` | Parsed structured output. Has `fromJson(Map)` factory and `tryParse(String?)` static method. `tryParse` strips `<think>…</think>` blocks (Qwen reasoning models), removes markdown fences, extracts the outermost JSON object, and returns null on failure. |

Return type:

| Class | Fields / Getters | Notes |
|-------|-----------------|-------|
| `ProjectSummaryOutcome` | `rawOutput?, structured?, documentPaths?`; `hasStructured` getter; `isSuccess` getter | `isSuccess` is true if `structured != null` OR `rawOutput` is non-null and non-error. |

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
  → FilePicker.platform.pickFiles(allowedExtensions: [txt,md,json,csv,pdf,docx,doc,html,htm,eml,jpg,jpeg,png,gif,webp,bmp])
  → AppState.importDocumentFromPath(path)
    → AppDb.importDocumentFromPath(path, {projectId})
      → File(path).existsSync()  ← throws FileSystemException if missing
      → File.copy(destPath)      ← destPath = atlas_documents/<id>.<ext>
      → mimeTypeForExtension(ext) ← document_extractor.dart
      → if txt/csv/json: File(destPath).readAsString() → extractedText
      → if md: File(destPath).readAsString() → renderedMarkdown
      → if docx: extractDocxText(destPath) → extractedText
        → ZipDecoder().decodeBytes(bytes)
        → archive.findFile('word/document.xml')
        → XmlDocument.parse(utf8.decode(content))
        → collect <w:t> nodes, separate <w:p> with newlines
      → INSERT INTO documents (storedPath=destPath, mimeType, extractedText, renderedMarkdown, ...)
  → watchDocuments() stream fires → LibraryScreen rebuilds
  → _LibraryEntry.fromDocument(d)
      → if ext in {jpg,jpeg,png,gif,webp,bmp}: isMedia=true, mediaType='image'
      → content = d.renderedMarkdown ?? d.extractedText
  → _EntryViewer renders:
      → mediaType='image' → InteractiveViewer(Image.file)
      → content != null  → SelectableText(content)
      → document != null → DocumentPreview(document)
          → ext='md'          → Markdown widget
          → ext='json'        → _CodeBlock (pretty-printed)
          → ext='html'/'htm'  → Html widget (flutter_html)
          → ext='eml'         → _CodeBlock(stripEmlBody(body))
          → ext='txt'/'csv'   → _CodeBlock(body)
          → ext='pdf'         → _ExternalViewerPrompt (url_launcher)
          → ext='docx'/'doc'  → _CodeBlock(body) if content, else _ExternalViewerPrompt
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

**Migration strategy:** `onCreate` calls `createAll()`. `onUpgrade` applies changes sequentially by version. `addColumn` calls are wrapped in typed `on SqliteException` catches (v4+) that only swallow duplicate-column errors and rethrow anything else. New tables use `CREATE TABLE IF NOT EXISTS` in the startup repair path.

---

## 9. Known Limitations / Future Work

| Area | Current state | Detail |
|------|---------------|--------|
| Database encryption | Plaintext SQLite | `sqlcipher_flutter_libs` is in pubspec but `db_open.dart` does not yet pass a passphrase. |
| `accepted` field on drafts | Schema exists, unused | Reserved for an approval workflow. |
| Drafts first-class route | Table + Library filter exist; no dedicated route | Planned as next phase. |
| Inbound Telegram | Not implemented | `/done`, `/snooze`, `/add` commands planned. |
| Project snapshots / export | Not implemented | Decision-log export planned. |
| `correlation_id` on event_log | Defined, never set | Reserved for multi-step tracing. |
| `stages.is_bottleneck` vs `app_meta` | Dual storage | GovernanceScreen reads `app_meta`; table column is historical. |
| Document/media file cleanup | Stored files not deleted on record delete | Manual via Open app data folder. Affects both `documents` and `project_media`. |
| `telegram_enabled` flag | Set but not enforced | `sendTodayToTelegram()` does not check this flag before sending. |
| PDF in-app rendering | External viewer only | `DocumentPreview` shows an "Open in system viewer" button for `.pdf`. `pdfx`/PDFium integration is a planned future milestone. |
| `.doc` (legacy Word) | External viewer only | No text extraction for binary `.doc` format. Only `.docx` (OOXML) supports paragraph text extraction. |
