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

**Written by:** `saveDraft()` — only after explicit "Save Draft" action by user  
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
| `id` | TEXT PK | | |
| `title` | TEXT | | Display name. |
| `original_filename` | TEXT | | File name at import time. |
| `stored_path` | TEXT? | null | App-owned copy path under app data directory. |
| `mime_type` | TEXT? | null | Set on import if detectable. |
| `extension` | TEXT? | null | Lowercase file extension without dot. |
| `project_id` | TEXT? | null | Optional project link. |
| `source` | TEXT? | null | Import origin note. |
| `status` | TEXT | `'imported'` | `imported\|draft\|archived` |
| `created_at` | DATETIME | | |
| `updated_at` | DATETIME | | |
| `metadata_json` | TEXT? | null | Arbitrary metadata blob. |
| `extracted_text` | TEXT? | null | Plain text content for search. |
| `rendered_markdown` | TEXT? | null | Cached markdown rendering. |
| `parse_error` | TEXT? | null | Non-null if parsing failed. |

**Written by:** `importDocument()`, document update methods  
**Read by:** `watchDocuments()` → `LibraryScreen`, `watchDocumentsForWorkItem()` → `WorkItemDetailSheet`, Ollama AI analysis  
**Quirks:** `stored_path` points to an app-owned copy. Original source file is not tracked after import.

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

## 3. Services

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

**`OllamaResult`:** `{ input: String, output: String?, kind: String, title: String, isSuccess: bool }`  
`output == null` or `isSuccess == false` means unavailable or empty. Never auto-applied.

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

## 4. Navigation

Router: `lib/app/router.dart` using `go_router`  
Shell: `lib/shared/widgets/atlas_shell.dart`

| Route | Screen | Requires active project? |
|-------|--------|-------------------------|
| `/today` | `TodayScreen` | Yes |
| `/projects` | `ProjectsScreen` | No |
| `/projects/:id` | `ProjectDetailScreen` | No |
| `/library` | `LibraryScreen` | No |
| `/settings` | `SettingsScreen` | No |
| `/` | `DashboardScreen` (legacy) | Yes |
| `/work` | `WorkScreen` (legacy) | Yes |
| `/review` | `ReviewScreen` (legacy) | Yes |
| `/export` | `ExportScreen` (legacy) | Yes |
| `/governance` | `GovernanceScreen` (legacy) | Yes |
| `/log` | `LogScreen` (legacy) | Yes |

**Gate logic:** `AtlasShell` checks `hasActiveProject`. If false and current route is not `/projects`, it redirects to `/projects` via `addPostFrameCallback`.  
**Quirk:** Initial location is `/today`. If no active project exists, the app immediately redirects to `/projects`.

---

## 5. Data Flows

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

---

## 6. Schema Migration History

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

## 7. Known Limitations / Future Work

| Area | Current state | Detail |
|------|---------------|--------|
| Database encryption | Plaintext SQLite | `sqlcipher_flutter_libs` is in pubspec but `db_open.dart` does not yet pass a passphrase. |
| `accepted` field on drafts | Schema exists, unused | Reserved for an approval workflow. |
| Drafts first-class route | Table + Library filter exist; no dedicated route | Planned as next phase. |
| Inbound Telegram | Not implemented | `/done`, `/snooze`, `/add` commands planned. |
| Project snapshots / export | Not implemented | Decision-log export planned. |
| `correlation_id` on event_log | Defined, never set | Reserved for multi-step tracing. |
| `stages.is_bottleneck` vs `app_meta` | Dual storage | GovernanceScreen reads `app_meta`; table column is historical. |
| Project media file cleanup | Stored files not deleted on record delete | Manual via Open app data folder. |
| `telegram_enabled` flag | Set but not enforced | `sendTodayToTelegram()` does not check this flag before sending. |
